import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/collection/services/manage_collection_artworks_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/solana.dart';

import 'manage_collection_artworks_bloc_test.mocks.dart';

const _collection = 'Co11ection1111111111111111111111111111111111';
const _authority = 'Auth1111111111111111111111111111111111111111';
const _oneOfOne = 'One1111111111111111111111111111111111111111';
const _masterEd = 'Master11111111111111111111111111111111111111';
const _member = 'Member11111111111111111111111111111111111111';

/// The collection's on-chain update authority — a **different** session wallet
/// than the active signer ([_authority]). Creator status spans the whole
/// session, so this screen is reachable while a wallet that does not administer
/// the collection is active.
const _creator = 'Creator11111111111111111111111111111111111111';

/// The active signer at submit time (what `getAddress()` reports pre-switch).
const _activeWallet = WalletInfo(
  id: 'active-wallet',
  address: _authority,
  name: 'active',
  walletType: WalletType.hd,
  chain: 'solana',
  accountId: 'acct',
);

/// The signable session wallet that administers the collection.
const _creatorWallet = WalletInfo(
  id: 'creator-wallet',
  address: _creator,
  name: 'creator',
  walletType: WalletType.hd,
  chain: 'solana',
  accountId: 'acct',
);

/// The same collection authority held only as a watch-only session wallet.
const _watchOnlyCreatorWallet = WalletInfo(
  id: 'creator-watch-only',
  address: _creator,
  name: 'creator (watch-only)',
  walletType: WalletType.viewOnly,
  chain: 'solana',
  accountId: 'acct',
);

/// A 1/1 asset (maxSupply 1 → not a master edition → routes into addAssets).
PortfolioArtwork _asset(String mint) => PortfolioArtwork(
  mintAccount: mint,
  title: mint,
  imageUrl: '',
  artistName: '',
  maxSupply: 1,
);

/// A limited-edition master (maxSupply > 1 → master edition → addMasterEditions).
PortfolioArtwork _master(String mint) => PortfolioArtwork(
  mintAccount: mint,
  title: mint,
  imageUrl: '',
  artistName: '',
  maxSupply: 10,
);

