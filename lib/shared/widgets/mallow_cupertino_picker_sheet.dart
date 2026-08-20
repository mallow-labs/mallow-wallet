import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';

/// iOS-style wheel date/time pickers presented in a mallow-styled bottom sheet.
///
/// These replace Flutter's Material [showDatePicker]/[showTimePicker] dialogs,
/// whose calendar grid and clock dial clash with the wallet's cream/editorial
/// look. The wheel sits on a rounded surface with a Cancel/Done header so the
/// selection is only committed on Done (matching native iOS behaviour).

/// Presents an iOS-style date wheel and resolves to the chosen date, or `null`
/// if the user cancels. Only the date components are meaningful on the result.
Future<DateTime?> showMallowDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String title = 'Select Date',
}) {
  return _showPicker(
    context: context,
    title: title,
    mode: CupertinoDatePickerMode.date,
    initialDateTime: initialDate,
    minimumDate: firstDate,
    maximumDate: lastDate,
  );
}

/// Presents an iOS-style time wheel and resolves to the chosen time of day, or
/// `null` if the user cancels.
Future<TimeOfDay?> showMallowTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String title = 'Select Time',
}) async {
  final now = DateTime.now();
  final seed = DateTime(
    now.year,
    now.month,
    now.day,
    initialTime.hour,
    initialTime.minute,
  );
  final picked = await _showPicker(
    context: context,
    title: title,
    mode: CupertinoDatePickerMode.time,
    initialDateTime: seed,
  );
  if (picked == null) return null;
  return TimeOfDay(hour: picked.hour, minute: picked.minute);
}

Future<DateTime?> _showPicker({
  required BuildContext context,
  required String title,
  required CupertinoDatePickerMode mode,
  required DateTime initialDateTime,
  DateTime? minimumDate,
  DateTime? maximumDate,
}) {
  return showMallowSheet<DateTime>(
    context: context,
    builder: (context) => _CupertinoPickerSheet(
      title: title,
      mode: mode,
      initialDateTime: initialDateTime,
      minimumDate: minimumDate,
      maximumDate: maximumDate,
    ),
  );
}

class _CupertinoPickerSheet extends StatefulWidget {
  const _CupertinoPickerSheet({
    required this.title,
    required this.mode,
    required this.initialDateTime,
    this.minimumDate,
    this.maximumDate,
  });

  final String title;
  final CupertinoDatePickerMode mode;
  final DateTime initialDateTime;
  final DateTime? minimumDate;
  final DateTime? maximumDate;

  @override
  State<_CupertinoPickerSheet> createState() => _CupertinoPickerSheetState();
}

class _CupertinoPickerSheetState extends State<_CupertinoPickerSheet> {
  late DateTime _selected = widget.initialDateTime;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacingMd,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: MallowTheme.uiTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  MallowButton(
                    label: 'Done',
                    size: MallowButtonSize.small,
                    variant: MallowButtonVariant.text,
                    onPressed: () => Navigator.of(context).pop(_selected),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 216,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: brightness,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: MallowTheme.uiTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: widget.mode,
                  initialDateTime: widget.initialDateTime,
                  minimumDate: widget.minimumDate,
                  maximumDate: widget.maximumDate,
                  use24hFormat: true,
                  onDateTimeChanged: (value) => _selected = value,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
