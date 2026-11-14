import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:solana/base58.dart';

import '../../../core/crypto/ed25519_curve.dart';
import '../../../core/models/simulation_review.dart' show NftDelegatePower;
import '../../../core/services/known_solana_instructions.dart';
import '../../../core/services/program_label_service.dart';

/// Instructions of the programs that hold something for a wallet where no
/// balance shows it: compressed NFTs (Metaplex Bubblegum), a Core NFT's
/// delegates, stake accounts, upgradeable programs and names.
///
/// A simulation reports the wallet's SOL, its token accounts and who owns its
/// Core assets. None of those change when a compressed NFT is transferred,
/// when a Core NFT gets a transfer delegate or when a stake account gets a
/// new withdraw authority, so a review built from balances alone would show
/// the fee and nothing else. These instructions are therefore read from their
/// own bytes, wherever they appear: at the top of a transaction, or as a call
/// another program makes.
///
/// What is decoded becomes something the review can show. What is known to
/// change nothing a holder owns is left alone. Anything else of these
/// programs is reported as [UnreadAssetInstruction], and only that gets a
/// caution. Nothing here touches the network.
const solanaBubblegumProgram = 'BGUMAp9Gq7iTEuizy4pqaxsTyUCBK68MDfK752saRPUY';
const solanaCoreProgram = 'CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d';
const solanaStakeProgram = 'Stake11111111111111111111111111111111111111';
const solanaUpgradeableLoaderProgram =
    'BPFLoaderUpgradeab1e11111111111111111111111';
const solanaNameServiceProgram = 'namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX';
const solanaAssociatedTokenProgram =
    'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';

const _system = '11111111111111111111111111111111';
const _token = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const _token2022 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';

const _assetPrograms = {
  solanaBubblegumProgram: 'Metaplex Bubblegum',
  solanaCoreProgram: 'Metaplex Core',
  solanaStakeProgram: 'Stake Program',
  solanaUpgradeableLoaderProgram: 'BPF Upgradeable Loader',
  solanaNameServiceProgram: 'Name Service',
};

/// Whether [program] is one this reader covers.
bool isSolanaAssetProgram(String program) =>
    _assetPrograms.containsKey(program);

/// A program's name for a caution: compiled in, so a published label cannot
/// rename the program a warning is about.
String solanaReadProgramName(String program) =>
    _assetPrograms[program] ??
    ProgramLabelService.canonicalNames[program] ??
    'program';

// ---------------------------------------------------------------------------
// Program-derived addresses
// ---------------------------------------------------------------------------

final _pdaMarker = utf8.encode('ProgramDerivedAddress');

List<int>? _addressBytes(String address) {
  try {
    final bytes = base58decode(address);
    return bytes.length == 32 ? bytes : null;
  } catch (_) {
    return null;
  }
}

/// The address [program] derives from [seeds]: the first of bump 255 down to
/// 0 whose hash is off the Ed25519 curve. Null when an input is not an
/// address or no bump gives one.
String? solanaProgramDerivedAddress(List<List<int>> seeds, String program) {
  final programBytes = _addressBytes(program);
  if (programBytes == null || seeds.any((seed) => seed.length > 32)) {
    return null;
  }
  for (var bump = 255; bump >= 0; bump--) {
    final hash = sha256.convert([
      for (final seed in seeds) ...seed,
      bump,
      ...programBytes,
      ..._pdaMarker,
    ]).bytes;
    if (!isOnEd25519Curve(hash)) return base58encode(hash);
  }
  return null;
}

/// The associated token account of [owner] for [mint] under [tokenProgram],
/// or null when one of them is not an address.
String? solanaAssociatedTokenAddress(
  String owner,
  String mint,
  String tokenProgram,
) {
  final seeds = [
    _addressBytes(owner),
    _addressBytes(tokenProgram),
    _addressBytes(mint),
  ];
  if (seeds.any((seed) => seed == null)) return null;
  return solanaProgramDerivedAddress([
    for (final seed in seeds) seed!,
  ], solanaAssociatedTokenProgram);
}

