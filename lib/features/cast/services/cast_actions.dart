import '../../../core/network/auth_service.dart';
import '../../../di.dart';
import '../../artwork/services/active_wallet_verification.dart';
import '../models/cast_queue.dart';
import 'cast_bloc.dart';

/// Dispatches [CastEvent.castArtwork] for [item] after the standard
/// pre-flight hardware check — if the active wallet is a hardware wallet
/// without a cached signature, its device signs one first (Ledger sheet,
/// Seed Vault approval or Keystone QR exchange)
/// and casting proceeds only on successful verification.
Future<void> castArtworkWithVerify(CastQueueItem item) async {
  if (!await _ensureHardwareVerified()) return;
  sl<CastBloc>().add(CastEvent.castArtwork(item));
}

/// Bulk variant: opens the device picker (if not already connected) with
/// the full queue seeded so the user can preview/edit it via "View Queue"
/// before committing to cast. The hardware verification prompt fires at most
/// once per call.
Future<void> castArtworksWithVerify(List<CastQueueItem> items) async {
  if (items.isEmpty) return;
  if (!await _ensureHardwareVerified()) return;
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

/// Signs, not just asks: Seed Vault's and Keystone's verify sheets collect
/// consent and sign nothing, so treating that sheet's answer as "verified" cast
/// without a wallet-sig. [ensureActiveWalletVerified] runs each device's whole
/// handshake from this tap and caches the sig.
Future<bool> _ensureHardwareVerified() async {
  final auth = sl<AuthService>();
  if (!await auth.currentWalletNeedsHardwareVerification()) return true;
  return await ensureActiveWalletVerified() == null;
}
