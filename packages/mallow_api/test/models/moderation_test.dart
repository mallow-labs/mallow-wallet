import 'dart:convert';

import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  // The report taxonomy is a *closed* set the backend validates against.
  // Field names are
  // camelCase like the rest of the v2 wire, but the enum **values** are
  // snake_case — a distinction that is easy to lose to a blanket rename
  // convention, and one that fails at runtime (400) rather than at compile
  // time. These tests pin both halves.
  group('ReportRequest wire payload', () {
    test('serializes with camelCase keys and snake_case enum values', () {
      final request = ReportRequest(
        targetType: ReportTargetType.artwork,
        targetId: 'MINT',
        reason: ReportReason.copyrightImpersonation,
        note: 'looks like a stolen piece',
        context: const ReportContext(
          screen: 'artwork_detail',
          appVersion: '0.11.0+14',
          platform: 'ios',
        ).toJson(),
      );

      final wire = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

      expect(wire['targetType'], 'artwork');
      expect(wire['targetId'], 'MINT');
      expect(wire['reason'], 'copyright_impersonation');
      expect(wire['note'], 'looks like a stolen piece');

      final context = wire['context'] as Map<String, dynamic>;
      expect(context['appVersion'], '0.11.0+14');
      expect(context['platform'], 'ios');

      // The snake_case field names the backend never reads must be absent.
      expect(wire.containsKey('target_type'), isFalse);
      expect(wire.containsKey('target_id'), isFalse);
    });

    test('every reason maps to its exact backend wire value', () {
      // Written out longhand rather than derived from the enum: a test that
      // reads the value off the same enum it is checking cannot fail when the
      // value changes, which is the whole point of pinning it.
      const expected = {
        ReportReason.sexualContent: 'sexual_content',
        ReportReason.violenceGore: 'violence_gore',
        ReportReason.hate: 'hate',
        ReportReason.spamScam: 'spam_scam',
        ReportReason.copyrightImpersonation: 'copyright_impersonation',
        ReportReason.other: 'other',
      };

      // Guards against a member being added without a pinned wire value.
      // `swaggerGeneratedUnknown` is the generator's placeholder for values the
      // spec doesn't list — it is never sent, so it carries no wire value.
      expect(expected.keys, containsAll(reportableReasons));

      for (final entry in expected.entries) {
        final wire =
            jsonDecode(
                  jsonEncode(
                    ReportRequest(
                      targetType: ReportTargetType.user,
                      targetId: 'ADDR',
                      reason: entry.key,
                    ),
                  ),
                )
                as Map<String, dynamic>;
        expect(wire['reason'], entry.value, reason: '${entry.key} wire value');
      }
    });

    test('every target type maps to its exact backend wire value', () {
      const expected = {
        ReportTargetType.artwork: 'artwork',
        ReportTargetType.user: 'user',
        ReportTargetType.curation: 'curation',
      };

      expect(expected.keys, containsAll(reportableTargetTypes));

      for (final entry in expected.entries) {
        final wire =
            jsonDecode(
                  jsonEncode(
                    ReportRequest(
                      targetType: entry.key,
                      targetId: 'ID',
                      reason: ReportReason.other,
                    ),
                  ),
                )
                as Map<String, dynamic>;
        expect(wire['targetType'], entry.value, reason: '${entry.key} wire value');
      }
    });
  });

  group('BlockRequest wire payload', () {
    test('sends the address under the camelCase key the backend reads', () {
      final wire =
          jsonDecode(jsonEncode(const BlockRequest(address: 'ADDR'))) as Map<String, dynamic>;

      expect(wire['address'], 'ADDR');
    });
  });

  group('BlockedAccount', () {
    // `address` and `createdAt` are `required` in the spec, so the generated
    // model throws on a row missing either. That is the intended contract: the
    // profile fields are what vary (a blocked address may have no mallow user),
    // not the identity of the block itself. A row without an address could not
    // be unblocked anyway.
    test('parses a row with no profile fields', () {
      final account = BlockedAccount.fromJson(const {
        'address': 'ADDR',
        'createdAt': '2026-07-31T00:00:00.000Z',
      });

      expect(account.address, 'ADDR');
      expect(account.username, isNull);
      expect(account.displayName, isNull);
      expect(account.imageUrl, isNull);
    });

    test('parses a fully populated row with camelCase keys', () {
      final account = BlockedAccount.fromJson(const {
        'address': 'ADDR',
        'username': 'someone',
        'displayName': 'Some One',
        'imageUrl': 'https://cdn.example/a.png',
        'createdAt': '2026-07-31T00:00:00.000Z',
      });

      expect(account.username, 'someone');
      expect(account.displayName, 'Some One');
      expect(account.imageUrl, 'https://cdn.example/a.png');
      expect(account.createdAt, '2026-07-31T00:00:00.000Z');
    });
  });

  group('OffersInboxPage.hiddenByBlockCount', () {
    // Defaults to 0 so a backend that predates the block filter — or a cached
    // response — degrades to "nothing hidden" rather than throwing.
    test('defaults to 0 when the backend omits it', () {
      final page = OffersInboxPage.fromJson(const {'result': <dynamic>[]});

      expect(page.hiddenByBlockCount, 0);
    });

    test('reads the count when present', () {
      final page = OffersInboxPage.fromJson(const {'result': <dynamic>[], 'hiddenByBlockCount': 3});

      expect(page.hiddenByBlockCount, 3);
    });
  });
}
