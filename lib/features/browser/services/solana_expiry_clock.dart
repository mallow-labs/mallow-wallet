import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:solana/base58.dart' show base58encode;
import 'package:solana/encoder.dart';

import '../../../shared/widgets/transaction_expiry.dart';
import 'solana_dapp_adapter.dart' show DappRpc;
import 'solana_slot_time.dart';

/// Counts down to the expiry of the Solana transactions under one review.
///
/// A transaction carries the blockhash the site picked, and the network
/// accepts it for [maxAgeBlocks] blocks after that block: about half a minute,
/// most of it often gone before the review opens. The age is read from the
/// RecentBlockhashes sysvar, which lists the most recent blockhashes newest
/// first, so a blockhash's position is its age in blocks. Seconds come from
/// the slot time in [SolanaSlotTimeSource].
///
/// The clock ticks every second and re-reads the sysvar every [resyncEvery],
/// so drift and a slower or faster cluster are corrected while the sheet is
/// open. A review of several transactions counts down to the first to expire.
///
/// The estimate errs early: it starts from when the read was sent, keeps
/// [safetyBlocks] in hand for the confirmed view's lag and the trip to a
/// leader, and the slot time understates the time per block. "Expired" is
/// only ever declared from the chain (the blockhash has left the sysvar and
/// `isBlockhashValid` says false, or no blocks are left) or when a countdown
/// that reached zero cannot be checked.
///
/// A transaction whose first instruction advances a durable nonce has no
/// network expiry. The only clock left for it is the wallet's own review
/// window, which [reviewed] starts.
class SolanaExpiryClock {
  SolanaExpiryClock({
    required List<Uint8List> payloads,
    required String chain,
    required DappRpc rpc,
    SolanaSlotTimeSource? slotTime,
    DateTime Function()? now,
  }) : _chain = chain,
       _rpc = rpc,
       _slotTime = slotTime ?? SolanaSlotTimeSource.instance,
       _now = now ?? DateTime.now,
       _blockhashes = _expiringBlockhashes(payloads);

  /// How many blocks after its own a blockhash is accepted (the runtime's
  /// `MAX_PROCESSING_AGE`).
  static const maxAgeBlocks = 150;

  /// Blocks kept in hand: the confirmed sysvar lags the cluster's tip by a
  /// slot or two, and the signed transaction still has to reach a leader.
  static const safetyBlocks = 4;

  static const resyncEvery = Duration(seconds: 5);

  /// How long after its simulation a reviewed transaction may still be
  /// signed. Mirrors the check in `SolanaDappAdapter.signPrepared`.
  static const reviewWindow = Duration(minutes: 2);

  static const _sysvar = 'SysvarRecentB1ockHashes11111111111111111111';
  static const _systemProgram = '11111111111111111111111111111111';

  final String _chain;
  final DappRpc _rpc;
  final SolanaSlotTimeSource _slotTime;
  final DateTime Function() _now;

  /// The distinct blockhashes that expire, so durable-nonce transactions
  /// excluded. Empty when every transaction uses a nonce. Null when a
  /// payload cannot be read, which leaves the expiry unmeasured.
  final List<String>? _blockhashes;

  final _state = ValueNotifier<TransactionExpiry>(const ExpiryChecking());
  Timer? _ticker;
  DateTime? _deadline;
  DateTime? _reviewDeadline;
  Duration? _unmeasuredFor;
  var _sinceSync = Duration.zero;
  var _syncing = false;
  var _stopped = false;

  ValueListenable<TransactionExpiry> get state => _state;

  bool get expired => _state.value is ExpiryPassed;

