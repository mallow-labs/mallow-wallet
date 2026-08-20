import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../services/cast_bloc.dart';
import '../services/cast_service.dart';

/// How long the "Searching for devices..." indicator stays visible before
/// falling back to a quiet UI. The native scan keeps running for as long as
/// the sheet is open, but anything we haven't found within ~10s is unlikely
/// to appear without user intervention, so the spinner becomes noise.
const Duration _kSearchingDisplayDuration = Duration(seconds: 10);

/// Renders the list of cast devices reachable from a [CastState], with a
/// "Searching for devices..." row pinned below while a scan is in progress.
///
/// Used by the cast configuration sheet and the standalone device picker
/// sheet — both share the same row visuals and selection semantics. Both
/// sheets dispatch [CastEvent.refreshDiscovery] on mount, so a scan is
/// always in flight while this widget is visible in [CastDiscovering] or
/// [CastActive]. The spinner auto-hides after [_kSearchingDisplayDuration];
/// if the device list is still empty at that point, a "no devices found"
/// hint replaces it so the sheet isn't blank.
class CastDevicesList extends StatelessWidget {
  const CastDevicesList({
    required this.state,
    required this.selectedDeviceId,
    required this.onSelected,
    this.showInlineSearchingSpinner = true,
    super.key,
  });

  final CastState state;
  final String? selectedDeviceId;

  /// Called when the user taps a device row. Pass `null` to disable taps —
  /// the sheet does this when a session is already active to keep the
  /// device list informational rather than interactive.
  final ValueChanged<CastDevice>? onSelected;

  /// Whether to render the inline "Searching for devices..." spinner row while
  /// a scan is in flight. Sheets that surface the searching state in their
  /// header (via [CastSearchingIndicator]) pass `false` to avoid duplicating
  /// it; the timed-out empty-state hint still renders either way.
  final bool showInlineSearchingSpinner;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final devices = _devicesFor(state);
    final isScanning = state is CastDiscovering || state is CastActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final device in devices)
          _DeviceTile(
            device: device,
            selected: device.id == selectedDeviceId,
            connecting:
                state is CastConnecting &&
                (state as CastConnecting).device.id == device.id,
            onTap: onSelected == null ? null : () => onSelected!(device),
            colors: colors,
          ),
        if (isScanning)
          _DiscoveringRow(
            colors: colors,
            hasDevices: devices.isNotEmpty,
            renderSpinner: showInlineSearchingSpinner,
          ),
      ],
    );
  }

  static List<CastDevice> _devicesFor(CastState state) => switch (state) {
    CastDiscovering(:final devices) => devices,
    CastConnecting(:final device) => [device],
    CastActive(:final device, :final availableDevices) => _mergeActive(
      device,
      availableDevices,
    ),
    _ => const [],
  };

  /// Keep the active device pinned in the list so it stays selected, then
  /// append any other discovered devices. The active device may or may not
  /// be in [availableDevices] depending on whether the native scan reports
  /// the connected target.
  static List<CastDevice> _mergeActive(
    CastDevice active,
    List<CastDevice> availableDevices,
  ) {
    if (availableDevices.isEmpty) return [active];
    final others = [
      for (final d in availableDevices)
        if (d.id != active.id) d,
    ];
    return [active, ...others];
  }
}

/// Owns the [_kSearchingDisplayDuration] timeout and rebuilds with
/// `expired: true` once it elapses. Both the header indicator and the
/// inline discovering row build from this so their windows stay in
/// lockstep.
class _SearchingWindow extends StatefulWidget {
  const _SearchingWindow({required this.builder});

  final Widget Function(BuildContext context, bool expired) builder;

  @override
  State<_SearchingWindow> createState() => _SearchingWindowState();
}

class _SearchingWindowState extends State<_SearchingWindow> {
  Timer? _timeoutTimer;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(_kSearchingDisplayDuration, () {
      if (!mounted) return;
      setState(() => _expired = true);
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _expired);
}

/// Compact "Searching..." label with a spinner, shown across from a sheet
/// title while a scan is in flight. Auto-hides after
/// [_kSearchingDisplayDuration] so a stale header indicator doesn't linger,
/// matching the device list's empty-state fallback timing.
class CastSearchingIndicator extends StatelessWidget {
  const CastSearchingIndicator({required this.colors, super.key});

  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return _SearchingWindow(
      builder: (_, expired) {
        if (expired) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MallowLoader(size: 14, color: colors.textSecondary),
            const SizedBox(width: MallowTheme.spacingSm),
            Text(
              'Searching...',
              style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
            ),
          ],
        );
      },
    );
  }
}

class _DiscoveringRow extends StatelessWidget {
  const _DiscoveringRow({
    required this.colors,
    required this.hasDevices,
    this.renderSpinner = true,
  });

  final MallowColors colors;

  /// Whether the surrounding list already has at least one device. Used to
  /// decide between the empty-state hint and rendering nothing once the
  /// search indicator times out.
  final bool hasDevices;

  /// Whether to render the inline spinner row during the searching window.
  /// When `false`, the searching state is surfaced elsewhere (a sheet header)
  /// and only the timed-out empty-state hint renders here.
  final bool renderSpinner;

  @override
  Widget build(BuildContext context) {
    return _SearchingWindow(builder: (_, expired) => _buildRow(expired));
  }

  Widget _buildRow(bool expired) {
    if (!expired) {
      if (!renderSpinner) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: MallowTheme.spacingMd,
        ),
        child: Row(
          children: [
            MallowLoader(size: 16, color: colors.textSecondary),
            const SizedBox(width: MallowTheme.spacingMd),
            Text(
              'Searching for devices...',
              style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    // Timed out — surface an empty-state hint only when we have nothing else
    // to show. With devices in the list, dropping the row keeps the sheet
    // clean.
    if (hasDevices) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacing20,
        vertical: MallowTheme.spacingMd,
      ),
      child: Text(
        "No devices found. Make sure you're on the same Wi-Fi.",
        style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.selected,
    required this.connecting,
    required this.onTap,
    required this.colors,
  });

  final CastDevice device;
  final bool selected;
  final bool connecting;
  final VoidCallback? onTap;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
            vertical: MallowTheme.spacingSm,
          ),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/icons/cast.svg',
                width: 20,
                height: 20,
                colorFilter: ColorFilter.mode(
                  selected ? colors.accent : colors.textPrimary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: MallowTheme.spacingMd),
              Expanded(
                child: Text(
                  device.name.isEmpty ? 'This device' : device.name,
                  style: MallowTheme.uiBody.copyWith(
                    color: selected ? colors.accent : colors.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (connecting)
                MallowLoader(size: 16, color: colors.textSecondary)
              else if (selected)
                MallowSvgIcon(
                  'assets/icons/checkmark.svg',
                  width: 14,
                  height: 14,
                  color: colors.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
