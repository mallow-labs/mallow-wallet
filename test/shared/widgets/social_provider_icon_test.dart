import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/social_wallet_copy.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mallow_wallet/shared/widgets/social_provider_icon.dart';
import 'package:mallow_wallet/shared/widgets/wallet_type_badge.dart';

/// The Google or Apple icon is how a wallet's type is shown. A wallet from the
/// older sign-in must be told apart from a social vault wallet at a glance —
/// the sign-in account alone opens the first and can never open the second —
/// so the mark has to be there for exactly those wallets, on every surface.
void main() {
  final mark = find.byKey(const ValueKey('legacy-sign-in-mark'));

  Future<void> pump(WidgetTester tester, Widget child, {ThemeData? theme}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: theme ?? MallowTheme.lightTheme,
          home: Scaffold(body: Center(child: child)),
        ),
      );

  /// The asset paths of every SVG under [finder], in paint order.
  List<String> assetsIn(WidgetTester tester, Finder finder) => [
    for (final icon in tester.widgetList<MallowSvgIcon>(
      find.descendant(of: finder, matching: find.byType(MallowSvgIcon)),
    ))
      icon.assetPath,
  ];

  // The image drawn on the legacy mark's plate.
  final markImage = find.descendant(of: mark, matching: find.byType(Image));

  BoxDecoration plateDecoration(WidgetTester tester) =>
      tester.widget<Container>(mark).decoration! as BoxDecoration;

  group('SocialProviderIcon', () {
    testWidgets('a vault wallet shows the plain provider mark', (tester) async {
      await pump(tester, const SocialProviderIcon(provider: 'google'));

      expect(mark, findsNothing);
      expect(assetsIn(tester, find.byType(SocialProviderIcon)), [
        'assets/icons/google.svg',
      ]);
      expect(
        tester.getSize(find.byType(SocialProviderIcon)),
        const Size(20, 20),
      );
    });

    testWidgets('a wallet from the older sign-in carries the mark at the '
        'bottom right of the provider mark', (tester) async {
      await pump(
        tester,
        const SocialProviderIcon(provider: 'google', legacy: true, size: 40),
      );

      expect(mark, findsOneWidget);
      expect(assetsIn(tester, find.byType(SocialProviderIcon)), [
        'assets/icons/google.svg',
      ]);
      expect(
        tester.widget<Image>(markImage).image,
        isA<AssetImage>().having(
          (a) => a.assetName,
          'assetName',
          SocialProviderIcon.legacyMarkAsset,
        ),
      );

      final provider = tester.getRect(find.byType(SvgPicture).first);
      final plate = tester.getRect(mark);
      expect(provider.size, const Size(40, 40));
      // Small, and anchored to the provider mark's bottom-right corner: it
      // overlaps that corner and reaches a little past it, and it stays
      // inside the widget so a tight row cannot clip it.
      expect(plate.width, lessThan(provider.width * 0.7));
      expect(plate.center.dx, greaterThan(provider.center.dx));
      expect(plate.center.dy, greaterThan(provider.center.dy));
      expect(plate.right, greaterThan(provider.right));
      expect(plate.bottom, greaterThan(provider.bottom));
      expect(plate.left, lessThan(provider.right));
      expect(plate.top, lessThan(provider.bottom));
      final box = tester.getRect(find.byType(SocialProviderIcon));
      expect(box.right, plate.right);
      expect(box.bottom, plate.bottom);
    });

    testWidgets('the mark is white on its own blue, in either theme', (
      tester,
    ) async {
      for (final theme in [MallowTheme.lightTheme, MallowTheme.darkTheme]) {
        await pump(
          tester,
          const SocialProviderIcon(provider: 'google', legacy: true, size: 40),
          theme: theme,
        );

        final decoration = plateDecoration(tester);
        expect(decoration.shape, BoxShape.circle);
        expect(decoration.color, const Color(0xFF0364FF));
        // The ring that separates the plate from the provider mark follows
        // the theme; the plate and the mark do not.
        final context = tester.element(find.byType(SocialProviderIcon));
        expect(
          (decoration.border! as Border).top.color,
          context.mallowColors.bgPrimary,
        );
        // Drawn as shipped: a tint would recolour someone else's mark.
        final image = tester.widget<Image>(markImage);
        expect(image.color, isNull);
      }
    });

    testWidgets('the mark sits centred in the plate with room around it', (
      tester,
    ) async {
      for (final size in [12.0, 20.0, 40.0]) {
        await pump(
          tester,
          SocialProviderIcon(provider: 'google', legacy: true, size: size),
        );

        final plate = tester.getRect(mark);
        final glyph = tester.getRect(markImage);
        expect(glyph.center.dx, closeTo(plate.center.dx, 0.01));
        expect(glyph.center.dy, closeTo(plate.center.dy, 0.01));
        // The W's top corners are the opaque pixels farthest from the image's
        // centre, 1.14 half-sides out. They must stay inside the plate's
        // one-pixel ring, or the circle clips them.
        expect(
          glyph.width / 2 * 1.14,
          lessThan(plate.width / 2 - 1),
          reason: 'size $size',
        );
      }
    });

    testWidgets('the mark is bundled with the app', (tester) async {
      // An asset that is not declared in pubspec.yaml fails silently on a
      // device: the plate would show as an empty blue dot.
      final data = await tester.runAsync(
        () => rootBundle.load(SocialProviderIcon.legacyMarkAsset),
      );
      expect(data!.lengthInBytes, greaterThan(0));
    });

    testWidgets('Apple draws the Apple mark, tinted to the theme', (
      tester,
    ) async {
      await pump(
        tester,
        const SocialProviderIcon(provider: 'apple', legacy: true),
        theme: MallowTheme.darkTheme,
      );

      final icons = tester
          .widgetList<MallowSvgIcon>(find.byType(MallowSvgIcon))
          .toList();
      expect(icons.single.assetPath, 'assets/icons/apple.svg');
      expect(icons.single.useOriginalColors, isFalse);
      final context = tester.element(find.byType(SocialProviderIcon));
      expect(icons.single.color, context.mallowColors.textPrimary);
      expect(markImage, findsOneWidget);
    });

    testWidgets('an unrecorded provider falls back to Google', (tester) async {
      await pump(tester, const SocialProviderIcon(provider: null));
      expect(assetsIn(tester, find.byType(SocialProviderIcon)), [
        'assets/icons/google.svg',
      ]);
    });
  });

  group('WalletTypeBadge', () {
    testWidgets('marks exactly the two legacy badges', (tester) async {
      for (final badge in WalletBadge.values) {
        await pump(tester, WalletTypeBadge(badge, key: ValueKey(badge)));
        final legacy =
            badge == WalletBadge.googleLegacy ||
            badge == WalletBadge.appleLegacy;
        expect(mark, legacy ? findsOneWidget : findsNothing, reason: '$badge');
      }
    });

    testWidgets('a legacy badge still shows its provider', (tester) async {
      await pump(tester, const WalletTypeBadge(WalletBadge.appleLegacy));
      expect(
        tester.widget<SocialProviderIcon>(find.byType(SocialProviderIcon)),
        isA<SocialProviderIcon>()
            .having((i) => i.provider, 'provider', 'apple')
            .having((i) => i.legacy, 'legacy', isTrue),
      );
    });

    testWidgets('a wallet row gets the mark from the model alone', (
      tester,
    ) async {
      // Every name surface renders `WalletTypeBadge(wallet.badge)`; the mark
      // must follow from the wallet, with nothing for a call site to forget.
      const older = WalletInfo(
        id: 'w',
        address: 'addr',
        name: 'Google Wallet',
        walletType: WalletType.social,
        chain: 'solana',
        socialProvider: 'google',
        legacySocial: true,
      );
      await pump(tester, WalletTypeBadge(older.badge));
      expect(mark, findsOneWidget);

      await pump(
        tester,
        WalletTypeBadge(
          older.copyWith(legacySocial: false, socialVaultId: 'v').badge,
        ),
      );
      expect(mark, findsNothing);
    });

    testWidgets('no badge renders nothing', (tester) async {
      await pump(tester, const WalletTypeBadge(null));
      expect(find.byType(MallowSvgIcon), findsNothing);
    });
  });

  group('LegacySocialNote', () {
    testWidgets('says the sentence for the wallet\'s provider, beside the '
        'marked icon', (tester) async {
      await pump(tester, const LegacySocialNote(provider: 'apple'));

      expect(
        find.text(
          'Older sign-in, run by Web3Auth: your Apple account alone can open '
          'this wallet.',
        ),
        findsOneWidget,
      );
      expect(mark, findsOneWidget);
    });
  });

  group('copy', () {
    test('the sentence is fixed, per provider', () {
      expect(
        legacySocialSentence('Google'),
        'Older sign-in, run by Web3Auth: your Google account alone can open '
        'this wallet.',
      );
      expect(legacySocialSentence('Apple'), contains('your Apple account'));
    });

    test('no copy about the older sign-in names a host', () {
      for (final text in [
        legacySocialSentence('Google'),
        legacySocialRecoverySentence,
        socialRemovalAftermath(legacy: true, hasVault: false),
      ]) {
        expect(text, isNot(matches(RegExp(r'[a-z0-9-]+\.[a-z]{2,}(/|\b)'))));
        expect(text, isNot(contains('http')));
      }
    });

    test('only a vault wallet is told signing in again brings it back', () {
      expect(
        socialRemovalAftermath(legacy: false, hasVault: true),
        contains('signing in with the same account again'),
      );
      for (final legacy in [true, false]) {
        expect(
          socialRemovalAftermath(legacy: legacy, hasVault: false),
          isNot(contains('You can add it back')),
        );
      }
      expect(
        socialRemovalAftermath(legacy: true, hasVault: false),
        contains('older sign-in on the mallow website'),
      );
      expect(
        socialRemovalAftermath(legacy: false, hasVault: false),
        isNot(contains('older sign-in')),
      );
    });
  });
}
