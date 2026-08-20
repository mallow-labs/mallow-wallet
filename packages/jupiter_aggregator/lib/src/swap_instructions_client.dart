import 'package:dio/dio.dart';

const _defaultClassicSwapApiUrl = 'https://api.jup.ag/swap/v1';

/// A quote from the classic `GET /swap/v1/quote` endpoint.
///
/// Held as the **raw response map** because `POST /swap-instructions` must
/// receive it verbatim as `quoteResponse` — a typed DTO that drops unknown
/// fields would corrupt the route (same failure mode as the swagger
/// additionalProperties quirk). Only the display fields the UI needs are
/// exposed as getters.
class JupiterClassicQuote {
  const JupiterClassicQuote(this.raw);

  final Map<String, dynamic> raw;

  String get inAmount => '${raw['inAmount']}';
  String get outAmount => '${raw['outAmount']}';
}

/// One instruction as serialized by Jupiter's swap-instructions response:
/// `{programId, accounts: [{pubkey, isSigner, isWritable}], data: base64}`.
class JupSerializedInstruction {
  const JupSerializedInstruction({
    required this.programId,
    required this.accounts,
    required this.dataBase64,
  });

  final String programId;
  final List<JupSerializedAccountMeta> accounts;
  final String dataBase64;

  factory JupSerializedInstruction.fromJson(Map<String, dynamic> json) => JupSerializedInstruction(
    programId: '${json['programId']}',
    accounts: ((json['accounts'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(JupSerializedAccountMeta.fromJson)
        .toList(growable: false),
    dataBase64: '${json['data']}',
  );
}

class JupSerializedAccountMeta {
  const JupSerializedAccountMeta({
    required this.pubkey,
    required this.isSigner,
    required this.isWritable,
  });

  final String pubkey;
  final bool isSigner;
  final bool isWritable;

  factory JupSerializedAccountMeta.fromJson(Map<String, dynamic> json) => JupSerializedAccountMeta(
    pubkey: '${json['pubkey']}',
    isSigner: json['isSigner'] == true,
    isWritable: json['isWritable'] == true,
  );
}

/// Response of `POST /swap/v1/swap-instructions`.
///
/// `computeBudgetInstructions` are parsed but deliberately unused by callers —
/// the webapp drops them and prepends its own compute-budget instructions
/// (its `createVersionedTransactionWithTables`).
class JupSwapInstructions {
  const JupSwapInstructions({
    required this.computeBudgetInstructions,
    required this.setupInstructions,
    required this.swapInstruction,
    required this.cleanupInstruction,
    required this.addressLookupTableAddresses,
  });

  final List<JupSerializedInstruction> computeBudgetInstructions;
  final List<JupSerializedInstruction> setupInstructions;
  final JupSerializedInstruction swapInstruction;
  final JupSerializedInstruction? cleanupInstruction;
  final List<String> addressLookupTableAddresses;

  factory JupSwapInstructions.fromJson(Map<String, dynamic> json) {
    List<JupSerializedInstruction> list(String key) => ((json[key] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(JupSerializedInstruction.fromJson)
        .toList(growable: false);
    return JupSwapInstructions(
      computeBudgetInstructions: list('computeBudgetInstructions'),
      setupInstructions: list('setupInstructions'),
      swapInstruction: JupSerializedInstruction.fromJson(
        json['swapInstruction'] as Map<String, dynamic>,
      ),
      cleanupInstruction: json['cleanupInstruction'] is Map<String, dynamic>
          ? JupSerializedInstruction.fromJson(json['cleanupInstruction'] as Map<String, dynamic>)
          : null,
      addressLookupTableAddresses: ((json['addressLookupTableAddresses'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
    );
  }
}

/// Client for Jupiter's **classic** swap API (`/swap/v1`) — distinct from
/// [JupiterAggregatorClient], which fronts the Ultra API (`/ultra/v1`) and
/// returns pre-compiled transactions.
///
/// Hand-rolled on Dio (no retrofit) because the quote must round-trip as a
/// raw map (see [JupiterClassicQuote]).
class JupiterSwapInstructionsClient {
  JupiterSwapInstructionsClient({String? baseUrl, Dio? dio})
    : _dio = dio ?? Dio(),
      _baseUrl =
          baseUrl ??
          const String.fromEnvironment(
            'CLASSIC_SWAP_API_BASE',
            defaultValue: _defaultClassicSwapApiUrl,
          );

  final Dio _dio;
  final String _baseUrl;

  /// `GET /quote`. Mirrors the webapp's `fetchExactInJupQuote` with
  /// `anyDexes: true` (no dex restriction params), `platformFeeBps: 0`.
  Future<JupiterClassicQuote> getQuote({
    required String inputMint,
    required String outputMint,
    required int amount,
    int slippageBps = 50,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$_baseUrl/quote',
      queryParameters: {
        'inputMint': inputMint,
        'outputMint': outputMint,
        'amount': '$amount',
        'slippageBps': '$slippageBps',
        'platformFeeBps': '0',
      },
    );
    final data = response.data;
    if (data == null || data['error'] != null) {
      throw Exception('Failed to get quote: ${data?['error']}');
    }
    return JupiterClassicQuote(data);
  }

  /// `POST /swap-instructions`. Body matches the webapp's
  /// `fetchJupIxsWithoutFeeAccount` exactly (no feeAccount, dynamic compute
  /// unit limit + slippage, veryHigh priority capped at 1M lamports).
  Future<JupSwapInstructions> getSwapInstructions({
    required JupiterClassicQuote quote,
    required String userPublicKey,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '$_baseUrl/swap-instructions',
      data: {
        'quoteResponse': quote.raw,
        'userPublicKey': userPublicKey,
        'dynamicComputeUnitLimit': true,
        'dynamicSlippage': true,
        'prioritizationFeeLamports': {
          'priorityLevelWithMaxLamports': {'maxLamports': 1000000, 'priorityLevel': 'veryHigh'},
        },
      },
    );
    final data = response.data;
    if (data == null || data['error'] != null) {
      throw Exception('Failed to get swap instructions: ${data?['error']}');
    }
    return JupSwapInstructions.fromJson(data);
  }
}