/// The id a compressed NFT is known by: the address Bubblegum derives from
/// its tree and its leaf's nonce. Asset lookups name the NFT under this id.
String? solanaCompressedAssetId(String tree, BigInt nonce) {
  final treeBytes = _addressBytes(tree);
  if (treeBytes == null || nonce.isNegative || nonce.bitLength > 64) {
    return null;
  }
  return solanaProgramDerivedAddress([
    utf8.encode('asset'),
    treeBytes,
    [
      for (var i = 0; i < 8; i++)
        ((nonce >> (8 * i)) & BigInt.from(0xff)).toInt(),
    ],
  ], solanaBubblegumProgram);
}

// ---------------------------------------------------------------------------
// What an instruction does
// ---------------------------------------------------------------------------

sealed class SolanaAssetEffect {
  const SolanaAssetEffect();
}

/// A compressed NFT changes owner.
class CompressedNftTransfer extends SolanaAssetEffect {
  const CompressedNftTransfer({
    required this.assetId,
    required this.owner,
    required this.to,
  });
  final String assetId;
  final String owner;
  final String to;
}

class CompressedNftBurn extends SolanaAssetEffect {
  const CompressedNftBurn({required this.assetId, required this.owner});
  final String assetId;
  final String owner;
}

/// A compressed NFT's owner names who else may move it. [freeze] also stops
/// the owner moving it.
class CompressedNftDelegation extends SolanaAssetEffect {
  const CompressedNftDelegation({
    required this.assetId,
    required this.owner,
    required this.delegate,
    required this.freeze,
  });
  final String assetId;
  final String owner;
  final String delegate;
  final bool freeze;
}

/// A Core NFT's owner names who else may transfer, burn or freeze it.
/// [owner] is the account that signs for the asset.
class CoreNftDelegation extends SolanaAssetEffect {
  const CoreNftDelegation({
    required this.assetId,
    required this.owner,
    required this.delegate,
    required this.power,
  });
  final String assetId;
  final String owner;
  final String delegate;
  final NftDelegatePower power;
}

/// Control of [account] passes from [current] to [next] (null: to nobody).
/// [what] names the thing in a sentence: "a stake account's withdraw
/// authority".
class AuthorityHandover extends SolanaAssetEffect {
  const AuthorityHandover({
    required this.program,
    required this.account,
    required this.what,
    required this.current,
    required this.next,
  });
  final String program;
  final String account;
  final String what;
  final String? current;
  final String? next;
}

class StakeWithdrawal extends SolanaAssetEffect {
  const StakeWithdrawal({
    required this.account,
    required this.authority,
    required this.to,
    required this.lamports,
  });
  final String account;
  final String authority;
  final String to;
  final BigInt lamports;
}

/// An instruction of one of these programs that may re-assign what it holds,
/// and was not read.
class UnreadAssetInstruction extends SolanaAssetEffect {
  const UnreadAssetInstruction(this.program);
  final String program;
}

/// An account an instruction names by position, or null when the reader does
/// not have its address (past the end, or loaded from a table it could not
/// resolve).
typedef SolanaAccountAt = String? Function(int position);

String _hex(Uint8List data, int length) => [
  for (var i = 0; i < length && i < data.length; i++)
    data[i].toRadixString(16).padLeft(2, '0'),
].join();

int? _u32(Uint8List data, int offset) => offset < 0 || offset + 4 > data.length
    ? null
    : ByteData.sublistView(data).getUint32(offset, Endian.little);

BigInt? _u64(Uint8List data, int offset) {
  if (offset < 0 || offset + 8 > data.length) return null;
  var value = BigInt.zero;
  for (var i = 7; i >= 0; i--) {
    value = (value << 8) | BigInt.from(data[offset + i]);
  }
  return value;
}

String? _address(Uint8List data, int offset) =>
    offset < 0 || offset + 32 > data.length
    ? null
    : base58encode(data.sublist(offset, offset + 32));

/// The offset after the Borsh options whose payloads are [sizes] bytes, or
/// null when a flag is neither 0 nor 1 or the data ends first.
int? _skipOptions(Uint8List data, int offset, List<int> sizes) {
  var at = offset;
  for (final size in sizes) {
    if (at >= data.length) return null;
    final flag = data[at];
    if (flag == 0) {
      at += 1;
    } else if (flag == 1) {
      at += 1 + size;
    } else {
      return null;
    }
    if (at > data.length) return null;
  }
  return at;
}

enum _Leaf { transfer, delegate, delegateAndFreeze, burn }

