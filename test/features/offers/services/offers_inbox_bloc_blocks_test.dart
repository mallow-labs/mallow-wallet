import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mallow_wallet/features/offers/data/offers_inbox_repository.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';
import 'package:mocktail/mocktail.dart';

import '../../moderation/support/moderation_fakes.dart';

// A session has not always proven its wallet to the backend (a hardware or
// Seed Vault session often has not), so the inbox can arrive with a blocked
// account's offers in it. The bloc applies the block list the device holds
// to whatever arrives, and still owns up to what it withheld: an offer is
// money on the viewer's own artwork.

class _Repo extends Mock implements OffersInboxRepository {}

class _Session extends Fake implements SessionManager {
  @override
  List<String> get apiOwnerAddresses => const [_me];

  @override
  List<WalletInfo> get sessionWallets => const [
    WalletInfo(
      id: _me,
      address: _me,
      name: _me,
      walletType: WalletType.hd,
      chain: 'solana',
    ),
  ];
}

const _me = 'Viewer1111111111111111111111111111111111111';
const _blocked = 'BlockedBidder111111111111111111111111111111';
const _bidder = 'SomeBidder111111111111111111111111111111111';

api.OffersInboxItem _offer(
  String asset, {
  required String from,
  api.OffersInboxDirection direction = api.OffersInboxDirection.received,
}) => api.OffersInboxItem(
  kind: api.OffersInboxKind.offer,
  direction: direction,
  asset: asset,
  artworkTitle: asset,
  actorAddress: from,
  viewerAddress: _me,
  rawAmount: 1,
  currencyMint: 'So11111111111111111111111111111111111111112',
);

