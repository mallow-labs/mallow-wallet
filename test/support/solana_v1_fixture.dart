/// Shared v1 transaction fixture for the Solana v1 tests.
library;

// A v1 transaction built and signed by `@solana/kit` 8.3 (the reference
// implementation the backend's v1 builder is checked against): fee payer from a
// 32-byte seed of 1s, a read-only co-signer from a seed of 2s, one memo
// instruction naming the co-signer, compute limit 11,000, loaded-data limit
// 4,096 and a 15,000-lamport priority fee. ed25519 is deterministic, so signing
// [v1Unsigned] with the same keys must reproduce [v1Signed] byte for byte.
const v1Payer = 'AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9';
const v1Cosigner = '9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu';
const v1Blockhash = 'EETubP5AKHgjPAhzPAFcb8BAY1hMH639CWCFTqi3hq1k';
const v1Message =
    '810201010f000000c49ae77603782054f17a9decea43b444eba0edb12c6f1d31c6e0e4a8'
    '4bf052eb01038a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f'
    '6f5c8139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394054a'
    '535a992921064d24e87160da387c7c35b5ddbc92bb81e41fa8404105448d983a00000000'
    '0000f82a0000001000000201100001676966744d65737361676549643a3432';
final v1Unsigned = v1Message + '00' * 128;
const v1Signed =
    '$v1Message'
    '8536de8f2ff26ddc986eb17d0d1ae851d4ceb33eec4b70be1df64bb5459b98565efbc1af'
    'f35a6446d71d8b7b07c8cb100d902b17f7936ad195ddb4623276f0011e4896f45de6de31'
    'f1486ba70e496152723a0ec134035e889fef13169c3b98ef7b19092ea0979cbe8ba9cceb'
    'aa92bbc58906eae25d588f6fd1be515312331707';

/// [hex] as bytes.
List<int> hexBytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];