/// Where a Bubblegum instruction keeps its leaf's owner, the new owner or
/// delegate ([target]), and its tree, by account position; [options] are the
/// sizes of the optional values between the three hashes and the nonce.
///
/// The second version of these instructions has optional accounts. One that
/// is left out still takes up its position: the client writes Bubblegum's own
/// address there, and the program reads that as "not given" and falls back to
/// another account. [ownerWhenOmitted] is where the owner then is.
class _BubblegumLayout {
  const _BubblegumLayout({
    required this.effect,
    required this.owner,
    this.ownerWhenOmitted,
    this.target,
    required this.tree,
    this.options = const [],
  });
  final _Leaf effect;
  final int owner;
  final int? ownerWhenOmitted;
  final int? target;
  final int tree;
  final List<int> options;
}

const _bubblegumLayouts = <String, _BubblegumLayout>{
  // Transfer: [tree config, leaf owner, leaf delegate, new leaf owner, tree].
  // The first version has no optional accounts.
  'a334c8e78c0345ba': _BubblegumLayout(
    effect: _Leaf.transfer,
    owner: 1,
    target: 3,
    tree: 4,
  ),
  // TransferV2: [tree config, payer, authority (optional), leaf owner, leaf
  // delegate (optional), new leaf owner, tree]. The owner and the new owner
  // are always given. The two that can be left out are who signs for the
  // move and who the delegate was, and neither is read here.
  '772806ebeaddf831': _BubblegumLayout(
    effect: _Leaf.transfer,
    owner: 3,
    target: 5,
    tree: 6,
    options: [32, 1],
  ),
  // Delegate: [tree config, leaf owner, previous delegate, new delegate, tree]
  '5a934bb255580489': _BubblegumLayout(
    effect: _Leaf.delegate,
    owner: 1,
    target: 3,
    tree: 4,
  ),
  // DelegateV2: [tree config, payer, leaf owner (optional), previous delegate
  // (optional), new delegate, tree]. With the owner left out the program
  // takes the payer as the owner. The new delegate is always given.
  '5f577d8cb58380e3': _BubblegumLayout(
    effect: _Leaf.delegate,
    owner: 2,
    ownerWhenOmitted: 1,
    target: 4,
    tree: 5,
    options: [32, 32, 1],
  ),
  // DelegateAndFreezeV2: as DelegateV2.
  '11e523dabef1fa7b': _BubblegumLayout(
    effect: _Leaf.delegateAndFreeze,
    owner: 2,
    ownerWhenOmitted: 1,
    target: 4,
    tree: 5,
    options: [32, 32, 1],
  ),
  // Burn: [tree config, leaf owner, leaf delegate, tree]
  '746e1d386bdb2a5d': _BubblegumLayout(effect: _Leaf.burn, owner: 1, tree: 3),
  // BurnV2: [tree config, payer, authority (optional), leaf owner, leaf
  // delegate (optional), tree]. As in TransferV2, the owner is always given.
  '73d222f0e88fb710': _BubblegumLayout(
    effect: _Leaf.burn,
    owner: 3,
    tree: 5,
    options: [32, 1],
  ),
};

/// SetTreeDelegate: [tree config, tree creator, new tree delegate, tree].
const _bubblegumSetTreeDelegate = 'fd764225be319a66';

/// Bubblegum's root, data hash and creator hash: three 32-byte values after
/// the discriminator.
const _bubblegumHashesEnd = 8 + 96;

/// Bubblegum instructions that leave a holder's compressed NFT with its owner
/// and give nobody a new way to move it: minting, a creator's or collection
/// authority's upkeep, lifting a freeze, redeeming to the owner's own
/// voucher.
const _bubblegumUnchangingNames = {
  'CancelRedeem',
  'CollectV2',
  'Compress',
  'CreateTree',
  'CreateTreeV2',
  'DecompressV1',
  'MintToCollectionV1',
  'MintV1',
  'MintV2',
  'Redeem',
  'SetAndVerifyCollection',
  'SetCollectionV2',
  'SetDecompressableState',
  'SetDecompressibleState',
  'ThawAndRevokeV2',
  'ThawV2',
  'UnverifyCollection',
  'UnverifyCreator',
  'UnverifyCreatorV2',
  'UpdateAssetDataV2',
  'UpdateMetadata',
  'UpdateMetadataV2',
  'VerifyCollection',
  'VerifyCreator',
  'VerifyCreatorV2',
};

