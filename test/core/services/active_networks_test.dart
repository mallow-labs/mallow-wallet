import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/active_networks.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSession extends Mock implements SessionManager {}

/// The Active Networks preference is read by three surfaces that must agree —
/// the tokens tab, the NFT portfolio request, and the import picker. These
/// tests pin the two properties they rely on: the read is scoped to the
/// session, and a write announces itself so a portfolio already on screen
/// drops the chain.
void main() {
  setUpAll(() => registerFallbackValue(Chain.solana));

  late _MockStorage storage;
  late _MockSession session;
  late ActiveNetworks networks;

  setUp(() {
    storage = _MockStorage();
    session = _MockSession();
    networks = ActiveNetworks(storage, session);
    when(() => session.settingsScopeId()).thenAnswer((_) async => 'profile-1');
    when(
      () =>
          storage.storeNetworkEnabled(any(), any(), scope: any(named: 'scope')),
    ).thenAnswer((_) async {});
  });

  test('reads the preference under the session scope', () async {
    when(
      () => storage.loadNetworkEnabled(Chain.tezos, scope: 'profile-1'),
    ).thenAnswer((_) async => false);

    expect(await networks.isEnabled(Chain.tezos), isFalse);
    // Why: the preference is per profile (and per account). Reading the
    // unscoped key would leak one profile's networks into another's.
    verify(
      () => storage.loadNetworkEnabled(Chain.tezos, scope: 'profile-1'),
    ).called(1);
  });

  test('Solana is never togglable', () async {
    expect(await networks.isEnabled(Chain.solana), isTrue);
    await networks.setEnabled(Chain.solana, false);

    // Why: Solana is the transactional chain the session identity is built on.
    // Storing a preference nothing reads would strand a user with no chains.
    verifyNever(
      () =>
          storage.loadNetworkEnabled(Chain.solana, scope: any(named: 'scope')),
    );
    verifyNever(
      () => storage.storeNetworkEnabled(
        Chain.solana,
        any(),
        scope: any(named: 'scope'),
      ),
    );
  });

  test('disabled() collects only the switched-off chains', () async {
    when(
      () => storage.loadNetworkEnabled(Chain.tezos, scope: 'profile-1'),
    ).thenAnswer((_) async => false);
    when(
      () => storage.loadNetworkEnabled(Chain.ethereum, scope: 'profile-1'),
    ).thenAnswer((_) async => true);

    expect(await networks.disabled(), {Chain.tezos});
  });

  test('setEnabled writes and announces the change', () async {
    final seen = <void>[];
    networks.changes.listen(seen.add);

    await networks.setEnabled(Chain.ethereum, false);
    await Future<void>.delayed(Duration.zero);

    verify(
      () => storage.storeNetworkEnabled(
        Chain.ethereum,
        false,
        scope: 'profile-1',
      ),
    ).called(1);
    // Why: the toggle screen sits on top of a live portfolio. Without this
    // signal the switched-off chain's rows and their USD stay on the tab until
    // the next wallet switch or pull-to-refresh.
    expect(seen, hasLength(1));
  });
}
