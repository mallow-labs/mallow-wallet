import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart'
    show SolanaTransactionUnconfirmedException;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/collection/screens/manage_collection_artworks_screen.dart';
import 'package:mallow_wallet/features/collection/services/manage_collection_artworks_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockBloc
    extends
        MockBloc<ManageCollectionArtworksEvent, ManageCollectionArtworksState>
    implements ManageCollectionArtworksBloc {}

const _collection = 'CoLLmMwXbaVvXtqVYPWZ4cJx3rC2mCG4wPHF9GHTr5s';
const _mint = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

/// "Try again" here re-signs a fresh batch of `edit-collection-artworks`
/// transactions. When the broadcast outcome is unknown
/// (`SolanaTransactionUnconfirmedException`: the blockhash expired before the
/// transaction was ever observed landing), the membership change may already
/// have applied — so "Could not update collection" is a claim we cannot make,
/// and an enabled retry signs a second batch over state we can no longer
/// describe. Determinate failures keep their retry: nothing landed, so
/// re-submitting is safe.
void main() {
  late _MockBloc bloc;
  late StreamController<ManageCollectionArtworksState> states;

  final artwork = PortfolioArtwork(
    mintAccount: _mint,
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  // One artwork checked and not yet a member → `canSubmit`, so the submit bar
  // is live and opens the pipeline sheet.
  late ManageCollectionArtworksState pending;

  setUp(() {
    bloc = _MockBloc();
    states = StreamController<ManageCollectionArtworksState>.broadcast();
    pending = ManageCollectionArtworksState(
      isLoading: false,
      artworks: [artwork],
      selected: const {_mint},
    );
    whenListen(bloc, states.stream, initialState: pending);
    if (sl.isRegistered<ManageCollectionArtworksBloc>()) {
      sl.unregister<ManageCollectionArtworksBloc>();
    }
    sl.registerFactory<ManageCollectionArtworksBloc>(() => bloc);
  });

  tearDown(() async {
    await states.close();
    sl.unregister<ManageCollectionArtworksBloc>();
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Submits the pending membership change, then lands [failure] on the
  /// pipeline sheet.
  Future<void> submitUntilError(WidgetTester tester, AppFailure failure) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const ManageCollectionArtworksScreen(collectionMint: _collection),
      ),
    );
    await flush(tester);

    await tester.tap(find.text('Add 1 artwork'));
    await flush(tester);

    states.add(
      pending.copyWith(
        txStatus: ManageArtworksTxStatus.error,
        txError: failure.message,
        txFailure: failure,
      ),
    );
    await flush(tester);
  }

  testWidgets('a determinate failure keeps the failure headline and offers a '
      'retry', (tester) async {
    await submitUntilError(
      tester,
      const AppFailure.rpc('Instruction 0 failed: Custom error 6003'),
    );

    expect(find.text('Could not update collection'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    verify(
      () => bloc.add(const ManageCollectionArtworksEvent.retry()),
    ).called(1);
  });

  testWidgets('an unconfirmed broadcast is not framed as a failure and cannot '
      'be retried', (tester) async {
    await submitUntilError(
      tester,
      AppFailure.from(const SolanaTransactionUnconfirmedException('sigSTUCK')),
    );

    expect(find.text('Could not update collection'), findsNothing);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    // The exception's own copy points the user at Activity / the explorer.
    expect(find.textContaining('may still land'), findsOneWidget);

    // The button is still laid out (the sheet keeps a fixed footprint) but is
    // inert — it must not sign a second batch.
    await tester.tap(find.text('Try again'), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => bloc.add(const ManageCollectionArtworksEvent.retry()));

    // …and the user is never stranded: Back still dismisses the sheet. (The
    // screen's `whenComplete` re-dispatches `dismissError` for the barrier-tap
    // / swipe-down paths that bypass `onClose`, and a mock bloc never leaves
    // the error state — hence the loose count.)
    await tester.tap(find.text('Back'));
    await flush(tester);
    expect(find.text('Not confirmed yet'), findsNothing);
    verify(
      () => bloc.add(const ManageCollectionArtworksEvent.dismissError()),
    ).called(greaterThanOrEqualTo(1));
  });
}
