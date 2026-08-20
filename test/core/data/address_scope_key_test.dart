import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/address_scope_key.dart';

const _addr = '8M9bV1Rjs1R4w4uX4qzPCsBkLs1ehrhRrUkkPwbAddrz';
const _siblingAddr = '9N1cW2Sktu2S5x5vY5razQDtCmLt2fisSsVllQxcBees';

/// One definition, because the key has to mean the same thing in every feature
/// that touches an aggregated wallet scope: `TokenBalanceBloc` compares it to
/// decide whether the header is showing a new session or refreshing the old
/// one, while `TokenTransferRepository` and `ActivityRepository` write their
/// Drift rows under it. This used to be four hand-synced copies of the same
/// expression; if one drifted, a wallet-set change would read history under a
/// key the balances side never wrote to.
void main() {
  group('addressScopeKey', () {
    // A single-wallet scope keeps the bare address, because that is what the
    // pre-aggregation write paths stored — collapse it to any other shape and
    // every existing single-wallet cache row is orphaned.
    test('is the bare address for a single-wallet scope', () {
      expect(addressScopeKey([_addr]), _addr);
    });

    // The address resolvers return session order, which is not stable across
    // a restore or a wallet switch. Sorting is what stops the same set of
    // wallets from cold-starting its own cache.
    test('is order-independent for a multi-wallet scope', () {
      expect(
        addressScopeKey([_addr, _siblingAddr]),
        addressScopeKey([_siblingAddr, _addr]),
      );
    });

    // The exact string is a durable on-disk key, not an implementation detail:
    // changing the separator or the ordering silently orphans every cached row
    // (reaped only by the 24h prune) and refetches from cold.
    test('joins a multi-wallet scope with | in sorted order', () {
      expect(addressScopeKey([_siblingAddr, _addr]), '$_addr|$_siblingAddr');
    });

    // Callers pass the live scope list and then keep using it — the request
    // body, the per-wallet cache reads. Sorting in place would silently
    // re-order the addresses those later calls are built from.
    test('does not reorder the caller\'s list', () {
      final addresses = [_siblingAddr, _addr];
      addressScopeKey(addresses);
      expect(addresses, [_siblingAddr, _addr]);
    });

    // Deliberately no de-duplication: callers hand over an already-unique
    // scope, and folding duplicates here would change the key for any scope
    // that ever contained one — the same cold-start as a format change.
    test('does not de-duplicate repeated addresses', () {
      expect(addressScopeKey([_addr, _addr]), '$_addr|$_addr');
    });

    // Empty scopes reach this from callers that decide separately whether to
    // fetch (`TokenDetailBloc` maps empty to a null scope key). It must return
    // a value rather than throw.
    test('collapses an empty scope to the empty string', () {
      expect(addressScopeKey(const []), '');
    });
  });
}
