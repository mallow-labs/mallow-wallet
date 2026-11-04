import 'package:reown_sign/reown_sign.dart' show Namespace, RequiredNamespace;

import '../../../shared/utils/chain.dart';
import '../../browser/services/ethereum_dapp_adapter.dart' show ethereumMainnet;
import '../../browser/services/tezos_dapp_adapter.dart' show tezosMainnet;

/// The CAIP-2 chains a session may hold, each mapped to the chain id the
/// browser's request coordinator uses. Solana's older mainnet id is still sent
/// by some websites, so it is accepted as an alias of mainnet.
const walletConnectSolanaMainnet = 'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp';
const walletConnectSolanaMainnetLegacy =
    'solana:4sGjMW1sUnHzSxGspuhpqLDx6wiyjNtZ';
const walletConnectSolanaDevnet = 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1';
const walletConnectEthereumMainnet = 'eip155:1';
const walletConnectTezosMainnet = 'tezos:mainnet';

/// The methods each namespace answers. `eth_sign` is left out on purpose: it
/// signs a raw hash, which no review can explain.
const walletConnectMethods = <String, List<String>>{
  'solana': [
    'solana_signTransaction',
    'solana_signAllTransactions',
    'solana_signAndSendTransaction',
    'solana_signMessage',
    'solana_getAccounts',
    'solana_requestAccounts',
  ],
  'eip155': [
    'personal_sign',
    'eth_signTypedData_v4',
    'eth_signTypedData',
    'eth_sendTransaction',
    'eth_accounts',
    'eth_requestAccounts',
    'eth_chainId',
    'wallet_switchEthereumChain',
  ],
  'tezos': ['tezos_getAccounts', 'tezos_sign', 'tezos_send'],
};

const _events = <String, List<String>>{
  'solana': [],
  'eip155': ['chainChanged', 'accountsChanged'],
  'tezos': [],
};

/// The coordinator's chain id for a WalletConnect chain, or null when the
/// wallet does not support it. Devnet is offered only when [allowDevnet].
String? coordinatorChain(String caip2, {bool allowDevnet = false}) =>
    switch (caip2) {
      walletConnectSolanaMainnet ||
      walletConnectSolanaMainnetLegacy => 'solana:mainnet',
      walletConnectSolanaDevnet when allowDevnet => 'solana:devnet',
      walletConnectEthereumMainnet => ethereumMainnet,
      walletConnectTezosMainnet => tezosMainnet,
      _ => null,
    };

/// The app chain a namespace's wallet is chosen from.
Chain? namespaceChain(String namespace) => switch (namespace) {
  'solana' => Chain.solana,
  'eip155' => Chain.ethereum,
  'tezos' => Chain.tezos,
  _ => null,
};

/// Why a proposal cannot be approved.
class WalletConnectUnsupported implements Exception {
  const WalletConnectUnsupported(this.message, {this.methods = false});
  final String message;

  /// The required methods, not chains, were the problem.
  final bool methods;
  @override
  String toString() => 'WalletConnectUnsupported($message)';
}

/// One namespace a website asked for, reduced to the chains this wallet can
/// serve. [required] namespaces must all be served for the session to exist.
class RequestedNamespace {
  const RequestedNamespace({
    required this.namespace,
    required this.chains,
    required this.required,
    this.requiredKeys = const {},
  });
  final String namespace;
  final List<String> chains;
  final bool required;

  /// The proposal's required entries for this namespace, under their own
  /// keys (`eip155`, or a chain such as `eip155:1`). The approved session
  /// must answer each under the same key, with all its methods and events.
  final Map<String, RequiredNamespace> requiredKeys;
}

