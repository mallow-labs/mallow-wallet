import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/cast_display_type.dart';
import '../services/cast_bloc.dart';
import '../services/cast_service.dart';
import 'cast_devices_list.dart';
import 'cast_error_view.dart';
import 'cast_queue_sheet.dart';

part 'cast_configuration_sheet/action_buttons.dart';
part 'cast_configuration_sheet/display_options.dart';
part 'cast_configuration_sheet/interval_section.dart';
part 'cast_configuration_sheet/section_widgets.dart';

const _kIntervalMin = 10;
const _kIntervalMax = 300;
const _kIntervalStep = 10;

/// Cast configuration sheet — devices list, Display Type selector,
/// Display Options (caption + QR), interval stepper, shuffle toggle, and the
/// bottom Cast / View Queue / Disconnect actions.
///
/// Auto-shown by [app.dart] when the bloc enters [CastDiscovering], and also
/// reachable from the Now Casting bar while a session is active.
Future<void> showCastConfigurationSheet(BuildContext context) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: sl<CastBloc>(),
      child: const _CastConfigurationSheet(),
    ),
  );
}

class _CastConfigurationSheet extends StatefulWidget {
  const _CastConfigurationSheet();

  @override
  State<_CastConfigurationSheet> createState() =>
      _CastConfigurationSheetState();
}

class _CastConfigurationSheetState extends State<_CastConfigurationSheet> {
  late final CastBloc _bloc = sl<CastBloc>();
  late final PreferencesService _prefs = sl<PreferencesService>();
  String? _selectedDeviceId;
  bool _displayOptionsExpanded = false;
  bool _userCommittedConnect = false;

  // Local mirror of session settings so the sheet stays interactive before a
  // session is active — when not in CastActive, dispatching set* events
  // persists prefs but does not change bloc state, so without local state the
  // BlocBuilder would never rebuild.
  late int _intervalSeconds = _prefs.castIntervalSeconds;
  late bool _showCaption = _prefs.castShowCaption;
  late bool _showQr = _prefs.castShowQr;
  late bool _shuffle = _prefs.castShuffle;
  late CastDisplayType _displayType = _prefs.castDisplayType;

  @override
  void initState() {
    super.initState();
    final state = _bloc.state;
    if (state is CastActive) {
      _selectedDeviceId = state.device.id;
      _intervalSeconds = state.queue.slideshowIntervalSeconds;
      _showCaption = state.queue.showCaption;
      _showQr = state.queue.showQr;
      _shuffle = state.queue.isShuffled;
    } else {
      // Seed from the last-used device so it auto-highlights when discovery
      // surfaces it. Stale ids that never appear stay harmless — Cast stays
      // disabled until a matching device is in the live list.
      _selectedDeviceId = _prefs.castLastDeviceId;
    }
    // Always nudge a fresh scan when the sheet opens so device entries reflect
    // the current network. No-op when connecting/active.
    _bloc.add(const CastEvent.refreshDiscovery());
  }

  @override
  void dispose() {
    // If the sheet is dismissed mid-discovery without tapping Cast, end the
    // session so the bloc doesn't sit in CastDiscovering forever. Same for a
    // dismissed failure: nothing else renders CastError once this sheet is
    // gone, so leaving the bloc there would strand it in a state with no UI.
    final state = _bloc.state;
    if (state is CastError ||
        (!_userCommittedConnect &&
            (state is CastDiscovering || state is CastConnecting))) {
      _bloc.add(const CastEvent.disconnect());
    }
    super.dispose();
  }

  List<CastDevice> _devicesFor(CastState state) => switch (state) {
    CastDiscovering(:final devices) => devices,
    CastConnecting(:final device) => [device],
    CastActive(:final device) => [device],
    _ => const [],
  };

  bool _canCast(CastState state) {
    if (state is! CastDiscovering) return false;
    final selected = _selectedDeviceId;
    if (selected == null) return false;
    // Require the selected id to be in the live list — otherwise the persisted
    // id is stale and Cast would have nothing to connect to.
    return state.devices.any((d) => d.id == selected);
  }

  bool _canViewQueue(CastState state) => switch (state) {
    CastActive(:final queue) => queue.items.isNotEmpty,
    CastDiscovering(:final pendingItems) => pendingItems.isNotEmpty,
    CastConnecting(:final pendingItems) => pendingItems.isNotEmpty,
    _ => false,
  };

  void _onCast(CastState state) {
    final selected = _selectedDeviceId;
    if (selected == null) return;
    final devices = _devicesFor(state);
    CastDevice? device;
    for (final d in devices) {
      if (d.id == selected) {
        device = d;
        break;
      }
    }
    if (device == null) return;
    _userCommittedConnect = true;
    _bloc.add(CastEvent.connectToDevice(device));
  }

  void _onIntervalChanged(int seconds) {
    setState(() => _intervalSeconds = seconds);
    _bloc.add(CastEvent.setInterval(seconds));
  }

  void _onCaptionChanged(bool v) {
    setState(() => _showCaption = v);
    _bloc.add(CastEvent.setOverlay(showCaption: v));
  }

  void _onQrChanged(bool v) {
    setState(() => _showQr = v);
    _bloc.add(CastEvent.setOverlay(showQr: v));
  }

