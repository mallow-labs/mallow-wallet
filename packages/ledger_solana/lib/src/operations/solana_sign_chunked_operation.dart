import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../models/solana_derivation_path.dart';
import '../solana_apdu.dart';

/// Builds the frame operation for one APDU of a signing stream — INS 0x06 for
/// transactions, INS 0x07 for off-chain messages.
typedef SolanaSignFrameBuilder = LedgerRawOperation<Uint8List> Function(
  int p2,
  Uint8List chunk,
  bool isLast,
);

/// Streams `[pathsCount][pathBytes][data]` to the device across as many APDU
/// frames as the 255-byte `Lc` ceiling requires, and returns the signature the
/// final frame yields.
///
/// **Why a complex operation.** Each frame must be its own device exchange:
/// `LedgerGattGateway` registers one pending operation per exchange and
/// completes it on the FIRST reassembled response, so emitting every frame from
/// a single `write()` would resolve against the non-final frame's bare `0x9000`
/// ack — surfacing success as "signing failed (0x9000)" and dropping the
/// signature. But the frames also must not be *separately queued*:
/// `LedgerConnection` serializes queued requests without grouping them, so a
/// concurrent `getAppConfig()` / `getPublicKey()` could land between frame N and
/// N+1, and the intervening INS discards the device's accumulated signing
/// buffer. `LedgerComplexOperation` gives both — one outer queue entry holding
/// the whole exchange, with the frames sent one at a time through a nested
/// queue.
///
/// P2 flag sequence matches `@ledgerhq/hw-app-solana`: `p2More` while more data
/// follows, `p2Extend` on every frame after the first.
class SolanaSignChunkedOperation extends LedgerComplexOperation<Uint8List> {
  const SolanaSignChunkedOperation({
    required this.derivationPath,
    required this.data,
    required this.buildFrame,
  });

  /// The path whose key signs — encoded into the first frame's payload.
  final SolanaDerivationPath derivationPath;

  /// The bytes to sign: a compiled transaction message or an off-chain message.
  final Uint8List data;

  /// Builds one frame; varies only by INS between the two signing paths.
  final SolanaSignFrameBuilder buildFrame;

  @override
  Future<Uint8List> invoke(LedgerSendFct send) async {
    final pathBytes = derivationPath.toBytes();
    final payload = Uint8List(1 + pathBytes.length + data.length);
    payload[0] = 1; // paths count — single-signer only.
    payload.setRange(1, 1 + pathBytes.length, pathBytes);
    payload.setRange(1 + pathBytes.length, payload.length, data);

    var offset = 0;
    var p2 = SolanaApdu.p2Init;
    while (true) {
      final remaining = payload.length - offset;
      final isLast = remaining <= SolanaApdu.maxChunkSize;
      final size = isLast ? remaining : SolanaApdu.maxChunkSize;
      final chunk = payload.sublist(offset, offset + size);

      final result = await send(
        buildFrame(isLast ? p2 : p2 | SolanaApdu.p2More, chunk, isLast),
      );
      if (isLast) return result;

      offset += size;
      p2 |= SolanaApdu.p2Extend;
    }
  }
}
