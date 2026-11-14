import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../config/environment.dart';
import 'known_solana_instructions.dart';
import 'preferences_service.dart';

/// Names for well-known Solana programs and their instructions, shown in the
/// signing review's "Program calls".
///
/// The list is a static JSON object at [Config.programLabelsUrl], curated and
/// published by the backend, so a new program or instruction needs no app
/// release:
///
/// ```json
/// {"version": 1, "programs": [{"address": "1111…", "name": "System Program",
///   "instructions": [{"discriminator": "02000000", "name": "Transfer"}]}]}
/// ```
///
/// `instructions` is optional; see [ProgramInstructions] for how a
/// discriminator selects one.
///
/// Fetched at launch, and only when the cached copy is older than [ttl]: the
/// list moves on the scale of weeks, and the review must never wait on it. A
/// launch inside the TTL makes no request at all. A launch fetch that fails to
/// reach the list retries a few times on a backoff ([retryDelays]), since a
/// phone that has just woken often has no working network for its first
/// seconds, and one attempt would otherwise leave the whole session unnamed.
///
/// The review marks a labelled program as verified, because we publish the
/// list, but the address is always shown with it, and nothing approves or
/// blocks on whether a program has one.
/// What a label *can* do is mislead, so [parse] admits only plain ASCII names —
/// no look-alike letters, no bidi controls — and drops any entry it cannot
/// read rather than guessing.
///
/// The list is not signed, so it is trusted no further than its publish path.
/// The compiled-in [canonicalNames] bound what it can do: they always name
/// their own programs, and [parse] refuses a published entry that gives one
/// of those names to any other address. Compiled-in instruction names win
/// over published ones the same way ([ProgramInstructions.beneath]).
///
/// Never throws. A failed or malformed fetch keeps the last good list, and the
/// next launch tries again; with no list at all the review shows program
/// addresses, the compiled-in names, and built-in instruction names for
/// known Solana programs.
@lazySingleton
class ProgramLabelService {
  @factoryMethod
  ProgramLabelService(PreferencesService prefs) : this.withSeams(prefs);

