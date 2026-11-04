@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_js_dialog.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// Settles a sheet's entrance, including the short buffer after it during
/// which the sheet swallows taps. pumpAndSettle alone stops before that
/// timer, since it schedules no frame.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('BrowserJsDialogs.attribution', () {
    final page = Uri.parse('https://app.example.com/swap');

    test('the page itself is named by its host', () {
      final who = BrowserJsDialogs.attribution(
        url: Uri.parse('https://app.example.com/swap'),
        isMainFrame: null,
        documentUrl: page,
      );
      expect(who, (host: 'app.example.com', embeddedIn: null));
    });

    test('an iframe is named by its own host, inside the page', () {
      // iOS says which frame asked; Android does not, but the frame's URL
      // still differs from the page's.
      for (final isMainFrame in [false, null]) {
        final who = BrowserJsDialogs.attribution(
          url: Uri.parse('https://ads.other.example/frame'),
          isMainFrame: isMainFrame,
          documentUrl: page,
        );
        expect(who, (
          host: 'ads.other.example',
          embeddedIn: 'app.example.com',
        ), reason: '$isMainFrame');
      }
    });

    test('a frame with no host is named by the page that holds it', () {
      final who = BrowserJsDialogs.attribution(
        url: Uri.parse('data:text/html,<p>'),
        isMainFrame: false,
        documentUrl: page,
      );
      expect(who, (host: 'app.example.com', embeddedIn: 'app.example.com'));
    });

    test('nothing to name means no dialog', () {
      expect(
        BrowserJsDialogs.attribution(
          url: Uri.parse('about:blank'),
          isMainFrame: true,
          documentUrl: null,
        ),
        isNull,
      );
      expect(
        BrowserJsDialogs.attribution(
          url: null,
          isMainFrame: null,
          documentUrl: null,
        ),
        isNull,
      );
    });

    test('a non-default port is part of the name', () {
      final who = BrowserJsDialogs.attribution(
        url: Uri.parse('https://app.example.com:8443/'),
        isMainFrame: true,
        documentUrl: Uri.parse('https://app.example.com:8443/'),
      );
      expect(who?.host, 'app.example.com:8443');
    });
  });

  group('BrowserJsDialogs', () {
    late BuildContext hostContext;
    late bool active;
    late ({int key, Uri? url}) document;

    Future<BrowserJsDialogs> mount(WidgetTester tester) async {
      active = true;
      document = (key: 1, url: Uri.parse('https://app.example.com/'));
      await tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      final dialogs = BrowserJsDialogs(
        context: () => hostContext,
        isActive: () => active,
        document: () => document,
      );
      addTearDown(dialogs.dispose);
      return dialogs;
    }

    final pageUrl = WebUri('https://app.example.com/');

    testWidgets('a prompt names the site and returns what was typed', (
      tester,
    ) async {
      final dialogs = await mount(tester);
      final response = dialogs.prompt(
        JsPromptRequest(url: pageUrl, message: 'Your name?', defaultValue: ''),
      );
      await settle(tester);

      expect(find.text('app.example.com'), findsOneWidget);
      expect(find.text(' says'), findsOneWidget);
      expect(find.text('Your name?'), findsOneWidget);
      expect(find.byKey(const Key('js-dialog-seed-warning')), findsOneWidget);
      expect(find.byKey(const Key('js-dialog-block')), findsNothing);

      await tester.enterText(find.byKey(const Key('js-dialog-field')), 'Ana');
      await tester.tap(find.byKey(const Key('js-dialog-ok')));
      await settle(tester);

      final answer = await response;
      expect(answer.handledByClient, isTrue);
      expect(answer.action, JsPromptResponseAction.CONFIRM);
      expect(answer.value, 'Ana');
    });

    testWidgets('Cancel, and a dismissal, answer cancel', (tester) async {
      final dialogs = await mount(tester);
      final prompt = dialogs.prompt(
        JsPromptRequest(url: pageUrl, message: 'Seed?', defaultValue: 'x'),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('js-dialog-cancel')));
      await settle(tester);
      final cancelled = await prompt;
      expect(cancelled.action, JsPromptResponseAction.CANCEL);
      expect(cancelled.value, isNull);

      final confirm = dialogs.confirm(
        JsConfirmRequest(url: pageUrl, message: 'Sure?'),
      );
      await settle(tester);
      // Tap the scrim above the sheet.
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      expect((await confirm).action, JsConfirmResponseAction.CANCEL);
    });

    testWidgets('after the first dialog, the page can be blocked', (
      tester,
    ) async {
      final dialogs = await mount(tester);
      final first = dialogs.alert(JsAlertRequest(url: pageUrl, message: '1'));
      await settle(tester);
      expect(find.byKey(const Key('js-dialog-cancel')), findsNothing);
      expect(find.byKey(const Key('js-dialog-block')), findsNothing);
      await tester.tap(find.byKey(const Key('js-dialog-ok')));
      await settle(tester);
      expect((await first).handledByClient, isTrue);

      final second = dialogs.confirm(
        JsConfirmRequest(url: pageUrl, message: '2'),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('js-dialog-block')));
      await settle(tester);
      expect((await second).action, JsConfirmResponseAction.CANCEL);

      // The rest of this document's dialogs are answered unseen.
      final third = dialogs.prompt(
        JsPromptRequest(url: pageUrl, message: '3', defaultValue: ''),
      );
      await tester.pump();
      expect(find.byType(BrowserJsDialogSheet), findsNothing);
      expect((await third).action, JsPromptResponseAction.CANCEL);

      // A new document starts over.
      document = (key: 2, url: document.url);
      final fourth = dialogs.alert(JsAlertRequest(url: pageUrl, message: '4'));
      await settle(tester);
      expect(find.byType(BrowserJsDialogSheet), findsOneWidget);
      expect(find.byKey(const Key('js-dialog-block')), findsNothing);
      await tester.tap(find.byKey(const Key('js-dialog-ok')));
      await settle(tester);
      await fourth;
    });

    testWidgets('an iframe dialog says which page embeds it', (tester) async {
      final dialogs = await mount(tester);
      final response = dialogs.alert(
        JsAlertRequest(
          url: WebUri('https://ads.other.example/frame'),
          message: 'hello',
          isMainFrame: false,
        ),
      );
      await settle(tester);
      expect(find.text('ads.other.example'), findsOneWidget);
      expect(find.text('An embedded page on app.example.com'), findsOneWidget);
      await tester.tap(find.byKey(const Key('js-dialog-ok')));
      await settle(tester);
      await response;
    });

    testWidgets('an unnamed or inactive dialog is answered unseen', (
      tester,
    ) async {
      final dialogs = await mount(tester);
      document = (key: 1, url: null);
      final unnamed = dialogs.prompt(
        JsPromptRequest(
          url: WebUri('about:blank'),
          message: 'Seed?',
          defaultValue: '',
        ),
      );
      await tester.pump();
      expect(find.byType(BrowserJsDialogSheet), findsNothing);
      expect((await unnamed).action, JsPromptResponseAction.CANCEL);

      document = (key: 1, url: Uri.parse('https://app.example.com/'));
      active = false;
      final inactive = dialogs.confirm(
        JsConfirmRequest(url: pageUrl, message: 'Sure?'),
      );
      await tester.pump();
      expect(find.byType(BrowserJsDialogSheet), findsNothing);
      expect((await inactive).action, JsConfirmResponseAction.CANCEL);
    });

    testWidgets('leaving asks, and Stay keeps the page', (tester) async {
      final dialogs = await mount(tester);
      final stay = dialogs.beforeUnload(
        JsBeforeUnloadRequest(url: pageUrl, message: 'Page text'),
      );
      await settle(tester);
      // The page's own text is not shown.
      expect(find.text('Page text'), findsNothing);
      expect(find.text('Leave this site?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('js-dialog-cancel')));
      await settle(tester);
      expect((await stay).action, JsBeforeUnloadResponseAction.CANCEL);

      final leave = dialogs.beforeUnload(JsBeforeUnloadRequest(url: pageUrl));
      await settle(tester);
      await tester.tap(find.byKey(const Key('js-dialog-ok')));
      await settle(tester);
      expect((await leave).action, JsBeforeUnloadResponseAction.CONFIRM);
    });

    testWidgets('disposing answers a pending dialog and removes its sheet', (
      tester,
    ) async {
      final dialogs = await mount(tester);
      final pending = dialogs.prompt(
        JsPromptRequest(url: pageUrl, message: 'Seed?', defaultValue: ''),
      );
      await settle(tester);
      expect(find.byType(BrowserJsDialogSheet), findsOneWidget);
      dialogs.dispose();
      expect((await pending).action, JsPromptResponseAction.CANCEL);
      // One frame runs the removal, the next drops the sheet.
      await tester.pump();
      await settle(tester);
      expect(find.byType(BrowserJsDialogSheet), findsNothing);
    });
  });
}
