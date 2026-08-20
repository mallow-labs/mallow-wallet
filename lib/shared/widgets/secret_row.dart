import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import '../utils/address_utils.dart';
import 'mallow_svg_icon.dart';

/// Read-only adaptation of the Edit-Accounts row: leading avatar/glyph, title,
/// a horizontally-scrollable run of address pills, and a trailing chevron.
///
/// Shared by the "Your secrets" screen and the "Select recovery phrase" import
/// picker so both read identically.
class SecretRow extends StatelessWidget {
  const SecretRow({
    required this.leading,
    required this.title,
    required this.addresses,
    required this.onTap,
    super.key,
  });

  final Widget leading;
  final String title;
  final List<String> addresses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: MallowTheme.uiMeta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (addresses.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < addresses.length; i++)
                            Padding(
                              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                              child: _AddressPill(
                                address: truncateAddress(addresses[i]),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            MallowSvgIcon(
              'assets/icons/arrow_right.svg',
              width: 16,
              height: 16,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Leading slot for recovery-phrase rows — a static notes glyph in a muted
/// circle (recovery phrases span several accounts, so there is no single
/// account avatar to show).
class SecretGlyphAvatar extends StatelessWidget {
  const SecretGlyphAvatar({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: MallowSvgIcon(
          'assets/icons/notes.svg',
          width: 14,
          height: 14,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// A filled pill showing a single truncated wallet address. Mirrors the
/// Edit-Accounts address pill so the rows read identically.
class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        address,
        style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
      ),
    );
  }
}