  /// Test seam for the HTTP client, the clock and the retry backoff.
  ///
  /// Split from the injectable constructor because `injectable` cannot resolve
  /// a bare function type in a constructor parameter.
  @visibleForTesting
  ProgramLabelService.withSeams(
    this._prefs, {
    Dio? dio,
    DateTime Function()? now,
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 15),
             ),
           ),
       _now = now ?? DateTime.now;

  final PreferencesService _prefs;
  final Dio _dio;
  final DateTime Function() _now;

  /// The wait before each retry of a launch fetch that could not reach the
  /// list. A malformed list is not retried: the same bytes would come back.
  final List<Duration> retryDelays;

  static const ttl = Duration(days: 1);

  /// Bounds on what one payload may carry. Far above the real list; they only
  /// stop a broken publish from filling preferences.
  static const _maxPrograms = 5000;
  static const _maxNameLength = 40;
  static const _maxInstructionsPerProgram = 1024;

  /// Lower-case hex, at most 16 bytes; empty matches any data.
  static final _discriminator = RegExp(r'^(?:[0-9a-f]{2}){0,16}$');

  /// A bare identifier, as programs log it ("TransferChecked").
  static final _instructionName = RegExp(r'^[A-Za-z0-9]{1,64}$');

  static final _base58Address = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');

  /// Letters, digits, space and the punctuation real program names use
  /// ("Token-2022", "Pump.fun AMM", "Wormhole (Core)").
  static final _plainName = RegExp(r"^[A-Za-z0-9 .\-_()/&+':]+$");

  /// Names compiled into the app for the programs a transaction most often
  /// calls, and that a look-alike would most like to pass for. Each always
  /// names its own address, whatever the published list says, and no
  /// published entry may use one of these names for another address.
  static const canonicalNames = <String, String>{
    '11111111111111111111111111111111': 'System Program',
    'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA': 'Token Program',
    'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb': 'Token-2022',
    'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL': 'Associated Token Account',
    'ComputeBudget111111111111111111111111111111': 'Compute Budget',
    'Stake11111111111111111111111111111111111111': 'Stake Program',
    'Vote111111111111111111111111111111111111111': 'Vote Program',
    'AddressLookupTab1e1111111111111111111111111': 'Address Lookup Table',
    'BPFLoaderUpgradeab1e11111111111111111111111': 'BPF Upgradeable Loader',
    'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr': 'Memo Program',
    'Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo': 'Memo Program v1',
    // mallow builds every memo against v4, so the review names it offline too.
    'Memo4c2pN8afCj432Lb7RMVKi9PbQnnW7ewFFaV3oAH': 'Memo Program v4',
    'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s': 'Metaplex Token Metadata',
    'CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d': 'Metaplex Core',
    'BGUMAp9Gq7iTEuizy4pqaxsTyUCBK68MDfK752saRPUY': 'Metaplex Bubblegum',
    'cmtDvXumGCrqC1Age74AVPhSRVXJMd8PJS91L8KbNCK': 'Account Compression',
    'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4': 'Jupiter Aggregator v6',
  };

  /// [canonicalNames] keyed by [_nameKey], so "system-program" and
  /// "SystemProgram" collide with "System Program" too.
  static final Map<String, String> _reservedNames = {
    for (final MapEntry(key: address, value: name) in canonicalNames.entries)
      _nameKey(name): address,
  };

  /// A name with case, spacing and punctuation folded away.
  static String _nameKey(String name) =>
      name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Whether [name] may label [address]: false when it is, or folds to, a
  /// canonical name of a different program.
  static bool _mayName(String address, String name) {
    final owner = _reservedNames[_nameKey(name)];
    return owner == null || owner == address;
  }

  /// [published] names, less any that borrow a canonical name, under the
  /// canonical names themselves.
  static Map<String, String> _withCanonical(Map<String, String> published) =>
      Map.unmodifiable({
        for (final MapEntry(key: address, value: name) in published.entries)
          if (_mayName(address, name)) address: name,
        ...canonicalNames,
      });

  /// Whether [name] is a bare instruction identifier ("TransferChecked"),
  /// the only form a published or logged instruction name is shown in.
  static bool isInstructionName(String name) => _instructionName.hasMatch(name);

  final ValueNotifier<Map<String, String>> _labels = ValueNotifier(
    _withCanonical(const {}),
  );
  ProgramInstructions _instructions = ProgramInstructions.builtIn;
  bool _started = false;
  Future<void>? _inFlight;

  /// Program address → name: the [canonicalNames] until a list has been
  /// cached or fetched, then the list under them.
  ValueListenable<Map<String, String>> get labels => _labels;

  /// The name for [address], or null when the list does not name it.
  String? nameOf(String address) => _labels.value[address];

  /// Published instruction names supplemented by known public instructions.
  /// Read when a review is prepared, so a list that lands later names the
  /// next review's calls.
  ProgramInstructions get instructions => _instructions;

  /// Loads the cached list, then fetches a fresh one if it is missing or older
  /// than [ttl]. Runs once per launch; later calls return at once.
  void start() {
    if (_started) return;
    _started = true;
    final cachedAt = _loadCache();
    if (cachedAt != null && _now().difference(cachedAt) < ttl) return;
    if (Config.programLabelsUrl.isEmpty) return;
    unawaited(_inFlight ??= _fetchWithRetry());
  }

  /// Completes when the launch fetch and its retries, if any, have finished.
  @visibleForTesting
  Future<void> get settled => _inFlight ?? Future<void>.value();

  /// The cache's timestamp, or null when there is no readable cache.
  DateTime? _loadCache() {
    final raw = _prefs.programLabelCache;
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final programs = (json['programs'] as Map<String, dynamic>).map(
        (address, name) => MapEntry(address, name as String),
      );
      _labels.value = _withCanonical(programs);
      final instructions = json['instructions'];
      // A cache from before instructions were published is refetched now
      // rather than when its TTL runs out.
      if (instructions is! Map<String, dynamic>) return null;
      _instructions = ProgramInstructions(
        instructions.map(
          (address, table) => MapEntry(
            address,
            (table as Map<String, dynamic>).cast<String, String>(),
          ),
        ),
      ).beneath(ProgramInstructions.builtIn);
      return DateTime.fromMillisecondsSinceEpoch(json['fetchedAt'] as int);
    } catch (e) {
      debugPrint('[ProgramLabelService] ignoring unreadable cache: $e');
      return null;
    }
  }

  Future<void> _fetchWithRetry() async {
    for (var attempt = 0; ; attempt++) {
      if (await _fetch() != _FetchOutcome.unreachable) return;
      if (attempt >= retryDelays.length) return;
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  Future<_FetchOutcome> _fetch() async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        Config.programLabelsUrl,
        options: Options(responseType: ResponseType.json),
      );
    } catch (e) {
      debugPrint('[ProgramLabelService] label list fetch failed: $e');
      return _FetchOutcome.unreachable;
    }
    final programs = parse(response.data);
    if (programs == null) {
      debugPrint('[ProgramLabelService] ignoring malformed label list');
      return _FetchOutcome.malformed;
    }
    final instructions = parseInstructions(response.data);
    _labels.value = _withCanonical(programs);
    _instructions = instructions.beneath(ProgramInstructions.builtIn);
    try {
      await _prefs.setProgramLabelCache(
        jsonEncode({
          'fetchedAt': _now().millisecondsSinceEpoch,
          'programs': programs,
          'instructions': instructions.tables,
        }),
      );
    } catch (e) {
      // The names are already live for this session; only the next launch's
      // head start is lost.
      debugPrint('[ProgramLabelService] could not cache label list: $e');
    }
    return _FetchOutcome.applied;
  }

  /// The address → name map in a published payload, or null when the payload
  /// is not a version-1 list. Entries that fail validation, or that give a
  /// canonical name to another address, are dropped one by one; the first
  /// entry for an address wins.
  @visibleForTesting
  static Map<String, String>? parse(Object? data) {
    final programs = _programs(data);
    if (programs == null) return null;
    final result = <String, String>{};
    for (final entry in programs.take(_maxPrograms)) {
      if (entry is! Map<String, dynamic>) continue;
      final address = entry['address'];
      final name = entry['name'];
      if (address is! String || !_base58Address.hasMatch(address)) continue;
      if (name is! String) continue;
      final trimmed = name.trim().replaceAll(RegExp(' +'), ' ');
      if (trimmed.isEmpty ||
          trimmed.length > _maxNameLength ||
          !_plainName.hasMatch(trimmed) ||
          !_mayName(address, trimmed)) {
        continue;
      }
      result.putIfAbsent(address, () => trimmed);
    }
    return result;
  }

  /// The instruction tables in a published payload: empty when it is not a
  /// version-1 list. Like [parse], drops each entry it cannot trust, and the
  /// first entry for a discriminator wins.
  @visibleForTesting
  static ProgramInstructions parseInstructions(Object? data) {
    final programs = _programs(data);
    if (programs == null) return ProgramInstructions.empty;
    final result = <String, Map<String, String>>{};
    for (final entry in programs.take(_maxPrograms)) {
      if (entry is! Map<String, dynamic>) continue;
      final address = entry['address'];
      final instructions = entry['instructions'];
      if (address is! String || !_base58Address.hasMatch(address)) continue;
      if (instructions is! List || result.containsKey(address)) continue;
      final table = <String, String>{};
      for (final instruction in instructions.take(_maxInstructionsPerProgram)) {
        if (instruction is! Map<String, dynamic>) continue;
        final discriminator = instruction['discriminator'];
        final name = instruction['name'];
        if (discriminator is! String ||
            !_discriminator.hasMatch(discriminator) ||
            name is! String ||
            !_instructionName.hasMatch(name)) {
          continue;
        }
        table.putIfAbsent(discriminator, () => name);
      }
      if (table.isNotEmpty) result[address] = table;
    }
    return ProgramInstructions(result);
  }

  /// The `programs` array of a version-1 payload, or null.
  static List<dynamic>? _programs(Object? data) {
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        return null;
      }
    }
    if (data is! Map<String, dynamic>) return null;
    if (data['version'] != 1) return null;
    final programs = data['programs'];
    return programs is List ? programs : null;
  }

  @disposeMethod
  void dispose() => _labels.dispose();
}

