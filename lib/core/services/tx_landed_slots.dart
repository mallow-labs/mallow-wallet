import 'dart:collection';

import 'package:injectable/injectable.dart';

/// Registry of the Solana slot each of our own confirmed transactions landed
/// in, keyed by signature. Populated by `SolanaRpcService.transactionStatus`
/// — `getSignatureStatuses` returns the processed slot alongside the
/// confirmation status, which every flow previously discarded. Only a landed
/// *successful* tx records a slot: a landed-but-failed tx mutated nothing, so
/// it must not raise the ordering floor.
///
/// The landed slot is the client's per-action ordering floor: after our tx
/// landed at slot S, any on-chain read whose view slot is older than S
/// predates our own action and must not be trusted to contradict it (e.g. an
/// `absent` listing read served by a lagging RPC node right after a list).
/// This is the slot-precise replacement for wall-clock grace heuristics.
///
/// Bounded LRU — a session signs a handful of txs; 64 covers any realistic
/// burst while keeping the map trivially small.
@lazySingleton
class TxLandedSlots {
  static const _capacity = 64;

  final LinkedHashMap<String, int> _slots = LinkedHashMap();

  /// Record that [signature] was confirmed in [slot].
  void record(String signature, int slot) {
    if (signature.isEmpty || slot <= 0) return;
    _slots.remove(signature);
    _slots[signature] = slot;
    while (_slots.length > _capacity) {
      _slots.remove(_slots.keys.first);
    }
  }

  /// The slot [signature] landed in, or null when unknown (not ours, not yet
  /// confirmed, or evicted).
  int? slotFor(String signature) => _slots[signature];
}
