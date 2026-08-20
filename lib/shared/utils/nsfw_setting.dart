import '../../core/network/auth_service.dart';
import '../../core/services/preferences_service.dart';
import '../../core/session/session_manager.dart';
import '../../di.dart';
import '../../features/profile/data/user_profile_repository.dart';

/// Applies a change to the global "show NSFW" setting.
///
/// Local-first, mirroring the Active Networks pattern: the device preference
/// flips immediately (blur overlays listen to
/// [PreferencesService.showNsfwNotifier]), and in a Profile (signed-login)
/// session the change is also pushed to the profile via `/v1/showNsfw` so it
/// follows the user across devices. When the server rejects the change the
/// local flip is reverted.
///
/// Returns an error message to surface to the user, or null on success.
Future<String?> applyShowNsfwSetting(bool show) async {
  final auth = sl<AuthService>();
  // Moderation lock: the account may not change (or bypass) its blur state.
  if (auth.currentUser?.disableNsfwSetting ?? false) {
    return 'NSFW setting is disabled';
  }

  final prefs = sl<PreferencesService>();
  final previous = prefs.showNsfw;
  await prefs.setShowNsfw(show);

  if (!sl<SessionManager>().isProfileMode) return null;
  try {
    await sl<UserProfileRepository>().setShowNsfw(show);
    // Keep the cached user in step so the moderation-lock check above (and
    // anything else reading `currentUser.showNsfw`) stays fresh.
    final user = auth.currentUser;
    if (user != null) {
      auth.applyProfileUpdate(user.copyWith(showNsfw: show), null);
    }
  } catch (_) {
    await prefs.setShowNsfw(previous);
    return "Couldn't save the NSFW setting to your profile";
  }
  return null;
}
