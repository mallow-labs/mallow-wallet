import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_cupertino_picker_sheet.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../mint/widgets/mint_radio_row.dart';
import '../services/auction_bloc.dart';

const _presetDurationsSeconds = [21600, 43200, 86400, 172800];

/// Step 3: timing — start type (On Bid / Instant Start / Schedule Start),
/// scheduled start date+time (when applicable), auction duration with
/// presets or custom end date+time.
class TimingStep extends StatelessWidget {
  const TimingStep({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      buildWhen: (prev, next) =>
          prev.startTime != next.startTime || prev.duration != next.duration,
      builder: (context, state) {
        final colors = context.mallowColors;
        final isScheduled = state.startTime > 0;
        final isPresetDuration = _presetDurationsSeconds.contains(
          state.duration,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Auction Start Type',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              MintRadioRow(
                label: 'On Bid',
                selected: state.startTime == 0,
                onTap: () => context.read<AuctionBloc>().add(
                  const AuctionEvent.setStartTime(0),
                ),
              ),
              MintRadioRow(
                label: 'Instant Start',
                selected: state.startTime == -1,
                onTap: () => context.read<AuctionBloc>().add(
                  const AuctionEvent.setStartTime(-1),
                ),
              ),
              MintRadioRow(
                label: 'Schedule Start',
                selected: isScheduled,
                onTap: () {
                  if (isScheduled) return;
                  // Default to the start of the next hour after now + 1h
                  // (e.g. 3:25 → +1h = 4:25 → 5:00).
                  final base = DateTime.now().add(const Duration(hours: 1));
                  final defaultStart = DateTime(
                    base.year,
                    base.month,
                    base.day,
                    base.hour,
                  ).add(const Duration(hours: 1));
                  context.read<AuctionBloc>().add(
                    AuctionEvent.setStartTime(
                      defaultStart.millisecondsSinceEpoch ~/ 1000,
                    ),
                  );
                },
              ),
              if (isScheduled) ...[
                const SizedBox(height: MallowTheme.spacing20),
                _DateTimeRow(
                  dateLabel: 'Start Date',
                  timeLabel: 'Start Time',
                  epochSeconds: state.startTime,
                  onChanged: (epoch) => context.read<AuctionBloc>().add(
                    AuctionEvent.setStartTime(epoch),
                  ),
                ),
              ],
              const SizedBox(height: MallowTheme.spacing20),
              Text(
                'Auction Duration',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              for (final preset in _presetDurationsSeconds)
                MintRadioRow(
                  label: _formatPresetDuration(preset),
                  selected: state.duration == preset,
                  onTap: () => context.read<AuctionBloc>().add(
                    AuctionEvent.setDuration(preset),
                  ),
                ),
              MintRadioRow(
                label: 'Custom',
                selected: !isPresetDuration,
                onTap: () {
                  if (isPresetDuration) {
                    // Scheduled start shows End Date/Time pickers, so default to
                    // start+1h; the unscheduled custom Hours/Minutes fields start
                    // empty (0 → blank) rather than pre-populating an hour.
                    context.read<AuctionBloc>().add(
                      AuctionEvent.setDuration(isScheduled ? 3600 : 0),
                    );
                  }
                },
              ),
              if (!isPresetDuration) ...[
                const SizedBox(height: MallowTheme.spacing20),
                if (isScheduled)
                  _DateTimeRow(
                    dateLabel: 'End Date',
                    timeLabel: 'End Time',
                    epochSeconds: state.startTime + state.duration,
                    onChanged: (endEpoch) {
                      final duration = (endEpoch - state.startTime).clamp(
                        60,
                        365 * 24 * 3600,
                      );
                      context.read<AuctionBloc>().add(
                        AuctionEvent.setDuration(duration),
                      );
                    },
                  )
                else
                  _CustomDurationRow(seconds: state.duration),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Side-by-side date + time pill buttons with a timezone caption below.
class _DateTimeRow extends StatelessWidget {
  const _DateTimeRow({
    required this.dateLabel,
    required this.timeLabel,
    required this.epochSeconds,
    required this.onChanged,
  });

  final String dateLabel;
  final String timeLabel;
  final int epochSeconds;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _PillPickerField(
                label: dateLabel,
                value: DateFormat('dd/MM/yyyy').format(dt),
                onTap: () => _pickDate(context, dt),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: _PillPickerField(
                label: timeLabel,
                value: DateFormat('HH:mm').format(dt),
                onTap: () => _pickTime(context, dt),
              ),
            ),
          ],
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Text(
          'Timezone: ${tz.local.name}',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  Future<void> _pickDate(BuildContext context, DateTime current) async {
    final now = DateTime.now();
    final picked = await showMallowDatePicker(
      context: context,
      initialDate: current.isBefore(now) ? now : current,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      title: dateLabel,
    );
    if (picked == null) return;
    final dt = DateTime(
      picked.year,
      picked.month,
      picked.day,
      current.hour,
      current.minute,
    );
    onChanged(dt.millisecondsSinceEpoch ~/ 1000);
  }

  Future<void> _pickTime(BuildContext context, DateTime current) async {
    final picked = await showMallowTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      title: timeLabel,
    );
    if (picked == null) return;
    final dt = DateTime(
      current.year,
      current.month,
      current.day,
      picked.hour,
      picked.minute,
    );
    onChanged(dt.millisecondsSinceEpoch ~/ 1000);
  }
}

/// Small inline label (Geist 13px) above a pill-shaped tappable selector
/// that displays the current value with a chevron on the right.
class _PillPickerField extends StatelessWidget {
  const _PillPickerField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
              border: Border.all(color: colors.divider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                MallowSvgIcon(
                  'assets/icons/arrow_down.svg',
                  width: 6,
                  height: 6,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CustomDurationRow extends StatefulWidget {
  const _CustomDurationRow({required this.seconds});

  final int seconds;

  @override
  State<_CustomDurationRow> createState() => _CustomDurationRowState();
}

class _CustomDurationRowState extends State<_CustomDurationRow> {
  late final TextEditingController _hoursController;
  late final TextEditingController _minutesController;

  @override
  void initState() {
    super.initState();
    final hours = widget.seconds ~/ 3600;
    final minutes = (widget.seconds % 3600) ~/ 60;
    _hoursController = TextEditingController(
      text: hours == 0 ? '' : hours.toString(),
    );
    _minutesController = TextEditingController(
      text: minutes == 0 ? '' : minutes.toString(),
    );
  }

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  void _emit() {
    final h = int.tryParse(_hoursController.text) ?? 0;
    final m = int.tryParse(_minutesController.text) ?? 0;
    final total = h * 3600 + m * 60;
    context.read<AuctionBloc>().add(AuctionEvent.setDuration(total));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: MallowPillField(
            controller: _hoursController,
            hintText: 'Hours',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => _emit(),
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: MallowPillField(
            controller: _minutesController,
            hintText: 'Minutes',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => _emit(),
          ),
        ),
      ],
    );
  }
}

String _formatPresetDuration(int seconds) {
  final hours = seconds ~/ 3600;
  return '$hours hours';
}
