import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_namespaces.dart';
import 'package:reown_sign/reown_sign.dart' show Namespace, RequiredNamespace;
import 'package:reown_sign/utils/sign_api_validator_utils.dart';

void main() {
  const solana = 'SoLAddress1111111111111111111111111111111111';
  const ethereum = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  test('Given an unsupported required chain, the proposal is refused', () {
    expect(
      () => requestedNamespaces(
        requiredNamespaces: const {
          'eip155': RequiredNamespace(
            chains: ['eip155:1', 'eip155:137'],
            methods: ['personal_sign'],
            events: [],
          ),
        },
        optionalNamespaces: const {},
      ),
      throwsA(isA<WalletConnectUnsupported>()),
    );
  });

  test('Given unsupported optional chains, they are dropped', () {
    final requested = requestedNamespaces(
      requiredNamespaces: const {},
      optionalNamespaces: const {
        'eip155': RequiredNamespace(
          chains: ['eip155:1', 'eip155:8453'],
          methods: ['eth_sendTransaction'],
          events: [],
        ),
        'cosmos': RequiredNamespace(
          chains: ['cosmos:cosmoshub-4'],
          methods: [],
          events: [],
        ),
      },
    );
    expect(requested.single.namespace, 'eip155');
    expect(requested.single.chains, ['eip155:1']);
    expect(requested.single.required, isFalse);
  });

  test('Given a chain-keyed namespace and the old Solana id, both map', () {
    final requested = requestedNamespaces(
      requiredNamespaces: const {
        walletConnectSolanaMainnetLegacy: RequiredNamespace(
          methods: ['solana_signTransaction'],
          events: [],
        ),
      },
      optionalNamespaces: const {
        'solana': RequiredNamespace(
          chains: [walletConnectSolanaMainnet, walletConnectSolanaDevnet],
          methods: [],
          events: [],
        ),
      },
    );
    expect(requested.single.chains, [
      walletConnectSolanaMainnetLegacy,
      walletConnectSolanaMainnet,
    ]);
    expect(requested.single.required, isTrue);
  });

  test('Devnet is offered only where allowed', () {
    final requested = requestedNamespaces(
      requiredNamespaces: const {},
      optionalNamespaces: const {
        'solana': RequiredNamespace(
          chains: [walletConnectSolanaDevnet],
          methods: [],
          events: [],
        ),
      },
      allowDevnet: true,
    );
    expect(requested.single.chains, [walletConnectSolanaDevnet]);
    expect(coordinatorChain(walletConnectSolanaDevnet), isNull);
  });

  test('Approved namespaces give each chain the chosen account', () {
    final requested = requestedNamespaces(
      requiredNamespaces: const {
        'eip155': RequiredNamespace(
          chains: ['eip155:1'],
          methods: ['personal_sign', 'eth_sign'],
          events: ['chainChanged'],
        ),
      },
      optionalNamespaces: const {
        'solana': RequiredNamespace(
          chains: [walletConnectSolanaMainnet],
          methods: ['solana_signTransaction', 'solana_somethingElse'],
          events: [],
        ),
      },
    );
    final namespaces = approvedNamespaces(requested, {
      'eip155': ethereum,
      'solana': solana,
    });
    expect(namespaces['eip155']!.accounts, ['eip155:1:$ethereum']);
    // A required method is listed for conformance, then refused per request.
    expect(namespaces['eip155']!.methods, contains('eth_sign'));
    expect(namespaces['solana']!.accounts, [
      '$walletConnectSolanaMainnet:$solana',
    ]);
    expect(
      namespaces['solana']!.methods,
      isNot(contains('solana_somethingElse')),
    );
    expect(sessionAddress(namespaces, 'eip155'), ethereum);
    expect(sessionAddress(namespaces, 'tezos'), isNull);
  });

  test('Chain-keyed required entries keep their key, methods and events', () {
    const required = {
      'eip155:1': RequiredNamespace(
        methods: ['personal_sign'],
        events: ['chainChanged', 'message'],
      ),
      'solana': RequiredNamespace(
        chains: [walletConnectSolanaMainnet],
        methods: ['solana_signMessage'],
        events: ['accountsChanged'],
      ),
    };
    final requested = requestedNamespaces(
      requiredNamespaces: required,
      optionalNamespaces: const {
        'solana': RequiredNamespace(
          chains: [walletConnectSolanaMainnetLegacy],
          methods: [],
          events: [],
        ),
      },
    );
    final namespaces = approvedNamespaces(requested, {
      'eip155': ethereum,
      'solana': solana,
    });
    expect(
      SignApiValidatorUtils.isConformingNamespaces(
        requiredNamespaces: required,
        namespaces: namespaces,
        context: 'test',
      ),
      isTrue,
    );
    expect(namespaces['eip155:1']!.accounts, ['eip155:1:$ethereum']);
    expect(namespaces['solana']!.chains, [
      walletConnectSolanaMainnet,
      walletConnectSolanaMainnetLegacy,
    ]);
    final accounts = sessionAccounts(namespaces)!;
    expect(accounts['eip155']!.address, ethereum);
    expect(accounts['solana']!.chains, hasLength(2));
  });

  test('A session naming two addresses for one namespace is refused', () {
    expect(
      sessionAccounts(const {
        'eip155': Namespace(
          accounts: ['eip155:1:$ethereum', 'eip155:1:0xabc'],
          methods: [],
          events: [],
        ),
      }),
      isNull,
    );
  });

  test('A required namespace without a wallet cannot be approved', () {
    final requested = requestedNamespaces(
      requiredNamespaces: const {
        'tezos': RequiredNamespace(
          chains: [walletConnectTezosMainnet],
          methods: ['tezos_send'],
          events: [],
        ),
      },
      optionalNamespaces: const {},
    );
    expect(
      () => approvedNamespaces(requested, const {}),
      throwsA(isA<WalletConnectUnsupported>()),
    );
  });
}
