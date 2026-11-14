import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart' show WalletType;
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';
import 'package:mallow_wallet/features/browser/services/ethereum_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/widgets/message_signing_review.dart';
import 'package:mallow_wallet/features/browser/widgets/typed_data_signing_review.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/review_risk_card.dart';
import 'package:mallow_wallet/shared/widgets/review_wallet_identity.dart';
import 'package:mallow_wallet/shared/widgets/signing_review_layout.dart';
import 'package:mallow_wallet/shared/widgets/simulation_review_sheet.dart';
import 'package:mocktail/mocktail.dart';

class _WalletManager extends Mock implements WalletManager {}

const _me = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
const _spender = '0x1111111254eeb25477b68fb85ed929f73a960582';
const _usdc = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
const _wallet = ReviewWalletIdentity(address: _me, name: 'Main');

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Eip712TypedData _permit({String value = '2500000'}) => Eip712TypedData.parse({
  'types': {
    'EIP712Domain': [
      {'name': 'name', 'type': 'string'},
      {'name': 'version', 'type': 'string'},
      {'name': 'chainId', 'type': 'uint256'},
      {'name': 'verifyingContract', 'type': 'address'},
    ],
    'Permit': [
      {'name': 'owner', 'type': 'address'},
      {'name': 'spender', 'type': 'address'},
      {'name': 'value', 'type': 'uint256'},
      {'name': 'nonce', 'type': 'uint256'},
      {'name': 'deadline', 'type': 'uint256'},
    ],
  },
  'primaryType': 'Permit',
  'domain': {
    'name': 'USD Coin',
    'version': '2',
    'chainId': 1,
    'verifyingContract': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
  },
  'message': {
    'owner': _me,
    'spender': _spender,
    'value': value,
    'nonce': 0,
    'deadline': 1893456000,
  },
});

