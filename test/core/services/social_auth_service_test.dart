import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:web3auth_flutter/enums.dart';

/// A 32-byte secp256k1 key whose first byte is zero — the shape Web3Auth
/// returns leading-zero-stripped. Everything after the leading zeros is
/// arbitrary but fixed, so the derived address is stable across runs.
const _leadingZeroKey =
    '0007b1c2d3e4f5061728394a5b6c7d8e9fa0b1c2d3e4f5061728394a5b6c7d8e';

/// A 64-byte Ed25519 keypair hex, the shape `getEd25519PrivateKey` returns
/// (32-byte seed ‖ 32-byte public key). Only the trailing half is read for the
/// address, so the two halves need not be a real pair here.
const _ed25519KeypairKey = '$_leadingZeroKey$_leadingZeroKey';

/// The channel the `web3auth_flutter` plugin talks over. Mocking it is the
/// only seam into the interactive half of [SocialAuthService] — the service
/// calls the plugin's statics directly, so the platform boundary is where a
/// test can stand in for the browser round-trip.
const _web3AuthChannel = MethodChannel('web3auth_flutter');

/// A [WalletRepository] stand-in for the two calls key recovery makes.
///
/// Hand-written rather than mocked because these tests are about *how many
/// times* a login reaches storage, and about the exact credentials it stores.
class _RecordingWalletRepository implements WalletRepository {
  _RecordingWalletRepository(this.rowsByAccount);

  final Map<String, List<WalletInfo>> rowsByAccount;

  int storeCalls = 0;
  SocialChainCredential? storedEthereum;
  SocialChainCredential? storedTezos;

  @override
  Future<List<WalletInfo>> getWalletsForAccount(String accountId) async =>
      rowsByAccount[accountId] ?? const <WalletInfo>[];

  @override
  Future<({List<WalletInfo> wallets, bool existed})> addSocialAccount({
    required String provider,
    required String name,
    required SocialChainCredential solana,
    required SocialChainCredential ethereum,
    required SocialChainCredential tezos,
  }) async {
    storeCalls++;
    storedEthereum = ethereum;
    storedTezos = tezos;
    // Key recovery ignores the return value; only sign-in reads it.
    return (
      wallets: rowsByAccount.values.firstWhere(
        (rows) => rows.any((w) => w.address == solana.address),
      ),
      existed: true,
    );
  }

  // Everything else on WalletRepository is unreachable from key recovery;
  // reaching it should fail the test loudly rather than return a stub.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WalletInfo _wallet({
  required String id,
  required String address,
  required String chain,
  WalletType walletType = WalletType.social,
  String? socialProvider = 'google',
  String accountId = 'account-1',
}) => WalletInfo(
  id: id,
  address: address,
  name: 'Google Wallet',
  walletType: walletType,
  chain: chain,
  socialProvider: socialProvider,
  accountId: accountId,
);

/// The three rows one Web3Auth login creates.
List<WalletInfo> _socialAccountRows({String? provider = 'google'}) => [
  _wallet(
    id: 'sol',
    address: 'So1anaAddress11111111111111111111111111111',
    chain: 'solana',
    socialProvider: provider,
  ),
  _wallet(
    id: 'eth',
    address: '0x1111111111111111111111111111111111111111',
    chain: 'ethereum',
    socialProvider: provider,
  ),
  _wallet(
    id: 'tez',
    address: 'tz1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    chain: 'tezos',
    socialProvider: provider,
  ),
];

