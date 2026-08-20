import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../services/mint_bloc.dart';
import '../widgets/mint_creator_row.dart';

/// Royalties step.
///
/// Captures royalty percentage and proceed splits. The user's own wallet
/// is locked at index 0; additional wallets can be added up to a cap of 5
/// (webapp parity).
class RoyaltiesStep extends StatefulWidget {
  const RoyaltiesStep({super.key});

  @override
  State<RoyaltiesStep> createState() => _RoyaltiesStepState();
}

class _RoyaltiesStepState extends State<RoyaltiesStep> {
  late final TextEditingController _royaltyController;
  final FocusNode _royaltyFocus = FocusNode();
  late MintStep _lastStep;

  @override
  void initState() {
    super.initState();
    final state = context.read<MintBloc>().state;
    _royaltyController = TextEditingController(text: state.royaltyPercent);
    _lastStep = state.step;
    // The flow hosts every step in an IndexedStack, so a plain `autofocus`
    // would fire while this step is still off-screen and be lost. Focus the
    // empty input only when the user actually lands on the royalties step —
    // here on first frame if it opens directly on this step, otherwise via
    // the step transition in the listener below.
    if (state.step == MintStep.royalties &&
        state.royaltyPercent.trim().isEmpty) {
      _focusRoyaltyNextFrame();
    }
  }

  /// Focuses the royalty input on the next frame. Deferred because the
  /// IndexedStack only moves this step onstage during the parent's rebuild for
  /// the same state change — focusing synchronously would target a still-
  /// offstage field and be lost.
  void _focusRoyaltyNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _royaltyFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _royaltyController.dispose();
    _royaltyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MintBloc, MintState>(
      listenWhen: (prev, next) =>
          prev.royaltyPercent != next.royaltyPercent || prev.step != next.step,
      listener: (context, state) {
        if (_royaltyController.text != state.royaltyPercent) {
          _royaltyController.value = _royaltyController.value.copyWith(
            text: state.royaltyPercent,
            selection: TextSelection.collapsed(
              offset: state.royaltyPercent.length,
            ),
          );
        }
        final arrived =
            state.step == MintStep.royalties && _lastStep != MintStep.royalties;
        _lastStep = state.step;
        if (arrived && state.royaltyPercent.trim().isEmpty) {
          _focusRoyaltyNextFrame();
        }
      },
      buildWhen: (prev, next) =>
          prev.royaltyPercent != next.royaltyPercent ||
          prev.creators != next.creators,
      builder: (context, state) {
        final colors = context.mallowColors;
        final canAddWallet = state.creators.length < 5;
        return ListView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          children: [
            const MallowSectionLabel(label: 'Royalties'),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _royaltyController,
              focusNode: _royaltyFocus,
              hintText: 'Typically 5 - 15%',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                LengthLimitingTextInputFormatter(5),
              ],
              onChanged: (value) => context.read<MintBloc>().add(
                MintEvent.setRoyaltyPercent(value),
              ),
              prefix: Text(
                '%',
                style: MallowTheme.uiBody.copyWith(color: colors.textTertiary),
              ),
            ),
            if (state.royaltyError != null) ...[
              const SizedBox(height: MallowTheme.spacingXs),
              Text(
                state.royaltyError!,
                style: MallowTheme.uiCaption.copyWith(color: colors.error),
              ),
            ],
            const SizedBox(height: MallowTheme.spacingLg),
            Text(
              'Proceed Splits',
              style: MallowTheme.uiLabel.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            for (var i = 0; i < state.creators.length; i++) ...[
              MintCreatorRow(
                creator: state.creators[i],
                onAddressChanged: (value) => context.read<MintBloc>().add(
                  MintEvent.setCreatorAddress(i, value),
                ),
                onShareChanged: (value) => context.read<MintBloc>().add(
                  MintEvent.setCreatorShare(i, value),
                ),
                onRemove: state.creators[i].isSelf
                    ? null
                    : () => context.read<MintBloc>().add(
                        MintEvent.removeCreator(i),
                      ),
              ),
              if (i < state.creators.length - 1)
                const SizedBox(height: MallowTheme.spacingSm),
            ],
            const SizedBox(height: MallowTheme.spacingMd),
            Align(
              alignment: Alignment.centerLeft,
              child: TapTargetExpander(
                child: GestureDetector(
                  onTap: canAddWallet
                      ? () => context.read<MintBloc>().add(
                          const MintEvent.addCreator(),
                        )
                      : null,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: MallowTheme.spacingXs,
                    ),
                    child: Text(
                      '+ Add another wallet',
                      style: MallowTheme.uiCaption.copyWith(
                        color: canAddWallet
                            ? colors.textPrimary
                            : colors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (state.creatorsError != null) ...[
              const SizedBox(height: MallowTheme.spacingXs),
              Text(
                state.creatorsError!,
                style: MallowTheme.uiCaption.copyWith(color: colors.error),
              ),
            ],
          ],
        );
      },
    );
  }
}
