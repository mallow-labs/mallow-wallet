import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_certificate_exceptions.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/services/dapp_request_coordinator.dart';
import 'package:mallow_wallet/features/browser/services/tezos_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_certificate_warning.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_page_menu.dart';
import 'package:mallow_wallet/features/browser/widgets/dapp_connect_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

final _page = Uri.parse('https://devbox.example.com:5173/app?x=1');
final _der = Uint8List.fromList([0x30, 0x82, 1, 2, 3]);

ServerTrustChallenge _challenge({SslErrorType? code, Uint8List? der}) =>
    ServerTrustChallenge(
      protectionSpace: URLProtectionSpace(
        host: _page.host,
        protocol: 'https',
        port: _page.port,
        sslError: code == null ? null : SslError(code: code),
        sslCertificate: der == null
            ? null
            : SslCertificate(x509Certificate: X509Certificate()..encoded = der),
      ),
    );

void main() {
  group('browserCertificateFailure', () {
    test('iOS hands a trusted certificate back to the platform', () {
      for (final code in [null, SslErrorType.UNSPECIFIED]) {
        expect(
          browserCertificateFailure(
            _challenge(code: code, der: _der),
            url: _page,
            isIOS: true,
          ),
          isNull,
        );
      }
    });

    test('iOS lets the user override only a recoverable failure', () {
      final recoverable = browserCertificateFailure(
        _challenge(code: SslErrorType.RECOVERABLE_TRUST_FAILURE, der: _der),
        url: _page,
        isIOS: true,
      )!;
      expect(recoverable.overridable, isTrue);
      expect(recoverable.fingerprint, browserCertificateFingerprint(_der));
      expect(recoverable.origin, 'https://devbox.example.com:5173');

      final fatal = browserCertificateFailure(
        _challenge(code: SslErrorType.FATAL_TRUST_FAILURE, der: _der),
        url: _page,
        isIOS: true,
      )!;
      expect(fatal.overridable, isFalse);
    });

    test('Android failures are overridable and named like Chrome', () {
      final failure = browserCertificateFailure(
        _challenge(code: SslErrorType.UNTRUSTED, der: _der),
        url: _page,
        isIOS: false,
      )!;
      expect(failure.overridable, isTrue);
      expect(failure.reason, 'ERR_CERT_AUTHORITY_INVALID');
    });

    test('a failure without a certificate cannot be bypassed', () {
      final failure = browserCertificateFailure(
        _challenge(code: SslErrorType.UNTRUSTED),
        url: _page,
        isIOS: false,
      )!;
      expect(failure.fingerprint, isNull);
      expect(failure.overridable, isFalse);
    });
  });

  group('BrowserCertificateExceptions', () {
    final certA = browserCertificateFingerprint(_der);
    final certB = browserCertificateFingerprint(Uint8List.fromList([9, 9]));
    late String? stored;
    late int writes;
    late int legacyDeletes;
    BrowserCertificateExceptions store() => BrowserCertificateExceptions(
      read: () async => stored,
      write: (value) async {
        writes++;
        stored = value;
      },
      deleteLegacy: () async => legacyDeletes++,
    );
    setUp(() {
      stored = null;
      writes = 0;
      legacyDeletes = 0;
    });

    test('an exception covers one certificate on one origin', () async {
      final exceptions = store();
      await exceptions.allow(_page.origin, certA);
      expect(exceptions.allows(_page.origin, certA), isTrue);
      // An interceptor presenting any other certificate is warned about.
      expect(exceptions.allows(_page.origin, certB), isFalse);
      expect(exceptions.allows('https://devbox.example.com', certA), isFalse);
      expect(exceptions.covers(_page.origin), isTrue);
      expect(exceptions.covers('https://devbox.example.com'), isFalse);
      expect(exceptions.coversHost('DEVBOX.example.com'), isTrue);
      expect(exceptions.coversHost('other.example.com'), isFalse);
    });

    test('a rotated certificate is added beside the old one', () async {
      final exceptions = store();
      await exceptions.allow(_page.origin, certA);
      await exceptions.allow(_page.origin, certB);
      expect(exceptions.allows(_page.origin, certA), isTrue);
      expect(exceptions.allows(_page.origin, certB), isTrue);
      for (
        var i = 0;
        i < BrowserCertificateExceptions.maxCertificatesPerOrigin;
        i++
      ) {
        await exceptions.allow(
          _page.origin,
          browserCertificateFingerprint(Uint8List.fromList([i])),
        );
      }
      expect(exceptions.allows(_page.origin, certA), isFalse);
    });

    test('an accepted certificate stays accepted after a restart', () async {
      await store().allow(_page.origin, certA);

      final restarted = store();
      expect(restarted.allows(_page.origin, certA), isFalse);
      await restarted.load();
      expect(restarted.allows(_page.origin, certA), isTrue);
      expect(restarted.allows(_page.origin, certB), isFalse);
    });

    test('origin-only exceptions from the first format are dropped', () async {
      // The v1 row lives under its own key and is never read: whatever was
      // accepted there warns again, and the row is deleted.
      final exceptions = store();
      await exceptions.load();
      expect(legacyDeletes, 1);
      expect(exceptions.covers(_page.origin), isFalse);

      // A list in the current key, as a downgrade-then-upgrade could leave,
      // trusts nothing either.
      stored = '["${_page.origin}"]';
      final listed = store();
      await listed.load();
      expect(listed.covers(_page.origin), isFalse);
    });

    test('accepting before the saved list loads keeps both', () async {
      stored = '{"https://a.example":["$certB"]}';
      final exceptions = store();
      await exceptions.allow(_page.origin, certA);
      expect(exceptions.allows('https://a.example', certB), isTrue);
      expect(stored, contains('https://a.example'));
      expect(stored, contains(_page.origin));
      expect(stored, contains(certA));
    });

    test('clearing forgets every site, saved ones included', () async {
      await store().allow(_page.origin, certA);

      final restarted = store();
      await restarted.clear();
      expect(restarted.covers(_page.origin), isFalse);
      expect(stored, isNull);
      final again = store();
      await again.load();
      expect(again.covers(_page.origin), isFalse);
    });

    test('a clear during the first read is not undone by it', () async {
      stored = '{"${_page.origin}":["$certA"]}';
      final read = Completer<String?>();
      final exceptions = BrowserCertificateExceptions(
        read: () => read.future,
        write: (value) async => stored = value,
      );
      final loading = exceptions.load();
      final clearing = exceptions.clear();
      read.complete(stored);
      await loading;
      await clearing;
      expect(exceptions.covers(_page.origin), isFalse);
      expect(stored, isNull);
    });

    test('a corrupt or unreadable store leaves no exceptions', () async {
      for (final raw in [
        '{',
        '{"a":1}',
        '{"http://plain.example":["$certA"]}',
        '{"${_page.origin}":["not-a-fingerprint", 1]}',
      ]) {
        stored = raw;
        final exceptions = store();
        await exceptions.load();
        expect(exceptions.covers('http://plain.example'), isFalse);
        expect(exceptions.covers(_page.origin), isFalse);
      }
      final failing = BrowserCertificateExceptions(
        read: () async => throw Exception('locked'),
        write: (_) async {},
      );
      await failing.load();
      expect(failing.covers(_page.origin), isFalse);
    });

    test('a failed save still opens the site for this run', () async {
      final exceptions = BrowserCertificateExceptions(
        read: () async => null,
        write: (_) async => throw Exception('locked'),
      );
      await exceptions.allow(_page.origin, certA);
      expect(exceptions.allows(_page.origin, certA), isTrue);
    });

    test(
      'only canonical HTTPS origins and real fingerprints are kept',
      () async {
        final exceptions = store();
        await exceptions.allow('http://plain.example', certA);
        await exceptions.allow('${_page.origin}/path', certA);
        await exceptions.allow(_page.origin, 'aa');
        expect(writes, 0);
        expect(exceptions.covers('http://plain.example'), isFalse);
        expect(exceptions.covers(_page.origin), isFalse);
      },
    );

    test('changes notify listeners, so the chrome can mark the site', () async {
      final exceptions = store();
      var notified = 0;
      exceptions.addListener(() => notified++);
      await exceptions.allow(_page.origin, certA);
      await exceptions.allow(_page.origin, certA);
      expect(notified, 1);
      await exceptions.clear();
      expect(notified, 2);
    });
  });

  group('connect on a certificate exception', () {
    const address = '11111111111111111111111111111111';
    late String? stored;
    late int approvals;
    late DappPermissionService permissions;
    late DappRequestCoordinator coordinator;
    var sequence = 0;

    DappFrameContext frame({required bool exception}) => DappFrameContext(
      tabId: 'tab',
      generation: 1,
      origin: Uri.parse(_page.origin),
      isMainFrame: true,
      isActive: true,
      certificateException: exception,
    );
    Map<String, dynamic> connect([Map<String, dynamic>? params]) => {
      'id': '${sequence++}',
      'method': 'connect',
      'params': params ?? {},
    };

    setUp(() async {
      stored = null;
      approvals = 0;
      permissions = DappPermissionService(
        read: () async => stored,
        write: (value) async => stored = value,
      );
      coordinator = DappRequestCoordinator(
        permissions: permissions,
        currentWallet: () =>
            const DappWallet(id: 'wallet', address: address, canSign: true),
        approveConnection: (_) async {
          approvals++;
          return true;
        },
        execute: (_) async => {},
        isContextCurrent: (_) => true,
      );
      await permissions.grant(_page.origin, address);
    });
    tearDown(() async {
      coordinator.dispose();
      await permissions.dispose();
    });

    test('a saved grant still connects silently on a trusted page', () async {
      final result = await coordinator.handle(
        connect(),
        frame(exception: false),
      );
      expect((result['result'] as Map?)?['publicKey'], address);
      expect(approvals, 0);
    });

    test(
      'a saved grant is not trusted without a verified certificate',
      () async {
        final trusted = await coordinator.handle(
          connect({'onlyIfTrusted': true}),
          frame(exception: true),
        );
        expect((trusted['error'] as Map?)?['code'], 4100);

        final asked = await coordinator.handle(
          connect(),
          frame(exception: true),
        );
        expect((asked['result'] as Map?)?['publicKey'], address);
        expect(approvals, 1);
      },
    );
  });

  group('signing on a certificate exception', () {
    const solana = '11111111111111111111111111111111';
    const ethereum = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
    const tezos = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
    late String? stored;
    late int approvals;
    late List<DappSigningRequest> executed;
    late DappPermissionService permissions;
    late DappRequestCoordinator coordinator;
    var sequence = 0;

    DappFrameContext frame({
      bool exception = true,
      int generation = 1,
      String document = 'doc-1',
    }) => DappFrameContext(
      tabId: 'tab',
      generation: generation,
      origin: Uri.parse(_page.origin),
      isMainFrame: true,
      isActive: true,
      certificateException: exception,
      documentToken: document,
    );
    Map<String, dynamic> call(
      String method, {
      String? namespace,
      Map<String, Object?> params = const {},
    }) => {
      'id': '${sequence++}',
      'method': method,
      'namespace': ?namespace,
      'params': params,
    };
    String? message(Map<String, Object?> response) =>
        (response['error'] as Map?)?['message'] as String?;
    int? code(Map<String, Object?> response) =>
        (response['error'] as Map?)?['code'] as int?;

    final requests =
        <
          String,
          (Map<String, dynamic> Function(), Map<String, dynamic> Function())
        >{
          'solana': (
            () => call('connect'),
            () => call('signTransaction', params: {'transaction': 'AQID'}),
          ),
          'eip155': (
            () => call('connect', namespace: 'eip155'),
            () => call(
              'personal_sign',
              namespace: 'eip155',
              params: {'message': 'hello'},
            ),
          ),
          'tezos': (
            () => call('connect', namespace: 'tezos'),
            () => call(
              'signPayload',
              namespace: 'tezos',
              params: {
                'payload': '0501000000026869',
                'signingType': 'micheline',
              },
            ),
          ),
        };

    setUp(() async {
      stored = null;
      approvals = 0;
      executed = [];
      permissions = DappPermissionService(
        read: () async => stored,
        write: (value) async => stored = value,
      );
      coordinator = DappRequestCoordinator(
        permissions: permissions,
        currentWallet: () =>
            const DappWallet(id: 'sol', address: solana, canSign: true),
        currentEthereumWallet: () => const DappWallet(
          id: 'eth',
          address: ethereum,
          canSign: true,
          chains: ['eip155:1'],
        ),
        currentTezosWallet: () => const DappWallet(
          id: 'tez',
          address: tezos,
          canSign: true,
          chains: [tezosMainnet],
        ),
        tezosPublicKey: (_, active) async {
          active();
          return 'edpkuRXPQpuQyDemXE59dyYA1Eu5T94waiiL5PjcWDSkkw86ZvxR2j';
        },
        approveConnection: (_) async {
          approvals++;
          return true;
        },
        execute: (request) async {
          executed.add(request);
          return {'signature': 'sig'};
        },
        isContextCurrent: (_) => true,
      );
      // Granted earlier, on a page whose certificate was trusted.
      await permissions.grant(_page.origin, solana);
      await permissions.grant(_page.origin, ethereum);
      await permissions.grant(
        _page.origin,
        tezos,
        scopes: const ['sign', 'operation_request'],
      );
    });
    tearDown(() async {
      coordinator.dispose();
      await permissions.dispose();
    });

    for (final MapEntry(key: namespace, value: (connect, sign))
        in requests.entries) {
      test(
        '$namespace: a saved grant does not let the page skip connect',
        () async {
          final refused = await coordinator.handle(sign(), frame());
          expect(code(refused), 4100);
          expect(message(refused), contains('certificate is not trusted'));
          expect(executed, isEmpty);

          final trusted = await coordinator.handle(
            sign(),
            frame(exception: false),
          );
          expect(trusted['error'], isNull);
          expect(executed, hasLength(1));
        },
      );

      test(
        '$namespace: connecting under the warning admits that document only',
        () async {
          expect(
            (await coordinator.handle(connect(), frame()))['error'],
            isNull,
          );
          expect(approvals, 1);
          expect((await coordinator.handle(sign(), frame()))['error'], isNull);
          expect(executed, hasLength(1));

          // A new document, or a new WebView whose generations restarted,
          // inherits nothing.
          for (final next in [
            frame(generation: 2, document: 'doc-2'),
            frame(document: 'doc-3'),
          ]) {
            expect(code(await coordinator.handle(sign(), next)), 4100);
          }
          expect(executed, hasLength(1));

          // Cancelling work (an overlay, the app in the background) keeps the
          // page connected, so it keeps the document's approval too.
          coordinator.invalidate();
          expect((await coordinator.handle(sign(), frame()))['error'], isNull);
        },
      );
    }
  });

  group('chrome on a site past a certificate warning', () {
    BrowserAddressBar bar({required bool notSecure, bool compact = false}) =>
        BrowserAddressBar(
          compact: compact,
          host: _page.host,
          blank: false,
          loading: false,
          notSecure: notSecure,
          onAddress: () {},
          onTabs: () {},
          onReloadOrStop: () {},
          onExpand: () {},
        );
    Widget app(Widget child) => MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Align(alignment: Alignment.topCenter, child: child),
      ),
    );

    testWidgets('the address bar trades its lock for a warning', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(bar(notSecure: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('browser-address-not-secure')), findsNothing);
      expect(
        find.bySemanticsLabel('Edit address, ${_page.host}'),
        findsOneWidget,
      );

      await tester.pumpWidget(app(bar(notSecure: true)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('browser-address-not-secure')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Edit address, not secure, ${_page.host}'),
        findsOneWidget,
      );

      await tester.pumpWidget(app(bar(notSecure: true, compact: true)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('browser-address-not-secure')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('${_page.host}. Not secure. Show toolbar'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the page menu says the site is not secure', (tester) async {
      for (final notSecure in [false, true]) {
        await tester.pumpWidget(
          app(
            BrowserPageMenu(
              url: _page,
              title: 'Dev',
              bookmarked: false,
              loading: false,
              wallet: null,
              connected: false,
              notSecure: notSecure,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('browser-menu-not-secure')),
          notSecure ? findsOneWidget : findsNothing,
        );
      }
    });
  });

  group('BrowserCertificateWarning', () {
    Future<(List<String>, Widget)> pump(
      WidgetTester tester, {
      bool overridable = true,
    }) async {
      final calls = <String>[];
      final widget = MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BrowserCertificateWarning(
            failure: BrowserCertificateFailure(
              url: _page,
              fingerprint: overridable ? 'aa' : null,
              overridable: overridable,
              reason: 'ERR_CERT_AUTHORITY_INVALID',
            ),
            onBack: () => calls.add('back'),
            onProceed: () => calls.add('proceed'),
          ),
        ),
      );
      await tester.pumpWidget(widget);
      return (calls, widget);
    }

    testWidgets('proceeding sits behind Advanced', (tester) async {
      final (calls, _) = await pump(tester);
      expect(find.text('Your connection is not private'), findsOneWidget);
      expect(find.byKey(const Key('certificate-proceed')), findsNothing);

      await tester.tap(find.byKey(const Key('certificate-back')));
      await tester.tap(find.byKey(const Key('certificate-advanced')));
      await tester.pumpAndSettle();
      expect(
        find.text('Proceed to devbox.example.com:5173 (unsafe)'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('certificate-proceed')));
      await tester.tap(find.byKey(const Key('certificate-proceed')));
      expect(calls, ['back', 'proceed']);
    });

    testWidgets('a fatal failure offers no way through', (tester) async {
      await pump(tester, overridable: false);
      await tester.tap(find.byKey(const Key('certificate-advanced')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('certificate-proceed')), findsNothing);
      expect(find.textContaining("can't be bypassed"), findsOneWidget);
    });
  });

  testWidgets('the connect sheet warns on a certificate exception', (
    tester,
  ) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    unawaited(
      Navigator.of(host).push(
        dappConnectRoute(
          context: host,
          request: DappConnectionRequest(
            context: DappFrameContext(
              tabId: 'tab',
              generation: 1,
              origin: Uri.parse(_page.origin),
              isMainFrame: true,
              isActive: true,
              certificateException: true,
            ),
            wallet: const DappWallet(
              id: 'w',
              address: '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU',
              canSign: true,
            ),
            cancelled: Completer<void>().future,
            ensureActive: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('connect-certificate-warning')),
      findsOneWidget,
    );
  });
}
