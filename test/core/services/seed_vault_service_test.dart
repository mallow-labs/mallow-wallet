import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';

/// Two seeds, so resolution has to walk past the first one to find [_addrB].
const _addrA = 'A11111111111111111111111111111111111111111';
const _addrB = 'B22222222222222222222222222222222222222222';

/// Deliberately *not* the string [seedVaultDerivationPath] would build for
/// index 3: the vault normalizes paths itself, and signing has to echo back
/// what it reported rather than what we would have guessed.
const _pathB = "bip44:/m'/44'/501'/3'/0'";

Uint8List _sig(int fill) => Uint8List.fromList(List.filled(64, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.mallow.wallet/seed_vault');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late SeedVaultService service;

  int callsTo(String method) => calls.where((c) => c.method == method).length;

  /// Installs a handler that answers the enumeration methods with two seeds
  /// and defers everything else to [onOther].
  void mockVault({
    required Future<Object?> Function(MethodCall call) onOther,
    List<Map<String, Object?>> seeds = const [
      {'authToken': 10, 'name': 'Seed one', 'purpose': 0},
      {'authToken': 11, 'name': 'Seed two', 'purpose': 0},
    ],
    Map<int, List<Map<String, Object?>>> accountsByToken = const {
      10: [
        {
          'accountId': 1,
          'publicKeyEncoded': _addrA,
          'derivationPath': "bip44:/m'/44'/501'/0'/0'",
          'name': 'Account 1',
          'isUserWallet': true,
          'isValid': true,
        },
      ],
      11: [
        {
          'accountId': 7,
          'publicKeyEncoded': _addrB,
          'derivationPath': _pathB,
          'name': 'Account 4',
          'isUserWallet': false,
          'isValid': true,
        },
      ],
    },
  }) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getAuthorizedSeeds':
          return seeds;
        case 'getAccounts':
          final token = (call.arguments as Map)['authToken']! as int;
          return accountsByToken[token] ?? const [];
        default:
          return onOther(call);
      }
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    service = SeedVaultService();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('resolution', () {
    // The auth token is never persisted because it dies on
    // deauthorize/re-authorize. That only works if a bare address can be
    // resolved back to its seed at call time — including when the address
    // belongs to the second, third, … authorized seed.
    test('walks every authorized seed to find the address', () async {
      mockVault(onOther: (_) async => [_sig(1)]);

      await service.signTransaction(
        Uint8List.fromList([1, 2, 3]),
        address: _addrB,
      );

      final sign = calls.firstWhere((c) => c.method == 'signTransactions');
      final args = sign.arguments as Map;
      expect(
        args['authToken'],
        11,
        reason:
            'must use the token of the seed that actually holds the address',
      );
      expect(callsTo('getAccounts'), 2, reason: 'both seeds were searched');
    });

    // A reconstructed path that disagrees with the vault's own produces a
    // valid signature from a *different* address — no error, just a signature
    // nothing accepts. So the path goes back verbatim, whatever its form.
    test('sends back the path the vault reported, not a rebuilt one', () async {
      mockVault(onOther: (_) async => [_sig(1)]);

      await service.signTransaction(Uint8List.fromList([9]), address: _addrB);

      final args =
          calls.firstWhere((c) => c.method == 'signTransactions').arguments
              as Map;
      expect(args['derivationPath'], _pathB);
      expect(
        args['derivationPath'],
        isNot(seedVaultDerivationPath(3, SolanaDerivationScheme.standard)),
        reason: 'the fixture path is normalized differently on purpose',
      );
    });

    // Enumeration is a Binder round trip per seed. Doing it before every
    // signature would add latency to the one flow where the user is already
    // waiting on an OS approval screen.
    test('caches the triple, so a second sign re-enumerates nothing', () async {
      mockVault(onOther: (_) async => [_sig(1)]);

      await service.signTransaction(Uint8List.fromList([1]), address: _addrB);
      await service.signTransaction(Uint8List.fromList([2]), address: _addrB);

      expect(callsTo('getAuthorizedSeeds'), 1);
      expect(callsTo('signTransactions'), 2);
    });

    // A miss is not a cancellation and not an unavailable device: the recovery
    // is to re-authorize the seed, and the UI needs the address to say which
    // wallet went dark.
    test(
      'an unknown address throws seed-not-authorized, not cancelled',
      () async {
        mockVault(onOther: (_) async => [_sig(1)]);

        await expectLater(
          service.signTransaction(
            Uint8List.fromList([1]),
            address: 'ZZZZ1111111111111111111111111111111111111',
          ),
          throwsA(
            isA<SeedVaultSeedNotAuthorizedException>().having(
              (e) => e.address,
              'address',
              'ZZZZ1111111111111111111111111111111111111',
            ),
          ),
        );
        expect(
          callsTo('signTransactions'),
          0,
          reason: 'a miss must never raise an approval screen',
        );
      },
    );

    // A miss is never cached. The recovery from one is `authorizeSeed`, and
    // that has to take effect on the next attempt — caching the negative would
    // make the user restart the app after authorizing.
    test('re-enumerates after a miss instead of caching it', () async {
      mockVault(onOther: (_) async => [_sig(1)]);

      for (var i = 0; i < 2; i++) {
        await expectLater(
          service.signTransaction(Uint8List.fromList([1]), address: 'nope'),
          throwsA(isA<SeedVaultSeedNotAuthorizedException>()),
        );
      }

      expect(callsTo('getAuthorizedSeeds'), 2);
    });

    // Every cached row carries the token that just died.
    test('deauthorizeSeed drops the cache', () async {
      mockVault(onOther: (_) async => [_sig(1)]);

      await service.signTransaction(Uint8List.fromList([1]), address: _addrB);
      await service.deauthorizeSeed(11);
      await service.signTransaction(Uint8List.fromList([1]), address: _addrB);

      expect(callsTo('getAuthorizedSeeds'), 2);
    });

    test('listAccounts flattens every seed without raising vault UI', () async {
      mockVault(onOther: (call) async => fail('unexpected ${call.method}'));

      final accounts = await service.listAccounts();

      expect(accounts.map((a) => a.address), [_addrA, _addrB]);
      expect(accounts.first.authToken, 10);
      expect(accounts.last.authToken, 11);
      expect(accounts.last.accountId, 7);
      expect(accounts.last.derivationPath, _pathB);
      expect(accounts.first.isUserWallet, isTrue);
      expect(accounts.last.isUserWallet, isFalse);
    });
  });

  group('INVALID_AUTH_TOKEN', () {
    // The token can die between resolution and use. Re-resolving once is the
    // whole reason the token is not persisted — it makes the failure
    // self-healing without a DB migration.
    test('re-resolves once and retries once', () async {
      var signAttempts = 0;
      mockVault(
        onOther: (_) async {
          signAttempts++;
          if (signAttempts == 1) {
            throw PlatformException(code: 'INVALID_AUTH_TOKEN');
          }
          return [_sig(2)];
        },
      );

      final sig = await service.signTransaction(
        Uint8List.fromList([1]),
        address: _addrB,
      );

      expect(sig, _sig(2));
      expect(signAttempts, 2, reason: 'exactly one retry');
      expect(
        callsTo('getAuthorizedSeeds'),
        2,
        reason: 'the cache was invalidated and re-resolved exactly once',
      );
    });

    // A token that is invalid twice in a row is a real failure. Retrying in a
    // loop would spin Seed Vault's full-screen approval Activity.
    test('a second failure propagates instead of looping', () async {
      var signAttempts = 0;
      mockVault(
        onOther: (_) async {
          signAttempts++;
          throw PlatformException(code: 'INVALID_AUTH_TOKEN');
        },
      );

      await expectLater(
        service.signMessage(Uint8List.fromList([1]), address: _addrB),
        throwsA(
          isA<SeedVaultException>().having(
            (e) => e.code,
            'code',
            'INVALID_AUTH_TOKEN',
          ),
        ),
      );
      expect(signAttempts, 2);
      expect(callsTo('getAuthorizedSeeds'), 2);
    });
  });

  group('error mapping', () {
    // Cancelling is an ordinary outcome — the caller shows nothing, or a
    // "cancelled" toast. It must not be confused with a broken seed.
    test('CANCELED becomes SeedVaultApprovalCancelledException', () async {
      mockVault(
        onOther: (_) async {
          throw PlatformException(code: 'CANCELED', message: 'user dismissed');
        },
      );

      await expectLater(
        service.signTransaction(Uint8List.fromList([1]), address: _addrB),
        throwsA(isA<SeedVaultApprovalCancelledException>()),
      );
      await expectLater(
        service.authorizeSeed(),
        throwsA(isA<SeedVaultApprovalCancelledException>()),
      );
    });

    // The permission can be denied permanently while Seed Vault stays
    // available, and the only recovery is an app-settings CTA — so the caller
    // has to be able to tell this apart from "no Seed Vault here".
    test(
      'PERMISSION_DENIED becomes SeedVaultPermissionDeniedException',
      () async {
        mockVault(
          onOther: (_) async {
            throw PlatformException(code: 'PERMISSION_DENIED');
          },
        );

        await expectLater(
          service.requestPermission(),
          throwsA(isA<SeedVaultPermissionDeniedException>()),
        );
      },
    );

    test(
      'SEED_VAULT_UNAVAILABLE becomes SeedVaultUnavailableException',
      () async {
        mockVault(
          onOther: (_) async {
            throw PlatformException(code: 'SEED_VAULT_UNAVAILABLE');
          },
        );

        await expectLater(
          service.showSeedSettings(10),
          throwsA(isA<SeedVaultUnavailableException>()),
        );
      },
    );

    // Every device without Seed Vault (and every iOS build) has no handler
    // registered. A raw MissingPluginException escaping to a caller reads as a
    // crash rather than as "this device has no Seed Vault".
    test(
      'a missing platform handler becomes SeedVaultUnavailableException',
      () async {
        await expectLater(
          service.listAccounts(),
          throwsA(isA<SeedVaultUnavailableException>()),
        );
      },
    );

    // isAvailable is the gate that decides whether any Seed Vault UI renders,
    // so it must answer rather than throw — a throwing gate breaks the screen
    // that asked instead of just hiding the row.
    test('isAvailable answers false rather than throwing', () async {
      expect(await service.isAvailable(), isFalse);

      mockVault(
        onOther: (_) async {
          throw PlatformException(code: 'UNKNOWN_ERROR');
        },
      );
      expect(await service.isAvailable(), isFalse);
    });

    // An unrecognised code keeps its string so a caller can log it, instead of
    // being flattened into one of the four handled cases.
    test('an unknown code keeps its code on SeedVaultException', () async {
      mockVault(
        onOther: (_) async {
          throw PlatformException(code: 'REQUEST_IN_FLIGHT', message: 'busy');
        },
      );

      await expectLater(
        service.signTransaction(Uint8List.fromList([1]), address: _addrB),
        throwsA(
          isA<SeedVaultException>()
              .having((e) => e.code, 'code', 'REQUEST_IN_FLIGHT')
              .having((e) => e.message, 'message', 'busy'),
        ),
      );
    });

    // A short signature spliced into a transaction's signature array fails
    // far away from here, as an unrelated-looking RPC rejection.
    test('a malformed signature is rejected at the boundary', () async {
      mockVault(onOther: (_) async => [Uint8List(32)]);

      await expectLater(
        service.signMessage(Uint8List.fromList([1]), address: _addrB),
        throwsA(isA<SeedVaultException>()),
      );
    });
  });

  group('resolved-address assertion', () {
    // Signing under a path belonging to a different key yields a *valid*
    // signature from the wrong address — the failure is silent, so the refusal
    // has to happen before the payload leaves.
    test('refuses to sign for an account that is not the one requested', () {
      const account = SeedVaultAccount(
        authToken: 11,
        accountId: 7,
        address: _addrB,
        derivationPath: _pathB,
      );

      expect(
        () => SeedVaultService.assertResolvedAccountMatches(_addrA, account),
        throwsStateError,
      );
      expect(
        () => SeedVaultService.assertResolvedAccountMatches(_addrB, account),
        returnsNormally,
      );
    });
  });

  group('seedVaultDerivationPath', () {
    // These are the URI forms of MultiChainDerivation.solanaHdPath's two
    // offerable schemes; the scheme is part of a wallet's identity, so the
    // index and the depth both have to land in the right place.
    test('builds the standard and legacy URIs', () {
      expect(
        seedVaultDerivationPath(0, SolanaDerivationScheme.standard),
        "bip32:/m'/44'/501'/0'/0'",
      );
      expect(
        seedVaultDerivationPath(3, SolanaDerivationScheme.standard),
        "bip32:/m'/44'/501'/3'/0'",
      );
      expect(
        seedVaultDerivationPath(0, SolanaDerivationScheme.legacy),
        "bip32:/m'/44'/501'/0'",
      );
      expect(
        seedVaultDerivationPath(2, SolanaDerivationScheme.legacy),
        "bip32:/m'/44'/501'/2'",
      );
    });

    // Seed Vault pre-derives the common Solana paths on first authorization,
    // but not the index-less depth-2 root — offering it in the picker would
    // cost the user a password prompt for an account almost nobody holds.
    test('refuses the root scheme', () {
      expect(
        () => seedVaultDerivationPath(0, SolanaDerivationScheme.root),
        throwsArgumentError,
      );
    });
  });
}
