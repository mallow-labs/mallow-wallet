import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/mint_form_models.dart';

/// A single proceed-split row on the Royalties step.
///
/// When `creator.isSelf` is true the address pill is locked and shows
/// "(You) \<shortened pubkey\>". Otherwise the address and share pills are
/// editable and an optional trash icon removes the row.
class MintCreatorRow extends StatefulWidget {
  const MintCreatorRow({
    required this.creator,
    required this.onAddressChanged,
    required this.onShareChanged,
    super.key,
    this.onRemove,
  });

  final MintCreatorInput creator;
  final ValueChanged<String> onAddressChanged;
  final ValueChanged<String> onShareChanged;
  final VoidCallback? onRemove;

  @override
  State<MintCreatorRow> createState() => _MintCreatorRowState();
}

class _MintCreatorRowState extends State<MintCreatorRow> {
  late final TextEditingController _addressController;
  late final TextEditingController _shareController;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(text: widget.creator.address);
    _shareController = TextEditingController(text: widget.creator.shareText);
  }

  @override
  void didUpdateWidget(covariant MintCreatorRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.creator.address != _addressController.text) {
      _addressController.value = _addressController.value.copyWith(
        text: widget.creator.address,
        selection: TextSelection.collapsed(
          offset: widget.creator.address.length,
        ),
      );
    }
    if (widget.creator.shareText != _shareController.text) {
      _shareController.value = _shareController.value.copyWith(
        text: widget.creator.shareText,
        selection: TextSelection.collapsed(
          offset: widget.creator.shareText.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    _shareController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isSelf = widget.creator.isSelf;

    // Address widget — read-only truncated label for self, editable pill
    // otherwise.
    final addressWidget = isSelf
        ? Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
              border: Border.all(color: colors.divider),
              color: colors.surfaceMuted,
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              '(You) ${truncateAddress(widget.creator.address)}',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          )
        : MallowPillField(
            controller: _addressController,
            hintText: 'Wallet address',
            onChanged: widget.onAddressChanged,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
          );

    final shareWidget = SizedBox(
      width: 88,
      child: MallowPillField(
        controller: _shareController,
        hintText: '%',
        onChanged: widget.onShareChanged,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
      ),
    );

    return Row(
      children: [
        Expanded(child: addressWidget),
        const SizedBox(width: MallowTheme.spacingSm),
        shareWidget,
        if (!isSelf && widget.onRemove != null) ...[
          const SizedBox(width: MallowTheme.spacingSm),
          TapTargetExpander(
            child: GestureDetector(
              onTap: widget.onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(MallowTheme.spacingXs),
                child: MallowSvgIcon(
                  'assets/icons/x_circle.svg',
                  width: 20,
                  height: 20,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