/// The discriminators of [_bubblegumUnchangingNames], from the compiled-in
/// table only: a published name must never be what turns a caution off.
final Set<String> _bubblegumUnchanging = {
  for (final MapEntry(key: discriminator, value: name)
      in (knownSolanaInstructions[solanaBubblegumProgram] ??
              const <String, String>{})
          .entries)
    if (_bubblegumUnchangingNames.contains(name)) discriminator,
};

SolanaAssetEffect? _decodeBubblegum(Uint8List data, SolanaAccountAt at) {
  const unread = UnreadAssetInstruction(solanaBubblegumProgram);
  final discriminator = data.length >= 8 ? _hex(data, 8) : '';
  if (discriminator == _bubblegumSetTreeDelegate) {
    final tree = at(3);
    final next = at(2);
    if (tree == null || next == null) return unread;
    return AuthorityHandover(
      program: solanaBubblegumProgram,
      account: tree,
      what: 'a compressed NFT tree',
      current: at(1),
      next: next,
    );
  }
  final layout = _bubblegumLayouts[discriminator];
  if (layout == null) {
    return _bubblegumUnchanging.contains(discriminator) ? null : unread;
  }
  // An owner that was left out is the payer's leaf: the wallet's, when the
  // wallet pays. Read as "owned by Bubblegum", the instruction would be about
  // nobody's compressed NFT and the review would show nothing for it.
  final named = at(layout.owner);
  final owner =
      named == solanaBubblegumProgram && layout.ownerWhenOmitted != null
      ? at(layout.ownerWhenOmitted!)
      : named;
  final tree = at(layout.tree);
  final nonceAt = _skipOptions(data, _bubblegumHashesEnd, layout.options);
  final nonce = nonceAt == null ? null : _u64(data, nonceAt);
  if (owner == null || tree == null || nonce == null) return unread;
  final assetId = solanaCompressedAssetId(tree, nonce);
  if (assetId == null) return unread;
  if (layout.effect == _Leaf.burn) {
    return CompressedNftBurn(assetId: assetId, owner: owner);
  }
  final target = layout.target == null ? null : at(layout.target!);
  if (target == null) return unread;
  if (layout.effect == _Leaf.transfer) {
    return CompressedNftTransfer(assetId: assetId, owner: owner, to: target);
  }
  return CompressedNftDelegation(
    assetId: assetId,
    owner: owner,
    delegate: target,
    freeze: layout.effect == _Leaf.delegateAndFreeze,
  );
}

/// Core's plugins a holder can hand to someone else, by plugin type, with
/// the size of the plugin's own data: the right to freeze (`frozen`, one
/// byte), to burn and to transfer the asset. Every other plugin is the
/// creator's.
const _coreDelegatePlugins = <int, ({NftDelegatePower power, int size})>{
  1: (power: NftDelegatePower.freeze, size: 1),
  2: (power: NftDelegatePower.burn, size: 0),
  3: (power: NftDelegatePower.transfer, size: 0),
};

/// Core instructions, by their one-byte tag.
const _coreAddPlugin = 0x02;
const _coreApprovePluginAuthority = 0x08;
const _coreExecute = 0x1f;

/// Metaplex Core. Who owns an asset is read from the simulation's accounts;
/// who else may move, burn or lock it is in no balance, and is read here.
/// `AddPluginV1` and `ApprovePluginAuthorityV1` both name [asset, collection,
/// payer, authority, …], and say which plugin and who holds it. An authority
/// that is left out is written as Core's own address, and the program then
/// takes the payer: read as "signed by Core", the instruction would be about
/// nobody's NFT and the review would show nothing for it.
SolanaAssetEffect? _decodeCore(Uint8List data, SolanaAccountAt at) {
  const unread = UnreadAssetInstruction(solanaCoreProgram);
  if (data.isEmpty) return null;
  final tag = data[0];
  // ExecuteV1 runs an instruction of the caller's choosing, signed by the
  // asset.
  if (tag == _coreExecute) return unread;
  if (tag != _coreAddPlugin && tag != _coreApprovePluginAuthority) return null;
  // Cut off before it says which plugin: it may be one of the three.
  if (data.length < 2) return unread;
  final plugin = _coreDelegatePlugins[data[1]];
  if (plugin == null) return null;
  var authorityAt = 2;
  if (tag == _coreAddPlugin) {
    // The plugin's data, then an optional authority. None: the owner keeps
    // it.
    final optionAt = 2 + plugin.size;
    if (optionAt >= data.length) return unread;
    if (data[optionAt] == 0) return null;
    if (data[optionAt] != 1) return unread;
    authorityAt = optionAt + 1;
  }
  if (authorityAt >= data.length) return unread;
  // Who holds the plugin: 0 nobody, 1 the owner, 2 the update authority,
  // 3 an address.
  final holder = data[authorityAt];
  if (holder == 1) return null;
  // Nobody (a freeze no one can lift) and the update authority are not an
  // address the review could show.
  if (holder != 3) return unread;
  final delegate = _address(data, authorityAt + 1);
  final asset = at(0);
  final named = at(3);
  final owner = named == solanaCoreProgram ? at(2) : named;
  if (delegate == null || asset == null || owner == null) return unread;
  return CoreNftDelegation(
    assetId: asset,
    owner: owner,
    delegate: delegate,
    power: plugin.power,
  );
}