enum _FetchOutcome {
  /// The list was parsed and is live.
  applied,

  /// The list arrived but could not be read; retrying would get the same bytes.
  malformed,

  /// No list arrived: a network error, a timeout or an error status.
  unreachable,
}

/// Instruction names by program, each keyed by the hex of the bytes
/// instruction data starts with. The longest key the data starts with names
/// it, so one table shape covers a one-byte tag (`0c`), a little-endian
/// `u32` tag (`02000000`), a tag refined by a variant byte (`2c` and
/// `2c05`), an Anchor discriminator (eight bytes), and a catch-all (`""`).
class ProgramInstructions {
  ProgramInstructions(Map<String, Map<String, String>> tables)
    : tables = Map.unmodifiable({
        for (final MapEntry(key: program, value: table) in tables.entries)
          program: Map<String, String>.unmodifiable(table),
      }),
      _lengths = {
        for (final MapEntry(key: program, value: table) in tables.entries)
          program: ({for (final hex in table.keys) hex.length ~/ 2}.toList()
            ..sort((a, b) => b.compareTo(a))),
      };

  static final empty = ProgramInstructions(const {});

  /// Known instructions must be named even before the remote list arrives,
  /// or when a cached list names programs without their instructions.
  /// These tags identify instructions; they do not validate their payloads
  /// or establish their effects.
  static final builtIn = ProgramInstructions({
    ...knownSolanaInstructions,
    'ComputeBudget111111111111111111111111111111': {
      '01': 'RequestHeapFrame',
      '02': 'SetComputeUnitLimit',
      '03': 'SetComputeUnitPrice',
      '04': 'SetLoadedAccountsDataSizeLimit',
    },
    '11111111111111111111111111111111': {
      '00000000': 'CreateAccount',
      '01000000': 'Assign',
      '02000000': 'Transfer',
      '03000000': 'CreateAccountWithSeed',
      '04000000': 'AdvanceNonceAccount',
      '05000000': 'WithdrawNonceAccount',
      '06000000': 'InitializeNonceAccount',
      '07000000': 'AuthorizeNonceAccount',
      '08000000': 'Allocate',
      '09000000': 'AllocateWithSeed',
      '0a000000': 'AssignWithSeed',
      '0b000000': 'TransferWithSeed',
      '0c000000': 'UpgradeNonceAccount',
    },
    'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA': _tokenInstructions,
  });

