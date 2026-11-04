import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import 'browser_host_text.dart';

/// The page dialog being shown: `alert()`, `confirm()`, `prompt()`, or the
/// leave-page check a `beforeunload` handler asks for.
enum BrowserJsDialogKind { alert, confirm, prompt, beforeUnload }

/// What the user chose. [confirmed] is OK (or Leave); [value] is the text a
/// prompt returns. [blockMore] asks that this page show no more dialogs.
typedef BrowserJsDialogResult = ({
  bool confirmed,
  String? value,
  bool blockMore,
});

/// The longest page message shown. Longer text is cut, as browsers do.
const int _maxMessageLength = 2000;

/// A page's JavaScript dialog, named by the site that raised it, as a
/// browser does ("example.com says"). The platform's own dialogs name no
/// one, so a page could pass its text off as the wallet's.
///
/// [host] is the requesting frame's host, as the WebView reports it, never
/// page-supplied text. [embeddedIn] is set when that frame is not the page
/// itself: an iframe, or a frame with no host of its own (`data:`), whose
/// [host] is then the page's.
///
/// Pops with the user's answer. A dismissal (a drag, a tap on the scrim)
/// pops null, which the caller treats as Cancel.
class BrowserJsDialogSheet extends StatefulWidget {
  const BrowserJsDialogSheet({
    required this.kind,
    required this.host,
    this.message = '',
    this.defaultValue = '',
    this.embeddedIn,
    this.offerBlock = false,
    super.key,
  });

  final BrowserJsDialogKind kind;
  final String host;
  final String? embeddedIn;
  final String message;
  final String defaultValue;

  /// Offers "Don't allow more dialogs from this page", once a page has
  /// already shown one.
  final bool offerBlock;

  @override
  State<BrowserJsDialogSheet> createState() => _BrowserJsDialogSheetState();
}

