import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class SeedPhraseGrid extends StatefulWidget {
  const SeedPhraseGrid({
    required this.words,
    super.key,
    this.is24Words = false,
    this.editable = false,
    this.onWordChanged,
    this.onPhrasePasted,
  });

  final List<String> words;
  final bool is24Words;
  final bool editable;
  final void Function(int, String)? onWordChanged;

  /// Called when a multi-word phrase is pasted into any field.
  final void Function(List<String> words)? onPhrasePasted;

  @override
  State<SeedPhraseGrid> createState() => _SeedPhraseGridState();
}

class _SeedPhraseGridState extends State<SeedPhraseGrid>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<TextEditingController> _textControllers = [];
  List<FocusNode> _focusNodes = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..forward();
    _syncControllers();
  }

  void _syncControllers() {
    // Dispose old controllers and focus nodes
    for (final c in _textControllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _textControllers = List.generate(
      widget.words.length,
      (i) => TextEditingController(text: widget.words[i]),
    );
    _focusNodes = List.generate(widget.words.length, (i) => FocusNode());
  }

  /// Get the next word index in visual order (left-to-right, top-to-bottom).
  int? _getNextWordIndex(int currentWordIndex) {
    final columnCount = widget.is24Words ? 3 : 2;
    final rowCount = widget.is24Words ? 8 : 6;
    final totalWords = columnCount * rowCount;

    // Word index is now row-major: wordIndex = rowIndex * columnCount + colIndex
    // So next word is simply currentWordIndex + 1
    final nextWordIndex = currentWordIndex + 1;
    if (nextWordIndex >= totalWords) {
      return null; // No more fields
    }

    return nextWordIndex;
  }

  void _focusNextField(int currentWordIndex) {
    final nextIndex = _getNextWordIndex(currentWordIndex);
    if (nextIndex != null && nextIndex < _focusNodes.length) {
      _focusNodes[nextIndex].requestFocus();
    }
  }

  @override
  void didUpdateWidget(SeedPhraseGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.words, widget.words) ||
        oldWidget.is24Words != widget.is24Words) {
      _controller.forward(from: 0);
      _syncControllers();
    }
  }

  @override
  void dispose() {
    for (final c in _textControllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final columnCount = widget.is24Words ? 3 : 2;
    final rowCount = widget.is24Words ? 8 : 6;

    return Column(
      children: List.generate(
        rowCount,
        (rowIndex) => _buildRow(context, rowIndex, rowCount, columnCount),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    int rowIndex,
    int rowCount,
    int columnCount,
  ) {
    final isLastRow = rowIndex == rowCount - 1;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(columnCount, (colIndex) {
        // Row-major ordering: numbers go left-to-right, then top-to-bottom
        final wordIndex = rowIndex * columnCount + colIndex;
        final isLastColumn = colIndex == columnCount - 1;

        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: isLastColumn ? 0 : 12),
            child: _buildWordCell(
              context,
              wordIndex,
              isLastRow,
              rowCount * columnCount,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildWordCell(
    BuildContext context,
    int index,
    bool isLastRow,
    int totalWords,
  ) {
    final word = index < widget.words.length ? widget.words[index] : '';

    // Staggered fade: each word starts slightly after the previous
    // Words overlap so it shimmers rather than pops one at a time
    // With row-major ordering, index equals the visual order
    final startPercent = index / totalWords * 0.6;
    final endPercent = startPercent + 0.4;

    final fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        startPercent.clamp(0.0, 1.0),
        endPercent.clamp(0.0, 1.0),
        curve: Curves.easeOut,
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        border: isLastRow
            ? null
            : Border(
                bottom: BorderSide(color: context.mallowColors.dividerLight),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: FadeTransition(
              opacity: fadeAnimation,
              child: Text(
                '${index + 1}.',
                style: GoogleFonts.newsreader(
                  fontSize: 17,
                  fontStyle: FontStyle.italic,
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ),
          ),
          if (widget.editable)
            Expanded(
              child: TextField(
                controller: index < _textControllers.length
                    ? _textControllers[index]
                    : null,
                focusNode: index < _focusNodes.length
                    ? _focusNodes[index]
                    : null,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                style: MallowTheme.uiBody,
                textInputAction: _getNextWordIndex(index) != null
                    ? TextInputAction.next
                    : TextInputAction.done,
                onSubmitted: (_) => _focusNextField(index),
                onChanged: (val) {
                  final trimmed = val.trim();
                  final parts = trimmed.split(RegExp(r'\s+'));
                  if (parts.length > 1 && widget.onPhrasePasted != null) {
                    widget.onPhrasePasted!(parts);
                  } else {
                    widget.onWordChanged?.call(index, val);
                  }
                },
              ),
            )
          else
            FadeTransition(
              opacity: fadeAnimation,
              child: Text(word, style: MallowTheme.uiBody),
            ),
        ],
      ),
    );
  }
}
