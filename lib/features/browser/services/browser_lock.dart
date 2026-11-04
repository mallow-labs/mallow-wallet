import '../../../core/security/app_lock_bloc.dart';
import 'browser_session.dart';

/// Drops every tab screenshot when the app locks, whether or not the browser
/// is on screen. Called from the app-wide lock listener, because a minimised
/// browser is unmounted and could not react itself. Never creates the
/// session: an unused browser has nothing to drop.
void dropBrowserThumbnailsOnLock(
  AppLockState state, {
  BrowserSession? session,
}) {
  if (state is AppLockStateLocked || state is AppLockStateUninitialized) {
    (session ?? BrowserSession.existing)?.clearThumbnails();
  }
}