class _BrowserJsDialogSheetState extends State<BrowserJsDialogSheet> {
  late final _value = TextEditingController(text: widget.defaultValue);

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _pop({required bool confirmed, bool blockMore = false}) =>
      Navigator.of(context).pop<BrowserJsDialogResult>((
        confirmed: confirmed,
        value: confirmed && widget.kind == BrowserJsDialogKind.prompt
            ? _value.text
            : null,
        blockMore: blockMore,
      ));

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final body = MallowTheme.uiBody.copyWith(color: colors.textSecondary);
    final kind = widget.kind;
    final leave = kind == BrowserJsDialogKind.beforeUnload;
    var message = leave
        // The page's own text is ignored here, as every browser now does:
        // it could say anything to keep the user on the page.
        ? 'Changes you made may not be saved.'
        : widget.message;
    if (message.length > _maxMessageLength) {
      message = '${message.substring(0, _maxMessageLength)}…';
    }
    final embeddedIn = widget.embeddedIn;
    final ok = MallowButton(
      key: const Key('js-dialog-ok'),
      label: leave ? 'Leave' : 'OK',
      isFullWidth: true,
      onPressed: () => _pop(confirmed: true),
    );
    final cancel = kind == BrowserJsDialogKind.alert
        ? null
        : MallowButton(
            key: const Key('js-dialog-cancel'),
            label: leave ? 'Stay' : 'Cancel',
            variant: MallowButtonVariant.secondary,
            isFullWidth: true,
            onPressed: () => _pop(confirmed: false),
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Padding(
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
                  if (embeddedIn != null) ...[
                    Text(
                      'An embedded page on $embeddedIn',
                      key: const Key('js-dialog-embedded'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: body,
                    ),
                    const SizedBox(height: MallowTheme.spacingXs),
                  ],
                  // Outside the scrolling message, so no amount of page text
                  // can push the site's name out of view.
                  BrowserHostText(
                    widget.host,
                    key: const Key('js-dialog-host'),
                    detail: leave ? null : 'says',
                    separator: ' ',
                    style: MallowTheme.editorialSection.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  if (leave) ...[
                    const SizedBox(height: MallowTheme.spacingXs),
                    Text(
                      'Leave this site?',
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (message.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    MallowTheme.spacing20,
                    MallowTheme.spacingSm,
                    MallowTheme.spacing20,
                    0,
                  ),
                  child: Text(
                    message,
                    key: const Key('js-dialog-message'),
                    style: body,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (kind == BrowserJsDialogKind.prompt) ...[
                    MallowPillField(
                      key: const Key('js-dialog-field'),
                      controller: _value,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      height: 48,
                      onSubmitted: (_) => _pop(confirmed: true),
                    ),
                    const SizedBox(height: MallowTheme.spacingSm),
                    // A page can ask for anything, so this is the one place
                    // the wallet says what it never asks for.
                    Text(
                      'Never enter your recovery phrase or private key on a '
                      'website.',
                      key: const Key('js-dialog-seed-warning'),
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.warning,
                      ),
                    ),
                  ],
                  const SizedBox(height: MallowTheme.spacingLg),
                  if (cancel == null)
                    ok
                  // Large text stacks the buttons so neither label breaks.
                  else if (MediaQuery.textScalerOf(context).scale(15) > 22) ...[
                    ok,
                    const SizedBox(height: MallowTheme.spacingSm),
                    cancel,
                  ] else
                    Row(
                      children: [
                        Expanded(child: cancel),
                        const SizedBox(width: MallowTheme.spacingSm),
                        Expanded(child: ok),
                      ],
                    ),
                  if (widget.offerBlock) ...[
                    const SizedBox(height: MallowTheme.spacingSm),
                    MallowButton(
                      key: const Key('js-dialog-block'),
                      label: "Don't allow more dialogs from this page",
                      variant: MallowButtonVariant.text,
                      isFullWidth: true,
                      onPressed: () => _pop(confirmed: leave, blockMore: true),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Answers a browser WebView's JavaScript dialogs with [BrowserJsDialogSheet],
/// one at a time, on the root navigator.
///
/// A dialog is shown only while [isActive] holds and is named by the frame
/// that raised it. One that cannot be named is answered as dismissed without
/// being shown. Once the user blocks dialogs, the rest of that document's
/// are answered the same way. [dispose] answers a pending one and removes
/// its sheet.
class BrowserJsDialogs {
  BrowserJsDialogs({
    required this.context,
    required this.isActive,
    required this.document,
  });

  /// The context the sheet is pushed from.
  final BuildContext Function() context;
  final bool Function() isActive;

  /// The page's document: a key that changes with every navigation, and its
  /// committed URL, if one has committed.
  final ({int key, Uri? url}) Function() document;

  final _disposed = Completer<void>();
  Future<void> _queue = Future.value();
  ModalBottomSheetRoute<BrowserJsDialogResult>? _route;
  int? _shownKey;
  int _shownCount = 0;
  int? _blockedKey;

  Future<JsAlertResponse> alert(JsAlertRequest request) async {
    await _show(
      BrowserJsDialogKind.alert,
      url: request.url,
      isMainFrame: request.isMainFrame,
      message: request.message,
    );
    return JsAlertResponse(
      handledByClient: true,
      action: JsAlertResponseAction.CONFIRM,
    );
  }

  Future<JsConfirmResponse> confirm(JsConfirmRequest request) async {
    final result = await _show(
      BrowserJsDialogKind.confirm,
      url: request.url,
      isMainFrame: request.isMainFrame,
      message: request.message,
    );
    return JsConfirmResponse(
      handledByClient: true,
      action: result?.confirmed == true
          ? JsConfirmResponseAction.CONFIRM
          : JsConfirmResponseAction.CANCEL,
    );
  }

  Future<JsPromptResponse> prompt(JsPromptRequest request) async {
    final result = await _show(
      BrowserJsDialogKind.prompt,
      url: request.url,
      isMainFrame: request.isMainFrame,
      message: request.message,
      defaultValue: request.defaultValue,
    );
    final value = result?.confirmed == true ? result?.value : null;
    return value == null
        ? JsPromptResponse(
            handledByClient: true,
            action: JsPromptResponseAction.CANCEL,
          )
        : JsPromptResponse(
            handledByClient: true,
            action: JsPromptResponseAction.CONFIRM,
            value: value,
          );
  }

  /// Leaves unless the user chose Stay. A dialog that is not shown (blocked,
  /// or nothing to name) lets the user leave: a handler must never hold the
  /// user on a page.
  Future<JsBeforeUnloadResponse> beforeUnload(
    JsBeforeUnloadRequest request,
  ) async {
    final result = await _show(
      BrowserJsDialogKind.beforeUnload,
      url: request.url,
      isMainFrame: true,
      message: '',
      unanswered: (confirmed: true, value: null, blockMore: false),
    );
    return JsBeforeUnloadResponse(
      handledByClient: true,
      action: result?.confirmed == false
          ? JsBeforeUnloadResponseAction.CANCEL
          : JsBeforeUnloadResponseAction.CONFIRM,
    );
  }

  void dispose() {
    if (!_disposed.isCompleted) _disposed.complete();
    final route = _route;
    if (route != null) {
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (route.isActive) route.navigator?.removeRoute(route);
        })
        // Nothing else may be rebuilding to carry the callback.
        ..scheduleFrame();
    }
  }

  /// Who to name for a dialog from the frame at [url]: its host, and the
  /// page's when the frame is not the page itself. Null when neither is
  /// known, and the dialog is not shown.
  @visibleForTesting
  static ({String host, String? embeddedIn})? attribution({
    required Uri? url,
    required bool? isMainFrame,
    required Uri? documentUrl,
  }) {
    String? hostOf(Uri? uri) {
      final scheme = uri?.scheme.toLowerCase();
      if (uri == null || (scheme != 'https' && scheme != 'http')) return null;
      final host = uri.host.toLowerCase();
      if (host.isEmpty) return null;
      final defaultPort = scheme == 'https' ? 443 : 80;
      return uri.hasPort && uri.port != defaultPort
          ? '$host:${uri.port}'
          : host;
    }

    final frameHost = hostOf(url);
    final pageHost = hostOf(documentUrl);
    if (frameHost == null) {
      // A frame with no host of its own (about:blank, data:, srcdoc) is
      // named by the page that holds it.
      return pageHost == null ? null : (host: pageHost, embeddedIn: pageHost);
    }
    final embedded =
        isMainFrame == false ||
        (pageHost != null && url!.origin != documentUrl!.origin);
    return (host: frameHost, embeddedIn: embedded ? pageHost : null);
  }

  Future<BrowserJsDialogResult?> _show(
    BrowserJsDialogKind kind, {
    required WebUri? url,
    required bool? isMainFrame,
    required String? message,
    String? defaultValue,
    BrowserJsDialogResult? unanswered,
  }) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    try {
      await previous;
      final document = this.document();
      if (_disposed.isCompleted || !isActive() || _blockedKey == document.key) {
        return unanswered;
      }
      final who = attribution(
        url: Uri.tryParse(url?.toString() ?? ''),
        isMainFrame: isMainFrame,
        documentUrl: document.url,
      );
      if (who == null) return unanswered;
      if (_shownKey != document.key) {
        _shownKey = document.key;
        _shownCount = 0;
      }
      final context = this.context();
      if (!context.mounted) return unanswered;
      // Read now: the builder runs only once the route is built.
      final offerBlock = _shownCount > 0;
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = _route = mallowSheetRoute<BrowserJsDialogResult>(
        context: context,
        isScrollControlled: true,
        builder: (_) => BrowserJsDialogSheet(
          kind: kind,
          host: who.host,
          embeddedIn: who.embeddedIn,
          message: message ?? '',
          defaultValue: defaultValue ?? '',
          offerBlock: offerBlock,
        ),
      );
      _shownCount++;
      try {
        final result = await Future.any<BrowserJsDialogResult?>([
          navigator.push(route),
          _disposed.future.then((_) => null),
        ]);
        if (result?.blockMore == true) _blockedKey = document.key;
        // Dismissed (or the page went away): Cancel, and Stay.
        return result ?? (confirmed: false, value: null, blockMore: false);
      } finally {
        if (identical(_route, route)) _route = null;
      }
    } finally {
      done.complete();
    }
  }
}