  // Token-2022's public IDL also preserves these base Token Program tags.
  static const _tokenInstructions = {
    '00': 'InitializeMint',
    '01': 'InitializeAccount',
    '02': 'InitializeMultisig',
    '03': 'Transfer',
    '04': 'Approve',
    '05': 'Revoke',
    '06': 'SetAuthority',
    '07': 'MintTo',
    '08': 'Burn',
    '09': 'CloseAccount',
    '0a': 'FreezeAccount',
    '0b': 'ThawAccount',
    '0c': 'TransferChecked',
    '0d': 'ApproveChecked',
    '0e': 'MintToChecked',
    '0f': 'BurnChecked',
    '10': 'InitializeAccount2',
    '11': 'SyncNative',
    '12': 'InitializeAccount3',
    '13': 'InitializeMultisig2',
    '14': 'InitializeMint2',
    '15': 'GetAccountDataSize',
    '16': 'InitializeImmutableOwner',
    '17': 'AmountToUiAmount',
    '18': 'UiAmountToAmount',
  };

  /// Program address → discriminator hex → instruction name.
  final Map<String, Map<String, String>> tables;

  /// Each program's discriminator lengths in bytes, longest first.
  final Map<String, List<int>> _lengths;

  /// These tables placed beneath [builtIn], whose names win. They can name
  /// what [builtIn] leaves unnamed but never rename it: an entry is dropped
  /// when its discriminator equals or extends one of [builtIn]'s for the same
  /// program, because the longest match would otherwise beat the built-in
  /// name. A shorter entry stays, as it names only data the built-in
  /// entries do not match.
  ProgramInstructions beneath(ProgramInstructions builtIn) =>
      ProgramInstructions({
        for (final program in {...builtIn.tables.keys, ...tables.keys})
          program: {
            for (final MapEntry(key: hex, value: name)
                in (tables[program] ?? const <String, String>{}).entries)
              if (!(builtIn.tables[program]?.keys.any(hex.startsWith) ?? false))
                hex: name,
            ...?builtIn.tables[program],
          },
      });

  /// The instruction [data] selects in [program], or null when the program
  /// has no table or no discriminator matches.
  String? nameOf(String program, Uint8List data) {
    final table = tables[program];
    if (table == null) return null;
    for (final length in _lengths[program]!) {
      if (length > data.length) continue;
      final name = table[_hex(data, length)];
      if (name != null) return name;
    }
    return null;
  }

  static String _hex(Uint8List data, int length) => [
    for (var i = 0; i < length; i++) data[i].toRadixString(16).padLeft(2, '0'),
  ].join();
}
