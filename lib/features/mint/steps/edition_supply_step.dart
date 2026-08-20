import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../services/mint_bloc.dart';
import '../widgets/mint_radio_row.dart';

/// Editions configuration step.
///
/// Lets the user pick **Limited Edition** vs **Open Edition** and (for
/// Limited) the total supply. Open disables the Supply field and shows
/// `No max supply`. Limited requires a value in `[2, 10000]` before the Next
/// button enables — and, on an edit, one that is at least the number of
/// editions already printed (`MintState.canGoNext`).
class EditionSupplyStep extends StatefulWidget {
  const EditionSupplyStep({super.key});

  @override
  State<EditionSupplyStep> createState() => _EditionSupplyStepState();
}

class _EditionSupplyStepState extends State<EditionSupplyStep> {
  late final TextEditingController _supplyController;

  @override
  void initState() {
    super.initState();
    _supplyController = TextEditingController(
      text: context.read<MintBloc>().state.editionSupply,
    );
  }

  @override
  void dispose() {
    _supplyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MintBloc, MintState>(
      listenWhen: (prev, next) => prev.editionSupply != next.editionSupply,
      listener: (context, state) {
        if (_supplyController.text != state.editionSupply) {
          _supplyController.value = _supplyController.value.copyWith(
            text: state.editionSupply,
            selection: TextSelection.collapsed(
              offset: state.editionSupply.length,
            ),
          );
        }
      },
      buildWhen: (prev, next) =>
          prev.editionType != next.editionType ||
          prev.editionSupply != next.editionSupply ||
          prev.isEdit != next.isEdit ||
          prev.editCurrentSupply != next.editCurrentSupply,
      builder: (context, state) {
        final colors = context.mallowColors;
        final isLimited = state.editionType == MintEditionType.limited;
        // Edit mode can't cap supply below what's already printed (the chain
        // rejects it), so surface the floor the way the webapp does
        // (`EditionsFields` — "N editions printed").
        final printed = state.editCurrentSupply;
        final supplyHint = state.isEdit && isLimited
            ? '$printed edition${printed == 1 ? '' : 's'} printed'
            : 'You can change this at any time';
        return ListView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          children: [
            const MallowSectionLabel(label: 'Edition Type'),
            const SizedBox(height: MallowTheme.spacingMd),
            MintRadioRow(
              label: 'Limited Edition',
              selected: isLimited,
              onTap: () => context.read<MintBloc>().add(
                const MintEvent.setEditionType(MintEditionType.limited),
              ),
            ),
            MintRadioRow(
              label: 'Open Edition',
              selected: !isLimited,
              onTap: () => context.read<MintBloc>().add(
                const MintEvent.setEditionType(MintEditionType.open),
              ),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            const MallowSectionLabel(label: 'Supply'),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _supplyController,
              enabled: isLimited,
              autofocus: isLimited && state.editionSupply.isEmpty,
              hintText: isLimited ? 'Total Edition Count' : 'No max supply',
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(5),
              ],
              onChanged: (value) => context.read<MintBloc>().add(
                MintEvent.setEditionSupply(value),
              ),
            ),
            const SizedBox(height: MallowTheme.spacingXs),
            Text(
              supplyHint,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        );
      },
    );
  }
}
