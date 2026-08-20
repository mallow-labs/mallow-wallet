import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../shared/theme/mallow_theme.dart';

/// Header shown when viewing filter results — replaces the search bar.
/// Displays the filter name with a back chevron.
class FilterResultsHeader extends StatelessWidget {
  const FilterResultsHeader({
    required this.label,
    required this.onBack,
    super.key,
  });

  final String label;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Transform.translate(
      offset: const Offset(-12, 0),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onBack,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: SvgPicture.asset(
                  'assets/icons/arrow_left.svg',
                  width: 16,
                  height: 16,
                  colorFilter: ColorFilter.mode(
                    colors.textPrimary,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.newsreader(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
