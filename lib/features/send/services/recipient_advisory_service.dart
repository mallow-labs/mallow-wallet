import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:solana/base58.dart';
import 'package:solana/dto.dart' show DataSlice, Encoding;
import 'package:solana/solana.dart';

import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../shared/utils/chain.dart' show Chain;
import '../../../shared/utils/tezos_address.dart';
import '../models/recipient_advisory.dart';

/// Classifies a send recipient so the confirm step can warn — never block —
/// before an irreversible transfer.
///
/// Three rules the implementation is built around:
///
/// 1. **Fail soft.** Any transport error resolves to "no advisory". A timeout
///    must never surface as "this recipient is dangerous", and must never stop
///    a send.
/// 2. **No false positives.** A plain funded wallet on every chain produces
///    nothing. A user who has dismissed three useless warnings will dismiss the
///    fourth real one, so a marginal signal is omitted rather than guessed at.
/// 3. **One advisory, most severe wins** ([RecipientAdvisoryKind] declaration
///    order). Stacking banners is the same fatigue problem.
///
/// Detection is *not* wired into the review/prepare path — the send sheet fires
/// it when the confirm step appears, alongside the simulation, so it can never
/// add a round-trip to the time it takes to reach the confirm step.
@lazySingleton
class RecipientAdvisoryService {
  RecipientAdvisoryService(this._solana, this._ethereum);

  final SolanaRpcService _solana;
  final EthereumRpcService _ethereum;

  /// The most severe advisory for [address] on [chain], or null when the
  /// recipient looks like an ordinary funded wallet (or nothing could be
  /// determined).
  Future<RecipientAdvisory?> detect({
    required Chain chain,
    required String address,
  }) async {
    switch (chain) {
      case Chain.solana:
        return _detectSolana(address);
      case Chain.ethereum:
        return _detectEthereum(address);
      case Chain.tezos:
        return _detectTezos(address);
    }
  }

  /// Solana: token account > PDA > unfunded.
  ///
  /// The off-curve test is local, so it still stands when the RPC read fails —
  /// note that an ATA is itself off-curve, which is why "token account" is
  /// ranked above "program address" rather than being a separate banner.
  Future<RecipientAdvisory?> _detectSolana(String address) async {
    final isProgramAddress = _isOffCurve(address);

    // Only `owner` is read, so the account's data is sliced to nothing — a
    // pasted program id or a large PDA would otherwise pull hundreds of KB of
    // base64 over mobile data on the confirm path.
    final account = await _soft(
      () => _solana.getAccountInfo(
        address,
        encoding: Encoding.base64,
        dataSlice: const DataSlice(offset: 0, length: 0),
      ),
    );

    if (account != null) {
      final owner = account.value?.owner;
      if (owner == TokenProgram.programId ||
          owner == Token2022Program.programId) {
        return const RecipientAdvisory(
          RecipientAdvisoryKind.tokenAccount,
          'This looks like a token account, not a wallet — '
          'please confirm the address is correct',
        );
      }
      if (isProgramAddress) return _solanaProgramAddress;
      if (account.value == null) return _emptyWallet;
      return null;
    }

    // RPC unavailable: the local signal is still trustworthy, the network one
    // is simply unknown.
    return isProgramAddress ? _solanaProgramAddress : null;
  }

  /// EVM: contract > unfunded. All three reads are dispatched before the first
  /// is awaited, so this is one round-trip's latency, not three.
  ///
  /// Zero balance alone is **not** "unfunded" — plenty of live wallets hold
  /// only tokens — so the nonce has to be zero too. Note the nonce counts
  /// *outgoing* transactions, so this is "no ether and never signed anything",
  /// which deliberately still fires on a receive-only address: an account that
  /// has never transacted is worth a second look even when tokens landed in it.
  Future<RecipientAdvisory?> _detectEthereum(String address) async {
    final codeFuture = _soft(() => _ethereum.hasContractCode(address));
    final balanceFuture = _soft(() => _ethereum.getBalance(address));
    final nonceFuture = _soft(() => _ethereum.getNonce(address));

    if (await codeFuture ?? false) {
      return const RecipientAdvisory(
        RecipientAdvisoryKind.contract,
        'This address is a contract, not a standard wallet — '
        'make sure it can receive this token',
      );
    }

    final balance = await balanceFuture;
    final nonce = await nonceFuture;
    if (balance == BigInt.zero && nonce == 0) return _emptyWallet;
    return null;
  }

  /// Tezos: `KT1` only, and purely local.
  ///
  /// No "can this contract receive FA2/native" check — that needs entrypoint
  /// introspection the app has no interpreter for, and a wrong answer either
  /// way is worse than silence. Reveal state is deliberately not read either:
  /// an unrevealed Tezos account is completely normal, so it would be a
  /// round-trip spent on a false positive.
  Future<RecipientAdvisory?> _detectTezos(String address) async {
    if (tezosAddressKind(address) != TezosAddressKind.kt1) return null;
    return const RecipientAdvisory(
      RecipientAdvisoryKind.contract,
      'This address is a contract (KT1), not a standard wallet — '
      'please confirm the address is correct',
    );
  }

  static const _emptyWallet = RecipientAdvisory(
    RecipientAdvisoryKind.unfunded,
    'This wallet is empty, please confirm the address is correct',
  );

  static const _solanaProgramAddress = RecipientAdvisory(
    RecipientAdvisoryKind.programAddress,
    'This address is a program account (PDA), not a standard wallet — '
    'please confirm the address is correct',
  );

  /// True when [address] decodes to 32 bytes that are *not* an ed25519 point,
  /// i.e. a program-derived address. Note `SecurityUtils.isValidSolanaAddress`
  /// deliberately skips this check because PDAs are legitimate recipients —
  /// which is exactly why it belongs here, as an advisory.
  static bool _isOffCurve(String address) {
    try {
      return !isPointOnEd25519Curve(base58decode(address));
    } catch (_) {
      // Not a 32-byte base58 key: the recipient step already rejected it, and
      // guessing here would warn on an address we can't classify.
      return false;
    }
  }

  static Future<T?> _soft<T>(Future<T> Function() read) async {
    try {
      return await read();
    } catch (e) {
      debugPrint('[RecipientAdvisory] read failed (advisory suppressed): $e');
      return null;
    }
  }
}
