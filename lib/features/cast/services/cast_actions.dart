import '../../../core/network/auth_service.dart';
import '../../../core/network/ledger_verify_controller.dart';
import '../../../di.dart';
import '../models/cast_queue.dart';
import 'cast_bloc.dart';

/// Dispatches [CastEvent.castArtwork] for [item] after the standard
/// pre-flight Ledger check — if the active wallet is a hardware wallet
/// without a cached signature, the user is shown the verify sheet first
/// and casting proceeds only on successful verification.
Future<void> castArtworkWithVerify(CastQueueItem item) async {
  if (!await _ensureLedgerVerified()) return;
  sl<CastBloc>().add(CastEvent.castArtwork(item));
}

/// Bulk variant: opens the device picker (if not already connected) with
/// the full queue seeded so the user can preview/edit it via "View Queue"
/// before committing to cast. The Ledger verification prompt fires at most
/// once per call.
Future<void> castArtworksWithVerify(List<CastQueueItem> items) async {
  if (items.isEmpty) return;
  if (!await _ensureLedgerVerified()) return;
  sl<CastBloc>().add(CastEvent.castArtworks(items));
}

/// True when a cast session is currently active. Used to gate the
/// "Add to cast" affordance — without an active session there's no queue
/// to add to, so the option is hidden.
bool get isCastActive => sl<CastBloc>().state is CastActive;

/// Stream of cast active/inactive transitions. Listeners that need to
/// reactively show/hide an "Add to cast" affordance can subscribe via
/// `BlocBuilder<CastBloc, CastState>` directly; this getter exists for
/// the few places that don't already have a [CastBloc] in scope.
Stream<bool> get isCastActiveStream =>
    sl<CastBloc>().stream.map((s) => s is CastActive);

/// Append [items] to the active cast queue. Duplicates (by mintAccount)
/// are skipped inside [CastBloc]. No-op when there's no active session —
/// callers should gate the affordance on [isCastActive] first.
void addArtworksToCastQueue(List<CastQueueItem> items) {
  if (items.isEmpty) return;
  sl<CastBloc>().add(CastEvent.addItemsToQueue(items));
}

Future<bool> _ensureLedgerVerified() async {
  final auth = sl<AuthService>();
  if (!await auth.currentWalletNeedsLedgerVerification()) return true;
  final addr = auth.currentAddress;
  if (addr == null) return false;
  return sl<LedgerVerifyController>().requestVerification(addr);
}