void main() {
  // Everything reachable from a test lives here: the SDK half of
  // SocialAuthService is a platform channel, so the class keeps its decisions
  // in pure statics ("pure core, untestable shell") and those are what these
  // tests pin.

  group('SocialAuthService.normalizedSecpKeyHex', () {
    // Why this exists at all: the secp256k1 key is a 256-bit *scalar* and the
    // SDK hands it back as big-integer hex, so a key with leading zero
    // bytes/nibbles arrives shorter than 64 characters. That same string is
    // stored verbatim for Ethereum AND re-used as the Tezos ed25519 seed, so
    // getting it wrong mis-derives two chains at once — and mis-derivation
    // here is silent: the wallet signs perfectly well, just as a different
    // address. Padding is therefore mandatory, not cosmetic.

    test('passes a canonical 64-char lowercase key through unchanged', () {
      expect(
        SocialAuthService.normalizedSecpKeyHex(_leadingZeroKey),
        _leadingZeroKey,
      );
    });

    test('strips a 0x prefix in either case', () {
      expect(
        SocialAuthService.normalizedSecpKeyHex('0x$_leadingZeroKey'),
        _leadingZeroKey,
      );
      expect(
        SocialAuthService.normalizedSecpKeyHex('0X$_leadingZeroKey'),
        _leadingZeroKey,
      );
    });

    test('lowercases so the stored form is the canonical one', () {
      expect(
        SocialAuthService.normalizedSecpKeyHex(_leadingZeroKey.toUpperCase()),
        _leadingZeroKey,
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        SocialAuthService.normalizedSecpKeyHex('  $_leadingZeroKey\n'),
        _leadingZeroKey,
      );
    });

    test('left-pads a whole stripped byte back to 64 characters', () {
      // The SDK dropped the leading 0x00 byte: 62 characters.
      final stripped = _leadingZeroKey.substring(2);
      expect(stripped.length, 62);
      expect(SocialAuthService.normalizedSecpKeyHex(stripped), _leadingZeroKey);
    });

    test('left-pads a stripped nibble (odd length) back to 64 characters', () {
      // The SDK dropped only the leading zero nibble: 63 characters. Odd
      // length is NOT rejected — it is the most common stripped shape, and
      // rejecting it would lock the user out of their own account.
      final stripped = _leadingZeroKey.substring(1);
      expect(stripped.length, 63);
      expect(SocialAuthService.normalizedSecpKeyHex(stripped), _leadingZeroKey);
    });

    test('padding is what stops the stored-key loader mis-decoding', () {
      // The concrete bug the padding prevents. `privateKeyBytesFromHex`
      // decodes hex pairwise from the left, so an odd-length string both
      // misaligns every byte and drops the last nibble — a *different*
      // 31-byte key, accepted without complaint.
      final stripped = _leadingZeroKey.substring(1);
      final mangled = MultiChainDerivation.privateKeyBytesFromHex(stripped);
      expect(mangled, hasLength(31));

      final normalized = SocialAuthService.normalizedSecpKeyHex(stripped);
      final recovered = MultiChainDerivation.privateKeyBytesFromHex(normalized);
      expect(recovered, hasLength(32));
      expect(
        recovered,
        MultiChainDerivation.privateKeyBytesFromHex(_leadingZeroKey),
      );
    });

    test('a padded key derives the same Ethereum address as the full key', () {
      // The end-to-end statement of the same invariant: the address the
      // account is created under must not depend on how many leading zeros
      // the SDK happened to strip on this login.
      final full = MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
        _leadingZeroKey,
      );
      final fromStripped =
          MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
            SocialAuthService.normalizedSecpKeyHex(
              _leadingZeroKey.substring(2),
            ),
          );
      expect(fromStripped, full);
    });

    test('throws on empty input', () {
      expect(
        () => SocialAuthService.normalizedSecpKeyHex('  '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on non-hex input', () {
      expect(
        () => SocialAuthService.normalizedSecpKeyHex('zz$_leadingZeroKey'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on more than 64 characters — not a 32-byte key', () {
      expect(
        () => SocialAuthService.normalizedSecpKeyHex('${_leadingZeroKey}ab'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the thrown error never carries the key material', () {
      // AppLogger.error survives release builds and debugPrint is captured as
      // a Sentry breadcrumb, so an error string holding the key would ship it
      // off-device.
      const secret = '${_leadingZeroKey}deadbeef';
      Object? caught;
      try {
        SocialAuthService.normalizedSecpKeyHex(secret);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), isNot(contains(secret)));
      expect(caught.toString(), isNot(contains(_leadingZeroKey)));
    });
  });

  group('SocialAuthService.web3AuthNetworkFor', () {
    // The network is an input to the key derivation: every social address on
    // sapphire_devnet differs from the same identity's address on
    // sapphire_mainnet. A silent fallback would hand a user a wallet that is
    // not theirs, so the mapping is exhaustive and throws on anything else.

    test('maps the two configured network names', () {
      expect(
        SocialAuthService.web3AuthNetworkFor('sapphire_devnet'),
        Web3AuthNetwork.sapphire_devnet,
      );
      expect(
        SocialAuthService.web3AuthNetworkFor('sapphire_mainnet'),
        Web3AuthNetwork.sapphire_mainnet,
      );
    });

    test('throws on an unknown network name', () {
      expect(
        () => SocialAuthService.web3AuthNetworkFor('mainnet'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => SocialAuthService.web3AuthNetworkFor(''),
        throwsA(isA<StateError>()),
      );
    });

    test('accepts whatever Config.web3AuthNetwork yields', () {
      // Pins the two vocabularies together: environment.dart stays SDK-free by
      // keeping the network a string, so nothing but this test would catch a
      // rename on either side.
      expect(
        () => SocialAuthService.web3AuthNetworkFor(Config.web3AuthNetwork),
        returnsNormally,
      );
    });
  });

  group('SocialAuthService.recoveryTargetFor', () {
    // Recovery is handed an account id and must decide, before opening a
    // browser, which identity to authenticate as and which address that login
    // has to reproduce. Anything it cannot answer is a pre-migration Reown
    // row, which is permanently unsignable — fail there rather than log the
    // user in and store a key for an address the row does not represent.

    test('returns the provider and the Solana address of a social account', () {
      final target = SocialAuthService.recoveryTargetFor(_socialAccountRows());

      expect(target.provider, 'google');
      expect(
        target.solanaAddress,
        'So1anaAddress11111111111111111111111111111',
      );
    });

    test('reads the provider off whichever social row carries it', () {
      final rows = _socialAccountRows(provider: 'apple');
      expect(SocialAuthService.recoveryTargetFor(rows).provider, 'apple');
    });

    test('ignores non-social rows in the same account', () {
      final rows = [
        _wallet(
          id: 'watch',
          address: 'WatchOnly1111111111111111111111111111111111',
          chain: 'solana',
          walletType: WalletType.viewOnly,
          socialProvider: null,
        ),
        ..._socialAccountRows(),
      ];

      final target = SocialAuthService.recoveryTargetFor(rows);
      expect(target.provider, 'google');
      // The social Solana row, not the view-only one sharing the chain.
      expect(
        target.solanaAddress,
        'So1anaAddress11111111111111111111111111111',
      );
    });

    test('throws when the account holds no social row', () {
      final rows = [
        _wallet(
          id: 'hd',
          address: 'HdWallet111111111111111111111111111111111111',
          chain: 'solana',
          walletType: WalletType.hd,
          socialProvider: null,
        ),
      ];

      expect(
        () => SocialAuthService.recoveryTargetFor(rows),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws when the social rows carry no provider', () {
      // A pre-migration row: nothing records which Google/Apple identity it
      // came from, so there is no login to run.
      expect(
        () => SocialAuthService.recoveryTargetFor(
          _socialAccountRows(provider: null),
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws on a provider this service cannot authenticate with', () {
      expect(
        () => SocialAuthService.recoveryTargetFor(
          _socialAccountRows(provider: 'facebook'),
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws when the account has no social Solana row', () {
      final rows = _socialAccountRows()
          .where((w) => w.chain != 'solana')
          .toList();

      expect(
        () => SocialAuthService.recoveryTargetFor(rows),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('throws on an empty row list', () {
      expect(
        () => SocialAuthService.recoveryTargetFor(const []),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });
  });

  group('SocialAuthService.requireDerivedAddressMatches', () {
    // The hard cutover. Web3Auth derives a different address than Reown did
    // for the same Google/Apple identity, so a mismatch is not a transient
    // error to retry — it means this row's key is unrecoverable, and storing
    // the new key against it would produce valid signatures from the wrong
    // address, which fails silently downstream.

    test('accepts a login that reproduces the row address', () {
      expect(
        () => SocialAuthService.requireDerivedAddressMatches(
          expected: 'So1anaAddress11111111111111111111111111111',
          derived: 'So1anaAddress11111111111111111111111111111',
        ),
        returnsNormally,
      );
    });

    test('rejects a different derived address as a legacy wallet', () {
      expect(
        () => SocialAuthService.requireDerivedAddressMatches(
          expected: 'So1anaAddress11111111111111111111111111111',
          derived: 'Different2222222222222222222222222222222222',
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });

    test('is case-sensitive — base58 addresses are', () {
      expect(
        () => SocialAuthService.requireDerivedAddressMatches(
          expected: 'So1anaAddress11111111111111111111111111111',
          derived: 'so1ANAaddress11111111111111111111111111111',
        ),
        throwsA(isA<LegacySocialWalletException>()),
      );
    });
  });

  group('SocialAuthService.recoverKeysForAccount', () {
    // Recovery is not called from a screen — `WalletManager` wires it into
    // every social key load, so the number of callers is whatever the signing
    // flow happens to need. That makes concurrency the interesting property:
    // a second login opens a second browser tab, and only one of them can be
    // the one a Cancel unwinds.

    late _RecordingWalletRepository repository;
    late int connectCalls;
    late int initCalls;
    late int logoutCalls;
    late Completer<void> connectGate;
    late SocialAuthService service;

    /// The Solana address this fixture login derives — the address the row
    /// must already hold, or `requireDerivedAddressMatches` rejects it.
    final derivedSolanaAddress =
        MultiChainDerivation.solanaAddressFromEd25519KeyHex(_ed25519KeypairKey);

    List<WalletInfo> rowsFor(String accountId, String address) => [
      _wallet(
        id: '$accountId-sol',
        address: address,
        chain: 'solana',
        accountId: accountId,
      ),
    ];

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      Config.debugOverrides['WEB3AUTH_CLIENT_ID'] = 'test-client-id';

      connectCalls = 0;
      initCalls = 0;
      logoutCalls = 0;
      connectGate = Completer<void>();
      repository = _RecordingWalletRepository({
        'account-1': rowsFor('account-1', derivedSolanaAddress),
        // A second social identity. Its address is deliberately not the one
        // the fixture login derives — the only test that touches it cancels
        // during the browser round-trip, well before the address gate.
        'account-2': rowsFor(
          'account-2',
          'So1anaAddress22222222222222222222222222222',
        ),
      });
      GetIt.instance.registerSingleton<WalletRepository>(repository);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_web3AuthChannel, (call) async {
            switch (call.method) {
              case 'init':
                initCalls++;
                return null;
              case 'logout':
                logoutCalls++;
                return null;
              // Stands in for the browser round-trip: it blocks until the
              // test releases [connectGate], which is what lets a test hold
              // two callers inside one login at the same time.
              case 'connectTo':
                connectCalls++;
                await connectGate.future;
                return jsonEncode({
                  'privKey': _leadingZeroKey,
                  'ed25519PrivKey': _ed25519KeypairKey,
                });
            }
            return null;
          });

      service = SocialAuthService();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_web3AuthChannel, null);
      Config.debugOverrides.clear();
      await GetIt.instance.reset();
    });

    test(
      'coalesces concurrent callers for one account into one login',
      () async {
        // The failure this prevents: two key loads for the same account (a
        // multi-chain sign, a Future.wait over two rows) each opening their own
        // OAuth tab. The user sees two browsers and can only finish one.
        final first = service.recoverKeysForAccount('account-1');
        final second = service.recoverKeysForAccount('account-1');
        await pumpEventQueue();

        expect(connectCalls, 1, reason: 'a second tab must not be opened');

        connectGate.complete();
        await Future.wait([first, second]);

        expect(connectCalls, 1);
        expect(repository.storeCalls, 1, reason: 'one login, one write');
      },
    );

    test('a cancel unwinds every caller sharing the login', () async {
      // The cancel affordance is a single button on the pipeline sheet. If it
      // resolved only one of the callers the other would keep waiting on a
      // browser tab that is never coming back, and the transaction it is
      // blocking would never fail either.
      final first = service.recoverKeysForAccount('account-1');
      final second = service.recoverKeysForAccount('account-1');
      final firstFails = expectLater(
        first,
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      final secondFails = expectLater(
        second,
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      await pumpEventQueue();

      service.cancelPendingRequest();

      await firstFails;
      await secondFails;
    });

    test('a cancel unwinds recoveries for different accounts too', () async {
      // Different accounts are genuinely different logins, so they are NOT
      // coalesced — but they do share the one Cancel button, and the second
      // one in must not displace the first one's cancel signal.
      final first = service.recoverKeysForAccount('account-1');
      final second = service.recoverKeysForAccount('account-2');
      final firstFails = expectLater(
        first,
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      final secondFails = expectLater(
        second,
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      await pumpEventQueue();

      expect(connectCalls, 2, reason: 'separate accounts need separate logins');

      service.cancelPendingRequest();

      await firstFails;
      await secondFails;
    });

    test(
      'reports one pending window across the whole shared round trip',
      () async {
        // Drives the Cancel affordance on the pipeline sheet. A flag that
        // dropped when the first of two shared callers unwound would take the
        // button away while the login was still open.
        final transitions = <bool>[];
        service.requestPending.addListener(
          () => transitions.add(service.requestPending.value),
        );

        final first = service.recoverKeysForAccount('account-1');
        final second = service.recoverKeysForAccount('account-1');
        await pumpEventQueue();

        expect(transitions, [true]);

        connectGate.complete();
        await Future.wait([first, second]);

        expect(transitions, [true, false]);
      },
    );

    test('drops the entry so a cancelled recovery can be retried', () async {
      // The user's actual next move after cancelling: retry the transaction.
      // A memoized future that outlived its own completion would hand the
      // retry the previous cancellation instead of opening a new login.
      final cancelled = service.recoverKeysForAccount('account-1');
      final cancelledFails = expectLater(
        cancelled,
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      await pumpEventQueue();
      service.cancelPendingRequest();
      await cancelledFails;

      connectGate.complete();
      await service.recoverKeysForAccount('account-1');

      expect(connectCalls, 2, reason: 'the retry must be a fresh login');
      expect(repository.storeCalls, 1);
    });

    test('initializes the native SDK once, even across a reset', () async {
      // 🛑 The Android SDK cannot be initialized twice in one process.
      // `Web3Auth.logout()` calls its own `AnalyticsManager.reset()`, which
      // clears that manager's `isInitialized` flag but never shuts down the
      // Segment client it registered. The next `Web3Auth(...)` construction —
      // which is exactly what `Web3AuthFlutter.init` does — therefore builds a
      // second Segment client for the same write key and throws
      // "Duplicate analytics client created with tag: ...".
      //
      // The app reaches that state routinely: removing a social wallet calls
      // [SocialAuthService.reset], and the next social sign-in would re-init.
      // What ends the session is the logout, not the init — so `reset` must
      // keep logging out while leaving the one-per-process init alone.
      connectGate.complete();
      await service.recoverKeysForAccount('account-1');
      expect(initCalls, 1);

      final logoutsBeforeReset = logoutCalls;
      await service.reset();
      expect(
        logoutCalls,
        greaterThan(logoutsBeforeReset),
        reason: 'reset must still end the Web3Auth session',
      );

      await service.recoverKeysForAccount('account-1');

      expect(
        initCalls,
        1,
        reason: 'a second native init throws Duplicate analytics client',
      );
      expect(connectCalls, 2, reason: 'the second login still runs');
    });

    test('stores the one secp256k1 key for both Ethereum and Tezos', () async {
      // The mapping sign-in and recovery must agree on. `secpKeyHex` is the
      // Ethereum key AND the Tezos stored key (Web3Auth feeds the secp256k1
      // bytes in as an Ed25519 seed), and only sign-in derived the addresses
      // the rows already hold — so if recovery stored anything else here it
      // would produce valid signatures from the wrong address, silently.
      connectGate.complete();
      await service.recoverKeysForAccount('account-1');

      expect(repository.storedEthereum!.storedKey, _leadingZeroKey);
      expect(
        repository.storedTezos!.storedKey,
        repository.storedEthereum!.storedKey,
      );
      expect(
        repository.storedEthereum!.address,
        MultiChainDerivation.ethereumAddressFromPrivateKeyHex(_leadingZeroKey),
      );
      expect(
        repository.storedTezos!.address,
        await MultiChainDerivation.tezosAddressFromSeedHex(_leadingZeroKey),
      );
    });
  });
}
