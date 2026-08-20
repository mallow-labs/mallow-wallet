import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/signing_copy.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  // These helpers decide whether the signing sheet shows local approval copy
  // ("Approving transaction…" / "One moment please") or nudges an external/Ledger
  // signer to act in their wallet. Getting this wrong reintroduces the QA
  // complaint where local-key signing read "Approve the transaction in your
  // wallet" even though no external prompt ever appears — so the branch
  // boundary matters, not just the happy path.
  group('isLocalSigningStage', () {
    test('local label tells the user the app is approving the transaction', () {
      expect(kLocalSigningLabel, 'Approving transaction…');
    });

    test('null stage is not local (external signer is the safe default)', () {
      expect(isLocalSigningStage(null), isFalse);
    });

    test('empty stage is not local', () {
      expect(isLocalSigningStage(''), isFalse);
    });

    test('exact local label is local', () {
      expect(isLocalSigningStage(kLocalSigningLabel), isTrue);
    });

    test('local label with a multi-tx progress suffix is still local', () {
      // Multi-tx flows append " (1/3)" to the label; the prefix match must
      // keep classifying these as local so the copy stays consistent.
      expect(isLocalSigningStage('$kLocalSigningLabel (1/3)'), isTrue);
    });

    test('the external sublabel string is not a local stage', () {
      expect(isLocalSigningStage(kExternalSigningSublabel), isFalse);
    });

    test('an arbitrary external stage label is not local', () {
      expect(isLocalSigningStage('Approve on your Ledger device'), isFalse);
    });

    test('Ledger stage is identified separately from local signing', () {
      expect(isLedgerSigningStage('Approve on your Ledger device'), isTrue);
      expect(isLedgerSigningStage('Awaiting approval…'), isFalse);
    });

    test('label mid-string (not a prefix) is not local', () {
      // startsWith — not contains — so a label embedded mid-string must not
      // trip the local branch.
      expect(isLocalSigningStage('Now: $kLocalSigningLabel'), isFalse);
    });
  });

  group('signingLabelForStage', () {
    test('uses the external approval label when no stage is available', () {
      expect(signingLabelForStage(null), kExternalSigningLabel);
    });

    test('preserves local progress stages', () {
      expect(
        signingLabelForStage('$kLocalSigningLabel (2/2)'),
        '$kLocalSigningLabel (2/2)',
      );
    });

    test('maps Ledger and external stages to the shared approval label', () {
      expect(signingLabelForStage(kLedgerSigningStage), kExternalSigningLabel);
      expect(
        signingLabelForStage('$kExternalSigningLabel (1 of 2)'),
        '$kExternalSigningLabel (1 of 2)',
      );
    });
  });

  group('signingSublabelForStage', () {
    test('null stage gets the approve-in-wallet copy', () {
      expect(signingSublabelForStage(null), kExternalSigningSublabel);
    });

    test('exact local label gets the reassurance copy', () {
      expect(
        signingSublabelForStage(kLocalSigningLabel),
        kLocalSigningSublabel,
      );
    });

    test('local label with progress suffix still gets reassurance copy', () {
      expect(
        signingSublabelForStage('$kLocalSigningLabel (2/2)'),
        kLocalSigningSublabel,
      );
    });

    test('Ledger stage gets the Ledger approval copy', () {
      expect(
        signingSublabelForStage('Approve on your Ledger device'),
        kLedgerSigningSublabel,
      );
    });

    test('external stage gets the approve-in-wallet fallback', () {
      expect(
        signingSublabelForStage('External approval stage (1/2)'),
        kExternalSigningSublabel,
      );
    });

    test('local and external sublabels are distinct copy', () {
      // Guards against a future refactor collapsing the two messages — the
      // whole point of this module is that they differ.
      expect(kLocalSigningSublabel, isNot(equals(kExternalSigningSublabel)));
    });
  });

  // The confirming subtitle makes a promise about how long the user waits, and
  // that promise is only true per-chain: Solana lands in a slot or two, EVM and
  // Tezos take block times far longer. Telling an Ethereum sender "a few
  // seconds" turns a normal confirmation into an apparent hang.
  group('confirmingSublabelForChain', () {
    test('Solana promises seconds', () {
      expect(
        confirmingSublabelForChain(Chain.solana),
        kConfirmingSublabelSolana,
      );
    });

    test('EVM and Tezos promise the longer wait, not Solana speeds', () {
      for (final chain in [Chain.ethereum, Chain.tezos]) {
        expect(
          confirmingSublabelForChain(chain),
          kConfirmingSublabelOtherChains,
          reason: '$chain must not inherit the Solana promise',
        );
      }
    });

    test('the two promises are distinct copy', () {
      expect(
        kConfirmingSublabelSolana,
        isNot(equals(kConfirmingSublabelOtherChains)),
      );
    });
  });

  // A Solana confirmation that outruns its "few seconds" promise leaves the
  // sheet frozen on copy the user can already see is wrong, which reads as a
  // hung app on a transaction that is usually still in flight. The reassurance
  // cycle exists to keep that step moving — so it must attach to exactly the
  // subtitle that makes the short promise, and to nothing else.
  group('sublabelCycleFor', () {
    test('the Solana confirming subtitle gets the reassurance cycle', () {
      expect(
        sublabelCycleFor(kConfirmingSublabelSolana),
        kConfirmingSublabelCycleSolana,
      );
    });

    test('a non-Solana confirmation does not cycle', () {
      // Its opening line already promises a minute, so there is nothing to
      // walk back.
      expect(sublabelCycleFor(kConfirmingSublabelOtherChains), isEmpty);
    });

    test('non-confirming steps do not cycle', () {
      for (final sublabel in [
        kPreparingSublabel,
        kLocalSigningSublabel,
        kExternalSigningSublabel,
        kLedgerSigningSublabel,
        null,
      ]) {
        expect(
          sublabelCycleFor(sublabel),
          isEmpty,
          reason: '"$sublabel" is not the step the cycle describes',
        );
      }
    });

    test('the cycle never returns to the opening promise', () {
      // The sheet holds on the last entry rather than looping, but if the
      // opening line were *in* the list the user would still be walked back to
      // "a few seconds" after already waiting longer than that.
      expect(
        kConfirmingSublabelCycleSolana,
        isNot(contains(kConfirmingSublabelSolana)),
      );
    });
  });
}
