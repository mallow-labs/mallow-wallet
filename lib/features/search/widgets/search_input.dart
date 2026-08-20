import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';

/// Pill-shaped search text field with a search icon on the left.
///
/// Calls [onChanged] with the raw text value whenever the user types.
/// Optionally accepts an external [controller] for programmatic text updates.
class SearchInput extends StatefulWidget {
  const SearchInput({
    required this.onChanged,
    super.key,
    this.autofocus = true,
    this.controller,
    this.hintText = 'Search artists, artworks, tokens…',
  });

  final ValueChanged<String> onChanged;
  final bool autofocus;
  final TextEditingController? controller;
  final String hintText;

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  late final TextEditingController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return MallowPillField(
      controller: _controller,
      hintText: widget.hintText,
      autofocus: widget.autofocus,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.search,
      onChanged: widget.onChanged,
      prefix: SvgPicture.asset(
        'assets/icons/search.svg',
        width: 20,
        height: 20,
        colorFilter: ColorFilter.mode(colors.textSecondary, BlendMode.srcIn),
      ),
    );
  }
}
