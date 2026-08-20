import 'package:mallow_wallet/core/database/database.dart';
import 'package:mocktail/mocktail.dart';

/// A [MallowDatabase] stand-in for tests that build a `TokenMetadataService`
/// without caring about its cached-Jupiter-list source.
///
/// The verified-list lookup it runs ahead of DAS always misses here, so the
/// service behaves exactly as it did before that source existed. Every other
/// member throws ([Fake]), so a test that starts depending on the database
/// fails loudly instead of quietly reading an empty one.
class NoVerifiedListDatabase extends Fake implements MallowDatabase {
  @override
  Future<CachedJupiterTokenListData?> getJupiterTokenListEntry(String mint) =>
      Future.value();
}