/// `StakeAuthorize`: 0 is the staker, 1 the withdrawer.
String? _stakeAuthority(Object? kind) => switch (kind) {
  0 || 'Staker' => 'a stake account\'s staking authority',
  1 || 'Withdrawer' => 'a stake account\'s withdraw authority',
  _ => null,
};

SolanaAssetEffect? _decodeStake(Uint8List data, SolanaAccountAt at) {
  const unread = UnreadAssetInstruction(solanaStakeProgram);
  final account = at(0);
  SolanaAssetEffect change(String? what, String? current, String? next) =>
      account == null || what == null || next == null
      ? unread
      : AuthorityHandover(
          program: solanaStakeProgram,
          account: account,
          what: what,
          current: current,
          next: next,
        );
  switch (_u32(data, 0)) {
    case 1: // Authorize: [stake, clock, authority]; new authority, kind
      return change(_stakeAuthority(_u32(data, 36)), at(2), _address(data, 4));
    case 8: // AuthorizeWithSeed: [stake, base]; new authority, kind, seed, owner
      return change(_stakeAuthority(_u32(data, 36)), at(1), _address(data, 4));
    case 10: // AuthorizeChecked: [stake, clock, authority, new authority]; kind
      return change(_stakeAuthority(_u32(data, 4)), at(2), at(3));
    case 11: // AuthorizeCheckedWithSeed: [stake, base, clock, new authority]
      return change(_stakeAuthority(_u32(data, 4)), at(1), at(3));
    case 4:
      // Withdraw: [stake, recipient, clock, stake history, withdraw authority]
      final to = at(1);
      final authority = at(4);
      final lamports = _u64(data, 4);
      if (account == null ||
          to == null ||
          authority == null ||
          lamports == null) {
        return unread;
      }
      return StakeWithdrawal(
        account: account,
        authority: authority,
        to: to,
        lamports: lamports,
      );
    // Initialize, DelegateStake, Split, Deactivate, Merge, InitializeChecked,
    // GetMinimumDelegation, DeactivateDelinquent, MoveStake, MoveLamports:
    // the stake stays under the authorities it had.
    case 0 || 2 || 3 || 5 || 7 || 9 || 13 || 14 || 16 || 17:
      return null;
    default:
      // SetLockup and anything newer.
      return unread;
  }
}

SolanaAssetEffect? _decodeLoader(Uint8List data, SolanaAccountAt at) {
  const unread = UnreadAssetInstruction(solanaUpgradeableLoaderProgram);
  switch (_u32(data, 0)) {
    // SetAuthority: [account, current authority, new authority?], and
    // SetAuthorityChecked, where the new authority signs too.
    case 4 || 7:
      final account = at(0);
      if (account == null) return unread;
      return AuthorityHandover(
        program: solanaUpgradeableLoaderProgram,
        account: account,
        what: 'a program',
        current: at(1),
        next: at(2),
      );
    // InitializeBuffer, Write, DeployWithMaxDataLen, Upgrade, ExtendProgram.
    case 0 || 1 || 2 || 3 || 6:
      return null;
    default:
      // Close and anything newer.
      return unread;
  }
}

SolanaAssetEffect? _decodeNameService(Uint8List data, SolanaAccountAt at) {
  const unread = UnreadAssetInstruction(solanaNameServiceProgram);
  if (data.isEmpty) return unread;
  switch (data[0]) {
    case 2:
      // Transfer: [name account, owner]; new owner
      final account = at(0);
      final next = _address(data, 1);
      if (account == null || next == null) return unread;
      return AuthorityHandover(
        program: solanaNameServiceProgram,
        account: account,
        what: 'a name',
        current: at(1),
        next: next,
      );
    // Create, Update, Realloc.
    case 0 || 1 || 4:
      return null;
    default:
      // Delete and anything newer.
      return unread;
  }
}

