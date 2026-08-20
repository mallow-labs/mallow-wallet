import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:three_js/three_js.dart' as three;

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import 'carousel_focus.dart';

/// When true (via `--dart-define=E2E_DISABLE_GL=true`), the 3D carousel skips
/// its three_js/flutter_angle GL backend and renders the existing non-GL
/// fallback instead. Set only in automated device tests: flutter_angle needs a
/// real GPU/ANGLE driver and hard-crashes (native `UnsatisfiedLinkError` on
/// `FlutterAnglePlugin.init`) on headless software-GL emulators. The ring is
/// decorative, so tests lose nothing.
const bool kE2eDisableGl = bool.fromEnvironment('E2E_DISABLE_GL');

/// A 3D perspective carousel that displays artwork cards in a circular arrangement.
///
/// Ported from React Three Fiber PerspectiveArtworkCarousel with:
/// - Cards in circular arrangement (configurable radius, default 7.0)
/// - Auto-rotation with configurable speed
/// - Drag interaction for manual rotation
/// - Axis tilt: X=18°, Z=20° (perspective view)
/// - Camera: position [0, -2, 40], FOV 50°
/// - Curved geometry: radius-based concentric curve with rounded corners
/// - Card dimensions: 4x5 (portrait, configurable)
/// - Responsive sizing via LayoutBuilder
class PerspectiveCarousel3D extends StatefulWidget {
  const PerspectiveCarousel3D({
    super.key,
    this.imageUrls = const [],
    this.assetPaths,
    this.artworkInfos,
    this.radius = 7.0,
    this.rotationSpeed = 0.181125,
    this.cardWidth = 4.0,
    this.cardHeight = 5.0,
  });
  final List<String> imageUrls;
  final List<String>? assetPaths;

  /// Title + artist per card, index-aligned with [assetPaths] / [imageUrls].
  /// When provided, a caption strip below the ring shows the card currently
  /// closest to the camera, cross-fading as the front card changes. GL mode
  /// only — the non-GL fallback spins on its own clock the captions cannot
  /// track, so it renders without them.
  final List<CarouselArtworkInfo>? artworkInfos;
  final double radius;
  final double rotationSpeed;
  final double cardWidth;
  final double cardHeight;

  @override
  State<PerspectiveCarousel3D> createState() => _PerspectiveCarousel3DState();
}

/// Everything the caption strip shows: which card is in front and how opaque
/// its caption is. Both derive from the ring rotation, but change far more
/// slowly than it does — the index holds for a whole segment and the opacity
/// sits at exactly 1 outside the fade band. Records compare by value, so a
/// [ValueNotifier] of this record notifies only when a caption pixel would
/// actually move, not on every rendered frame.
typedef _CaptionState = ({int frontIndex, double opacity});

class _PerspectiveCarousel3DState extends State<PerspectiveCarousel3D> {
  late three.ThreeJS threeJs;
  three.Group? carouselGroup;
  double rotationY = 0;
  bool isDragging = false;
  double dragStartX = 0;
  double dragStartRotation = 0;
  bool isInitialized = false;
  bool initFailed = false;

  /// Derived from [rotationY] once per rendered frame so the caption strip (a
  /// normal Flutter subtree) can follow the GL animation loop. The GL cards
  /// read [rotationY] directly, so this carries only what the caption needs.
  final ValueNotifier<_CaptionState> _captionNotifier = ValueNotifier((
    frontIndex: 0,
    opacity: 0,
  ));

  // Inertia physics. Velocity is in radians/second; the decay factor is the
  // fraction of velocity remaining after one second (0.95/frame at 60fps).
  double velocityY = 0;
  static const double frictionPerSecond = 0.046;

  /// How far the front card rises (world units) and grows at full focus.
  /// Both are driven by [CarouselFocus.focusStrength], a pure function of the
  /// ring angle — so the ease always runs at the speed of the spin itself.
  static const double _focusLift = 0.55;
  static const double _focusScale = 0.10;

  // Axis tilt (degrees to radians)
  final double axisRotationX = (20 * math.pi) / 180; // 18 degrees
  final double axisRotationZ = (14 * math.pi) / 180; // 12 degrees

