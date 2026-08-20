import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/services/token_metadata_service.dart';
import '../../../../core/services/token_price_service.dart';
import '../../../../core/utils/price_formatter.dart';
import '../../../../core/utils/reduce_motion.dart';
import '../../../../di.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/token_image_utils.dart';
import '../../../../shared/widgets/mallow_sheet.dart';
import '../../../../shared/widgets/token_amount_text.dart';

/// Shared chrome for every artwork-detail bottom sheet variant: rounded top
/// corners, surface background + fab shadow, padded content, and a
/// bottom-safe inset. Layouts compose this with their own [child].
///
/// No drag handle — these sheets are pinned to the artwork detail screen
/// and can't be dismissed by gesture, so the affordance would mislead.
///
/// Variants documented in `docs/artwork_state.md`.
class ArtworkSheetFrame extends StatelessWidget {
  const ArtworkSheetFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
        boxShadow: MallowTheme.fabShadow(context),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacing20,
              MallowTheme.spacing20,
              MallowTheme.spacingMd,
            ),
            child: child,
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}

/// Renders the atomic [rawAmount] in [currencyMint]'s display units alongside
/// a live USD equivalent pulled from [TokenPriceService]. The USD line tracks
/// the service's [ValueListenable] so the value fills in (and refreshes every
/// 5 minutes) without the parent rebuilding.
class ArtworkSheetPriceRow extends StatelessWidget {
  const ArtworkSheetPriceRow({
    required this.rawAmount,
    required this.currencyMint,
    this.buyerSetsPrice = false,
    super.key,
  });

  final double? rawAmount;
  final String? currencyMint;

  /// True for a SYOP ("set your own price") listing. Its on-chain price is 0,
  /// so [rawAmount] carries no information — render the label instead of a
  /// bogus "0 SOL" (webapp `PriceDisplay` does the same off its `-1`
  /// sentinel). See [_priceWord] for the zero / absent cases.
  final bool buyerSetsPrice;

