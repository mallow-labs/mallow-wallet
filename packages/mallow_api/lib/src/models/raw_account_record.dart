/// A thin pass-through wrapper around the flat, already-decoded on-chain
/// account record the backend returns from `GET /v2/accounts/...` (the same
/// `{ accountType, ...fields, pubkey, program }` shape the `/v2/ws/accounts`
/// stream pushes).
///
/// Retrofit cannot synthesize a `fromJson` for a bare `Map<String, dynamic>`
/// type argument inside `ApiResponse<T>` (it emits `Map.fromJson`, which does
/// not exist), so this wrapper provides a real `fromJson`/`toJson` and exposes
/// the untouched [data] map for the caller to decode (e.g. with the app's
/// `AccountUpdate` parser).
class RawAccountRecord {
  const RawAccountRecord(this.data);

  factory RawAccountRecord.fromJson(Map<String, dynamic> json) => RawAccountRecord(json);

  /// The decoded account record, verbatim.
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => data;
}