  @override
  void initState() {
    super.initState();
    // Seed the caption with the pose at rotation 0, so the strip's first paint
    // matches the first animated frame instead of flashing a different card.
    _updateCaptionState();
    if (kE2eDisableGl) {
      // Headless E2E: skip the GL backend and route to the non-GL fallback.
      initFailed = true;
    } else {
      _initThreeJs();
    }
  }

  void _initThreeJs() {
    threeJs = three.ThreeJS(
      onSetupComplete: () {
        if (mounted) {
          setState(() {
            isInitialized = true;
          });
        }
      },
      setup: _setup,
      settings: three.Settings(clearAlpha: 0),
    );
  }

  Future<void> _setup() async {
    try {
      // Camera: position [0, -2, 40], FOV 50
      threeJs.camera = three.PerspectiveCamera(30, 1, 0.1, 1000);
      threeJs.camera.position.setValues(0, -2, 30);

      // Scene
      threeJs.scene = three.Scene();

      // Lighting — bright ambient base so off-axis cards never go murky;
      // directional sits at the camera shifted up + right so the ring has a
      // soft key light from the viewer's perspective.
      final ambient = three.AmbientLight(0xffffff, 1.3);
      threeJs.scene.add(ambient);

      final directional = three.DirectionalLight(0xffffff, 0.6);
      // Camera is at (0, -2, 30); offset right (+x) and up (+y) from there.
      directional.position.setValues(6, 4, 30);
      threeJs.scene.add(directional);

      // Carousel group with axis tilt
      carouselGroup = three.Group();
      carouselGroup!.rotation.x = axisRotationX;
      carouselGroup!.rotation.z = axisRotationZ;
      threeJs.scene.add(carouselGroup!);

      // Create cards
      await _createCards();

      // Animation loop. dt is seconds since the last frame (three_js Clock),
      // so speeds are radians/second and identical on 60Hz and 120Hz
      // displays. Clamped so a resume-from-background spike cannot jump the
      // ring by a visible arc in one frame.
      threeJs.addAnimationEvent((dt) {
        final step = dt.clamp(0.0, 1 / 15);
        if (!isDragging) {
          // 0.6 rad/s at rotationSpeed 1.0 — the former 0.01 rad/frame @60fps.
          final autoSpeed = 0.6 * widget.rotationSpeed;

          // Smooth handoff: resume auto-rotation when velocity matches
          // - Same direction (positive): when speed decays to auto speed
          // - Opposite direction (negative): when nearly stopped
          final shouldResumeAuto =
              (velocityY >= 0 && velocityY <= autoSpeed) ||
              (velocityY < 0 && velocityY > -0.03);

          if (shouldResumeAuto) {
            velocityY = 0;
            rotationY += autoSpeed * step;
          } else {
            // Apply inertia with decay
            rotationY += velocityY * step;
            velocityY *= math.pow(frictionPerSecond, step);
          }
        }
        _updateCaptionState();
        _updateCardPositions();
      });
    } catch (e) {
      debugPrint('three_js setup failed: $e');
      if (mounted) {
        setState(() {
          initFailed = true;
        });
      }
    }
  }

  /// Returns the list of image sources (asset paths take priority over URLs)
  List<String> get _imageSources => widget.assetPaths ?? widget.imageUrls;

  Future<void> _createCards() async {
    final sources = _imageSources;
    final total = sources.length;
    if (total == 0) return;

    // Load ALL textures in parallel for faster loading
    final textures = await Future.wait(
      sources.map((source) => _loadTexture(source)).toList(),
    );

    // Create cards with pre-loaded textures (sync)
    for (int i = 0; i < total; i++) {
      final cardGroup = _createCardWithTexture(i, total, textures[i]);
      carouselGroup!.add(cardGroup);
    }
  }

  /// Loads a texture from either an asset path or network URL.
  ///
  /// Tags the texture as sRGB so the renderer applies the proper
  /// sRGB→linear→sRGB round-trip. Without this, sRGB-encoded source
  /// images are sampled as linear and look washed out (lifted blacks,
  /// flattened mids).
  Future<three.Texture?> _loadTexture(String source) async {
    try {
      final three.Texture? texture;
      if (source.startsWith('assets/')) {
        texture = await three.TextureLoader().fromAsset(source);
      } else {
        texture = await three.TextureLoader().fromNetwork(Uri.parse(source));
      }
      if (texture != null) {
        texture.colorSpace = three.SRGBColorSpace;
      }
      return texture;
    } catch (e) {
      debugPrint('Failed to load texture: $e');
      return null;
    }
  }