/// What one instruction of an asset program does, or null when it changes
/// nothing a holder owns (or [program] is not one this reader covers).
SolanaAssetEffect? decodeSolanaAssetInstruction(
  String program,
  Uint8List data,
  SolanaAccountAt at,
) {
  try {
    return switch (program) {
      solanaBubblegumProgram => _decodeBubblegum(data, at),
      solanaCoreProgram => _decodeCore(data, at),
      solanaStakeProgram => _decodeStake(data, at),
      solanaUpgradeableLoaderProgram => _decodeLoader(data, at),
      solanaNameServiceProgram => _decodeNameService(data, at),
      _ => null,
    };
  } catch (_) {
    return isSolanaAssetProgram(program)
        ? UnreadAssetInstruction(program)
        : null;
  }
}

/// Node-parsed stake and loader calls that leave an account under the
/// authorities it had: the names a node gives the instructions
/// [_decodeStake] and [_decodeLoader] step over.
const _parsedUnchanging = {
  solanaStakeProgram: {
    'initialize',
    'delegate',
    'split',
    'deactivate',
    'merge',
    'initializeChecked',
    'getMinimumDelegation',
    'deactivateDelinquent',
    'moveStake',
    'moveLamports',
  },
  solanaUpgradeableLoaderProgram: {
    'initializeBuffer',
    'write',
    'deployWithMaxDataLen',
    'upgrade',
    'extendProgram',
  },
};

/// [decodeSolanaAssetInstruction] for an inner call the node parsed itself,
/// which reports named fields and no data: `{"type", "info"}`. Nodes parse
/// the Stake program and the upgradeable loader. A call that is not
/// understood counts as unread only when it names [wallet], since that is
/// all a parsed call says about whose accounts it touches.
SolanaAssetEffect? decodeParsedSolanaAssetInstruction(
  String program,
  Object? parsed,
  String wallet,
) {
  if (!isSolanaAssetProgram(program)) return null;
  final type = parsed is Map ? parsed['type'] : null;
  final info = parsed is Map && parsed['info'] is Map
      ? (parsed['info'] as Map).cast<String, Object?>()
      : const <String, Object?>{};
  String? text(String key) => info[key] is String ? info[key] as String : null;
  final unread = info.values.contains(wallet)
      ? UnreadAssetInstruction(program)
      : null;
  if (_parsedUnchanging[program]?.contains(type) ?? false) return null;
  if (program == solanaStakeProgram) {
    final account = text('stakeAccount');
    final what = _stakeAuthority(info['authorityType']);
    switch (type) {
      case 'authorize' || 'authorizeChecked':
        final next = text('newAuthority');
        if (account == null || what == null || next == null) return unread;
        return AuthorityHandover(
          program: program,
          account: account,
          what: what,
          current: text('authority'),
          next: next,
        );
      case 'authorizeWithSeed' || 'authorizeCheckedWithSeed':
        final next = text('newAuthorized');
        if (account == null || what == null || next == null) return unread;
        return AuthorityHandover(
          program: program,
          account: account,
          what: what,
          current: text('authorityBase'),
          next: next,
        );
      case 'withdraw':
        final to = text('destination');
        final authority = text('withdrawAuthority');
        final lamports = switch (info['lamports']) {
          final int value when value >= 0 => BigInt.from(value),
          final String value => BigInt.tryParse(value),
          _ => null,
        };
        if (account == null ||
            to == null ||
            authority == null ||
            lamports == null) {
          return unread;
        }
        return StakeWithdrawal(
          account: account,
          authority: authority,
          to: to,
          lamports: lamports,
        );
    }
    return unread;
  }
  if (program == solanaUpgradeableLoaderProgram &&
      (type == 'setAuthority' || type == 'setAuthorityChecked')) {
    final account = text('account');
    if (account == null) return unread;
    return AuthorityHandover(
      program: program,
      account: account,
      what: 'a program',
      current: text('authority'),
      next: text('newAuthority'),
    );
  }
  return unread;
}

