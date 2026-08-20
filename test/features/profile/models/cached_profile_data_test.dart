import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/models/cached_profile_data.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';

UserProfile _profile() => const UserProfile(
  address: 'AaA',
  username: 'user1',
  handle: '@user1',
  role: 'member',
  bio: 'hi',
  avatarUrl: 'https://example.test/a.png',
  followerCount: 1,
  collectorCount: 2,
  ownedArtworkCount: 3,
);

PortfolioArtwork _art(String mint, {double? lastPrice, double aspect = 1.5}) =>
    PortfolioArtwork(
      mintAccount: mint,
      title: 'Title $mint',
      imageUrl: 'https://example.test/$mint.png',
      artistName: 'Artist',
      collectionName: 'Coll',
      lastPrice: lastPrice,
      aspectRatio: aspect,
      updateAuth: 'auth-$mint',
    );

ArtGroup _group(String id, ArtGroupType type) => ArtGroup(
  id: id,
  type: type,
  name: 'Group $id',
  thumbnailUrl: 'https://example.test/$id.png',
  artworkCount: 4,
  artistAddress: 'addr',
  collectionMint: 'cm',
  creatorName: 'creator',
);

void main() {
  group('CachedProfileData.toJsonString / fromJsonString', () {
    test('roundtrips the profile, artworks, groups, and ownership lists', () {
      final original = CachedProfileData(
        profile: _profile(),
        artworks: [_art('A', lastPrice: 2.5), _art('B')],
        groups: [
          _group('g1', ArtGroupType.artist),
          _group('g2', ArtGroupType.collection),
          _group('g3', ArtGroupType.curation),
        ],
        youOwnArtworks: [_art('Y')],
        ownedArtworks: [_art('O', aspect: 2.0)],
      );

      final round = CachedProfileData.fromJsonString(original.toJsonString());

      expect(round.profile.address, original.profile.address);
      expect(round.profile.username, original.profile.username);
      expect(round.artworks.map((a) => a.mintAccount), ['A', 'B']);
      expect(round.artworks.first.lastPrice, 2.5);
      expect(round.artworks.first.aspectRatio, 1.5);
      expect(round.artworks.first.updateAuth, 'auth-A');
      expect(round.groups.map((g) => g.type), [
        ArtGroupType.artist,
        ArtGroupType.collection,
        ArtGroupType.curation,
      ]);
      expect(round.youOwnArtworks.single.mintAccount, 'Y');
      expect(round.ownedArtworks.single.mintAccount, 'O');
      expect(round.ownedArtworks.single.aspectRatio, 2.0);
    });

    test('defaults ownedArtworks to empty when the key is absent', () {
      // Forward-compat: caches written by an older client predate the
      // ownedArtworks field. Reading must not crash and must yield [].
      final legacyJson = jsonEncode({
        'profile': _profile().toJson(),
        'artworks': <Map<String, dynamic>>[],
        'groups': <Map<String, dynamic>>[],
        'youOwnArtworks': <Map<String, dynamic>>[],
      });
      final round = CachedProfileData.fromJsonString(legacyJson);
      expect(round.ownedArtworks, isEmpty);
    });

    test('preserves null optional artwork fields', () {
      final original = CachedProfileData(
        profile: _profile(),
        artworks: [
          PortfolioArtwork(
            mintAccount: 'M',
            title: 'T',
            imageUrl: 'u',
            artistName: 'A',
          ),
        ],
        groups: const [],
        youOwnArtworks: const [],
      );
      final round = CachedProfileData.fromJsonString(original.toJsonString());
      expect(round.artworks.single.collectionName, isNull);
      expect(round.artworks.single.lastPrice, isNull);
      expect(round.artworks.single.updateAuth, isNull);
      // aspectRatio defaults to 1.0 when not supplied.
      expect(round.artworks.single.aspectRatio, 1.0);
    });

    test('preserves null optional group fields', () {
      final original = CachedProfileData(
        profile: _profile(),
        artworks: const [],
        groups: [
          const ArtGroup(
            id: 'g',
            type: ArtGroupType.artist,
            name: 'n',
            thumbnailUrl: null,
            artworkCount: 0,
          ),
        ],
        youOwnArtworks: const [],
      );
      final round = CachedProfileData.fromJsonString(original.toJsonString());
      expect(round.groups.single.thumbnailUrl, isNull);
      expect(round.groups.single.artistAddress, isNull);
      expect(round.groups.single.collectionMint, isNull);
      expect(round.groups.single.creatorName, isNull);
    });
  });
}