  /// Creates a card group with a pre-loaded texture (synchronous)
  three.Group _createCardWithTexture(
    int index,
    int total,
    three.Texture? texture,
  ) {
    final group = three.Group();

    // Create curved card geometry with rounded corners
    final frontGeom = _createCurvedCardGeometry();
    final backGeom = _createCurvedCardGeometry(isBack: true);

    // Front mesh — Lambert so AmbientLight + DirectionalLight shade the card
    // as it rotates through the ring. Geometry already has vertex normals
    // (see _createCurvedCardGeometry), so per-fragment Lambert shading just works.
    final frontMat = three.MeshLambertMaterial.fromMap({
      'map': texture,
      'color': 0xffffff,
      'side': three.FrontSide,
    });
    final frontMesh = three.Mesh(frontGeom, frontMat);
    frontMesh.position.z = 0.01;
    group.add(frontMesh);

    // Back mesh — same lit material with a darker tint so the inverse curve
    // reads as the back of the card under ambient.
    final backMat = three.MeshLambertMaterial.fromMap({
      'map': texture,
      'color': 0x606060,
      'side': three.FrontSide,
    });
    final backMesh = three.Mesh(backGeom, backMat);
    backMesh.position.z = -0.01;
    backMesh.rotation.y = math.pi;
    group.add(backMesh);

    // Store index for positioning
    group.userData['index'] = index;
    group.userData['total'] = total;

    return group;
  }

