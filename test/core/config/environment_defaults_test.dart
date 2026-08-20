import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/shared/utils/explorer_utils.dart';

/// What a build that configures **nothing** targets.
///
/// `ENV` used to default to `development`, which meant every unconfigured
/// build — a fresh clone, a fork that filled in every documented key but this
/// one, a CI job that forgot the define — silently ran against devnet. Nothing
/// errored: devnet answers every call, so the app simply showed an empty
/// wallet and mainnet-real links that pointed at a test cluster.
///
/// The default is `production` now, and these tests are what stops it drifting
/// back. Each case below is a *separate* devnet behaviour derived from
/// `Config.environment`, asserted individually rather than through `isDevnet`,
/// because the failure mode being guarded is one of them being rewired to its
/// own switch and quietly staying on devnet.
///
/// 🛑 `web3AuthNetwork` is the one that cannot be corrected after the fact: it
/// is part of the social key derivation, so a build on the wrong network hands
/// the user a different address for the same social account.
void main() {
  tearDown(Config.debugOverrides.clear);

  group('an unconfigured build targets production', () {
    test('ENV unset resolves to production, not development', () {
      expect(Config.environment, Environment.production);
      expect(Config.isProduction, isTrue);
      expect(Config.isDevnet, isFalse);
    });

    test('an unrecognised ENV resolves to production too', () {
      // A typo ("prod", "prd", a stale value from another project) must not be
      // a quiet downgrade to the most permissive tier. Production is both the
      // safe landing spot and the one the reader already expects.
      Config.debugOverrides['ENV'] = 'prod';

      expect(Config.environment, Environment.production);
    });

    test('the Solana RPC URL carries no cluster parameter', () {
      expect(Config.solanaRpcUrl, isNot(contains('network=devnet')));
    });

    test('the Solana RPC default is a mainnet node, not devnet', () {
      // The last hardcoded devnet default. It is still not a default worth
      // shipping on — the public node is rate-limited and implements no DAS —
      // but it is at least on the network everything else now assumes.
      expect(Config.rpcProxyBaseUrl, 'https://api.mainnet-beta.solana.com');
      expect(Config.rpcProxyBaseUrl, isNot(contains('devnet')));
    });

    test('Web3Auth resolves the mainnet key-derivation network', () {
      expect(Config.web3AuthNetwork, 'sapphire_mainnet');
    });

    test('the rewards store reads the production prefix', () {
      Config.debugOverrides['ASSET_CDN_BASE_URL'] = 'https://cdn.example.com';

      expect(Config.storeCdnBaseUrl, 'https://cdn.example.com/store');
    });

    test('explorer links carry no cluster parameter', () {
      expect(
        buildExplorerUrl('sigABC123', 'solscan'),
        'https://solscan.io/tx/sigABC123',
      );
    });

    test('the CAIP-2 chain id is mainnet-beta', () {
      expect(Config.solanaChainId, 'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp');
    });
  });

  group('ENV still selects the other tiers', () {
    // The flip removed the devnet *default*, not devnet. Internal and e2e
    // builds pass `ENV=development` explicitly, so every assertion above has
    // to be reachable from the other side — otherwise the flip would have
    // deleted the test cluster rather than stopped defaulting to it.
    setUp(() => Config.debugOverrides['ENV'] = 'development');

    test('development turns every derived behaviour back to devnet', () {
      Config.debugOverrides['ASSET_CDN_BASE_URL'] = 'https://cdn.example.com';

      expect(Config.environment, Environment.development);
      expect(Config.isDevnet, isTrue);
      expect(Config.solanaRpcUrl, contains('network=devnet'));
      expect(Config.web3AuthNetwork, 'sapphire_devnet');
      expect(Config.storeCdnBaseUrl, 'https://cdn.example.com/store/dev');
      expect(
        buildExplorerUrl('sigABC123', 'solscan'),
        endsWith('?cluster=devnet'),
      );
    });

    test('staging is devnet as well', () {
      Config.debugOverrides['ENV'] = 'staging';

      expect(Config.environment, Environment.staging);
      expect(Config.isDevnet, isTrue);
      expect(Config.web3AuthNetwork, 'sapphire_devnet');
    });
  });
}
