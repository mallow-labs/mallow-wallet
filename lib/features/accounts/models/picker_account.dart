import 'package:ledger_solana/ledger_solana.dart';

import '../../../core/models/account.dart';

import '../../../shared/utils/chain.dart';
// ---------------------------------------------------------------------------
// Account-picker view models
//
// Shared by the seed-phrase import picker and the Ledger account picker so both
// render the same account-card layout. A Ledger account is just a single-chain
// (Solana) [PickerAccount]; a seed-phrase account carries its multi-chain rows.
// ---------------------------------------------------------------------------

/// A single selectable wallet row inside an account card.
///
/// Only Solana addresses are [enrichable] (mallow indexes Solana NFTs and
/// balances); Ethereum/Tezos rows render the address with no activity chip.
class PickerWallet {
  const PickerWallet({
    required this.accountIndex,
    required this.chain,
    required this.address,
    required this.alreadyImported,
    this.scheme,
    this.artworkCount,
    this.balanceUsd,
    this.addressPending = false,
  });

  final int accountIndex;
  final Chain chain;
  final String address;
  final bool alreadyImported;

  /// True while this row's address is still being derived — the UI shows a
  /// shimmer placeholder where the address will appear (e.g. legacy rows that
  /// pop in after the "Show legacy Solana accounts" toggle).
  final bool addressPending;

  /// Solana derivation scheme; null for standard Solana and non-Solana chains.
  final SolanaDerivationScheme? scheme;

  /// Solana-only. Null while loading; set (possibly 0) once enriched.
  final int? artworkCount;
  final double? balanceUsd;

  bool get enrichable => chain == Chain.solana;

  bool get hasActivity =>
      (artworkCount != null && artworkCount! > 0) ||
      (balanceUsd != null && balanceUsd! > 0);

  /// Stable key used for selection tracking.
  String get key => '$accountIndex:${chain.name}:${scheme?.name ?? ''}';

  PickerWallet copyWith({int? artworkCount, double? balanceUsd}) =>
      PickerWallet(
        accountIndex: accountIndex,
        chain: chain,
        address: address,
        alreadyImported: alreadyImported,
        scheme: scheme,
        addressPending: addressPending,
        artworkCount: artworkCount ?? this.artworkCount,
        balanceUsd: balanceUsd ?? this.balanceUsd,
      );
}

/// One account card: a derivation index with its (one or more) wallet rows.
///
/// Shared by the seed-phrase and Ledger import pickers — both group by
/// derivation index, so the header reads "Account NN".
class PickerAccount {
  const PickerAccount({
    required this.index,
    required this.wallets,
    this.importedName,
  });

  final int index;
  final List<PickerWallet> wallets;

  /// Stored name of the already-imported account at this derivation index, when
  /// it exists. Set so a user-edited name surfaces in the picker instead of the
  /// generic `Account NN`; null for indices that aren't imported yet.
  final String? importedName;

  /// Whether at least one not-yet-imported wallet on this card is currently
  /// selected. Drives the live `Account NN` name preview: only selected,
  /// unimported cards consume a counter number.
  bool isSelectedIn(Set<String> selectedKeys) =>
      wallets.any((w) => !w.alreadyImported && selectedKeys.contains(w.key));

  /// Stable seed for this account's preview avatar.
  String get avatarSeed => 'account-preview-$index';

  /// Solana wallets that participate in enrichment. Already-imported wallets are
  /// skipped by the enricher (their counts stay null), so excluding them keeps
  /// the header aggregate from being stuck "loading" on a mixed account.
  List<PickerWallet> get _enrichableSolana => wallets
      .where((w) => w.chain == Chain.solana && !w.alreadyImported)
      .toList();

  /// Aggregate artwork count across Solana wallets, or null while loading.
  int? get artworkCount {
    final sol = _enrichableSolana;
    if (sol.any((w) => w.artworkCount == null)) return null;
    return sol.fold<int>(0, (sum, w) => sum + (w.artworkCount ?? 0));
  }

  /// Aggregate USD across Solana wallets, or null while loading.
  double? get balanceUsd {
    final sol = _enrichableSolana;
    if (sol.any((w) => w.balanceUsd == null)) return null;
    return sol.fold<double>(0.0, (sum, w) => sum + (w.balanceUsd ?? 0));
  }

  bool get isEnriched => _enrichableSolana.every((w) => w.artworkCount != null);

  bool get hasActivity => _enrichableSolana.any((w) => w.hasActivity);

  /// True once any of this account's wallets is already imported. Used to skip
  /// pre-selecting a phrase that the user is adding more wallets to.
  bool get isImported => wallets.any((w) => w.alreadyImported);

  PickerAccount withWallets(List<PickerWallet> next) =>
      PickerAccount(index: index, wallets: next, importedName: importedName);
}

/// Resolves the header name shown for each card in the import pickers, applying
/// the global-counter live-preview rules:
///
/// - already-imported cards keep their stored [PickerAccount.importedName]
///   (they consume no number);
/// - selected, not-yet-imported cards preview the exact `Account NN` they will
///   be saved as, numbered ascending by derivation index from [baseCounter];
/// - unselected, not-yet-imported cards show a bare `Account` (no number).
///
/// Returns a map keyed by [PickerAccount.index]. The ascending walk mirrors the
/// repository's import order, so previews equal the persisted names.
Map<int, String> previewAccountNames({
  required List<PickerAccount> accounts,
  required Set<String> selectedKeys,
  required int baseCounter,
}) {
  final ordered = [...accounts]..sort((a, b) => a.index.compareTo(b.index));
  final names = <int, String>{};
  var next = baseCounter;
  for (final a in ordered) {
    if (a.importedName != null) {
      names[a.index] = a.importedName!;
    } else if (a.isSelectedIn(selectedKeys)) {
      names[a.index] = formatAccountName(next);
      next++;
    } else {
      names[a.index] = 'Account';
    }
  }
  return names;
}
