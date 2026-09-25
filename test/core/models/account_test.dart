import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';

WalletInfo _wallet({
  String id = 'w-1',
  String address = 'addr-1',
  String name = 'Wallet 1',
  WalletType walletType = WalletType.hd,
  String chain = 'solana',
}) => WalletInfo(
  id: id,
  address: address,
  name: name,
  walletType: walletType,
  chain: chain,
);

/// [account.dart] is the single source of truth for which wallets can sign,
/// which groups can accept new links, and which are hardware-backed. The
/// derived getters here are read across the drawer, send/swap surfaces, and
/// signing gates — a regression in any of them silently shows the wrong UI.
void main() {
  group('AccountKind.toDbString / fromDbString', () {
    test('round-trips every value through its DB string', () {
      for (final kind in AccountKind.values) {
        expect(
          AccountKind.fromDbString(kind.toDbString()),
          kind,
          reason: 'round-trip should preserve $kind',
        );
      }
    });

    test('emits the exact DB strings the schema expects', () {
      // These strings are written into the `kind` column and read back by
      // `getHardwareAccountByIndex` / `getSeedVaultAccountByIndex`, which match
      // on the literal. Changing one silently stops those queries finding
      // existing accounts, and imports start forking new account cards.
      expect(AccountKind.seed.toDbString(), 'seed');
      expect(AccountKind.privateKey.toDbString(), 'privateKey');
      expect(AccountKind.viewOnly.toDbString(), 'viewOnly');
      expect(AccountKind.social.toDbString(), 'social');
      expect(AccountKind.hardware.toDbString(), 'hardware');
      expect(AccountKind.seedVault.toDbString(), 'seedVault');
    });

    test('Seed Vault is its own kind, distinct from hardware', () {
      // The whole point of the separate kind: hardware accounts resolve by
      // derivation index alone, so one shared kind merges a Ledger and a
      // Seed Vault imported at the same index into one account card.
      expect(AccountKind.seedVault, isNot(AccountKind.hardware));
      expect(
        AccountKind.seedVault.toDbString(),
        isNot(AccountKind.hardware.toDbString()),
      );
    });
  });

  group('WalletType.toDbString / fromDbString', () {
    test('round-trips every value through its DB string', () {
      for (final type in WalletType.values) {
        expect(
          WalletType.fromDbString(type.toDbString()),
          type,
          reason: 'round-trip should preserve $type',
        );
      }
    });

    test('emits the exact DB strings the schema expects', () {
      expect(WalletType.hd.toDbString(), 'hd');
      expect(WalletType.importedKey.toDbString(), 'imported_key');
      expect(WalletType.viewOnly.toDbString(), 'view_only');
      expect(WalletType.social.toDbString(), 'social');
      expect(WalletType.ledger.toDbString(), 'ledger');
      expect(WalletType.seedVault.toDbString(), 'seed_vault');
    });

    test('"hardware" string is backward-compatible with ledger', () {
      // Old DB rows pre-Ledger-rename used 'hardware' — must still load.
      expect(WalletType.fromDbString('hardware'), WalletType.ledger);
    });

    test('unknown DB string falls back to hd (does not throw)', () {
      // Fail-soft so a future enum addition can't brick the DB load path.
      expect(WalletType.fromDbString('keystone'), WalletType.hd);
      expect(WalletType.fromDbString(''), WalletType.hd);
    });
  });

  group('WalletType derived flags', () {
    // Why: `isHardware` is what every "this wallet cannot sign on its own"
    // decision reads — the drawer badge, the send-source gates, and the
    // background-login skip that keeps an external approval screen from
    // appearing with no user action behind it. A hardware type missing from
    // this set does not fail loudly; it signs silently, or prompts silently.
    const hardware = {WalletType.ledger, WalletType.seedVault};

    test('ledger and Seed Vault are the hardware types', () {
      for (final t in WalletType.values) {
        expect(
          t.isHardware,
          hardware.contains(t),
          reason: '$t hardware-ness is wrong',
        );
      }
    });

    test('needsDeviceForSigning tracks isHardware exactly', () {
      for (final t in WalletType.values) {
        expect(t.needsDeviceForSigning, t.isHardware);
      }
    });
  });

  group('WalletInfo.badge', () {
    // Why: the badge is the only on-screen signal that a wallet's key is not
    // on this device. A type that falls through to `null` looks like a plain
    // HD wallet in the drawer.
    test('Ledger and Seed Vault carry their own distinct marks', () {
      // Why: both are hardware, but the badge names *which* device holds the
      // key, and they demand different things to sign — a paired Ledger over
      // BLE, or an on-device Seed Vault prompt. Collapsing them back onto one
      // shared "hardware" icon would tell a Seeker owner to go find a Ledger.
      expect(_wallet(walletType: WalletType.ledger).badge, WalletBadge.ledger);
      expect(
        _wallet(walletType: WalletType.seedVault).badge,
        WalletBadge.seedVault,
      );
    });

    test('only plain local-key types carry no badge', () {
      for (final t in WalletType.values) {
        final expectBadge = t != WalletType.hd && t != WalletType.importedKey;
        expect(
          _wallet(walletType: t).badge != null,
          expectBadge,
          reason: '$t badge presence is wrong',
        );
      }
    });
  });

  group('WalletInfo.canSign', () {
    test('view-only wallets cannot sign', () {
      expect(_wallet(walletType: WalletType.viewOnly).canSign, isFalse);
    });

    test('every non-view-only wallet type can sign (including social)', () {
      for (final t in WalletType.values.where(
        (t) => t != WalletType.viewOnly,
      )) {
        expect(
          _wallet(walletType: t).canSign,
          isTrue,
          reason: '$t should be able to sign',
        );
      }
    });
  });

  group('ProfileGroup.canAcceptLink', () {
    test('returns true when at least one wallet can sign', () {
      final group = ProfileGroup(
        userId: 'u1',
        wallets: [
          _wallet(walletType: WalletType.viewOnly),
          _wallet(id: 'w-2'),
        ],
        isAnon: false,
      );
      expect(group.canAcceptLink, isTrue);
    });

    test('returns false when every wallet is view-only', () {
      final group = ProfileGroup(
        wallets: [
          _wallet(walletType: WalletType.viewOnly),
          _wallet(id: 'w-2', walletType: WalletType.viewOnly),
        ],
        isAnon: true,
      );
      expect(group.canAcceptLink, isFalse);
    });

    test('returns false for an empty group', () {
      const group = ProfileGroup(wallets: [], isAnon: true);
      expect(group.canAcceptLink, isFalse);
    });
  });

  group('ProfileGroup.isFull', () {
    test('cap is 5 wallets — 4 is not full, 5 is full, 6 is full', () {
      ProfileGroup withN(int n) => ProfileGroup(
        wallets: List.generate(n, (i) => _wallet(id: 'w-$i')),
        isAnon: true,
      );
      expect(withN(4).isFull, isFalse);
      expect(withN(5).isFull, isTrue);
      expect(withN(6).isFull, isTrue);
    });
  });

  group('ProfileGroup.loginAddress', () {
    // This is the address the edit/switch flows log in with to populate
    // AuthService.currentUser for THIS profile. Getting it wrong re-logs into
    // another profile and the edit wizard prefills the wrong avatar/details.
    test('prefers a held signable Solana wallet over other chains', () {
      final group = ProfileGroup(
        userId: 'u1',
        wallets: [
          _wallet(id: 'eth', address: '0xeth', chain: 'ethereum'),
          _wallet(id: 'sol', address: 'sol-addr'), // chain defaults to solana
        ],
        isAnon: false,
      );
      expect(group.loginAddress, 'sol-addr');
    });

    test('falls back to a view-only Solana address when no signer is held', () {
      // A profile whose Solana wallet is only a view-only placeholder still
      // identifies to the backend by that Solana address — not the first
      // (non-Solana) wallet, and never the global active selection.
      final group = ProfileGroup(
        userId: 'u1',
        wallets: [
          _wallet(id: 'eth', address: '0xeth', chain: 'ethereum'),
          // chain defaults to 'solana' in the helper.
          _wallet(
            id: 'sol-view',
            address: 'sol-view-addr',
            walletType: WalletType.viewOnly,
          ),
        ],
        isAnon: false,
      );
      expect(group.loginAddress, 'sol-view-addr');
    });

    test('falls back to the first wallet when the profile has no Solana', () {
      final group = ProfileGroup(
        userId: 'u1',
        wallets: [
          _wallet(id: 'eth', address: '0xeth', chain: 'ethereum'),
          _wallet(id: 'tez', address: 'tz-addr', chain: 'tezos'),
        ],
        isAnon: false,
      );
      expect(group.loginAddress, '0xeth');
    });

    test('is null for an empty group', () {
      const group = ProfileGroup(wallets: [], isAnon: true);
      expect(group.loginAddress, isNull);
    });
  });

  group('Account derived getters', () {
    test('primaryWallet returns the first wallet, or null when empty', () {
      const empty = Account(id: 'a', name: 'A');
      expect(empty.primaryWallet, isNull);

      final filled = Account(
        id: 'a',
        name: 'A',
        wallets: [
          _wallet(id: 'first'),
          _wallet(id: 'second'),
        ],
      );
      expect(filled.primaryWallet?.id, 'first');
    });

    test('hasSeedPhrase is true only when at least one HD wallet exists', () {
      final noHd = Account(
        id: 'a',
        name: 'A',
        wallets: [
          _wallet(walletType: WalletType.importedKey),
          _wallet(id: 'w-2', walletType: WalletType.ledger),
        ],
      );
      expect(noHd.hasSeedPhrase, isFalse);

      final withHd = Account(
        id: 'a',
        name: 'A',
        wallets: [
          _wallet(walletType: WalletType.importedKey),
          _wallet(id: 'w-2'),
        ],
      );
      expect(withHd.hasSeedPhrase, isTrue);
    });

    test('hasHardwareWallet only counts hardware types', () {
      final mixed = Account(
        id: 'a',
        name: 'A',
        wallets: [
          _wallet(),
          _wallet(id: 'w-2', walletType: WalletType.social),
        ],
      );
      expect(mixed.hasHardwareWallet, isFalse);

      final withLedger = Account(
        id: 'a',
        name: 'A',
        wallets: [
          _wallet(),
          _wallet(id: 'w-2', walletType: WalletType.ledger),
        ],
      );
      expect(withLedger.hasHardwareWallet, isTrue);

      final withSeedVault = Account(
        id: 'a',
        name: 'A',
        wallets: [
          _wallet(),
          _wallet(id: 'w-2', walletType: WalletType.seedVault),
        ],
      );
      expect(withSeedVault.hasHardwareWallet, isTrue);
    });

    test('empty wallets list reports no seed phrase and no hardware', () {
      const empty = Account(id: 'a', name: 'A');
      expect(empty.hasSeedPhrase, isFalse);
      expect(empty.hasHardwareWallet, isFalse);
    });
  });

  group('canSignSendTransfer', () {
    // Why: each arm must mirror what its `WalletManager.sign*` entry point
    // actually supports. A wallet that passes this gate but throws at signing
    // is offered as a send source and dead-ends the user *after* the biometric
    // prompt — the failure this predicate exists to prevent.
    test('Ethereum allows HD, imported key, social and Ledger', () {
      // Social is included because a social login stores a per-chain key
      // on-device (WalletRepository.addSocialAccount) and signs through the
      // imported-key path — nothing about it is remote.
      for (final type in [
        WalletType.hd,
        WalletType.importedKey,
        WalletType.social,
        WalletType.ledger,
      ]) {
        expect(
          _wallet(chain: 'ethereum', walletType: type).canSignSendTransfer,
          isTrue,
          reason: 'signEthereumTransaction supports $type',
        );
      }
      expect(
        _wallet(
          chain: 'ethereum',
          walletType: WalletType.viewOnly,
        ).canSignSendTransfer,
        isFalse,
        reason: 'a view-only wallet holds no key',
      );
    });

    test('Tezos allows HD, imported key and social — Ledger is NOT '
        'supported', () {
      for (final type in [
        WalletType.hd,
        WalletType.importedKey,
        WalletType.social,
      ]) {
        expect(
          _wallet(chain: 'tezos', walletType: type).canSignSendTransfer,
          isTrue,
        );
      }
      // `signTezosOperation` throws TezosOperationSigningNotSupportedException
      // for both. Tezos Ledger wallets are creatable, so the previous blanket
      // `canSign` gate offered one as a source and failed at forge/sign — after
      // the auth gate had already been cleared.
      for (final type in [WalletType.ledger, WalletType.viewOnly]) {
        expect(
          _wallet(chain: 'tezos', walletType: type).canSignSendTransfer,
          isFalse,
          reason: 'signTezosOperation throws for $type',
        );
      }
    });

    test(
      'Solana tracks canSign — the executor signs with the active wallet',
      () {
        for (final type in [
          WalletType.hd,
          WalletType.importedKey,
          WalletType.ledger,
          WalletType.social,
        ]) {
          expect(_wallet(walletType: type).canSignSendTransfer, isTrue);
        }
        expect(
          _wallet(walletType: WalletType.viewOnly).canSignSendTransfer,
          isFalse,
        );
      },
    );

    // Why: Seed Vault exposes exactly one signing purpose,
    // PURPOSE_SIGN_SOLANA_TRANSACTION, so there is no secp256k1 or Tezos path
    // to reach. A Seed Vault row is only ever written on Solana; the other two
    // arms are asserted so that stays true if a row is ever mislabelled.
    test('Seed Vault signs on Solana only', () {
      expect(
        _wallet(walletType: WalletType.seedVault).canSignSendTransfer,
        isTrue,
      );
      expect(
        _wallet(
          chain: 'ethereum',
          walletType: WalletType.seedVault,
        ).canSignSendTransfer,
        isFalse,
      );
      expect(
        _wallet(
          chain: 'tezos',
          walletType: WalletType.seedVault,
        ).canSignSendTransfer,
        isFalse,
      );
    });
  });

  group('bindsGlobalSigner', () {
    // Why: this is the predicate that decides whether a flow may re-point the
    // global wallet selection — and with it the backend login identity that
    // gates every `owner == req.loginAddress` write. Only Solana earns that,
    // because `WalletManager._getKeypair()` resolves its signer from
    // `loadSelectedWalletId()` and cannot be handed one.
    test('Solana binds the global signer; Tezos and Ethereum do not', () {
      expect(_wallet().bindsGlobalSigner, isTrue);
      expect(_wallet(chain: 'tezos').bindsGlobalSigner, isFalse);
      expect(_wallet(chain: 'ethereum').bindsGlobalSigner, isFalse);
    });

    test('is a property of the chain, not the wallet type', () {
      for (final type in WalletType.values) {
        expect(_wallet(walletType: type).bindsGlobalSigner, isTrue);
        expect(
          _wallet(chain: 'tezos', walletType: type).bindsGlobalSigner,
          isFalse,
        );
      }
    });
  });
}