void main() {
  late _Repo repo;
  late ModerationFilter moderation;
  late BlockStore blocks;
  late ModerationHideStore hides;
  late Map<int, api.OffersInboxPage> pages;
  late int inboxReads;

  setUpAll(() {
    registerFallbackValue(api.OffersInboxSort.latest);
    registerFallbackValue(() {});
  });

  setUp(() {
    final m = moderationOver(blocked: [_blocked], own: [_me]);
    moderation = m.filter;
    blocks = m.blocks;
    hides = m.hides;
    repo = _Repo();
    pages = {};
    inboxReads = 0;
    when(
      () => repo.getInbox(
        owners: any(named: 'owners'),
        sort: any(named: 'sort'),
        page: any(named: 'page'),
      ),
    ).thenAnswer((invocation) async {
      inboxReads++;
      return pages[invocation.namedArguments[#page] as int? ?? 0] ??
          const api.OffersInboxPage();
    });
    when(() => repo.getBidRefunds(any())).thenAnswer((_) async => const []);
  });

  Future<OffersInboxBloc> load() async {
    final bloc = OffersInboxBloc(
      repo,
      _Session(),
      moderation: () => moderation,
    );
    addTearDown(bloc.close);
    bloc.add(const OffersInboxEvent.load());
    await bloc.stream.firstWhere(
      (s) => s is OffersInboxLoaded && s.items != null,
    );
    await pumpEventQueue();
    return bloc;
  }

  OffersInboxLoaded loaded(OffersInboxBloc bloc) =>
      bloc.state as OffersInboxLoaded;

  List<String> assets(OffersInboxBloc bloc) =>
      loaded(bloc).items!.map((i) => i.asset).toList();

  test('withholds a blocked account\'s offer the backend did not, and counts '
      'it in the disclosure', () async {
    pages[0] = api.OffersInboxPage(
      result: [
        _offer('a', from: _blocked),
        _offer('b', from: _bidder),
        _offer('c', from: _blocked),
      ],
    );

    final bloc = await load();

    expect(assets(bloc), ['b']);
    expect(loaded(bloc).hiddenByBlockCount, 2, reason: 'never silently');
  });

  test('adds to the backend\'s own count instead of replacing it', () async {
    pages[0] = api.OffersInboxPage(
      result: [
        _offer('a', from: _blocked),
        _offer('b', from: _bidder),
      ],
      hiddenByBlockCount: 3,
    );

    final bloc = await load();

    expect(loaded(bloc).hiddenByBlockCount, 4);
  });

  // On a placed row the actor is the viewer's own wallet. Their own offers
  // and bids are theirs to see, whoever made the artwork.
  test('never withholds what the viewer placed', () async {
    pages[0] = api.OffersInboxPage(
      result: [
        _offer('mine', from: _me, direction: api.OffersInboxDirection.placed),
        // Even a placed row that names a blocked actor is left alone.
        _offer(
          'odd',
          from: _blocked,
          direction: api.OffersInboxDirection.placed,
        ),
      ],
    );

    final bloc = await load();

    expect(assets(bloc), ['mine', 'odd']);
    expect(loaded(bloc).hiddenByBlockCount, 0);
  });

  // A report says "someone should look at this". It must not make money on
  // the viewer's artwork disappear under a row that says "blocked".
  test('a report alone withholds nothing', () async {
    hides.hide(api.ReportTargetType.user, _bidder);
    pages[0] = api.OffersInboxPage(result: [_offer('b', from: _bidder)]);

    final bloc = await load();

    expect(assets(bloc), ['b']);
    expect(loaded(bloc).hiddenByBlockCount, 0);
  });

  test(
    'filters later pages too, keeps the cursor, and keeps counting',
    () async {
      pages[0] = api.OffersInboxPage(
        result: [
          _offer('a', from: _blocked),
          _offer('b', from: _bidder),
        ],
        nextPage: 1,
      );
      pages[1] = api.OffersInboxPage(
        result: [
          _offer('c', from: _blocked),
          _offer('d', from: _bidder),
        ],
      );
      final bloc = await load();
      expect(loaded(bloc).hasMore, isTrue);

      bloc.add(const OffersInboxEvent.loadMore());
      await pumpEventQueue();

      expect(assets(bloc), ['b', 'd']);
      expect(loaded(bloc).hiddenByBlockCount, 2);
      expect(loaded(bloc).hasMore, isFalse);
    },
  );

  // A page of nothing but blocked offers must not end the feed: the screen
  // keeps paging while there is a cursor.
  test('a page left empty by the filter still reports more to load', () async {
    pages[0] = api.OffersInboxPage(
      result: [_offer('a', from: _blocked)],
      nextPage: 1,
    );
    pages[1] = api.OffersInboxPage(result: [_offer('b', from: _bidder)]);

    final bloc = await load();

    expect(assets(bloc), isEmpty);
    expect(loaded(bloc).hasMore, isTrue);
    expect(loaded(bloc).hiddenByBlockCount, 1);
  });

  test('a refresh does not count the same rows twice', () async {
    pages[0] = api.OffersInboxPage(
      result: [
        _offer('a', from: _blocked),
        _offer('b', from: _bidder),
      ],
    );
    final bloc = await load();

    bloc.add(const OffersInboxEvent.refresh());
    await pumpEventQueue();

    expect(loaded(bloc).hiddenByBlockCount, 1);
  });

  group('a block made while the inbox is on screen', () {
    test('refetches, and the new account\'s rows are withheld', () async {
      pages[0] = api.OffersInboxPage(
        result: [
          _offer('b', from: _bidder),
          _offer('e', from: 'OtherBidder'),
        ],
      );
      final bloc = await load();
      expect(assets(bloc), ['b', 'e']);
      final readsBefore = inboxReads;

      blocks.blocked.value = {_blocked, _bidder};
      await pumpEventQueue();

      expect(inboxReads, readsBefore + 1);
      expect(assets(bloc), ['e']);
      expect(loaded(bloc).hiddenByBlockCount, 1);
    });

    test('does not refetch when the blocked account has no row here', () async {
      pages[0] = api.OffersInboxPage(result: [_offer('b', from: _bidder)]);
      final bloc = await load();
      final readsBefore = inboxReads;

      blocks.blocked.value = {_blocked, 'NobodyHere'};
      await pumpEventQueue();

      expect(inboxReads, readsBefore);
      expect(assets(bloc), ['b']);
    });
  });
}
