import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';

/// Reusable page header with back button and title.
///
/// Matches the 8px-gap Row-based pattern used across the app.
/// Optional [actions] for trailing icons (copy, paste, etc).
class MallowHeader extends StatelessWidget {
  const MallowHeader({
    required this.title,
    this.onBack,
    this.actions,
    super.key,
  });

  /// Header title text.
  final String title;

  /// Custom back action. Defaults to `context.pop()`.
  final VoidCallback? onBack;

  /// Optional trailing action widgets.
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final backAction = onBack ?? () => context.pop();
    return Row(
      children: [
        Expanded(
          child: Transform.translate(
            offset: const Offset(-5, 0),
            child: GestureDetector(
              onTap: backAction,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                child: Transform.translate(
                  offset: const Offset(-12, 0),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: MallowSvgIcon(
                            'assets/icons/arrow_left.svg',
                            width: 16,
                            height: 16,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          title,
                          style: MallowTheme.editorialSection,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        ...?actions,
      ],
    );
  }
}