  void _onShuffleToggled() {
    setState(() => _shuffle = !_shuffle);
    _bloc.add(const CastEvent.toggleShuffle());
  }

  void _onDisplayTypeChanged(CastDisplayType type) {
    setState(() => _displayType = type);
    _bloc.add(CastEvent.setDisplayType(type));
  }

  void _onDisconnect() {
    _bloc.add(const CastEvent.disconnect());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Grows with the device list / expanded display options until it hits
      // the cap [showMallowSheet] applies, then the body scrolls.
      child: BlocConsumer<CastBloc, CastState>(
        listener: (context, state) {
          // Auto-close once a connect we initiated lands on Active.
          if (state is CastActive && _userCommittedConnect) {
            Navigator.of(context).pop();
            return;
          }
          // The connect we committed to failed. Drop the commit flag so a
          // retry-then-dismiss tears the bloc down like any other abandoned
          // discovery instead of leaving it in CastDiscovering forever.
          if (state is CastError) {
            _userCommittedConnect = false;
            return;
          }
          // Sync local UI state to the active queue so it reflects whatever the
          // bloc decided (e.g. shuffle resolved against an empty queue).
          if (state is CastActive) {
            final q = state.queue;
            if (_intervalSeconds != q.slideshowIntervalSeconds ||
                _showCaption != q.showCaption ||
                _showQr != q.showQr ||
                _shuffle != q.isShuffled) {
              setState(() {
                _intervalSeconds = q.slideshowIntervalSeconds;
                _showCaption = q.showCaption;
                _showQr = q.showQr;
                _shuffle = q.isShuffled;
              });
            }
          }
        },
        builder: (context, state) {
          final isActive = state is CastActive;
          return SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetDragHandle(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MallowTheme.spacing20,
                    vertical: MallowTheme.spacingSm,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Cast to screen',
                          style: MallowTheme.uiBody.copyWith(
                            color: colors.textPrimary,
                          ),
                          textAlign: TextAlign.left,
                        ),
                      ),
                      if (state is CastDiscovering || state is CastActive)
                        CastSearchingIndicator(colors: colors),
                    ],
                  ),
                ),
                // This sheet stays mounted through the connect attempt, so it
                // is where a failed connect surfaces: without this the device
                // list empties and the primary button falls back to a disabled
                // "Cast" with no explanation.
                if (state is CastError)
                  CastErrorView(message: state.message)
                else
                  CastDevicesList(
                    state: state,
                    selectedDeviceId: _selectedDeviceId,
                    showInlineSearchingSpinner: false,
                    onSelected: isActive
                        ? null
                        : (device) =>
                              setState(() => _selectedDeviceId = device.id),
                  ),
                const SizedBox(height: MallowTheme.spacingSm),
                _SectionDivider(colors: colors),
                _CollapsibleSection(
                  title: 'Display Options',
                  expanded: _displayOptionsExpanded,
                  onToggle: () => setState(
                    () => _displayOptionsExpanded = !_displayOptionsExpanded,
                  ),
                  colors: colors,
                  children: [
                    _DisplayOptionsBody(
                      showCaption: _showCaption,
                      showQr: _showQr,
                      onCaptionChanged: _onCaptionChanged,
                      onQrChanged: _onQrChanged,
                      colors: colors,
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    _DisplayTypeSelector(
                      value: _displayType,
                      onChanged: _onDisplayTypeChanged,
                      colors: colors,
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                  ],
                ),
                _SectionDivider(colors: colors),
                _IntervalSection(
                  seconds: _intervalSeconds,
                  onChanged: _onIntervalChanged,
                  colors: colors,
                ),
                _SectionDivider(colors: colors),
                _ShuffleRow(
                  value: _shuffle,
                  onToggle: _onShuffleToggled,
                  colors: colors,
                ),
                const SizedBox(height: MallowTheme.spacingMd),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    MallowTheme.spacing20,
                    MallowTheme.spacingSm,
                    MallowTheme.spacing20,
                    sheetBottomInset(context),
                  ),
                  child: Column(
                    children: [
                      _OutlinedActionButton(
                        label: 'View Queue',
                        iconAsset: 'assets/icons/queue.svg',
                        enabled: _canViewQueue(state),
                        onPressed: () {
                          // Stack the queue sheet on top of this one
                          // rather than popping first. Popping would fire
                          // this sheet's `dispose`, which disconnects when
                          // not committed — leaving the queue sheet to
                          // render against an idle bloc and appear empty.
                          // Dismissing the queue sheet returns the user
                          // here, where they can still tap Cast.
                          final rootContext =
                              AppRoutes.rootNavigatorKey.currentContext;
                          if (rootContext != null) {
                            showCastQueueSheet(rootContext);
                          }
                        },
                        colors: colors,
                      ),
                      const SizedBox(height: MallowTheme.spacingSm),
                      if (isActive)
                        _DangerActionButton(
                          label: 'Disconnect',
                          onPressed: _onDisconnect,
                          colors: colors,
                        )
                      else
                        _PrimaryActionButton(
                          label: state is CastConnecting
                              ? 'Connecting…'
                              : 'Cast',
                          enabled: _canCast(state),
                          onPressed: () => _onCast(state),
                          colors: colors,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
