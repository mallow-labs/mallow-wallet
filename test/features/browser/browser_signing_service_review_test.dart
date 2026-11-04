import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/widgets/message_signing_review.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _Wallet extends Mock implements WalletManager {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Prices extends Mock implements TokenPriceService {}

class _Storage extends Mock implements SecureWalletStorage {}

void main() {
  late Completer<void> cancelled;
  late BuildContext host;

  DappSigningRequest request() => DappSigningRequest(
    id: '1',
    method: 'signMessage',
    context: DappFrameContext(
      tabId: 't',
      generation: 1,
      origin: Uri.parse('https://site.example'),
      isMainFrame: true,
      isActive: true,
    ),
    wallet: const DappWallet(
      id: 'w',
      address: '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU',
      canSign: true,
    ),
    chain: 'solana:mainnet',
    payloads: [Uint8List.fromList(utf8.encode('hello'))],
    payloadDigest: 'digest',
    cancelled: cancelled.future,
    options: const {},
    ensureActive: () {
      if (cancelled.isCompleted) {
        throw const DappException(4001, 'Request cancelled.');
      }
    },
  );

  Future<Future<Map<String, Object?>>> start(WidgetTester tester) async {
    cancelled = Completer<void>();
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
    final service = BrowserSigningService(
      adapter: SolanaDappAdapter(walletManager: _Wallet()),
      authGate: _Gate(),
      prices: _Prices(),
      session: BrowserSession(BrowserRepository(_Storage())),
    );
    final result = service.execute(host, request());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    return result;
  }

  Future<Object?> outcome(Future<Object?> future) =>
      future.then<Object?>((v) => v, onError: (Object e) => e);

  testWidgets('message review is a popup sheet and rejecting throws 4001', (
    tester,
  ) async {
    final result = outcome(await start(tester));
    final review = find.byType(MessageSigningReview);
    expect(review, findsOneWidget);
    expect(ModalRoute.of(tester.element(review)), isA<PopupRoute<Object?>>());
    await tester.tap(find.byKey(const Key('reject-signing')));
    await tester.pumpAndSettle();
    final error = await result;
    expect(error, isA<DappException>());
    expect((error! as DappException).code, 4001);
    expect(review, findsNothing);
  });

  testWidgets('dismissing the sheet rejects', (tester) async {
    final result = outcome(await start(tester));
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(await result, isA<DappException>());
  });

  testWidgets('cancellation removes exactly the review route', (tester) async {
    final result = outcome(await start(tester));
    // A newer route above the review must survive the cancellation.
    unawaited(
      Navigator.of(host, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('newer route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    cancelled.complete();
    await tester.pumpAndSettle();
    expect(await result, isA<DappException>());
    expect(find.byType(MessageSigningReview), findsNothing);
    expect(find.text('newer route'), findsOneWidget);
  });
}
