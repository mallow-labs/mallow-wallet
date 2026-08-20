import 'package:flutter/material.dart';

import '../../core/data/mallow_tokens.dart';
import '../../core/network/auth_service.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import '../utils/token_image_utils.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';
import 'sheet_overscroll_dismiss.dart';
import 'tappable.dart';

/// Bottom-sheet picker for the bid currency. Returns the selected
/// [MallowToken] or null on dismiss.
Future<MallowToken?> showCurrencyPickerSheet(BuildContext context) {
  return showMallowSheet<MallowToken>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CurrencyPickerSheet(),
  );
}

class _CurrencyPickerSheet extends StatelessWidget {
  const _CurrencyPickerSheet();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final tokens = pickableBidTokens(
      userListingMints: sl<AuthService>().currentUser?.listingTokenMints,
    );
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    return SheetOverscrollDismiss(
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
              ),
              child: Row(
                children: [
                  Text(
                    'Choose currency',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                    textAlign: TextAlign.left,
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
                itemCount: tokens.length,
                itemBuilder: (context, index) {
                  final token = tokens[index];
                  return _CurrencyRow(token: token);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrencyRow extends StatelessWidget {
  const _CurrencyRow({required this.token});

  final MallowToken token;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Tappable(
      onTap: () => Navigator.of(context).pop(token),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: 14,
        ),
        child: Row(
          children: [
            ClipOval(
              child: tokenImageWidget(
                mint: token.mint,
                symbol: token.symbol,
                size: 24,
                useChainSvg: false,
              ),
            ),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: Text(
                token.symbol,
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