  /// The word this row shows in place of a figure, or null when there is a
  /// real amount to render.
  String? get _priceWord => PriceFormatter.listingPriceWord(
    rawAmount,
    buyerSetsPrice: buyerSetsPrice,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final priceService = sl<TokenPriceService>();

    return Row(
      children: [
        tokenImageWidget(
          mint: currencyMint ?? PriceFormatter.solMint,
          size: 20,
          enlargeChainGlyph: true,
          logoUrl: sl<TokenMetadataService>().imageUrlFor(currencyMint),
        ),
        const SizedBox(width: MallowTheme.spacingXs),
        // A price of 0 or none isn't a number the user should read as one:
        // the webapp swaps in a word ("Free" / "Not listed" / "Set your own
        // price" — `PriceDisplay`), and a USD conversion of it is
        // meaningless, so the estimate is dropped alongside the figure.
        if (_priceWord != null)
          Text(
            _priceWord!,
            style: MallowTheme.uiTitle.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          )
        else ...[
          TokenAmountText(
            rawAmount: rawAmount,
            currencyMint: currencyMint,
            // A registry token is identified by the glyph to the left, so the
            // figure stays bare exactly as before. A mint resolved at runtime
            // has no curated glyph to speak for it (the icon degrades to
            // initials), so its ticker rides with the number instead.
            withSymbol: sl<TokenMetadataService>().needsLookup(currencyMint),
            style: MallowTheme.uiTitle.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          ValueListenableBuilder<Map<String, double>>(
            valueListenable: priceService.prices,
            builder: (context, _, _) {
              final usd = priceService.usdValueOfRaw(rawAmount, currencyMint);
              if (usd == null) return const SizedBox.shrink();
              return Text(
                '\$${usd.toStringAsFixed(2)}',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// Linear "X of Y sold" progress bar. Shared by the buy sheet, edition sheet,
/// and raffle sheet.
class ArtworkSheetSupplyProgress extends StatelessWidget {
  const ArtworkSheetSupplyProgress({
    required this.sold,
    required this.total,
    this.spark = false,
    super.key,
  });

  final double sold;
  final double total;

  /// When true, a small looping ember burst is emitted from the tip of the
  /// filled bar — a "burning fuse" cue for a live auction countdown. Left off
  /// for the static supply bars (buy / edition sheets).
  final bool spark;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final fraction = total > 0 ? (sold / total).clamp(0.0, 1.0) : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final filledWidth = totalWidth * fraction;
        final remainingWidth = totalWidth - filledWidth;

        final bar = SizedBox(
          height: 4,
          child: Row(
            children: [
              if (filledWidth > 0)
                Container(
                  width: filledWidth,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(4),
                      bottomLeft: const Radius.circular(4),
                      topRight: fraction >= 1.0
                          ? const Radius.circular(4)
                          : Radius.zero,
                      bottomRight: fraction >= 1.0
                          ? const Radius.circular(4)
                          : Radius.zero,
                    ),
                  ),
                ),
              if (remainingWidth > 0)
                Container(
                  width: remainingWidth,
                  decoration: BoxDecoration(
                    color: colors.dividerLight,
                    borderRadius: BorderRadius.only(
                      topLeft: fraction <= 0.0
                          ? const Radius.circular(4)
                          : Radius.zero,
                      bottomLeft: fraction <= 0.0
                          ? const Radius.circular(4)
                          : Radius.zero,
                      topRight: const Radius.circular(4),
                      bottomRight: const Radius.circular(4),
                    ),
                  ),
                ),
            ],
          ),
        );

        // Sparks only make sense while the tip sits mid-track — at fraction 1
        // it's pinned to the far edge and would spray off-widget, at 0 there's
        // nothing left to burn.
        if (!spark || fraction <= 0.0 || fraction >= 1.0) {
          return bar;
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            bar,
            Positioned(
              // Anchor the emitter on the burning tip, vertically centred on
              // the 4px bar.
              left: filledWidth,
              top: 2,
              child: _FuseSpark(color: colors.accent),
            ),
          ],
        );
      },
    );
  }
}

/// A tiny looping ember burst painted at the tip of the auction countdown bar.
/// Purely decorative; runs off a single repeating controller and repaints via
/// [_FuseSparkPainter] without rebuilding the widget tree.
class _FuseSpark extends StatefulWidget {
  const _FuseSpark({required this.color});

  final Color color;

  @override
  State<_FuseSpark> createState() => _FuseSparkState();
}

class _FuseSparkState extends State<_FuseSpark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  // Seeded so the sequence is reproducible run-to-run, but the pattern still
  // evolves within a session as each ember re-rolls on rebirth.
  final math.Random _rng = math.Random(7);
  late final List<_Spark> _sparks;

  @override
  void initState() {
    super.initState();
    // Evenly stagger births across the loop so the emission rate is constant —
    // this is what makes it read as one continuous fuse rather than rhythmic
    // bursts. Each ember's angle/speed/size are rolled here and again on every
    // rebirth (see _rollSpark).
    _sparks = List.generate(_sparkCount, (i) {
      final spark = _Spark(phase: i / _sparkCount);
      _rollSpark(spark, _rng);
      return spark;
    });
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion freezes the ember loop on a single static frame; otherwise
    // run the decorative repeat. Guarded so hot reload / dependency changes
    // don't stack multiple repeats.
    if (context.reduceMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Zero-size anchor (CustomPaint's default) at the tip; the painter draws
    // outside these bounds and the parent Stack (Clip.none) lets the embers
    // overflow.
    return CustomPaint(
      painter: _FuseSparkPainter(
        progress: _controller,
        sparks: _sparks,
        color: widget.color,
        rng: _rng,
      ),
    );
  }
}

const _sparkCount = 14;
// Emit in every direction except a 30°-wide wedge centred on straight-left (π),
// so nothing shoots back along the unburnt fuse. Angles run counter-clockwise
// from right (0), so the allowed arc is the full circle minus ±15° around π:
// start just past the wedge and sweep the remaining 330°.
const _sparkExcludedHalf = math.pi / 12; // 15°
const _sparkAllowedSpan = 2 * math.pi - 2 * _sparkExcludedHalf; // 330°
const _sparkArcStart = math.pi + _sparkExcludedHalf; // just past left

/// (Re)assigns an ember's launch parameters. Called at birth and again every
/// time the ember is reborn, so no two flights of the same ember are identical
/// and the overall spray never visibly repeats. [phase] is deliberately NOT
/// touched — its even staggering is what keeps the emission continuous.
void _rollSpark(_Spark s, math.Random rng) {
  s.angle = _sparkArcStart + rng.nextDouble() * _sparkAllowedSpan;
  s.speed = 6.0 + rng.nextDouble() * 6.0; // px of travel per cycle
  s.size = 0.9 + rng.nextDouble() * 1.1;
}

/// One ember. [phase] is fixed for the ember's lifetime (even stagger →
/// continuous emission); angle/speed/size are re-rolled on each rebirth.
class _Spark {
  _Spark({required this.phase});

  final double phase;
  double angle = 0;
  double speed = 0;
  double size = 0;

  /// Previous frame's life value; a drop signals the ember wrapped (was reborn)
  /// so its parameters should be re-rolled.
  double lastLife = 0;
}

class _FuseSparkPainter extends CustomPainter {
  _FuseSparkPainter({
    required this.progress,
    required this.sparks,
    required this.color,
    required this.rng,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final List<_Spark> sparks;
  final Color color;
  final math.Random rng;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    for (final s in sparks) {
      final life = (t + s.phase) % 1.0;
      // A drop in life means the ember just wrapped past 1.0 (reborn) — re-roll
      // its trajectory so no two flights are identical and the spray never
      // visibly repeats. Safe as a paint-time side effect: repaint is driven
      // solely by the controller, so this fires once per genuine wrap.
      if (life < s.lastLife) {
        _rollSpark(s, rng);
      }
      s.lastLife = life;
      // Ease-out flight so embers shoot then decelerate as they fade.
      final dist = s.speed * Curves.easeOut.transform(life);
      final pos = Offset(math.cos(s.angle) * dist, -math.sin(s.angle) * dist);
      final opacity = (1.0 - life).clamp(0.0, 1.0);
      final radius = s.size * (1.0 - 0.4 * life);
      canvas.drawCircle(
        pos,
        radius,
        Paint()..color = color.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_FuseSparkPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.sparks != sparks;
}