void main() {
  for (final (count, unlimited) in [
    (20, false),
    (21, true),
    (21, false),
    (23, true),
  ]) {
    testWidgets('a $count-entry Permit2 batch with unlimited=$unlimited '
        'discloses omitted permissions', (tester) async {
      final review =
          await EthereumDappAdapter(
            walletManager: _WalletManager(),
            rpc: (_, _) async =>
                throw StateError('No token metadata available'),
          ).prepareTypedData(
            typedData: {
              'types': {
                'EIP712Domain': [
                  {'name': 'chainId', 'type': 'uint256'},
                  {'name': 'verifyingContract', 'type': 'address'},
                ],
                'PermitDetails': [
                  {'name': 'token', 'type': 'address'},
                  {'name': 'amount', 'type': 'uint160'},
                  {'name': 'expiration', 'type': 'uint48'},
                  {'name': 'nonce', 'type': 'uint48'},
                ],
                'PermitBatch': [
                  {'name': 'details', 'type': 'PermitDetails[]'},
                  {'name': 'spender', 'type': 'address'},
                  {'name': 'sigDeadline', 'type': 'uint256'},
                ],
              },
              'primaryType': 'PermitBatch',
              'domain': {'chainId': 1, 'verifyingContract': permit2Address},
              'message': {
                'details': [
                  for (var i = 0; i < count; i++)
                    {
                      'token': i < 20 ? _spender : _usdc,
                      'amount': i < 20 || !unlimited
                          ? '0'
                          : ((BigInt.one << 160) - BigInt.one).toString(),
                      'expiration': 1893456000,
                      'nonce': 0,
                    },
                ],
                'spender': _spender,
                'sigDeadline': 1893456000,
              },
            },
            origin: 'https://app.example',
            address: _me,
            walletId: 'w',
          );
      var approved = 0;
      await _pump(
        tester,
        TypedDataSigningReview(
          review: review,
          wallet: _wallet,
          onReject: () {},
          onApprove: () => approved++,
        ),
      );
      expect(
        find.text(
          count == 20
              ? 'Revoke a spending permission'
              : 'Grant a spending permission',
        ),
        findsOneWidget,
      );
      if (count > 20) {
        expect(find.text('Revoke a spending permission'), findsNothing);
        final warning = find.byKey(const Key('unsummarized-permissions'));
        expect(warning, findsOneWidget);
        expect(
          find.text(
            count == 21
                ? '1 permission is not summarised'
                : '3 permissions are not summarised',
          ),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(warning).dy,
          lessThan(
            tester.getTopLeft(find.text('Revoke token allowance').first).dy,
          ),
        );
      } else {
        expect(find.byKey(const Key('unsummarized-permissions')), findsNothing);
      }
      expect(find.text('Revoke token allowance'), findsNWidgets(20));
      await tester.tap(find.byKey(const Key('approve-signing')));
      await tester.pump();
      expect(approved, 0);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('approve-signing'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(approved, 1, reason: 'long batches remain signable by holding');
    });
  }

  for (final primaryType in [
    'TransferWithAuthorization',
    'ReceiveWithAuthorization',
  ]) {
    testWidgets('$primaryType shows the transfer and requires a hold', (
      tester,
    ) async {
      var approved = 0;
      final review =
          await EthereumDappAdapter(
            walletManager: _WalletManager(),
            rpc: (_, _) async =>
                throw StateError('No token metadata available'),
          ).prepareTypedData(
            typedData: {
              'types': {
                'EIP712Domain': [
                  {'name': 'verifyingContract', 'type': 'address'},
                ],
                primaryType: [
                  {'name': 'from', 'type': 'address'},
                  {'name': 'to', 'type': 'address'},
                  {'name': 'value', 'type': 'uint256'},
                  {'name': 'validAfter', 'type': 'uint256'},
                  {'name': 'validBefore', 'type': 'uint256'},
                  {'name': 'nonce', 'type': 'bytes32'},
                ],
              },
              'primaryType': primaryType,
              'domain': {'verifyingContract': _usdc},
              'message': {
                'from': _me,
                'to': _spender,
                'value': '25000000000',
                'validAfter': 0,
                'validBefore': 1893456000,
                'nonce': '0x${'0' * 64}',
              },
            },
            origin: 'https://app.example',
            address: _me,
            walletId: 'w',
          );
      await _pump(
        tester,
        TypedDataSigningReview(
          review: review,
          wallet: _wallet,
          onReject: () {},
          onApprove: () => approved++,
        ),
      );
      expect(find.text('Authorize a token transfer'), findsOneWidget);
      expect(find.text('Transfer 25,000 USDC'), findsOneWidget);
      final card = find.byType(ReviewRiskCard);
      expect(card, findsOneWidget);
      // From, to and the token contract, in that order.
      expect(
        tester
            .widgetList<ReviewAddress>(
              find.descendant(of: card, matching: find.byType(ReviewAddress)),
            )
            .map((chip) => chip.address),
        [_me.toLowerCase(), _spender, _usdc],
      );
      expect(
        find.descendant(of: card, matching: find.text('USDC contract')),
        findsOneWidget,
      );
      expect(find.textContaining('is not this wallet'), findsNothing);
      // The review shows the expiry in the device's time zone, so the
      // expected text is that instant rendered locally, not its UTC form.
      final expires = DateTime.utc(2030).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(
        find.textContaining(
          '${expires.year}-${two(expires.month)}-${two(expires.day)} '
          '${two(expires.hour)}:${two(expires.minute)}',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('approve-signing')));
      await tester.pump();
      expect(approved, 0);
      final hold = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('approve-signing'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1300));
      await hold.up();
      await tester.pump();
      expect(approved, 1);
    });
  }

  testWidgets('a permit leads with its allowance and needs a hold', (
    tester,
  ) async {
    var approved = 0;
    await _pump(
      tester,
      TypedDataSigningReview(
        review: EthereumTypedDataReview(
          data: _permit(),
          origin: 'https://app.example',
          address: _me,
          walletId: 'w',
          kind: TypedDataKind.permit,
          permissions: [
            TypedDataPermission(
              token: _usdc,
              spender: _spender,
              amount: BigInt.from(2500000),
              expires: DateTime.utc(2030),
            ),
          ],
          tokens: const {
            _usdc: ReviewAsset(
              id: _usdc,
              symbol: 'USDC',
              decimals: 6,
              verified: true,
            ),
          },
        ),
        wallet: _wallet,
        onReject: () {},
        onApprove: () => approved++,
      ),
    );
    expect(find.text('Grant a spending permission'), findsOneWidget);
    expect(find.text('2.5 USDC allowance'), findsOneWidget);
    expect(find.text('USD Coin'), findsOneWidget);
    expect(find.text('Ethereum Mainnet'), findsOneWidget);
    expect(find.text('spender'), findsOneWidget);
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.pump();
    expect(approved, 0, reason: 'a permission is approved by holding');
  });

  testWidgets('a revocation-only permit revokes the allowance and needs a hold', (
    tester,
  ) async {
    var approved = 0;
    await _pump(
      tester,
      TypedDataSigningReview(
        review: EthereumTypedDataReview(
          data: _permit(value: '0'),
          origin: 'https://app.example',
          address: _me,
          walletId: 'w',
          kind: TypedDataKind.permit,
          permissions: [
            TypedDataPermission(
              token: _usdc,
              spender: _spender,
              amount: BigInt.zero,
              expires: DateTime.utc(2030),
            ),
          ],
          tokens: const {
            _usdc: ReviewAsset(
              id: _usdc,
              symbol: 'USDC',
              decimals: 6,
              verified: true,
            ),
          },
        ),
        wallet: _wallet,
        onReject: () {},
        onApprove: () => approved++,
      ),
    );
    expect(find.text('Revoke a spending permission'), findsOneWidget);
    expect(find.text('Grant a spending permission'), findsNothing);
    expect(find.text('Revoke USDC allowance'), findsOneWidget);
    expect(find.text('0 USDC allowance'), findsNothing);
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(
      find.textContaining(
        ' will no longer be able to spend your USDC once this signature is submitted.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    final card = find.byType(ReviewRiskCard);
    final spender = tester.widget<ReviewAddress>(
      find.descendant(of: card, matching: find.byType(ReviewAddress)),
    );
    expect(spender.address, _spender);
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining(' can spend', findRichText: true),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.pump();
    expect(approved, 0, reason: 'a revocation still needs a hold');
  });

  testWidgets('a mixed permit review keeps its grant title and revocation card', (
    tester,
  ) async {
    await _pump(
      tester,
      TypedDataSigningReview(
        review: EthereumTypedDataReview(
          data: _permit(),
          origin: 'https://app.example',
          address: _me,
          walletId: 'w',
          kind: TypedDataKind.permit2,
          permissions: [
            TypedDataPermission(
              token: _usdc,
              spender: _spender,
              amount: BigInt.zero,
            ),
            TypedDataPermission(
              token: _usdc,
              spender: _spender,
              amount: BigInt.from(2500000),
            ),
            const TypedDataPermission(token: _usdc, spender: _spender),
          ],
          tokens: const {
            _usdc: ReviewAsset(
              id: _usdc,
              symbol: 'USDC',
              decimals: 6,
              verified: true,
            ),
          },
        ),
        wallet: _wallet,
        onReject: () {},
        onApprove: () {},
      ),
    );
    expect(find.text('Grant a spending permission'), findsOneWidget);
    expect(find.text('Revoke a spending permission'), findsNothing);
    expect(find.text('Revoke USDC allowance'), findsOneWidget);
    expect(find.text('0 USDC allowance'), findsNothing);
    expect(find.text('2.5 USDC allowance'), findsOneWidget);
    expect(find.text('Unlimited USDC allowance'), findsOneWidget);
    expect(find.text('PERMISSION'), findsNWidgets(3));
    expect(
      find.textContaining(
        ' will no longer be able to spend your USDC once this signature is submitted.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(' can spend up to this amount', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(' can spend all of your USDC', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('generic typed data lists its fields and signs only on a hold', (
    tester,
  ) async {
    var approved = 0;
    final data = Eip712TypedData.parse({
      'types': {
        'Vote': [
          {'name': 'proposal', 'type': 'uint256'},
          {'name': 'support', 'type': 'bool'},
          {'name': 'tags', 'type': 'string[]'},
          {'name': 'weight', 'type': 'uint256'},
        ],
      },
      'primaryType': 'Vote',
      'domain': {'name': 'Gov'},
      'message': {
        'proposal': 42,
        'support': true,
        'tags': ['a', 'b'],
        'weight': '0xde0b6b3a7640000',
      },
    });
    await _pump(
      tester,
      TypedDataSigningReview(
        review: EthereumTypedDataReview(
          data: data,
          origin: 'https://gov.example',
          address: _me,
          walletId: 'w',
          kind: TypedDataKind.generic,
        ),
        wallet: _wallet,
        onReject: () {},
        onApprove: () => approved++,
      ),
    );
    expect(find.text('Sign typed data'), findsOneWidget);
    expect(find.text('Not specified'), findsOneWidget);
    expect(find.text('tags[1]'), findsOneWidget);
    expect(find.text('true'), findsOneWidget);
    // A hex integer reads as decimal; the signed digest is unchanged.
    expect(find.text('1000000000000000000'), findsOneWidget);
    expect(find.text('0xde0b6b3a7640000'), findsNothing);
    final decimal = Eip712TypedData.parse({
      'types': {
        'Vote': [
          for (final field in data.types['Vote']!)
            {'name': field.name, 'type': field.type},
        ],
      },
      'primaryType': 'Vote',
      'domain': {'name': 'Gov'},
      'message': {...data.message, 'weight': '1000000000000000000'},
    });
    expect(decimal.digest, data.digest);
    expect(find.byKey(const Key('unrecognised-typed-data')), findsOneWidget);
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.pump();
    expect(approved, 0, reason: 'unrecognised data is not signed on a tap');
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('approve-signing'))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1300));
    await hold.up();
    await tester.pump();
    expect(approved, 1);
  });

  testWidgets(
    'a Ledger signer is told which device setting it needs and gets both hashes',
    (tester) async {
      final data = Eip712TypedData.parse({
        'types': {
          'Vote': [
            {'name': 'proposal', 'type': 'uint256'},
          ],
        },
        'primaryType': 'Vote',
        'domain': {'name': 'Gov'},
        'message': {'proposal': 42},
      });
      String hex(Uint8List bytes) =>
          '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      Widget review(WalletType? signer) => TypedDataSigningReview(
        review: EthereumTypedDataReview(
          data: data,
          origin: 'https://gov.example',
          address: _me,
          walletId: 'w',
          kind: TypedDataKind.generic,
        ),
        wallet: _wallet,
        signer: signer,
        onReject: () {},
        onApprove: () {},
      );
      await _pump(tester, review(WalletType.hd));
      expect(find.byKey(const Key('ledger-typed-data-note')), findsNothing);

      await _pump(tester, review(WalletType.ledger));
      expect(find.byKey(const Key('ledger-typed-data-note')), findsOneWidget);
      expect(find.textContaining('Raw messages'), findsOneWidget);
      final disclosure = find.byKey(const Key('typed-data-full'));
      await tester.ensureVisible(disclosure);
      await tester.tap(disclosure);
      await tester.pumpAndSettle();
      expect(find.text('Domain hash'), findsOneWidget);
      expect(find.text('Message hash'), findsOneWidget);
      expect(find.textContaining(hex(data.domainSeparator)), findsOneWidget);
      expect(find.textContaining(hex(data.structHash)), findsOneWidget);
    },
  );

  testWidgets('personal_sign of a sign-in message reuses the sign-in card', (
    tester,
  ) async {
    final text =
        'app.example wants you to sign in with your Ethereum account:\n$_me\n\nWelcome.\n\nURI: https://app.example\nVersion: 1\nChain ID: 1\nNonce: 0123456789abcdef';
    await _pump(
      tester,
      MessageSigningReview(
        review: EthereumMessageReview(
          bytes: Uint8List.fromList(utf8.encode(text)),
          origin: 'https://app.example',
          address: _me,
          walletId: 'w',
        ),
        wallet: _wallet,
        onReject: () {},
        onApprove: () {},
      ),
    );
    expect(find.text('Sign in to app.example'), findsOneWidget);
  });

  for (final domain in ['app.example', 'other.example']) {
    for (final chainId in ['1', '137']) {
      for (final statement in [null, 'Welcome.']) {
        testWidgets(
          'sign-in to $domain on chain $chainId with statement=$statement '
          'retains its fields and cautions',
          (tester) async {
            final text =
                '$domain wants you to sign in with your Ethereum account:\n$_me\n\n${statement == null ? '' : '$statement\n'}\nURI: https://$domain\nVersion: 1\nChain ID: $chainId\nNonce: 0123456789abcdef\nIssued At: 2026-10-02T00:00:00Z';
            await _pump(
              tester,
              MessageSigningReview(
                review: EthereumMessageReview(
                  bytes: Uint8List.fromList(utf8.encode(text)),
                  origin: 'https://app.example',
                  address: _me,
                  walletId: 'w',
                ),
                wallet: _wallet,
                onReject: () {},
                onApprove: () {},
              ),
            );
            expect(find.text('Sign a message'), findsNothing);
            expect(
              find.text(
                domain == 'app.example'
                    ? 'Sign in to app.example'
                    : 'Review sign-in request',
              ),
              findsOneWidget,
            );
            expect(find.text('Chain ID'), findsOneWidget);
            expect(find.text(chainId), findsWidgets);
            expect(
              find.text('Statement'),
              statement == null ? findsNothing : findsOneWidget,
            );
            expect(
              find.text('The sign-in domain does not match this website.'),
              domain == 'app.example' ? findsNothing : findsOneWidget,
            );
            expect(
              find.text('The sign-in network does not match this wallet.'),
              chainId == '1' ? findsNothing : findsOneWidget,
            );
            if (chainId != '1') {
              expect(
                find.text(
                  'The message asks to sign in on Chain ID 137, but this wallet uses Ethereum mainnet (Chain ID 1).',
                ),
                findsOneWidget,
              );
            }
            await tester.tap(find.text('View full message'));
            await tester.pumpAndSettle();
            expect(find.text(text), findsOneWidget);
          },
        );
      }
    }
  }

  testWidgets('an Ethereum transaction review names its network, ETH fee and '
      'every approval', (tester) async {
    await _pump(
      tester,
      SimulationReviewSheet(
        review: SimulationReview(
          payloadDigest: '0x',
          origin: 'https://app.example',
          walletId: 'w',
          address: _me,
          chain: ethereumMainnet,
          simulatedAt: DateTime.now(),
          execution: SimulationExecution.succeeded,
          coverage: SimulationCoverage.partial,
          networkFee: BigInt.from(420000000000000),
          maxNetworkFee: BigInt.from(900000000000000),
          assets: const {
            _usdc: ReviewAsset(
              id: _usdc,
              symbol: 'USDC',
              decimals: 6,
              verified: true,
            ),
          },
          accounts: [
            AccountChange(
              kind: AccountChangeKind.approve,
              address: _usdc,
              program: _usdc,
              assetId: _usdc,
              description: 'Token spending permission',
              beneficiary: _spender,
              rawAllowance: (BigInt.one << 256) - BigInt.one,
              evidence: ReviewEvidence.simulatedState,
            ),
          ],
          funds: [
            FundChange(
              asset: const ReviewAsset(
                id: evmNativeAssetId,
                symbol: 'ETH',
                decimals: 18,
                verified: true,
              ),
              address: _me,
              rawAmount: -BigInt.from(10).pow(16),
              evidence: ReviewEvidence.simulatedState,
              isNet: true,
            ),
          ],
        ),
        wallet: _wallet,
        onReject: () {},
        onApprove: () {},
      ),
    );
    expect(find.text('Ethereum Mainnet'), findsOneWidget);
    expect(find.text('≈ 0.00042 ETH'), findsOneWidget);
    expect(find.text('0.0009 ETH'), findsOneWidget);
    expect(find.text('Unlimited USDC allowance'), findsOneWidget);
    expect(find.text('0.01 ETH'), findsOneWidget);
    expect(find.text('Open simulation in Solana Explorer'), findsNothing);
  });
}