  /// Takes the first reading and starts the ticker.
  void start() {
    if (_stopped || _ticker != null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    if (_blockhashes?.isEmpty ?? false) {
      _publish();
    } else {
      unawaited(_sync());
    }
  }

  /// Starts the wallet's review window from the review's simulation time.
  void reviewed(DateTime simulatedAt) {
    _reviewDeadline = simulatedAt.add(reviewWindow);
    _publish();
  }

  /// Stops ticking and reading. The state keeps its last value, so a sheet
  /// still on screen shows it frozen rather than failing.
  void stop() {
    _stopped = true;
    _ticker?.cancel();
  }

  void _tick() {
    if (_stopped) return;
    _sinceSync += const Duration(seconds: 1);
    final deadline = _deadline;
    final due =
        _sinceSync >= resyncEvery ||
        (deadline != null && !_now().isBefore(deadline));
    if (due && (_blockhashes?.isNotEmpty ?? true)) unawaited(_sync());
    _publish();
  }

  Future<void> _sync() async {
    if (_syncing || _stopped || expired) return;
    _syncing = true;
    _sinceSync = Duration.zero;
    final sentAt = _now();
    try {
      final slot = await _slotTime.load();
      final blockhashes = _blockhashes;
      final recent = blockhashes == null ? null : await _recentBlockhashes();
      if (_stopped) return;
      int? fewest;
      var unmeasured = blockhashes == null || recent == null;
      if (blockhashes != null && recent != null) {
        for (final blockhash in blockhashes) {
          final age = recent.indexOf(blockhash);
          if (age >= 0) {
            final left = maxAgeBlocks - age - safetyBlocks;
            fewest = fewest == null ? left : math.min(fewest, left);
            continue;
          }
          // Gone from the list: expired, unless it is newer than this read
          // (the site took it at a later commitment) or the sysvar is gone.
          final valid = await _isValid(blockhash);
          if (_stopped) return;
          if (valid == false) return _expire();
          unmeasured = true;
        }
      }
      if (fewest != null && fewest <= 0) return _expire();
      if (fewest != null) {
        _deadline = sentAt.add(slot * fewest);
        _unmeasuredFor = null;
        return;
      }
      if (unmeasured) {
        // A countdown that reached zero and cannot be checked fails closed.
        final deadline = _deadline;
        if (deadline != null && !_now().isBefore(deadline)) return _expire();
        if (blockhashes != null && recent == null) {
          for (final blockhash in blockhashes) {
            if (await _isValid(blockhash) == false) return _expire();
            if (_stopped) return;
          }
        }
        _deadline = null;
        _unmeasuredFor = slot * (maxAgeBlocks - safetyBlocks);
      }
    } catch (_) {
      // A failed reading changes nothing; the next one may succeed.
    } finally {
      _syncing = false;
      _publish();
    }
  }

  void _expire() {
    _state.value = const ExpiryPassed();
    _ticker?.cancel();
  }

  void _publish() {
    if (expired) return;
    final now = _now();
    final reviewDeadline = _reviewDeadline;
    if (reviewDeadline != null && !now.isBefore(reviewDeadline)) {
      return _expire();
    }
    final deadline = _deadline;
    final unmeasuredFor = _unmeasuredFor;
    _state.value = switch (_blockhashes) {
      [] => ExpiryNever(reviewRemaining: reviewDeadline?.difference(now)),
      _ when deadline != null => ExpiryCountdown(
        deadline.isAfter(now) ? deadline.difference(now) : Duration.zero,
      ),
      _ when unmeasuredFor != null => ExpiryUnmeasured(unmeasuredFor),
      _ => const ExpiryChecking(),
    };
  }

  Future<List<String>?> _recentBlockhashes() async {
    try {
      return decodeRecentBlockhashes(
        await _rpc(_chain, 'getAccountInfo', [
          _sysvar,
          {'encoding': 'base64', 'commitment': 'confirmed'},
        ]),
      );
    } catch (_) {
      return null;
    }
  }

  /// Null when the node could not be asked.
  Future<bool?> _isValid(String blockhash) async {
    try {
      final result = await _rpc(_chain, 'isBlockhashValid', [
        blockhash,
        {'commitment': 'confirmed'},
      ]);
      final value = result is Map ? result['value'] : null;
      return value is bool ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// The blockhashes listed in a `getAccountInfo` result for the sysvar,
  /// newest first: a u64 count, then per entry a 32-byte hash and an 8-byte
  /// fee rate. Null for anything else.
  @visibleForTesting
  static List<String>? decodeRecentBlockhashes(Object? result) {
    final value = result is Map ? result['value'] : null;
    final data = value is Map ? value['data'] : null;
    if (data is! List || data.isEmpty || data.first is! String) return null;
    final bytes = base64Decode(data.first as String);
    if (bytes.length < 8) return null;
    final count = ByteData.sublistView(bytes, 0, 8).getUint64(0, Endian.little);
    if (count > 1000 || bytes.length < 8 + count * 40) return null;
    return [
      for (var i = 0; i < count; i++)
        base58encode(bytes.sublist(8 + i * 40, 8 + i * 40 + 32)),
    ];
  }

  static List<String>? _expiringBlockhashes(List<Uint8List> payloads) {
    try {
      final blockhashes = <String>{};
      for (final payload in payloads) {
        final message = SignedTx.fromBytes(payload).compiledMessage;
        if (!_advancesNonce(message)) blockhashes.add(message.recentBlockhash);
      }
      return blockhashes.toList();
    } catch (_) {
      return null;
    }
  }

  /// The runtime treats a transaction as durable-nonce when its first
  /// instruction is the System program's AdvanceNonceAccount.
  static bool _advancesNonce(CompiledMessage message) {
    final first = message.instructions.firstOrNull;
    if (first == null || first.programIdIndex >= message.accountKeys.length) {
      return false;
    }
    final program = message.accountKeys[first.programIdIndex].toBase58();
    final data = first.data.toList();
    return program == _systemProgram &&
        data.length >= 4 &&
        data[0] == 4 &&
        data[1] == 0 &&
        data[2] == 0 &&
        data[3] == 0;
  }
}