@GenerateMocks([
  PortfolioRepository,
  UserProfileRepository,
  WalletManager,
  TransactionExecutor,
  MallowApiV2Client,
  SessionManager,
  AuthService,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    provideDummy<Result<String, AppFailure>>(
      const ResultFailure(AppFailure.unknown('dummy')),
    );
    provideDummy<ApiResponse<EditCollectionArtworksResponse>>(
      const ApiResponse<EditCollectionArtworksResponse>(
        result: EditCollectionArtworksResponse(txs: []),
      ),
    );
  });

  late MockPortfolioRepository portfolio;
  late MockUserProfileRepository profile;
  late MockWalletManager walletManager;
  late MockTransactionExecutor executor;
  late MockMallowApiV2Client apiV2;
  late MockSessionManager session;
  late MockAuthService auth;

  setUp(() {
    portfolio = MockPortfolioRepository();
    profile = MockUserProfileRepository();
    walletManager = MockWalletManager();
    executor = MockTransactionExecutor();
    apiV2 = MockMallowApiV2Client();
    session = MockSessionManager();
    auth = MockAuthService();

    // The pre-sign switch and its snapshot/restore resolve both services
    // through the global locator (as `ensure_signer` does).
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<AuthService>(auth);
    when(auth.currentAddress).thenReturn(_authority);
    // Default: no address resolves to a session wallet → no switch.
    when(session.sessionWalletForAddress(any)).thenReturn(null);
    when(session.resolveWalletForAddress(any)).thenReturn(null);
    when(session.selectSourceWallet(any)).thenAnswer((_) async {});

    // Candidate list = the art the signer *created* (their updateAuth) — a 1/1
    // and a master edition. Sourced from the byUpdateAuth query, not ownership,
    // so collected-from-others art (which would revert on-chain) is excluded.
    when(
      portfolio.getArtworksByUpdateAuth(
        masterOnly: anyNamed('masterOnly'),
        tokenStandards: anyNamed('tokenStandards'),
      ),
    ).thenAnswer((_) async => [_asset(_oneOfOne), _master(_masterEd)]);
    // Default: no members (brand-new / unresolved collection → add-only).
    // A null collection also means an unknown standard → treated as legacy
    // (assets-only, fail-closed), see the master-edition split tests below.
    when(profile.getCollectionByMint(any)).thenAnswer((_) async => null);
    // No current members by default (brand-new / empty collection → add-only);
    // the removal test overrides this. Members now come from the mint-keyed
    // getMintAccounts endpoint, not a slug-scoped page.
    when(
      profile.getCollectionMintAccounts(any),
    ).thenAnswer((_) async => const []);
    when(profile.reindexCollectionArtworks(any)).thenAnswer((_) async {});
    when(walletManager.getAddress()).thenAnswer((_) async => _authority);
    when(walletManager.isLocalSigner()).thenAnswer((_) async => true);
  });

  tearDown(() {
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
  });

  /// Stub a resolved **Core** parent collection, so the bloc splits printable
  /// masters into `addMasterEditions` (mpl-core Group ops) rather than assets.
  void stubCoreParent() {
    when(profile.getCollectionByMint(_collection)).thenAnswer(
      (_) async => const CollectionFullRender(
        slug: 'c',
        name: 'C',
        nft: CollectionDetailNft(
          mintAccount: _collection,
          tokenStandard: TokenStandard.coreCollection,
        ),
      ),
    );
  }

  ManageCollectionArtworksBloc build() => ManageCollectionArtworksBloc(
    portfolio,
    profile,
    walletManager,
    executor,
    apiV2,
  );

  void stubTxBuild() {
    when(apiV2.editCollectionArtworksTx(any)).thenAnswer(
      (_) async => const ApiResponse<EditCollectionArtworksResponse>(
        result: EditCollectionArtworksResponse(
          txs: [UnsignedTxResponse(tx: 'dHgx')],
        ),
      ),
    );
    when(
      executor.execute(
        txsBase64: anyNamed('txsBase64'),
        usdValue: anyNamed('usdValue'),
        flow: anyNamed('flow'),
        additionalSigners: anyNamed('additionalSigners'),
        onStage: anyNamed('onStage'),
      ),
    ).thenAnswer((_) async => const ResultSuccess('sig'));
  }

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'started loads the owned artworks as candidates',
    build: build,
    act: (b) => b.add(const ManageCollectionArtworksEvent.started(_collection)),
    skip: 1, // the interim isLoading:true emit
    expect: () => [
      isA<ManageCollectionArtworksState>()
          .having((s) => s.isLoading, 'isLoading', false)
          .having((s) => s.artworks.length, 'artworks', 2)
          .having((s) => s.memberMints, 'memberMints', isEmpty),
    ],
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'adding a 1/1 sends it as addAssets with no groupSigner',
    setUp: stubTxBuild,
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (_) {
      final req =
          verify(apiV2.editCollectionArtworksTx(captureAny)).captured.single
              as EditCollectionArtworksRequest;
      expect(req.authority, _authority);
      expect(req.parentCollection, _collection);
      expect(req.addAssets, [_oneOfOne]);
      expect(req.addMasterEditions ?? const [], isEmpty);
      // No master edition added → no lazy group → no group signer.
      expect(req.groupSigner, isNull);
      final signers =
          verify(
                executor.execute(
                  txsBase64: anyNamed('txsBase64'),
                  usdValue: anyNamed('usdValue'),
                  flow: anyNamed('flow'),
                  additionalSigners: captureAnyNamed('additionalSigners'),
                  onStage: anyNamed('onStage'),
                ),
              ).captured.single
              as List<Ed25519HDKeyPair>;
      expect(signers, isEmpty);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'adding a master edition sends addMasterEditions + a groupSigner keypair',
    setUp: () {
      stubTxBuild();
      // Master editions are a Core-only concept — only a Core parent buckets
      // them into addMasterEditions (see the legacy variant below).
      stubCoreParent();
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_masterEd));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (_) {
      final req =
          verify(apiV2.editCollectionArtworksTx(captureAny)).captured.single
              as EditCollectionArtworksRequest;
      expect(req.addMasterEditions, [_masterEd]);
      expect(req.addAssets ?? const [], isEmpty);
      // A group keypair is generated and its pubkey sent, and the keypair is
      // handed to the executor to co-sign the (possible) CreateGroupV1 chunk.
      expect(req.groupSigner, isNotNull);
      final signers =
          verify(
                executor.execute(
                  txsBase64: anyNamed('txsBase64'),
                  usdValue: anyNamed('usdValue'),
                  flow: anyNamed('flow'),
                  additionalSigners: captureAnyNamed('additionalSigners'),
                  onStage: anyNamed('onStage'),
                ),
              ).captured.single
              as List<Ed25519HDKeyPair>;
      expect(signers.length, 1);
      expect(signers.single.publicKey.toBase58(), req.groupSigner);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // The backend hard-rejects add/removeMasterEditions for a legacy
    // token-metadata parent (400s the whole batch — master editions / Groups
    // don't exist there); it verifies every move as a plain asset instead. So
    // for a non-Core parent a printable master must go out as addAssets, never
    // as a master-edition list, and no lazy Group is created.
    'legacy parent routes a master edition into addAssets, not a ME list',
    setUp: () {
      stubTxBuild();
      // Legacy parent: resolved collection with a token-metadata standard.
      when(profile.getCollectionByMint(_collection)).thenAnswer(
        (_) async => const CollectionFullRender(
          slug: 'c',
          name: 'C',
          nft: CollectionDetailNft(
            mintAccount: _collection,
            tokenStandard: TokenStandard.nft,
          ),
        ),
      );
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_masterEd));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (_) {
      final req =
          verify(apiV2.editCollectionArtworksTx(captureAny)).captured.single
              as EditCollectionArtworksRequest;
      expect(req.addAssets, [_masterEd]);
      expect(req.addMasterEditions ?? const [], isEmpty);
      expect(req.removeMasterEditions ?? const [], isEmpty);
      // No master-edition list → no lazy Group → no group signer co-signs.
      expect(req.groupSigner, isNull);
      final signers =
          verify(
                executor.execute(
                  txsBase64: anyNamed('txsBase64'),
                  usdValue: anyNamed('usdValue'),
                  flow: anyNamed('flow'),
                  additionalSigners: captureAnyNamed('additionalSigners'),
                  onStage: anyNamed('onStage'),
                ),
              ).captured.single
              as List<Ed25519HDKeyPair>;
      expect(signers, isEmpty);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // A candidate whose token standard doesn't match the parent's 400s the
    // whole edit batch server-side, so candidates are queried scoped to the
    // parent's standard. A Core *collection* holds Core *assets*, so a
    // core-collection parent must query for `core` (not `core-collection`).
    'scopes the candidate query to the parent standard (core-collection → core)',
    setUp: stubCoreParent,
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
    },
    verify: (_) {
      final standards =
          verify(
                portfolio.getArtworksByUpdateAuth(
                  masterOnly: anyNamed('masterOnly'),
                  tokenStandards: captureAnyNamed('tokenStandards'),
                ),
              ).captured.single
              as List<String>?;
      expect(standards, ['core']);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // An unresolved / legacy parent queries for its own (legacy `nft`)
    // standard — never `core-collection`, which would return nothing.
    'scopes the candidate query to nft for an unresolved parent',
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
    },
    verify: (_) {
      final standards =
          verify(
                portfolio.getArtworksByUpdateAuth(
                  masterOnly: anyNamed('masterOnly'),
                  tokenStandards: captureAnyNamed('tokenStandards'),
                ),
              ).captured.single
              as List<String>?;
      expect(standards, ['nft']);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'unchecking a current member sends it as removeAssets',
    setUp: () {
      stubTxBuild();
      when(profile.getCollectionByMint(_collection)).thenAnswer(
        (_) async => const CollectionFullRender(slug: 'c', name: 'C'),
      );
      // The member is both an indexed collection member AND one of the
      // signer's update-auth artworks — the only members that are displayed
      // (and therefore removable), exactly as on web. A member the signer
      // can't sign for wouldn't appear and would revert on-chain anyway.
      when(
        profile.getCollectionMintAccounts(_collection),
      ).thenAnswer((_) async => const [_member]);
      when(
        portfolio.getArtworksByUpdateAuth(
          masterOnly: anyNamed('masterOnly'),
          tokenStandards: anyNamed('tokenStandards'),
        ),
      ).thenAnswer((_) async => [_asset(_oneOfOne), _asset(_member)]);
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      // The member loads pre-selected; unchecking it queues the removal.
      b.add(const ManageCollectionArtworksEvent.toggled(_member));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (_) {
      final req =
          verify(apiV2.editCollectionArtworksTx(captureAny)).captured.single
              as EditCollectionArtworksRequest;
      expect(req.removeAssets, [_member]);
      expect(req.addAssets ?? const [], isEmpty);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'a signing failure surfaces as an error status',
    setUp: () {
      when(apiV2.editCollectionArtworksTx(any)).thenAnswer(
        (_) async => const ApiResponse<EditCollectionArtworksResponse>(
          result: EditCollectionArtworksResponse(
            txs: [UnsignedTxResponse(tx: 'dHgx')],
          ),
        ),
      );
      when(
        executor.execute(
          txsBase64: anyNamed('txsBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onStage: anyNamed('onStage'),
        ),
      ).thenAnswer(
        (_) async => const ResultFailure(AppFailure.unknown('nope')),
      );
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) => expect(b.state.txStatus, ManageArtworksTxStatus.error),
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'a kill from the signing backstop lands on txFailure so the screen shows '
    'the operator copy instead of "Could not update collection"',
    setUp: () {
      when(apiV2.editCollectionArtworksTx(any)).thenAnswer(
        (_) async => const ApiResponse<EditCollectionArtworksResponse>(
          result: EditCollectionArtworksResponse(
            txs: [UnsignedTxResponse(tx: 'dHgx')],
          ),
        ),
      );
      when(
        executor.execute(
          txsBase64: anyNamed('txsBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onStage: anyNamed('onStage'),
        ),
      ).thenAnswer(
        (_) async => const ResultFailure(
          AppFailure.flowDisabled('Collection edits are paused.'),
        ),
      );
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) {
      // The kind is what the screen branches on: a bare `txError` can't tell a
      // kill from a real failure, and the pipeline's generic error body (with
      // its Retry, which could only fail again) would swallow the operator's
      // copy.
      expect(b.state.txFailure?.isFlowDisabled, isTrue);
      expect(b.state.txError, 'Collection edits are paused.');
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    'dismissError clears txFailure alongside txError',
    setUp: () {
      when(apiV2.editCollectionArtworksTx(any)).thenAnswer(
        (_) async => const ApiResponse<EditCollectionArtworksResponse>(
          result: EditCollectionArtworksResponse(
            txs: [UnsignedTxResponse(tx: 'dHgx')],
          ),
        ),
      );
      when(
        executor.execute(
          txsBase64: anyNamed('txsBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onStage: anyNamed('onStage'),
        ),
      ).thenAnswer(
        (_) async => const ResultFailure(
          AppFailure.flowDisabled('Collection edits are paused.'),
        ),
      );
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.dismissError());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) {
      expect(b.state.txStatus, ManageArtworksTxStatus.idle);
      expect(b.state.txFailure, isNull);
      expect(b.state.txError, isNull);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // The backend returns 200 with an empty batch when every requested move is
    // already a no-op (it skips adds already in the target). That is benign
    // success — mirror the reference web client's "No updates required", not an error
    // sheet. The pipeline must show success WITHOUT ever asking the user to
    // sign, since there is no transaction and no signature.
    'an empty tx batch lands on success without signing or broadcasting',
    setUp: () {
      when(apiV2.editCollectionArtworksTx(any)).thenAnswer(
        (_) async => const ApiResponse<EditCollectionArtworksResponse>(
          result: EditCollectionArtworksResponse(txs: []),
        ),
      );
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) {
      expect(b.state.txStatus, ManageArtworksTxStatus.success);
      // No signature exists for a no-op, and the executor must never run.
      expect(b.state.signature, isNull);
      verifyNever(
        executor.execute(
          txsBase64: anyNamed('txsBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onStage: anyNamed('onStage'),
        ),
      );
      // Nothing landed on chain → nothing to reconcile.
      verifyNever(profile.reindexCollectionArtworks(any));
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // Members seed the removal set (removed = members − selected). A silent
    // empty-on-failure would make every established collection look empty —
    // structurally disabling removal and hiding a transient outage. A non-404
    // members failure must surface the load error / retry path instead.
    'a members-fetch failure surfaces a load error',
    setUp: () {
      when(
        profile.getCollectionMintAccounts(_collection),
      ).thenThrow(Exception('members endpoint 500'));
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) {
      expect(b.state.isLoading, false);
      expect(b.state.loadError, isNotNull);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // After a tx lands, the membership tables are otherwise only updated by the
    // lagging webhook indexer (on devnet often never), and the collection
    // screen refetches on return — so without a synchronous reindex the add
    // looks like it failed. The bloc must POST updateArtworks on success.
    'a successful edit reindexes the collection artworks',
    setUp: stubTxBuild,
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) {
      expect(b.state.txStatus, ManageArtworksTxStatus.success);
      verify(profile.reindexCollectionArtworks(_collection)).called(1);
    },
  );

  blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
    // The reindex is a best-effort post-step: the tx already landed, so a
    // reindex failure must NOT downgrade a confirmed success to an error.
    'a reindex failure does not break a landed success',
    setUp: () {
      stubTxBuild();
      when(
        profile.reindexCollectionArtworks(any),
      ).thenThrow(Exception('reindex 500'));
    },
    build: build,
    act: (b) async {
      b.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      b.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(Duration.zero);
    },
    verify: (b) => expect(b.state.txStatus, ManageArtworksTxStatus.success),
  );

  // A session spans several wallets and "is this collection mine?" is widened
  // across all of them, so the screen opens for a collection administered by a
  // wallet other than the active signer. `EditCollectionArtworksRequest
  // .authority` must then carry the *administering* wallet — signing as the
  // active one has the backend/chain reject every move. The bloc has no
  // BuildContext, so it mirrors the mint bloc's pre-sign switch.
  group('collection authority signer switch', () {
    /// Stub the collection as administered by [_creator] — a signable session
    /// wallet that is NOT the active signer. `getAddress()` and
    /// `currentAddress` both flip once the switch lands, mirroring what the
    /// app-level session listener does in production (and letting
    /// `restoreSigner`'s "already active" short-circuit see a real change).
    void stubNonActiveCreator() {
      when(profile.getCollectionByMint(_collection)).thenAnswer(
        (_) async => const CollectionFullRender(
          slug: 'c',
          name: 'C',
          creatorAddress: _creator,
        ),
      );
      when(
        session.sessionWalletForAddress(_creator),
      ).thenReturn(_creatorWallet);
      when(
        session.resolveWalletForAddress(_creator),
      ).thenReturn(_creatorWallet);
      when(
        session.sessionWalletForAddress(_authority),
      ).thenReturn(_activeWallet);
      when(
        session.resolveWalletForAddress(_authority),
      ).thenReturn(_activeWallet);
      when(session.selectSourceWallet(_creatorWallet)).thenAnswer((_) async {
        when(walletManager.getAddress()).thenAnswer((_) async => _creator);
        when(auth.currentAddress).thenReturn(_creator);
      });
    }

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      'builds the request with the administering wallet as authority when it '
      'is a non-active session wallet',
      setUp: () {
        stubTxBuild();
        stubNonActiveCreator();
      },
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
        b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
        b.add(const ManageCollectionArtworksEvent.submit());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        verify(session.selectSourceWallet(_creatorWallet)).called(1);
        final req =
            verify(apiV2.editCollectionArtworksTx(captureAny)).captured.single
                as EditCollectionArtworksRequest;
        // The wire authority is the collection's wallet, not the active one.
        // Asserting only that `selectSourceWallet` was called would pass even
        // if the request were still built for the pre-switch signer.
        expect(req.authority, _creator);
      },
    );

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      // The switch is durable (selectSourceWallet persists it), so a flow the
      // user abandons at the auth gate — or one the backend rejects — must not
      // leave the app-wide active wallet silently re-pointed.
      'restores the pre-submit signer when the tx build fails after the switch',
      setUp: () {
        stubNonActiveCreator();
        when(
          apiV2.editCollectionArtworksTx(any),
        ).thenThrow(Exception('build 500'));
      },
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
        b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
        b.add(const ManageCollectionArtworksEvent.submit());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        expect(b.state.txStatus, ManageArtworksTxStatus.error);
        verify(session.selectSourceWallet(_creatorWallet)).called(1);
        verify(session.selectSourceWallet(_activeWallet)).called(1);
      },
    );

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      // Cancelling the biometric/auth gate surfaces as an executor failure and
      // lands on the same restore path — the common "user changed their mind"
      // case, which happens *after* the durable switch.
      'restores the pre-submit signer when signing is cancelled/fails',
      setUp: () {
        stubTxBuild();
        stubNonActiveCreator();
        when(
          executor.execute(
            txsBase64: anyNamed('txsBase64'),
            usdValue: anyNamed('usdValue'),
            flow: anyNamed('flow'),
            additionalSigners: anyNamed('additionalSigners'),
            onStage: anyNamed('onStage'),
          ),
        ).thenAnswer(
          (_) async => const ResultFailure(AppFailure.unknown('cancelled')),
        );
      },
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
        b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
        b.add(const ManageCollectionArtworksEvent.submit());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        verify(session.selectSourceWallet(_creatorWallet)).called(1);
        verify(session.selectSourceWallet(_activeWallet)).called(1);
      },
    );

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      // A confirmed edit intentionally leaves the signer on the authority —
      // the transfer/burn/mint convention. Only the forward switch happens.
      'keeps the signer switched on a successful edit',
      setUp: () {
        stubTxBuild();
        stubNonActiveCreator();
      },
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
        b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
        b.add(const ManageCollectionArtworksEvent.submit());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        expect(b.state.txStatus, ManageArtworksTxStatus.success);
        verify(session.selectSourceWallet(_creatorWallet)).called(1);
        verifyNever(session.selectSourceWallet(_activeWallet));
      },
    );

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      // The active wallet already administers the collection — switching would
      // be a pointless durable re-point of the user's app-wide wallet.
      'does not switch when the active wallet already is the authority',
      setUp: () {
        stubTxBuild();
        when(profile.getCollectionByMint(_collection)).thenAnswer(
          (_) async => const CollectionFullRender(
            slug: 'c',
            name: 'C',
            creatorAddress: _authority,
          ),
        );
        when(
          session.sessionWalletForAddress(_authority),
        ).thenReturn(_activeWallet);
        when(
          session.resolveWalletForAddress(_authority),
        ).thenReturn(_activeWallet);
      },
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
        b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
        b.add(const ManageCollectionArtworksEvent.submit());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        verifyNever(session.selectSourceWallet(any));
        final req =
            verify(apiV2.editCollectionArtworksTx(captureAny)).captured.single
                as EditCollectionArtworksRequest;
        expect(req.authority, _authority);
      },
    );

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      // A watch-only authority can't sign at all, so the bloc must never
      // re-point to it — that gate (route to import) belongs to the screen's
      // `ensureSignerAvailable` call, which runs before any submit.
      'never switches to a watch-only authority',
      setUp: () {
        stubTxBuild();
        when(profile.getCollectionByMint(_collection)).thenAnswer(
          (_) async => const CollectionFullRender(
            slug: 'c',
            name: 'C',
            creatorAddress: _creator,
          ),
        );
        when(
          session.sessionWalletForAddress(_creator),
        ).thenReturn(_watchOnlyCreatorWallet);
        when(
          session.resolveWalletForAddress(_creator),
        ).thenReturn(_watchOnlyCreatorWallet);
      },
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
        b.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
        b.add(const ManageCollectionArtworksEvent.submit());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) => verifyNever(session.selectSourceWallet(any)),
    );

    blocTest<ManageCollectionArtworksBloc, ManageCollectionArtworksState>(
      // The authority the screen gates on is exposed from the load step; an
      // unresolved collection leaves it null so submit falls back to the active
      // wallet unchanged (the pre-existing behaviour).
      'exposes the collection authority on the loaded state',
      setUp: stubNonActiveCreator,
      build: build,
      act: (b) async {
        b.add(const ManageCollectionArtworksEvent.started(_collection));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) => expect(b.state.authority, _creator),
    );
  });

  test(
    // In a multi-tx batch (the lazy CreateGroupV1 chunk makes this the norm),
    // each tx fires its own approval event. After tx-0 broadcasts, tx-1's
    // approval must revert the sheet to the signing phase — otherwise a Ledger
    // user awaiting device approval for tx-1 is stuck reading tx-0's
    // "Confirming transaction". This is the marketplace_action_flow behaviour.
    'a second approval after a broadcast reverts to the signing phase',
    () async {
      when(apiV2.editCollectionArtworksTx(any)).thenAnswer(
        (_) async => const ApiResponse<EditCollectionArtworksResponse>(
          result: EditCollectionArtworksResponse(
            txs: [
              UnsignedTxResponse(tx: 'dHgx'),
              UnsignedTxResponse(tx: 'dHgy'),
            ],
          ),
        ),
      );
      // Drive the two-tx stage sequence: tx-0 approve → tx-0 broadcast →
      // tx-1 approve → tx-1 broadcast, then succeed.
      when(
        executor.execute(
          txsBase64: anyNamed('txsBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onStage: anyNamed('onStage'),
        ),
      ).thenAnswer((invocation) async {
        final onStage =
            invocation.namedArguments[#onStage]
                as void Function(ExecutorStageEvent)?;
        onStage?.call(
          const ExecutorStageEvent(
            stage: ExecutorStage.awaitingApproval,
            index: 0,
            total: 2,
          ),
        );
        onStage?.call(
          const ExecutorStageEvent(
            stage: ExecutorStage.broadcasting,
            index: 0,
            total: 2,
          ),
        );
        onStage?.call(
          const ExecutorStageEvent(
            stage: ExecutorStage.awaitingApproval,
            index: 1,
            total: 2,
          ),
        );
        onStage?.call(
          const ExecutorStageEvent(
            stage: ExecutorStage.broadcasting,
            index: 1,
            total: 2,
          ),
        );
        return const ResultSuccess('sig');
      });

      final bloc = build();
      final statuses = <ManageArtworksTxStatus>[];
      final sub = bloc.stream.listen((s) => statuses.add(s.txStatus));

      bloc.add(const ManageCollectionArtworksEvent.started(_collection));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ManageCollectionArtworksEvent.toggled(_oneOfOne));
      bloc.add(const ManageCollectionArtworksEvent.submit());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      // The first broadcast must be followed by a return to signing (tx-1's
      // approval), proving the phase isn't stuck on "Confirming transaction".
      final firstBroadcast = statuses.indexOf(
        ManageArtworksTxStatus.broadcasting,
      );
      expect(firstBroadcast, isNonNegative);
      expect(
        statuses.sublist(firstBroadcast + 1),
        contains(ManageArtworksTxStatus.signing),
      );
      expect(bloc.state.txStatus, ManageArtworksTxStatus.success);
      await bloc.close();
    },
  );
}