/// Reads a proposal's required and optional namespaces into the ones this
/// wallet can serve.
///
/// A required chain the wallet lacks fails the whole proposal: approving part
/// of a required set breaks the session for the website. Optional chains the
/// wallet lacks are dropped, and an optional namespace left with no chain is
/// dropped with them. A namespace key may be a chain itself (`eip155:1`)
/// rather than carry a `chains` list.
List<RequestedNamespace> requestedNamespaces({
  required Map<String, RequiredNamespace> requiredNamespaces,
  required Map<String, RequiredNamespace> optionalNamespaces,
  bool allowDevnet = false,
}) {
  final merged = <String, RequestedNamespace>{};
  void add(String key, RequiredNamespace value, {required bool required}) {
    final colon = key.indexOf(':');
    final namespace = colon == -1 ? key : key.substring(0, colon);
    final chains = colon == -1 ? (value.chains ?? const <String>[]) : [key];
    final supported = <String>[];
    for (final chain in chains) {
      if (!chain.startsWith('$namespace:')) {
        throw const WalletConnectUnsupported('Invalid chain');
      }
      if (namespaceChain(namespace) != null &&
          coordinatorChain(chain, allowDevnet: allowDevnet) != null) {
        supported.add(chain);
      } else if (required) {
        throw const WalletConnectUnsupported(
          'This site requires a network mallow does not support',
        );
      }
    }
    if (supported.isEmpty) {
      if (required) {
        throw const WalletConnectUnsupported(
          'This site requires a network mallow does not support',
        );
      }
      return;
    }
    final previous = merged[namespace];
    merged[namespace] = RequestedNamespace(
      namespace: namespace,
      chains: {...?previous?.chains, ...supported}.toList(),
      required: required || (previous?.required ?? false),
      requiredKeys: {...?previous?.requiredKeys, if (required) key: value},
    );
  }

  for (final entry in requiredNamespaces.entries) {
    add(entry.key, entry.value, required: true);
  }
  for (final entry in optionalNamespaces.entries) {
    add(entry.key, entry.value, required: false);
  }
  return merged.values.toList();
}

/// The session namespaces to approve, with one account per chain for the
/// wallet chosen for each namespace in [addresses].
///
/// Each required entry is answered under its own key, which the SDK checks
/// along with its methods and events. A required method this wallet does not
/// answer is therefore still listed; its requests are refused one by one as
/// unsupported. Chains no required entry names go under the namespace's own
/// key, with only the methods this wallet answers.
Map<String, Namespace> approvedNamespaces(
  List<RequestedNamespace> requested,
  Map<String, String> addresses,
) {
  final result = <String, Namespace>{};
  for (final namespace in requested) {
    final name = namespace.namespace;
    final address = addresses[name];
    if (address == null) {
      if (namespace.required) {
        throw const WalletConnectUnsupported(
          'Choose a wallet for each network',
        );
      }
      continue;
    }
    final supported = walletConnectMethods[name]!;
    final covered = <String>{};
    for (final entry in namespace.requiredKeys.entries) {
      final chains = entry.key.contains(':')
          ? [entry.key]
          : [
              for (final chain in entry.value.chains ?? const <String>[])
                if (namespace.chains.contains(chain)) chain,
            ];
      covered.addAll(chains);
      result[entry.key] = Namespace(
        chains: entry.key.contains(':') ? null : chains,
        accounts: [for (final chain in chains) '$chain:$address'],
        methods: {...supported, ...entry.value.methods}.toList(),
        events: {..._events[name]!, ...entry.value.events}.toList(),
      );
    }
    final rest = [
      for (final chain in namespace.chains)
        if (!covered.contains(chain)) chain,
    ];
    if (rest.isEmpty) continue;
    final existing = result[name];
    final chains = {...?existing?.chains, ...rest}.toList();
    result[name] = Namespace(
      chains: chains,
      accounts: [for (final chain in chains) '$chain:$address'],
      methods: {...supported, ...?existing?.methods}.toList(),
      events: {..._events[name]!, ...?existing?.events}.toList(),
    );
  }
  if (result.isEmpty) {
    throw const WalletConnectUnsupported(
      'This site asks for no network mallow supports',
    );
  }
  return result;
}

/// The address and chains a session holds for each namespace, read from its
/// accounts (`<namespace>:<reference>:<address>`) under every key. Null when
/// one namespace names two addresses, which this wallet never approves: one
/// wallet per namespace.
Map<String, ({String address, List<String> chains})>? sessionAccounts(
  Map<String, Namespace> namespaces,
) {
  final result = <String, ({String address, List<String> chains})>{};
  for (final entry in namespaces.values) {
    for (final account in entry.accounts) {
      final parts = account.split(':');
      if (parts.length != 3) return null;
      final chain = '${parts[0]}:${parts[1]}';
      final previous = result[parts[0]];
      if (previous != null && previous.address != parts[2]) return null;
      result[parts[0]] = (
        address: parts[2],
        chains: {...?previous?.chains, chain}.toList(),
      );
    }
  }
  return result;
}

/// The address a session holds for [namespace]; see [sessionAccounts].
String? sessionAddress(Map<String, Namespace> namespaces, String namespace) =>
    sessionAccounts(namespaces)?[namespace]?.address;
