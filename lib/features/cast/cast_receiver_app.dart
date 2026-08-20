import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/cast_media_type.dart';
import 'models/cast_overlay_config.dart';
import 'models/cast_queue.dart';
import 'widgets/cast_receiver_view.dart';

/// Top-level entry for the iOS AirPlay secondary `FlutterEngine`.
///
/// This Flutter app runs inside the secondary engine spun up by
/// `AirPlayPlugin` when an external screen connects (AirPlay Mirroring
/// active). It mounts a `FlutterViewController` on a `UIWindow` bound to
/// `UIScreen.screens[1]` so its UI lands on the TV rather than the phone.
class CastReceiverApp extends StatelessWidget {
  const CastReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        // Match the primary app: clamp system text scaling so large
        // accessibility sizes can't clip the receiver's overlay text.
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.textScalerOf(
              context,
            ).clamp(minScaleFactor: 1.0, maxScaleFactor: 1.3),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const CastReceiverHost(),
    );
  }
}

/// Listens to the receiver method channel and renders [CastReceiverView]
/// based on the most recent state pushed by the plugin.
class CastReceiverHost extends StatefulWidget {
  const CastReceiverHost({super.key});

  @override
  State<CastReceiverHost> createState() => _CastReceiverHostState();
}

class _CastReceiverHostState extends State<CastReceiverHost> {
  static const _channel = MethodChannel('com.mallow.wallet/airplay_receiver');

  CastQueueItem? _item;
  CastOverlayConfig _overlay = const CastOverlayConfig();

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleCall);
    // Notify the native plugin that this engine is up and ready to receive
    // state. The plugin will replay any pending 'show' it cached while the
    // engine was booting.
    _channel.invokeMethod<void>('ready');
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'show':
        final args = _asMap(call.arguments);
        final itemMap = _asMap(args['item']);
        final overlayMap = _asMap(args['overlay']);
        setState(() {
          _item = CastQueueItem.fromJson(itemMap);
          _overlay = CastOverlayConfig.fromJson(overlayMap);
        });
      case 'overlay':
        final overlayMap = _asMap(_asMap(call.arguments)['overlay']);
        setState(() {
          _overlay = CastOverlayConfig.fromJson(overlayMap);
        });
      case 'preload':
        final args = _asMap(call.arguments);
        final raw = args['items'];
        if (raw is List) {
          for (final entry in raw.whereType<Map<dynamic, dynamic>>()) {
            final item = CastQueueItem.fromJson(
              Map<String, dynamic>.from(entry),
            );
            ArtworkMediaResolver.resolveAsync(
              imageUrl: item.imageUrl,
              animationUrl: item.animationUrl,
            ).ignore();
            if (item.imageUrl.isNotEmpty) {
              // Resolve into the painting cache so the next 'show' renders
              // without a fetch — same trick LocalCastService uses.
              //
              // It must be the *poster* URL through
              // `ExtendedNetworkImageProvider`, matching what
              // `CastProgressiveArtwork` renders exactly: the raw source is
              // often an unfetchable `ipfs://` URI, and a `NetworkImage` of
              // it would key a different cache entry than the one the
              // receiver reads, warming nothing. Only the poster is warmed —
              // the originals are multi-megabyte and the slideshow interval
              // is long enough to fetch them on show.
              ExtendedNetworkImageProvider(
                ArtworkMediaResolver.posterUrl(item.imageUrl),
              ).resolve(ImageConfiguration.empty);
            }
          }
        }
      case 'clear':
        setState(() => _item = null);
    }
    return null;
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      // Cast receiver renders on TV black background — intentional literal.
      backgroundColor: Colors.black,
      body: item != null
          ? CastReceiverView(item: item, overlay: _overlay)
          : const Center(
              child: Text(
                'mallow',
                style: TextStyle(
                  color: Colors.white24,
                  fontSize: 24,
                  letterSpacing: 4,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
    );
  }
}
