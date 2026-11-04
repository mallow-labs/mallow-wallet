import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import '../models/browser_models.dart';
import 'browser_site_tile.dart';

enum BookmarkAction { openInNewTab, edit, reorder, remove }

/// The bookmark long-press menu. Resolves to the chosen action, or null when
/// dismissed; the caller acts after the sheet has closed.
Future<BookmarkAction?> showBookmarkActionsSheet(
  BuildContext context,
  BrowserBookmark bookmark,
) => runGuardedSheet<BookmarkAction>(
  'browserBookmarkActions',
  () => showMallowSheet<BookmarkAction>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BookmarkActionsSheet(bookmark: bookmark),
  ),
);

class BookmarkActionsSheet extends StatelessWidget {
  const BookmarkActionsSheet({required this.bookmark, super.key});
  final BrowserBookmark bookmark;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    void pick(BookmarkAction action) => Navigator.of(context).pop(action);
    return _SheetSurface(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingXs,
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
              ),
              child: Row(
                children: [
                  BrowserSiteTile(
                    host: bookmark.url.host,
                    iconUrl: bookmark.iconUrl,
                    size: 36,
                  ),
                  const SizedBox(width: MallowTheme.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bookmark.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MallowTheme.uiBody.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          bookmark.url.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MallowTheme.uiMeta.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: colors.dividerLight),
            const SizedBox(height: MallowTheme.spacingXs),
            SheetMenuRow(
              label: 'Open in new tab',
              assetPath: 'assets/icons/plus_large.svg',
              onTap: () => pick(BookmarkAction.openInNewTab),
            ),
            SheetMenuRow(
              label: 'Edit bookmark',
              assetPath: 'assets/icons/pencil.svg',
              onTap: () => pick(BookmarkAction.edit),
            ),
            SheetMenuRow(
              label: 'Reorder bookmarks',
              assetPath: 'assets/icons/arrows_sort.svg',
              onTap: () => pick(BookmarkAction.reorder),
            ),
            SheetMenuRow(
              label: 'Remove bookmark',
              assetPath: 'assets/icons/close.svg',
              onTap: () => pick(BookmarkAction.remove),
            ),
            SizedBox(
              height: sheetBottomInset(context, gap: MallowTheme.spacingSm),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edits a bookmark's name and address. Resolves to the edited bookmark, or
/// null when cancelled.
Future<BrowserBookmark?> showBookmarkEditSheet(
  BuildContext context,
  BrowserBookmark bookmark,
) => runGuardedSheet<BrowserBookmark>(
  'browserBookmarkEdit',
  () => showMallowSheet<BrowserBookmark>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BookmarkEditSheet(bookmark: bookmark),
  ),
);

class BookmarkEditSheet extends StatefulWidget {
  const BookmarkEditSheet({required this.bookmark, super.key});
  final BrowserBookmark bookmark;

  @override
  State<BookmarkEditSheet> createState() => _BookmarkEditSheetState();
}

class _BookmarkEditSheetState extends State<BookmarkEditSheet> {
  late final _title = TextEditingController(text: widget.bookmark.title);
  late final _url = TextEditingController(text: widget.bookmark.url.toString());
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  void _save() {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !isBrowserUrl(uri)) {
      setState(() => _error = 'Enter an HTTPS address without credentials');
      return;
    }
    final title = _title.text.trim();
    Navigator.of(context).pop(
      BrowserBookmark(
        url: uri,
        title: title.isEmpty ? uri.host : title,
        // The saved icon belongs to the old host; keep it only while the
        // edited address stays on that host.
        iconUrl: uri.host == widget.bookmark.url.host
            ? widget.bookmark.iconUrl
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final cancel = MallowButton(
      label: 'Cancel',
      variant: MallowButtonVariant.secondary,
      isFullWidth: true,
      onPressed: () => Navigator.of(context).pop(),
    );
    final save = MallowButton(
      label: 'Save',
      isFullWidth: true,
      onPressed: _save,
    );
    return _SheetSurface(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingSm,
                MallowTheme.spacing20,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Edit bookmark',
                    style: MallowTheme.editorialSection.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacing20),
                  const MallowSectionLabel(label: 'Name'),
                  const SizedBox(height: MallowTheme.spacingSm),
                  MallowPillField(
                    key: const Key('bookmark-name'),
                    controller: _title,
                    hintText: widget.bookmark.url.host,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.sentences,
                    height: 48,
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  const MallowSectionLabel(label: 'Address'),
                  const SizedBox(height: MallowTheme.spacingSm),
                  MallowPillField(
                    key: const Key('bookmark-url'),
                    controller: _url,
                    hintText: 'https://',
                    errorText: _error,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    height: 48,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  // Large text stacks the buttons so neither label breaks.
                  if (MediaQuery.textScalerOf(context).scale(15) > 22) ...[
                    save,
                    const SizedBox(height: MallowTheme.spacingSm),
                    cancel,
                  ] else
                    Row(
                      children: [
                        Expanded(child: cancel),
                        const SizedBox(width: MallowTheme.spacingSm),
                        Expanded(child: save),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetSurface extends StatelessWidget {
  const _SheetSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.mallowColors.bgSurface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
    child: child,
  );
}
