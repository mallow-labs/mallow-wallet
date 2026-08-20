import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/cast_bloc.dart';
import 'cast_devices_list.dart';
import 'cast_error_view.dart';

/// Standalone device picker — opened from the Now Playing screen's "Screen"
/// icon. Mirrors the device-list portion of [showCastConfigurationSheet]
/// without the slideshow/display-options sections.
///
/// Tapping a different device dispatches [CastConnectToDevice] and dismisses
/// the sheet; the bloc handles the connection lifecycle.
Future<void> showCastDevicePickerSheet(BuildContext context) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: sl<CastBloc>(),
      child: const _CastDevicePickerSheet(),
    ),
  );
}

class _CastDevicePickerSheet extends StatefulWidget {
  const _CastDevicePickerSheet();

  @override
  State<_CastDevicePickerSheet> createState() => _CastDevicePickerSheetState();
}

class _CastDevicePickerSheetState extends State<_CastDevicePickerSheet> {
  late final CastBloc _bloc = sl<CastBloc>();

  @override
  void initState() {
    super.initState();
    // Nudge a fresh scan so the device list reflects the current network.
    // When a session is active, the bloc runs a background scan whose
    // results land on CastActive.availableDevices — see [CastBloc].
    _bloc.add(const CastEvent.refreshDiscovery());
  }

  @override
  void dispose() {
    // Release the background scan started in initState; outside an active
    // session this is a no-op.
    _bloc.add(const CastEvent.stopBackgroundDiscovery());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: BlocBuilder<CastBloc, CastState>(
        builder: (context, state) {
          final activeDeviceId = state is CastActive ? state.device.id : null;
          final isScanning = state is CastDiscovering || state is CastActive;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetDragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacingSm,
                  MallowTheme.spacing20,
                  MallowTheme.spacingMd,
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
                    if (isScanning) CastSearchingIndicator(colors: colors),
                  ],
                ),
              ),
              // Reachable when the scan this sheet kicks off fails (e.g. the
              // Cast SDK can't initialise) — otherwise the sheet would show an
              // empty list that reads as "no devices on this network".
              if (state is CastError)
                CastErrorView(message: state.message)
              else
                CastDevicesList(
                  state: state,
                  selectedDeviceId: activeDeviceId,
                  showInlineSearchingSpinner: false,
                  onSelected: (device) {
                    if (device.id == activeDeviceId) {
                      Navigator.of(context).pop();
                      return;
                    }
                    _bloc.add(CastEvent.connectToDevice(device));
                    Navigator.of(context).pop();
                  },
                ),
              SizedBox(height: sheetBottomInset(context)),
            ],
          );
        },
      ),
    );
  }
}
