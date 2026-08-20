import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show TokenStandard;
import 'package:mallow_wallet/shared/utils/token_standard_label.dart';

void main() {
  group('tokenStandardLabel', () {
    test('maps every enum variant to a non-empty label', () {
      // Belt-and-suspenders: if a new variant is added to TokenStandard, the
      // exhaustive switch must add a label too. Compiler enforces it, but
      // this asserts the runtime mapping isn't accidentally empty.
      for (final ts in TokenStandard.values) {
        expect(tokenStandardLabel(ts), isNotEmpty);
      }
    });

    test('legacy/core/programmable/compressed labels match the webapp', () {
      expect(tokenStandardLabel(TokenStandard.nft), 'Metaplex Legacy');
      expect(tokenStandardLabel(TokenStandard.core), 'Metaplex Core');
      expect(tokenStandardLabel(TokenStandard.coreCollection), 'Metaplex Core');
      expect(tokenStandardLabel(TokenStandard.pnft), 'Metaplex Programmable');
      expect(tokenStandardLabel(TokenStandard.cnft), 'Metaplex Compressed');
    });

    test('cross-chain labels are formatted with their canonical name', () {
      expect(tokenStandardLabel(TokenStandard.objkt), 'FA2');
      expect(tokenStandardLabel(TokenStandard.erc721), 'ERC-721');
      expect(tokenStandardLabel(TokenStandard.erc1155), 'ERC-1155');
    });
  });

  group('tokenStandardLabelFromWire', () {
    test('maps known wire strings via the enum lookup', () {
      expect(tokenStandardLabelFromWire('nft'), 'Metaplex Legacy');
      expect(tokenStandardLabelFromWire('core'), 'Metaplex Core');
      expect(tokenStandardLabelFromWire('core-collection'), 'Metaplex Core');
      expect(tokenStandardLabelFromWire('pnft'), 'Metaplex Programmable');
      expect(tokenStandardLabelFromWire('cnft'), 'Metaplex Compressed');
      expect(tokenStandardLabelFromWire('erc721'), 'ERC-721');
    });

    test('unknown wire falls back to the raw value so the row never renders '
        'empty', () {
      // Mirrors the webapp's fallback so a freshly-shipped backend standard
      // still displays *something* until the wallet enum catches up.
      expect(tokenStandardLabelFromWire('future-standard'), 'future-standard');
      expect(tokenStandardLabelFromWire(''), '');
    });
  });
}
