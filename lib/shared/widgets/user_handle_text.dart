import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../utils/user_display.dart';
import 'tap_target_expander.dart';

/// Renders `@handle` (or a truncated address fallback) as an inline,
/// tappable span. Tapping navigates to the user's profile — by username
/// when present, otherwise by address. When neither is set the widget
/// renders an empty `SizedBox` so callers can drop it without guarding.
///
/// Optional [prefix] is rendered with the same style ahead of the handle
/// but is not part of the tap target, so labels like "by @handle" or
/// "Winner: @handle" can share one widget.
class UserHandleText extends StatelessWidget {
  const UserHandleText({
    required this.username,
    required this.address,
    this.prefix,
    this.style,
    this.linkStyle,
    this.suffix,
    this.maxLines,
    this.overflow,
    this.showAt = true,
    super.key,
  });

  final String? username;
  final String? address;
  final String? prefix;
  final TextStyle? style;

  /// Style for the tappable handle span; falls back to [style].
  final TextStyle? linkStyle;
  final String? suffix;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Whether to render the `@` prefix ahead of the username.
  final bool showAt;

  @override
  Widget build(BuildContext context) {
    final label = showAt
        ? formatHandleOrAddress(username: username, address: address)
        : formatUsernameOrAddress(username: username, address: address);
    if (label.isEmpty) return const SizedBox.shrink();
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        style: effectiveStyle,
        children: [
          if (prefix != null) TextSpan(text: prefix),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: TapTargetExpander(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final u = username;
                  if (u != null && u.isNotEmpty) {
                    context.push(AppRoutes.profileByUsernamePath(u));
                    return;
                  }
                  final a = address;
                  if (a != null && a.isNotEmpty) {
                    context.push(AppRoutes.profilePath(a));
                  }
                },
                child: Text(label, style: linkStyle ?? effectiveStyle),
              ),
            ),
          ),
          if (suffix != null) TextSpan(text: suffix),
        ],
      ),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }
}
