import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/staking/data/staking_tx_builder.dart';

/// Pins the epoch-boundary rules that decide whether a native stake account is
/// activating, active, deactivating, or inactive. These directly gate which
/// staking actions (stake / unstake / withdraw) the UI offers and whether
/// withdrawable funds are surfaced — a wrong classification either hides a
/// user's reclaimable SOL or offers a withdraw that the chain will reject.
void main() {
  // u64::MAX — the on-wire "never deactivated" sentinel. It does not fit Dart's
  // int64, so the builder's u64 read saturates at int64 max, which is what
  // reaches [classifyStakeState] as `deactivationEpoch`.
  const neverDeactivated = 9223372036854775807;

  StakeAccountState classify({
    required int activation,
    required int deactivation,
    required int epoch,
  }) => StakingTxBuilder.classifyStakeState(
    activationEpoch: activation,
    deactivationEpoch: deactivation,
    currentEpoch: epoch,
  );

  group('classifyStakeState — not yet deactivated (sentinel)', () {
    test('activation epoch in the future is activating', () {
      expect(
        classify(activation: 105, deactivation: neverDeactivated, epoch: 100),
        StakeAccountState.activating,
      );
    });

    test('activation epoch equal to current epoch is activating', () {
      // Boundary: delegated *this* epoch is not yet earning.
      expect(
        classify(activation: 100, deactivation: neverDeactivated, epoch: 100),
        StakeAccountState.activating,
      );
    });

    test('activation epoch one before current epoch is active', () {
      // Boundary: warmup completes the epoch after delegation.
      expect(
        classify(activation: 99, deactivation: neverDeactivated, epoch: 100),
        StakeAccountState.active,
      );
    });

    test('long-active account stays active', () {
      expect(
        classify(activation: 1, deactivation: neverDeactivated, epoch: 100),
        StakeAccountState.active,
      );
    });
  });

  group('classifyStakeState — deactivation requested', () {
    test('deactivation epoch equal to current epoch is deactivating', () {
      // Boundary: cooling down *this* epoch, not yet withdrawable.
      expect(
        classify(activation: 50, deactivation: 100, epoch: 100),
        StakeAccountState.deactivating,
      );
    });

    test('deactivation epoch one before current epoch is inactive', () {
      // Boundary: fully cooled down the epoch after deactivation → withdrawable.
      expect(
        classify(activation: 50, deactivation: 99, epoch: 100),
        StakeAccountState.inactive,
      );
    });

    test('deactivation epoch far in the past is inactive', () {
      expect(
        classify(activation: 1, deactivation: 2, epoch: 100),
        StakeAccountState.inactive,
      );
    });

    test('future deactivation epoch is ignored — account still active', () {
      // A scheduled-but-not-yet-reached deactivation must not flip the account
      // out of active; it keeps earning until the epoch arrives.
      expect(
        classify(activation: 10, deactivation: 105, epoch: 100),
        StakeAccountState.active,
      );
    });

    test('future deactivation while still warming up stays activating', () {
      expect(
        classify(activation: 100, deactivation: 105, epoch: 100),
        StakeAccountState.activating,
      );
    });
  });

  group('classifyStakeState — same-epoch stake then unstake', () {
    test('is withdrawable immediately, not deactivating', () {
      // The app can produce this state itself: stake, then unstake before the
      // epoch ends. Solana's stake program short-circuits
      // `activationEpoch == deactivationEpoch` to zero effective/activating/
      // deactivating stake, so the account is fully withdrawable at once — and
      // the backend counts those lamports as `inactive`, which is what drives
      // the "X SOL claimable" card and the Claim button. Classifying it
      // `deactivating` left Claim building nothing and reporting "Nothing to
      // claim" against funds the UI said were there.
      expect(
        classify(activation: 100, deactivation: 100, epoch: 100),
        StakeAccountState.inactive,
      );
    });

    test('stays withdrawable in later epochs', () {
      expect(
        classify(activation: 100, deactivation: 100, epoch: 103),
        StakeAccountState.inactive,
      );
    });

    test('a real cooldown is still deactivating in its own epoch', () {
      // Guard on the fix above: only activation == deactivation is instant.
      // Stake delegated in an earlier epoch and deactivated now must serve the
      // full cooldown, or Claim builds a withdraw the chain rejects.
      expect(
        classify(activation: 99, deactivation: 100, epoch: 100),
        StakeAccountState.deactivating,
      );
    });
  });

  group('classifyStakeState — edge cases', () {
    test(
      'deactivation precedence: reached deactivation wins over activation',
      () {
        // Even with activation in the future, a reached deactivation classifies
        // the account by its deactivation, never as activating.
        expect(
          classify(activation: 200, deactivation: 100, epoch: 100),
          StakeAccountState.deactivating,
        );
        expect(
          classify(activation: 200, deactivation: 50, epoch: 100),
          StakeAccountState.inactive,
        );
      },
    );

    test('epoch zero with zero activation is active', () {
      // Unparseable activation epochs fall back to 0 in the builder; at epoch 0
      // that means activation (0 >= 0), and at any later epoch, active.
      expect(
        classify(activation: 0, deactivation: neverDeactivated, epoch: 0),
        StakeAccountState.activating,
      );
      expect(
        classify(activation: 0, deactivation: neverDeactivated, epoch: 1),
        StakeAccountState.active,
      );
    });

    test('sentinel is never treated as a reached deactivation', () {
      // Guards against the int64-max sentinel ever satisfying `<= epoch`.
      expect(
        classify(
          activation: 1,
          deactivation: neverDeactivated,
          epoch: neverDeactivated,
        ),
        StakeAccountState.active,
      );
    });
  });

  group('decodeStakeAccount', () {
    // A real mainnet stake account (HFMCJhan9UZwmhCLn89aqF4S7Kukc4gjpumC18VApKX)
    // delegated to mallow's validator, captured raw. Its
    // `jsonParsed` form omits the deprecated `warmupCooldownRate` field, which
    // the solana package decodes as a required `num` — reading these accounts
    // parsed threw `type 'Null' is not a subtype of type 'num'` and broke every
    // unstake and claim, so the builder decodes the raw layout instead. This
    // fixture pins that layout against bytes the chain actually served.
    const accountBase64 =
        'AgAAAIDVIgAAAAAA3Yj03bPl2YA0dF1tnReVRJ2RrtXwF4f37LX8BZrAMbPdiPTd'
        's+XZgDR0XW2dF5VEnZGu1fAXh/fstfwFmsAxswAAAAAAAAAAAAAAAAAAAAAAAAAA'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAtQG+aqo3p4avRS8jub0ORotihH'
        'rCIc+sEPCusiBV8xW8kSAwAAAACMAwAAAAAAAP//////////AAAAAAAA0D8KM7BO'
        'AAAAAAAAAAA=';
    const address = 'HFMCJhan9UZwmhCLn89aqF4S7Kukc4gjpumC18VApKX';
    const lamports = 53845723;
    const mallowVote = 'mALLoAbdQrgsnm7kWJyPrhcQcmxfT73t8DaqEkpZNd6';
    const activationEpoch = 908;

    final raw = base64Decode(accountBase64);

    /// The fixture with [edit] applied to a copy of its bytes.
    Uint8List edited(void Function(ByteData view) edit) {
      final bytes = Uint8List.fromList(raw);
      edit(ByteData.sublistView(bytes));
      return bytes;
    }

    /// Write a little-endian u64 that fits in 32 bits.
    void writeEpoch(ByteData view, int offset, int value) {
      view.setUint32(offset, value, Endian.little);
      view.setUint32(offset + 4, 0, Endian.little);
    }

    StakeAccountInfo? decode(List<int> data, {required int currentEpoch}) =>
        StakingTxBuilder.decodeStakeAccount(
          address: address,
          accountLamports: lamports,
          data: data,
          validatorVoteAddress: mallowVote,
          currentEpoch: currentEpoch,
        );

    test('decodes delegated stake, lamports and state from raw bytes', () {
      final info = decode(raw, currentEpoch: 1013)!;
      expect(info.address, address);
      // What `withdraw` reclaims — the full account balance, not the delegation.
      expect(info.accountLamports, lamports);
      // `delegation.stake`, which is what the unstake builder sizes its
      // deactivate/split against.
      expect(info.delegatedLamports, 51562843);
      expect(info.state, StakeAccountState.active);
    });

    test('u64::MAX deactivation epoch reads as never deactivated', () {
      // The sentinel's high bit is set; a naive signed read yields -1, which is
      // `<= currentEpoch` and would misreport every live stake as inactive —
      // unstake would then find nothing to deactivate and throw "Not enough
      // active stake".
      expect(decode(raw, currentEpoch: 1013)!.state, StakeAccountState.active);
      expect(
        decode(raw, currentEpoch: activationEpoch)!.state,
        StakeAccountState.activating,
      );
    });

    test('a real deactivation epoch is read back as deactivating', () {
      final bytes = edited((view) => writeEpoch(view, 172, 1013));
      expect(
        decode(bytes, currentEpoch: 1013)!.state,
        StakeAccountState.deactivating,
      );
      expect(
        decode(bytes, currentEpoch: 1014)!.state,
        StakeAccountState.inactive,
      );
    });

    test('an account delegated to another validator is skipped', () {
      // The `getProgramAccounts` filter only matches the withdrawer authority,
      // so foreign delegations do come back and must not be unstaked here.
      expect(
        StakingTxBuilder.decodeStakeAccount(
          address: address,
          accountLamports: lamports,
          data: raw,
          validatorVoteAddress: 'CertusDeBmqN8ZawdkxK5kFGMwBXdudvWHYwtNgNhvLu',
          currentEpoch: 1013,
        ),
        isNull,
      );
    });

    test('a non-delegated account is skipped', () {
      // Discriminant 1 == initialized but never delegated: its delegation bytes
      // are zeroed, so decoding them as a delegation would invent stake.
      expect(
        decode(
          edited((view) => view.setUint32(0, 1, Endian.little)),
          currentEpoch: 1013,
        ),
        isNull,
      );
    });

    test('a short account is skipped rather than throwing', () {
      expect(decode(raw.sublist(0, 120), currentEpoch: 1013), isNull);
    });
  });
}