  /// Creates a curved card geometry with inward curve and rounded corners.
  /// Ported from React Three Fiber implementation.
  /// Uses 32 segments for smooth curves, radius-based concentric curve.
  ///
  /// [isBack] inverts the curve direction for the back face to create proper
  /// 3D depth perception (back curves away from center).
  three.BufferGeometry _createCurvedCardGeometry({bool isBack = false}) {
    const segments = 32;
    const cornerRadius = 0.25;

    final width = widget.cardWidth;
    final height = widget.cardHeight;
    final halfW = width / 2;
    final halfH = height / 2;

    // Create vertices for curved plane with rounded corners
    final vertices = <double>[];
    final uvs = <double>[];
    final indices = <int>[];

    const xSegments = segments;
    final ySegments = (segments * height / width).round();

    // Generate vertices (match React's nested loop structure)
    for (int i = 0; i <= xSegments; i++) {
      final u = i / xSegments;

      for (int j = 0; j <= ySegments; j++) {
        final v = j / ySegments;

        // Map to card coordinates
        final double localX = (u - 0.5) * width;
        final double localY = (v - 0.5) * height;

        // Apply rounded corners (match React's corner detection)
        final distFromLeft = localX + halfW;
        final distFromRight = halfW - localX;
        final distFromTop = halfH - localY;
        final distFromBottom = localY + halfH;

        double adjustedX = localX;
        double adjustedY = localY;

        // Top-left corner
        if (distFromLeft < cornerRadius && distFromTop < cornerRadius) {
          final cornerX = -halfW + cornerRadius;
          final cornerY = halfH - cornerRadius;
          final dx = localX - cornerX;
          final dy = localY - cornerY;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > cornerRadius) {
            final angle = math.atan2(dy, dx);
            adjustedX = cornerX + cornerRadius * math.cos(angle);
            adjustedY = cornerY + cornerRadius * math.sin(angle);
          }
        }
        // Top-right corner
        else if (distFromRight < cornerRadius && distFromTop < cornerRadius) {
          final cornerX = halfW - cornerRadius;
          final cornerY = halfH - cornerRadius;
          final dx = localX - cornerX;
          final dy = localY - cornerY;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > cornerRadius) {
            final angle = math.atan2(dy, dx);
            adjustedX = cornerX + cornerRadius * math.cos(angle);
            adjustedY = cornerY + cornerRadius * math.sin(angle);
          }
        }
        // Bottom-left corner
        else if (distFromLeft < cornerRadius && distFromBottom < cornerRadius) {
          final cornerX = -halfW + cornerRadius;
          final cornerY = -halfH + cornerRadius;
          final dx = localX - cornerX;
          final dy = localY - cornerY;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > cornerRadius) {
            final angle = math.atan2(dy, dx);
            adjustedX = cornerX + cornerRadius * math.cos(angle);
            adjustedY = cornerY + cornerRadius * math.sin(angle);
          }
        }
        // Bottom-right corner
        else if (distFromRight < cornerRadius &&
            distFromBottom < cornerRadius) {
          final cornerX = halfW - cornerRadius;
          final cornerY = -halfH + cornerRadius;
          final dx = localX - cornerX;
          final dy = localY - cornerY;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > cornerRadius) {
            final angle = math.atan2(dy, dx);
            adjustedX = cornerX + cornerRadius * math.cos(angle);
            adjustedY = cornerY + cornerRadius * math.sin(angle);
          }
        }

        // Calculate curve - React uses radius-based concentric curve
        final angleOffset = adjustedX / widget.radius;
        const centerZ = 0.0;
        final curveZ = widget.radius * (1 - math.cos(angleOffset));
        // Invert curve direction for back face (back curves away from center)
        final z = isBack ? centerZ - curveZ : centerZ + curveZ;

        vertices.addAll([adjustedX, adjustedY, z]);
        uvs.addAll([u, 1 - v]); // Flip V for correct texture orientation
      }
    }

    // Create triangle indices (match React's loop order)
    for (int i = 0; i < xSegments; i++) {
      for (int j = 0; j < ySegments; j++) {
        final a = i * (ySegments + 1) + j;
        final b = a + 1;
        final c = a + (ySegments + 1);
        final d = c + 1;

        indices.addAll([a, b, c]);
        indices.addAll([b, d, c]);
      }
    }

    final geometry = three.BufferGeometry();
    geometry.setAttributeFromString(
      'position',
      three.Float32BufferAttribute.fromList(vertices, 3),
    );
    geometry.setAttributeFromString(
      'uv',
      three.Float32BufferAttribute.fromList(uvs, 2),
    );
    geometry.setIndex(indices);
    geometry.computeVertexNormals();

    return geometry;
  }

  /// Recomputes what the caption strip shows at the current [rotationY].
  ///
  /// Runs every frame beside [_updateCardPositions], but the notifier compares
  /// the record by value: rotation that only moves the cards leaves the
  /// caption subtree — and its font lookups — untouched.
  void _updateCaptionState() {
    final total = _imageSources.length;
    if (total == 0) return;
    _captionNotifier.value = (
      frontIndex: CarouselFocus.frontIndex(total, rotationY),
      opacity: CarouselFocus.captionOpacity(total, rotationY),
    );
  }

  void _updateCardPositions() {
    if (carouselGroup == null) return;

    for (final child in carouselGroup!.children) {
      final index = child.userData['index'] as int?;
      final total = child.userData['total'] as int?;
      if (index == null || total == null) continue;

      final currentAngle = CarouselFocus.cardAngle(index, total, rotationY);

      final x = math.cos(currentAngle) * widget.radius;
      final z = math.sin(currentAngle) * widget.radius;

      // Angle-driven focus: the card nearest the camera eases up and grows as
      // a pure function of its ring position, so the transition runs at the
      // speed of the spin itself — auto-rotation or a finger drag alike.
      final focus = CarouselFocus.focusStrength(index, total, rotationY);
      // -1.0 base: match React, position cards slightly lower in viewport.
      final y = -1.0 + focus * _focusLift;
      final s = 1.0 + focus * _focusScale;

      child.position.setValues(x, y, z);
      child.scale.setValues(s, s, s);

      // Face inward (rotate card to face toward center)
      final dx = 0 - x; // centerX - x
      final dz = 0 - z; // centerZ - z
      final faceInwardRotation = math.atan2(dx, dz);
      child.rotation.y = faceInwardRotation;
    }
  }

  /// Fixed caption-strip height so opacity changes never shift layout.
  static const double _captionHeight = 42;

  @override
  Widget build(BuildContext context) {
    final infos = widget.artworkInfos;
    final ring = _buildRing();
    // Captions need the GL rotation stream; the non-GL fallback spins on its
    // own clock, so it renders without the strip (initFailed covers E2E too).
    if (infos == null || infos.isEmpty || initFailed || _imageSources.isEmpty) {
      return ring;
    }
    return Column(
      children: [
        Expanded(child: ring),
        const SizedBox(height: MallowTheme.spacingSm),
        SizedBox(
          height: _captionHeight,
          // Reserve the strip during GL setup, fill it once frames flow.
          child: isInitialized
              // Visual nudge toward the ring; translate instead of shrinking
              // the gap so the reserved strip height stays layout-stable.
              ? Transform.translate(
                  offset: const Offset(0, -20),
                  child: _CarouselCaption(
                    caption: _captionNotifier,
                    infos: infos,
                  ),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildRing() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive sizing: use available width, height proportional (~1.2x width)
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : screenWidth * 0.9;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : screenHeight * 0.45;

        // Show fallback if initialization failed or no images
        if (initFailed || _imageSources.isEmpty) {
          return SizedBox(
            height: height,
            width: width,
            child: _buildFallbackCarousel(),
          );
        }

        return GestureDetector(
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: SizedBox(
            height: height,
            width: width,
            child: Stack(
              children: [
                // Keep the GL surface in the tree so setup can run,
                // but hide it until the first transparent clear so
                // the loading state sits over the Scaffold bg only.
                Opacity(
                  opacity: isInitialized ? 1.0 : 0.0,
                  child: threeJs.build(),
                ),
                if (!isInitialized) _buildLoadingIndicator(),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onDragStart(DragStartDetails details) {
    isDragging = true;
    dragStartX = details.localPosition.dx;
    dragStartRotation = rotationY;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final deltaX = details.localPosition.dx - dragStartX;
    rotationY = dragStartRotation + deltaX * -0.005;
  }

  void _onDragEnd(DragEndDetails details) {
    isDragging = false;
    // Capture flick velocity and convert to rotation speed (rad/s; the former
    // 0.00008 rad/frame @60fps). Negative because drag direction is inverted
    // for rotation.
    velocityY = details.velocity.pixelsPerSecond.dx * -0.0048;
  }

  Widget _buildLoadingIndicator() {
    return const Center(child: MallowLoader());
  }

  /// Fallback 2D carousel when 3D fails
  Widget _buildFallbackCarousel() {
    final sources = _imageSources;
    final cardCount = sources.isEmpty ? 6 : sources.length;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(seconds: 30),
      builder: (context, value, child) {
        return Stack(
          alignment: Alignment.center,
          children: List.generate(cardCount, (index) {
            final angle =
                (2 * math.pi / cardCount) * index + (value * 2 * math.pi);
            final x = math.cos(angle) * 100;
            final z = math.sin(angle);
            final scale = 0.6 + (z + 1) * 0.2;

            final String? assetPath;
            final String? imageUrl;
            if (sources.isNotEmpty && index < sources.length) {
              final source = sources[index];
              if (source.startsWith('assets/')) {
                assetPath = source;
                imageUrl = null;
              } else {
                assetPath = null;
                imageUrl = source;
              }
            } else {
              assetPath = null;
              imageUrl = 'https://picsum.photos/200/150?random=$index';
            }

            const cardWidth = 120.0;
            const cardHeight = 90.0;
            const cardRadius = BorderRadius.all(Radius.circular(8));
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final assetCacheWidth = (cardWidth * dpr).ceil();

            final Widget card = assetPath != null
                ? ClipRRect(
                    borderRadius: cardRadius,
                    child: Image.asset(
                      assetPath,
                      width: cardWidth,
                      height: cardHeight,
                      fit: BoxFit.cover,
                      cacheWidth: assetCacheWidth,
                    ),
                  )
                : MallowNetworkImage(
                    imageUrl: imageUrl!,
                    logicalSize: cardWidth,
                    width: cardWidth,
                    height: cardHeight,
                    borderRadius: cardRadius,
                  );

            return Transform(
              transform: Matrix4.identity()
                ..setTranslationRaw(x, 0.0, 0.0)
                ..scaleByDouble(scale, scale, 1.0, 1.0),
              alignment: Alignment.center,
              child: Opacity(
                opacity: 0.4 + (z + 1) * 0.3,
                child: SizedBox(
                  width: cardWidth,
                  height: cardHeight,
                  child: card,
                ),
              ),
            );
          }),
        );
      },
    );
  }

  @override
  void dispose() {
    // `threeJs` is never initialized when the GL backend is skipped for E2E.
    // Disposed first so its animation loop stops writing to the notifier.
    if (!kE2eDisableGl) threeJs.dispose();
    _captionNotifier.dispose();
    super.dispose();
  }
}

/// Caption for the card closest to the camera: artwork title over the
/// artist's mallow username. Both which card is front and how opaque the
/// caption is derive from the ring's per-frame rotation, so the cross-fade
/// runs at the speed of the spin and the text swaps at the segment boundary,
/// where opacity is exactly 0.
class _CarouselCaption extends StatelessWidget {
  const _CarouselCaption({required this.caption, required this.infos});

  /// The front card and its opacity. The ring can hold more cards than [infos]
  /// credits, in which case an uncredited card shows no caption.
  final ValueListenable<_CaptionState> caption;
  final List<CarouselArtworkInfo> infos;

  @override
  Widget build(BuildContext context) {
    // Built here, not in the builder below: the styles depend on the theme,
    // never on the rotation, and resolving the font on every frame is the one
    // thing that made the caption expensive.
    final colors = context.mallowColors;
    final titleStyle = GoogleFonts.newsreader(
      fontSize: 15,
      fontStyle: FontStyle.italic,
      fontWeight: FontWeight.w500,
      color: colors.textPrimary,
    );
    final artistStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );
    return ValueListenableBuilder<_CaptionState>(
      valueListenable: caption,
      builder: (context, state, _) {
        if (state.frontIndex >= infos.length) return const SizedBox.shrink();
        final info = infos[state.frontIndex];
        return Opacity(
          opacity: state.opacity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                info.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              const SizedBox(height: 2),
              Text(
                '@${info.artist}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: artistStyle,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Title + mallow username for one carousel card.
class CarouselArtworkInfo {
  const CarouselArtworkInfo({required this.title, required this.artist});

  final String title;

  /// mallow username, rendered as `@artist`.
  final String artist;
}

/// Default carousel asset paths for instant loading
const List<String> kDefaultCarouselAssets = [
  'assets/images/carousel/carousel_1.webp',
  'assets/images/carousel/carousel_2.webp',
  'assets/images/carousel/carousel_3.webp',
  'assets/images/carousel/carousel_4.webp',
  'assets/images/carousel/carousel_5.webp',
  'assets/images/carousel/carousel_6.webp',
  'assets/images/carousel/carousel_7.webp',
  'assets/images/carousel/carousel_8.webp',
  'assets/images/carousel/carousel_9.webp',
];

/// Captions for [kDefaultCarouselAssets], index-aligned with it.
///
/// 🛑 The single source of truth for who is credited for the carousel art: the
/// About screen builds its artist credits from this list, so an artist named
/// here is credited there. The credit is required, not decorative. Keep the
/// attribution table in `THIRD_PARTY_NOTICES.md` in sync by hand — it maps the
/// same nine files to these titles and artists.
const List<CarouselArtworkInfo> kDefaultCarouselArtworks = [
  CarouselArtworkInfo(title: 'Sugar Rush', artist: 'trevelviz'),
  CarouselArtworkInfo(title: 'Lover 50', artist: 'wetiko'),
  CarouselArtworkInfo(title: 'Perenimals #406', artist: 'perenimals'),
  CarouselArtworkInfo(title: '#101', artist: 'solfriendssociety'),
  CarouselArtworkInfo(title: 'World', artist: 'degenpoet'),
  CarouselArtworkInfo(title: 'Taipan', artist: 'grey'),
  CarouselArtworkInfo(title: 'Cadence in Gold', artist: 'chronicpainting'),
  CarouselArtworkInfo(title: 'ZEKE', artist: 'scum'),
  CarouselArtworkInfo(title: 'Brand new SLAY', artist: 'amet'),
];