// ---------------------------------------------------------------------------
// System and Token instructions the review does not decode
// ---------------------------------------------------------------------------

/// System and Token instructions that can move or re-assign what an account
/// holds, for when the review could not read one: an instruction it has no
/// reader for, or one it reads whose bytes or accounts did not fit. Every
/// other instruction these programs name only sets something up or keeps a
/// mint in order (a new account, an extension's configuration, a metadata
/// field, a fee, a pause), and is listed in the program calls with no
/// caution: a caution on every routine transaction is one nobody reads.
const _unreadRisky = {
  // System
  'Allocate',
  'AllocateWithSeed',
  'Assign',
  'AssignWithSeed',
  'AuthorizeNonceAccount',
  'CreateAccount',
  'CreateAccountWithSeed',
  'Transfer',
  'TransferWithSeed',
  'WithdrawNonceAccount',
  // Token and Token-2022: tokens leave, are destroyed, or can be spent by
  // someone else; an account or an authority goes to someone else.
  'Approve',
  'ApproveChecked',
  'Burn',
  'BurnChecked',
  'CloseAccount',
  'SetAuthority',
  'TransferChecked',
  'TransferCheckedWithFee',
  // Token-2022 only. A batch runs other token instructions inside itself.
  'ApproveConfidentialTransferAccount',
  'Batch',
  'ConfidentialBurn',
  'ConfidentialDeposit',
  'ConfidentialTransfer',
  'ConfidentialTransferWithFee',
  'ConfidentialWithdraw',
  'DisableCpiGuard',
  'EmptyConfidentialTransferAccount',
  'PermissionedBurn',
  'PermissionedBurnChecked',
  'PermissionedConfidentialBurn',
  'UnwrapLamports',
  'UpdateTokenGroupUpdateAuthority',
  'UpdateTokenMetadataUpdateAuthority',
  'WithdrawExcessLamports',
  'WithdrawWithheldTokensFromAccounts',
  'WithdrawWithheldTokensFromAccountsForConfidentialTransferFee',
  'WithdrawWithheldTokensFromMint',
  'WithdrawWithheldTokensFromMintForConfidentialTransferFee',
};

/// The compiled-in name of a System or Token instruction, or null when the
/// tables have none. Published tables are not consulted: a published name
/// must never be what turns a caution off.
String? solanaBuiltInInstructionName(String program, Uint8List data) =>
    ProgramInstructions.builtIn.nameOf(program, data);

/// Whether a System, Token or Token-2022 instruction the review did not read
/// could move or re-assign holdings: one the compiled-in tables have no name
/// for, or a named one known to. It is the wallet's concern only when the
/// wallet is one of the accounts it names; the caller checks that.
bool solanaUnreadInstructionIsRisky(String program, Uint8List data) {
  if (program != _system && program != _token && program != _token2022) {
    return false;
  }
  final name = solanaBuiltInInstructionName(program, data);
  return name == null || _unreadRisky.contains(name);
}

String _instructionOf(String program, Uint8List data) {
  final name = solanaBuiltInInstructionName(program, data);
  return 'A ${solanaReadProgramName(program)} instruction'
      '${name == null ? '' : ' ($name)'}';
}

/// The caution for a System or Token instruction that names the wallet, that
/// the review could not read, and that [solanaUnreadInstructionIsRisky].
String solanaUnreadInstructionWarning(String program, Uint8List data) =>
    '${_instructionOf(program, data)} could not be read. With your signature it can move or re-assign what your wallet holds.';

/// [solanaUnreadInstructionWarning] for a call the node parsed itself, which
/// reports the instruction's [name] and no data.
String solanaUnreadNamedInstructionWarning(String program, String name) =>
    'A ${solanaReadProgramName(program)} instruction ($name) could not be read. With your signature it can move or re-assign what your wallet holds.';

/// The caution for a System instruction that was read and has more bytes
/// than it needs. The program ignores them, so what the review shows is what
/// the instruction does; nothing that builds a transaction adds them, so the
/// review says they are there.
String solanaExtraBytesWarning(String program, Uint8List data) =>
    '${_instructionOf(program, data)} has extra bytes after its own. The program ignores them, and so does this review.';

/// The caution for an instruction of an asset program the review could not
/// read.
String solanaUnreadAssetWarning(String program) =>
    'A ${solanaReadProgramName(program)} instruction could not be read. It may change who controls what your wallet holds there.';
