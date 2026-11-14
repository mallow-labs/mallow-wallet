import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart'
    show NftDelegatePower;
import 'package:mallow_wallet/features/browser/services/solana_asset_instructions.dart';
import 'package:solana/solana.dart';

const _token = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const _token2022 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const _system = '11111111111111111111111111111111';
const _usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

String _key(int fill) => Ed25519HDPublicKey(List.filled(32, fill)).toBase58();

List<int> _u64(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();
List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

/// An instruction's accounts, in order, as the reader is given them.
SolanaAccountAt _accounts(List<String?> keys) =>
    (position) => position < keys.length ? keys[position] : null;

Uint8List _bytes(List<List<int>> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);

final _hashes = List.filled(96, 9);

void main() {
  group('program-derived addresses', () {
    test('match addresses that exist on chain', () {
      // A wallet's USDC account on mainnet, which the Associated Token
      // Account program created at the address it derives.
      expect(
        solanaAssociatedTokenAddress(
          '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM',
          _usdc,
          _token,
        ),
        'FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B',
      );
      // Two compressed NFTs on mainnet: their tree and leaf index, and the
      // id asset lookups know each by.
      expect(
        solanaCompressedAssetId(
          '9oFp2PM6k1b5mmzpeHUaZkCAbTD1ykR4QiyQYu3EVnfK',
          BigInt.from(533886),
        ),
        'JEKNVjohV7ALhZbHgCwuCFCJKxnfPom2fR4eniHCmP39',
      );
      expect(
        solanaCompressedAssetId(
          'DVa63qXgEtyGUvzev5nCxEz7tgTMZHgocwMvaNvVrTT5',
          BigInt.from(196268),
        ),
        'JEKNVWWk5oPzAawWu1BKDS4s11PMvnQ9scDCvRa7eSuf',
      );
    });

    test('match another implementation, over many inputs', () async {
      for (var i = 1; i <= 24; i++) {
        final owner = Ed25519HDPublicKey(List.filled(32, i));
        final mint = Ed25519HDPublicKey(List.generate(32, (j) => (i * 7 + j)));
        for (final program in [_token, _token2022]) {
          final expected = await findAssociatedTokenAddress(
            owner: owner,
            mint: mint,
            tokenProgramType: program == _token
                ? TokenProgramType.tokenProgram
                : TokenProgramType.token2022Program,
          );
          expect(
            solanaAssociatedTokenAddress(
              owner.toBase58(),
              mint.toBase58(),
              program,
            ),
            expected.toBase58(),
          );
        }
        final tree = Ed25519HDPublicKey(List.generate(32, (j) => i ^ j));
        final nonce = i * 1000003;
        final asset = await Ed25519HDPublicKey.findProgramAddress(
          seeds: [utf8.encode('asset'), tree.bytes, _u64(nonce)],
          programId: Ed25519HDPublicKey.fromBase58(solanaBubblegumProgram),
        );
        expect(
          solanaCompressedAssetId(tree.toBase58(), BigInt.from(nonce)),
          asset.toBase58(),
        );
      }
    });

    test('answer null for what is not an address', () {
      expect(
        solanaAssociatedTokenAddress('not an address', _usdc, _token),
        null,
      );
      expect(solanaCompressedAssetId('0', BigInt.one), isNull);
      expect(solanaCompressedAssetId(_key(3), BigInt.from(-1)), isNull);
      expect(solanaCompressedAssetId(_key(3), BigInt.one << 64), isNull);
    });
  });

  group('Bubblegum', () {
    final owner = _key(1);
    final other = _key(2);
    final tree = _key(3);
    final config = _key(4);
    final payer = _key(5);
    const nonce = 77;
    final assetId = solanaCompressedAssetId(tree, BigInt.from(nonce))!;
    final leaf = [..._u64(nonce), ..._u32(nonce)];

    test('reads a transfer: whose compressed NFT, to whom', () {
      final effect = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [163, 52, 200, 231, 140, 3, 69, 186],
          _hashes,
          leaf,
        ]),
        _accounts([config, owner, owner, other, tree]),
      );
      expect(effect, isA<CompressedNftTransfer>());
      effect as CompressedNftTransfer;
      expect(
        (effect.assetId, effect.owner, effect.to),
        (assetId, owner, other),
      );
    });

    test('reads the second version, past its optional values', () {
      // The asset data hash is present, the flags are not.
      final effect = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [119, 40, 6, 235, 234, 221, 248, 49],
          _hashes,
          [1, ...List.filled(32, 7)],
          [0],
          leaf,
        ]),
        _accounts([config, payer, owner, owner, owner, other, tree]),
      );
      effect as CompressedNftTransfer;
      expect(
        (effect.assetId, effect.owner, effect.to),
        (assetId, owner, other),
      );
    });

    test('reads a delegation, with and without a freeze', () {
      final first = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [90, 147, 75, 178, 85, 88, 4, 137],
          _hashes,
          leaf,
        ]),
        _accounts([config, owner, owner, other, tree]),
      );
      first as CompressedNftDelegation;
      expect(
        (first.assetId, first.owner, first.delegate, first.freeze),
        (assetId, owner, other, false),
      );
      final frozen = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [17, 229, 35, 218, 190, 241, 250, 123],
          _hashes,
          [0],
          [0],
          [0],
          leaf,
        ]),
        _accounts([config, payer, owner, owner, other, tree]),
      );
      frozen as CompressedNftDelegation;
      expect(
        (frozen.assetId, frozen.delegate, frozen.freeze),
        (assetId, other, true),
      );
    });

    test('takes the payer as the owner when a delegation leaves the owner '
        'out', () {
      // The second version's owner is optional. Left out, its position holds
      // Bubblegum's own address and the program takes the payer.
      final data = [
        _hashes,
        [0, 0, 0],
        leaf,
      ];
      final omitted = _accounts([
        config,
        owner,
        solanaBubblegumProgram,
        solanaBubblegumProgram,
        other,
        tree,
      ]);
      for (final (discriminator, freeze) in [
        ([95, 87, 125, 140, 181, 131, 128, 227], false),
        ([17, 229, 35, 218, 190, 241, 250, 123], true),
      ]) {
        final effect = decodeSolanaAssetInstruction(
          solanaBubblegumProgram,
          _bytes([discriminator, ...data]),
          omitted,
        );
        expect(
          effect,
          isA<CompressedNftDelegation>(),
          reason: '$discriminator',
        );
        effect as CompressedNftDelegation;
        expect(
          (effect.assetId, effect.owner, effect.delegate, effect.freeze),
          (assetId, owner, other, freeze),
        );
      }
      // An owner that is named is the owner, whoever pays.
      final named = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [95, 87, 125, 140, 181, 131, 128, 227],
          ...data,
        ]),
        _accounts([config, payer, owner, owner, other, tree]),
      );
      named as CompressedNftDelegation;
      expect((named.owner, named.delegate), (owner, other));
      // The payer loaded from a table that was not resolved: whose leaf it is
      // cannot be said, so it is reported unread and not as nobody's.
      expect(
        decodeSolanaAssetInstruction(
          solanaBubblegumProgram,
          _bytes([
            [95, 87, 125, 140, 181, 131, 128, 227],
            ...data,
          ]),
          _accounts([
            config,
            null,
            solanaBubblegumProgram,
            solanaBubblegumProgram,
            other,
            tree,
          ]),
        ),
        isA<UnreadAssetInstruction>(),
      );
    });

    test('a transfer or burn that leaves its optional accounts out is still '
        'the named owner\'s', () {
      // In the second version of these two, who signs and who the delegate
      // was can be left out. The owner cannot, and is read where it is.
      final transfer = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [119, 40, 6, 235, 234, 221, 248, 49],
          _hashes,
          [0],
          [0],
          leaf,
        ]),
        _accounts([
          config,
          owner,
          solanaBubblegumProgram,
          owner,
          solanaBubblegumProgram,
          other,
          tree,
        ]),
      );
      transfer as CompressedNftTransfer;
      expect(
        (transfer.assetId, transfer.owner, transfer.to),
        (assetId, owner, other),
      );
      final burn = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [115, 210, 34, 240, 232, 143, 183, 16],
          _hashes,
          [0],
          [0],
          leaf,
        ]),
        _accounts([
          config,
          owner,
          solanaBubblegumProgram,
          owner,
          solanaBubblegumProgram,
          tree,
        ]),
      );
      burn as CompressedNftBurn;
      expect((burn.assetId, burn.owner), (assetId, owner));
    });

    test('reads a burn, in both versions', () {
      final first = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [116, 110, 29, 56, 107, 219, 42, 93],
          _hashes,
          leaf,
        ]),
        _accounts([config, owner, owner, tree]),
      );
      expect((first as CompressedNftBurn).assetId, assetId);
      final second = decodeSolanaAssetInstruction(
        solanaBubblegumProgram,
        _bytes([
          [115, 210, 34, 240, 232, 143, 183, 16],
          _hashes,
          [0],
          [0],
          leaf,
        ]),
        _accounts([config, payer, owner, owner, owner, tree]),
      );
      expect((second as CompressedNftBurn).owner, owner);
    });

    test('leaves minting alone, and reports what it cannot read', () {
      // MintV1.
      expect(
        decodeSolanaAssetInstruction(
          solanaBubblegumProgram,
          _bytes([
            [145, 98, 192, 118, 184, 147, 118, 104],
            [1, 2, 3],
          ]),
          _accounts([config, owner]),
        ),
        isNull,
      );
      for (final data in [
        // No instruction of this program.
        [9, 9, 9, 9, 9, 9, 9, 9, 1, 2, 3],
        // A transfer cut short of its nonce.
        [163, 52, 200, 231, 140, 3, 69, 186, ..._hashes],
        // An option flag that is neither absent nor present.
        [119, 40, 6, 235, 234, 221, 248, 49, ..._hashes, 2, 0, ...leaf],
        <int>[],
      ]) {
        expect(
          decodeSolanaAssetInstruction(
            solanaBubblegumProgram,
            Uint8List.fromList(data),
            _accounts([config, payer, owner, owner, owner, other, tree]),
          ),
          isA<UnreadAssetInstruction>(),
          reason: '$data',
        );
      }
      // A transfer whose tree comes from a table that was not resolved.
      expect(
        decodeSolanaAssetInstruction(
          solanaBubblegumProgram,
          _bytes([
            [163, 52, 200, 231, 140, 3, 69, 186],
            _hashes,
            leaf,
          ]),
          _accounts([config, owner, owner, other, null]),
        ),
        isA<UnreadAssetInstruction>(),
      );
    });
  });

  group('Metaplex Core', () {
    final owner = _key(21);
    final asset = _key(22);
    final collection = _key(23);
    final system = _key(24);
    // Someone's wallet, as text and as the 32 bytes an instruction carries.
    const other = '4qQ2g1cznQYXNrRKDXuMzoujEiyq2SykLnU6M315PA1T';
    final otherBytes = Ed25519HDPublicKey.fromBase58(other).bytes;
    // The plugin types a holder can hand on, in the program's numbering.
    const freeze = 1, burn = 2, transfer = 3;
    // Who holds a plugin: nobody, the owner, the update authority, an
    // address (which follows).
    const nobody = [0], theOwner = [1], updateAuthority = [2];
    final address = [3, ...otherBytes];

    /// ApprovePluginAuthorityV1: the plugin's type, then its new holder.
    Uint8List approve(int plugin, List<int> holder) =>
        Uint8List.fromList([0x08, plugin, ...holder]);

    /// AddPluginV1: the plugin with its own data, then an optional holder.
    Uint8List add(int plugin, List<int> pluginData, [List<int>? holder]) =>
        Uint8List.fromList([
          0x02,
          plugin,
          ...pluginData,
          if (holder == null) 0 else ...[1, ...holder],
        ]);

    Uint8List hex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);

    // [asset, collection, payer, authority, system program]
    final signedByOwner = _accounts([asset, collection, owner, owner, system]);

    void expectDelegation(SolanaAssetEffect? effect, NftDelegatePower power) {
      final delegation = effect as CoreNftDelegation;
      expect(
        (
          delegation.assetId,
          delegation.owner,
          delegation.delegate,
          delegation.power,
        ),
        (asset, owner, other, power),
      );
    }

    test('the layout read here is the one Metaplex\'s own client writes', () {
      // Each instruction as that client serializes it, for the same holder.
      const holder =
          '0338f8fa78bac6138f14f7268423abee0ee58c1ea626f8431e504aa68a8129878e';
      expect(approve(transfer, address), hex('0803$holder'));
      expect(approve(burn, address), hex('0802$holder'));
      expect(approve(freeze, address), hex('0801$holder'));
      expect(approve(transfer, theOwner), hex('080301'));
      expect(approve(transfer, nobody), hex('080300'));
      expect(approve(transfer, updateAuthority), hex('080302'));
      expect(add(transfer, const [], address), hex('020301$holder'));
      // The freeze plugin carries its own byte, `frozen`, before the holder.
      expect(add(freeze, const [1], address), hex('02010101$holder'));
      expect(add(freeze, const [0]), hex('02010000'));
      expectDelegation(
        decodeSolanaAssetInstruction(
          solanaCoreProgram,
          hex('0803$holder'),
          signedByOwner,
        ),
        NftDelegatePower.transfer,
      );
    });

    test('reads who is given the right to transfer, burn or freeze an '
        'NFT', () {
      for (final (plugin, power) in [
        (transfer, NftDelegatePower.transfer),
        (burn, NftDelegatePower.burn),
        (freeze, NftDelegatePower.freeze),
      ]) {
        expectDelegation(
          decodeSolanaAssetInstruction(
            solanaCoreProgram,
            approve(plugin, address),
            signedByOwner,
          ),
          power,
        );
      }
    });

    test('reads one named when the plugin is added', () {
      expectDelegation(
        decodeSolanaAssetInstruction(
          solanaCoreProgram,
          add(transfer, const [], address),
          signedByOwner,
        ),
        NftDelegatePower.transfer,
      );
      expectDelegation(
        decodeSolanaAssetInstruction(
          solanaCoreProgram,
          add(burn, const [], address),
          signedByOwner,
        ),
        NftDelegatePower.burn,
      );
      // The freeze plugin's own byte comes before the holder.
      expectDelegation(
        decodeSolanaAssetInstruction(
          solanaCoreProgram,
          add(freeze, const [1], address),
          signedByOwner,
        ),
        NftDelegatePower.freeze,
      );
    });

    test('takes the payer as the one who signs when the authority is left '
        'out', () {
      // An optional account that is left out is written as Core's own
      // address.
      expectDelegation(
        decodeSolanaAssetInstruction(
          solanaCoreProgram,
          approve(transfer, address),
          _accounts([
            asset,
            solanaCoreProgram,
            owner,
            solanaCoreProgram,
            system,
          ]),
        ),
        NftDelegatePower.transfer,
      );
      // An authority that is given is the one who signs, whoever pays.
      final payer = _key(25);
      expectDelegation(
        decodeSolanaAssetInstruction(
          solanaCoreProgram,
          approve(transfer, address),
          _accounts([asset, collection, payer, owner, system]),
        ),
        NftDelegatePower.transfer,
      );
    });

    test('leaves alone what stays with the owner, and a creator\'s '
        'plugins', () {
      for (final data in [
        approve(transfer, theOwner),
        add(transfer, const [], theOwner),
        // No holder named: the owner's by default.
        add(freeze, const [0]),
        add(burn, const []),
        // UpdateDelegate and Royalties are the creator's to hand on.
        approve(4, address),
        add(0, const [1, 2, 3], address),
        // TransferV1 and BurnV1 are read from the accounts the simulation
        // returns.
        Uint8List.fromList([14, 0]),
        Uint8List.fromList([12, 0]),
        Uint8List(0),
      ]) {
        expect(
          decodeSolanaAssetInstruction(solanaCoreProgram, data, signedByOwner),
          isNull,
          reason: '$data',
        );
      }
    });

    test('reports as unread a holder it cannot show, a cut-off instruction, '
        'and ExecuteV1', () {
      final whole = approve(transfer, address);
      for (final data in [
        // A freeze nobody can lift, and the update authority given the right
        // to move it.
        approve(freeze, nobody),
        approve(transfer, updateAuthority),
        add(freeze, const [1], nobody),
        add(transfer, const [], updateAuthority),
        // A holder of no kind the program has.
        approve(transfer, const [4]),
        // Cut off: in the delegate's address, before the holder, before the
        // option, and before the plugin is named at all.
        whole.sublist(0, whole.length - 5),
        Uint8List.fromList([0x08, transfer]),
        Uint8List.fromList([0x02, freeze, 1]),
        Uint8List.fromList([0x02, transfer, 1]),
        Uint8List.fromList([0x08]),
        // An option flag that is neither absent nor present.
        Uint8List.fromList([0x02, transfer, 2, ...address]),
        // ExecuteV1 runs an instruction of the caller's choosing.
        Uint8List.fromList([0x1f, 1, 2, 3]),
      ]) {
        final effect = decodeSolanaAssetInstruction(
          solanaCoreProgram,
          data,
          signedByOwner,
        );
        expect(effect, isA<UnreadAssetInstruction>(), reason: '$data');
        expect((effect as UnreadAssetInstruction).program, solanaCoreProgram);
      }
      // The asset or the signer comes from a table that was not resolved.
      for (final accounts in [
        [null, collection, owner, owner, system],
        [asset, collection, owner, null, system],
        [asset, collection, null, solanaCoreProgram, system],
        [asset, collection, owner],
      ]) {
        expect(
          decodeSolanaAssetInstruction(
            solanaCoreProgram,
            whole,
            _accounts(accounts),
          ),
          isA<UnreadAssetInstruction>(),
          reason: '$accounts',
        );
      }
      expect(
        solanaUnreadAssetWarning(solanaCoreProgram),
        'A Metaplex Core instruction could not be read. It may change who controls what your wallet holds there.',
      );
    });
  });

  group('stake, loader and names', () {
    final stake = _key(11);
    final wallet = _key(12);
    final next = Ed25519HDPublicKey(List.filled(32, 13));
    final clock = _key(14);

    test('a stake account\'s authorities, however they are handed on', () {
      final authorize = decodeSolanaAssetInstruction(
        solanaStakeProgram,
        _bytes([_u32(1), next.bytes, _u32(1)]),
        _accounts([stake, clock, wallet]),
      );
      authorize as AuthorityHandover;
      expect(
        (authorize.account, authorize.current, authorize.next, authorize.what),
        (
          stake,
          wallet,
          next.toBase58(),
          'a stake account\'s withdraw authority',
        ),
      );
      final checked = decodeSolanaAssetInstruction(
        solanaStakeProgram,
        _bytes([_u32(10), _u32(0)]),
        _accounts([stake, clock, wallet, next.toBase58()]),
      );
      checked as AuthorityHandover;
      expect(
        (checked.next, checked.what),
        (next.toBase58(), 'a stake account\'s staking authority'),
      );
      // An authority type the reader does not know.
      expect(
        decodeSolanaAssetInstruction(
          solanaStakeProgram,
          _bytes([_u32(1), next.bytes, _u32(5)]),
          _accounts([stake, clock, wallet]),
        ),
        isA<UnreadAssetInstruction>(),
      );
    });

    test('a stake withdrawal, and the instructions that hand nothing on', () {
      final withdraw = decodeSolanaAssetInstruction(
        solanaStakeProgram,
        _bytes([_u32(4), _u64(5000000000)]),
        _accounts([stake, next.toBase58(), clock, clock, wallet]),
      );
      withdraw as StakeWithdrawal;
      expect(
        (withdraw.authority, withdraw.to, withdraw.lamports),
        (wallet, next.toBase58(), BigInt.from(5000000000)),
      );
      // DelegateStake and Deactivate.
      for (final tag in [2, 5]) {
        expect(
          decodeSolanaAssetInstruction(
            solanaStakeProgram,
            _bytes([_u32(tag)]),
            _accounts([stake, wallet]),
          ),
          isNull,
        );
      }
      // SetLockup.
      expect(
        decodeSolanaAssetInstruction(
          solanaStakeProgram,
          _bytes([
            _u32(6),
            [0, 0, 0],
          ]),
          _accounts([stake, wallet]),
        ),
        isA<UnreadAssetInstruction>(),
      );
    });

    test('a program\'s upgrade authority, and a name\'s owner', () {
      final program = _key(15);
      final upgrade = decodeSolanaAssetInstruction(
        solanaUpgradeableLoaderProgram,
        _bytes([_u32(4)]),
        _accounts([program, wallet]),
      );
      upgrade as AuthorityHandover;
      // No new authority: the program can never be upgraded again.
      expect(
        (upgrade.account, upgrade.current, upgrade.next),
        (program, wallet, null),
      );
      // Close.
      expect(
        decodeSolanaAssetInstruction(
          solanaUpgradeableLoaderProgram,
          _bytes([_u32(5)]),
          _accounts([program, wallet]),
        ),
        isA<UnreadAssetInstruction>(),
      );
      final name = decodeSolanaAssetInstruction(
        solanaNameServiceProgram,
        _bytes([
          [2],
          next.bytes,
        ]),
        _accounts([stake, wallet]),
      );
      name as AuthorityHandover;
      expect(
        (name.what, name.current, name.next),
        ('a name', wallet, next.toBase58()),
      );
    });

    test('a call the node parsed is read from its named fields', () {
      final authorize = decodeParsedSolanaAssetInstruction(solanaStakeProgram, {
        'type': 'authorize',
        'info': {
          'stakeAccount': stake,
          'clockSysvar': clock,
          'authority': wallet,
          'newAuthority': next.toBase58(),
          'authorityType': 'Withdrawer',
        },
      }, wallet);
      authorize as AuthorityHandover;
      expect(
        (authorize.current, authorize.next, authorize.what),
        (wallet, next.toBase58(), 'a stake account\'s withdraw authority'),
      );
      final withdraw = decodeParsedSolanaAssetInstruction(solanaStakeProgram, {
        'type': 'withdraw',
        'info': {
          'stakeAccount': stake,
          'destination': next.toBase58(),
          'withdrawAuthority': wallet,
          'lamports': 7,
        },
      }, wallet);
      expect((withdraw as StakeWithdrawal).lamports, BigInt.from(7));
      final upgrade = decodeParsedSolanaAssetInstruction(
        solanaUpgradeableLoaderProgram,
        {
          'type': 'setAuthority',
          'info': {'account': stake, 'authority': wallet, 'newAuthority': null},
        },
        wallet,
      );
      expect((upgrade as AuthorityHandover).next, isNull);
      // Hands nothing on.
      expect(
        decodeParsedSolanaAssetInstruction(solanaStakeProgram, {
          'type': 'deactivate',
          'info': {'stakeAccount': stake, 'stakeAuthority': wallet},
        }, wallet),
        isNull,
      );
      // Not understood: unread when it names the wallet, silent otherwise.
      expect(
        decodeParsedSolanaAssetInstruction(solanaStakeProgram, {
          'type': 'setLockup',
          'info': {'stakeAccount': stake, 'custodian': wallet},
        }, wallet),
        isA<UnreadAssetInstruction>(),
      );
      expect(
        decodeParsedSolanaAssetInstruction(solanaStakeProgram, {
          'type': 'setLockup',
          'info': {'stakeAccount': stake, 'custodian': clock},
        }, wallet),
        isNull,
      );
      // A program this reader does not cover.
      expect(
        decodeParsedSolanaAssetInstruction(_token, const {}, wallet),
        null,
      );
    });
  });

  group('System and Token instructions the review does not read', () {
    Uint8List system(int tag) => Uint8List.fromList(_u32(tag));
    Uint8List token(List<int> data) => Uint8List.fromList(data);

    test('one with no name, and a named one that moves or re-assigns '
        'holdings, can need a caution', () {
      // A tag no table names.
      expect(solanaUnreadInstructionIsRisky(_system, system(99)), isTrue);
      expect(solanaUnreadInstructionIsRisky(_token, token([200])), isTrue);
      // A Token-2022 tag whose second byte no table names.
      expect(
        solanaUnreadInstructionIsRisky(_token2022, token([26, 9])),
        isTrue,
      );
      // Allocate, and the two that move SOL when they cannot be read.
      for (final tag in [8, 5, 11]) {
        expect(
          solanaUnreadInstructionIsRisky(_system, system(tag)),
          isTrue,
          reason: '$tag',
        );
      }
      // Token-2022: withdrawing withheld fees, a confidential transfer, a
      // batch of instructions, turning the CPI guard off, taking the SOL out
      // of a wrapped account, and handing on a metadata update authority.
      for (final data in [
        [26, 3],
        [27, 7],
        [255],
        [34, 1],
        [45],
        [215, 228, 166, 228, 84, 100, 86, 123],
      ]) {
        expect(
          solanaUnreadInstructionIsRisky(_token2022, token(data)),
          isTrue,
          reason: '$data',
        );
      }
      // A transfer, an approval and a new authority cut short of what the
      // review reads them from.
      for (final data in [
        [3],
        [4],
        [6, 2],
        [12, 1],
      ]) {
        expect(
          solanaUnreadInstructionIsRisky(_token, token(data)),
          isTrue,
          reason: '$data',
        );
      }
    });

    test('one that sets something up or keeps a mint in order does not', () {
      // InitializeNonceAccount, AdvanceNonceAccount, UpgradeNonceAccount.
      for (final tag in [6, 4, 12]) {
        expect(
          solanaUnreadInstructionIsRisky(_system, system(tag)),
          isFalse,
          reason: '$tag',
        );
      }
      // InitializeAccount3, MintTo, SyncNative.
      for (final tag in [18, 7, 17]) {
        expect(
          solanaUnreadInstructionIsRisky(_token, token([tag])),
          isFalse,
          reason: '$tag',
        );
      }
      // Token-2022: SetTransferFee, UpdateDefaultAccountState,
      // UpdateTransferHook, UpdateMetadataPointer, UpdateGroupPointer,
      // UpdateGroupMemberPointer, UpdateMultiplierScaledUiMint, Pause, Resume,
      // UpdateTokenMetadataField, RemoveTokenMetadataKey.
      for (final data in [
        [26, 5],
        [28, 1],
        [36, 1],
        [39, 1],
        [40, 1],
        [41, 1],
        [43, 1],
        [44, 1],
        [44, 2],
        [221, 233, 49, 45, 181, 202, 220, 200],
        [234, 18, 32, 56, 89, 141, 37, 181],
      ]) {
        expect(
          solanaUnreadInstructionIsRisky(_token2022, token(data)),
          isFalse,
          reason: '$data',
        );
      }
      // The same bytes for a program this reader does not cover.
      expect(solanaUnreadInstructionIsRisky(_usdc, system(99)), isFalse);
    });

    test('the cautions name the program and the instruction', () {
      expect(
        solanaUnreadInstructionWarning(_system, system(8)),
        'A System Program instruction (Allocate) could not be read. With your signature it can move or re-assign what your wallet holds.',
      );
      expect(
        solanaUnreadInstructionWarning(_token2022, token([200])),
        'A Token-2022 instruction could not be read. With your signature it can move or re-assign what your wallet holds.',
      );
      expect(
        solanaExtraBytesWarning(_system, system(2)),
        'A System Program instruction (Transfer) has extra bytes after its own. The program ignores them, and so does this review.',
      );
      expect(
        solanaUnreadAssetWarning(solanaBubblegumProgram),
        'A Metaplex Bubblegum instruction could not be read. It may change who controls what your wallet holds there.',
      );
    });
  });
}
