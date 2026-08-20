import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/send/models/recent_recipient.dart';

void main() {
  group('RecentRecipient.displayName', () {
    const address = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

    test('prefers the mallow username over accountName when both are set', () {
      // The username is the recipient's public identity — the name that also
      // labels them on their profile and on the web — while `Account NN` is a
      // local label that identifies nobody. The confirm step and the artwork
      // transfer flow order these the same way, so one recipient cannot be
      // named one thing here and another on the review screen.
      const r = RecentRecipient(
        address: address,
        username: 'mallowuser',
        accountName: 'Account 1',
      );
      expect(r.displayName, 'mallowuser');
    });

    test('falls back to accountName when the address has no profile', () {
      const r = RecentRecipient(address: address, accountName: 'Account 1');
      expect(r.displayName, 'Account 1');
    });

    test('returns null when neither accountName nor username is set', () {
      const r = RecentRecipient(address: address);
      expect(r.displayName, isNull);
    });

    test('returns the username even when accountName is also null', () {
      const r = RecentRecipient(address: address, username: 'mallowuser');
      expect(r.displayName, 'mallowuser');
    });
  });

  group('RecentRecipient.copyWith', () {
    const address = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

    test('address is always preserved', () {
      const r = RecentRecipient(address: address, username: 'user1');
      final r2 = r.copyWith(username: 'user2');
      expect(r2.address, address);
    });

    test('copyWith replaces only specified fields', () {
      const r = RecentRecipient(
        address: address,
        username: 'user1',
        imageUrl: 'https://example.com/pfp.jpg',
        accountName: 'Account 1',
        accountAvatarSeed: 'seed-abc',
      );

      final r2 = r.copyWith(username: 'user2');
      expect(r2.username, 'user2');
      expect(r2.imageUrl, 'https://example.com/pfp.jpg');
      expect(r2.accountName, 'Account 1');
      expect(r2.accountAvatarSeed, 'seed-abc');
    });

    test(
      'copyWith with null arg preserves existing field (uses ?? semantics)',
      () {
        // The implementation uses `accountName ?? this.accountName`, so passing
        // null for accountName keeps the existing value — it does NOT null it out.
        const r = RecentRecipient(
          address: address,
          accountName: 'Account 1',
          username: 'user1',
        );
        final r2 = r.copyWith();
        expect(r2.accountName, 'Account 1');
        // Both survive the copy; the username is the one that gets shown.
        expect(r2.displayName, 'user1');
      },
    );

    test('enriching an address-only entry with a profile username', () {
      const r = RecentRecipient(address: address);
      final enriched = r.copyWith(
        username: 'artist',
        imageUrl: 'https://cdn.example.com/pfp.webp',
      );
      expect(enriched.displayName, 'artist');
      expect(enriched.imageUrl, 'https://cdn.example.com/pfp.webp');
    });
  });
}
