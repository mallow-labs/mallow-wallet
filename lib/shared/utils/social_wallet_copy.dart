// The words the app uses about the two kinds of Google and Apple wallet, in
// one place so they cannot drift apart:
//
// - a social vault wallet, made by the current sign-in. The Google or Apple
//   account alone can never open it: a key only the owner's devices hold is
//   needed too.
// - a wallet from the older sign-in, the one run by Web3Auth
//   (`WalletInfo.isLegacySocialWallet`). The Google or Apple account alone
//   reproduces its keys. This app has no older sign-in, so it cannot fetch
//   those keys again.
//
// Nothing here may be shown for the wrong kind. No first-party host is named:
// "the mallow website" is whichever one the deployment serves.

/// What the older sign-in means for a wallet, in one sentence. [providerName]
/// is "Google" or "Apple". For a wallet from the older sign-in only.
String legacySocialSentence(String providerName) =>
    'Older sign-in, run by Web3Auth: your $providerName account alone can '
    'open this wallet.';

/// How a wallet from the older sign-in is recovered when its phone is lost.
const legacySocialRecoverySentence =
    'If this phone is lost, the wallet is recovered through the older sign-in '
    'on the mallow website.';

/// What comes after removing a Google or Apple wallet from this device: can
/// it be added back, and how. Follows the sentence that says the wallet and
/// its stored keys are removed.
///
/// [hasVault] — the wallet is linked to a social vault, which signing in
/// again reopens. Otherwise [legacy] tells a wallet from the older sign-in
/// from a vault wallet whose backup was deleted; signing in again brings
/// neither back, so each is told what does.
String socialRemovalAftermath({required bool legacy, required bool hasVault}) {
  if (hasVault) {
    return 'You can add it back by signing in with the same account again.';
  }
  if (legacy) {
    return 'This app cannot add it back: signing in again here makes a new '
        'wallet. It is recovered only through the older sign-in on the mallow '
        'website, so save its keys from Show secrets first.';
  }
  return 'Its backup was deleted, so signing in again will not bring it '
      'back. Save its recovery phrase from Show secrets first.';
}

// ── Social vault wallets ────────────────────────────────────────────────────

/// A vault write or status read was refused for its timestamp: this device's
/// clock is off. Nothing about the wallet or its keys changed.
const socialVaultClockMessage =
    'Check this device’s date and time, then try again.';

/// The account a sign-in was for, as the user knows it: the email the
/// provider shared, else "your Google account" / "your Apple account".
String socialAccountLabel(String providerName, String? emailHint) =>
    (emailHint != null && emailHint.isNotEmpty)
    ? emailHint
    : 'your $providerName account';

/// Asked before a wallet is created for an account that has none.
String noWalletFoundMessage(String providerName, String? emailHint) =>
    'No mallow wallet found for '
    '${socialAccountLabel(providerName, emailHint)}. Create one?';

/// Said instead of [noWalletFoundMessage] when this device already holds a
/// [providerName] wallet with sign-in keys: the account that just signed in
/// has none, and the wallet here belongs to [walletAccountEmail] (when
/// known).
String noWalletForThisAccountMessage(
  String providerName,
  String? emailHint, {
  String? walletAccountEmail,
}) {
  final signedIn = (emailHint != null && emailHint.isNotEmpty)
      ? emailHint
      : 'This $providerName account';
  final owner = (walletAccountEmail != null && walletAccountEmail.isNotEmpty)
      ? walletAccountEmail
      : 'another $providerName account';
  return '$signedIn has no mallow wallet. The $providerName wallet on this '
      'phone belongs to $owner.\n\n'
      'To open that wallet, use that account. Creating a wallet here makes a '
      'new, empty one.';
}

/// Asked when a wallet on this device had to be reopened and the sign-in
/// that answered was another account.
String wrongAccountMessage(
  String providerName, {
  String? expectedEmail,
  String? signedInEmail,
}) {
  final owner = (expectedEmail != null && expectedEmail.isNotEmpty)
      ? expectedEmail
      : 'the $providerName account it was created with';
  final signedIn = (signedInEmail != null && signedInEmail.isNotEmpty)
      ? ' You signed in as $signedInEmail.'
      : '';
  return 'This wallet belongs to $owner.$signedIn Sign in with that account '
      'to use it. Nothing was changed.';
}

/// What deleting a wallet's backup costs, said before it happens.
const deleteWalletBackupMessage =
    'mallow will no longer be able to recover this wallet on a new device.\n\n'
    'The wallet stays on this phone. Its recovery phrase becomes the only '
    'backup: write it down before you continue.';

/// On the Delete profile screen, for a profile signed in with a wallet that
/// has sign-in keys: deleting the profile leaves the wallet's backup alone,
/// and says where it is deleted.
const profileDeletionKeepsBackupMessage =
    'Your encrypted wallet backup stays with mallow, so you can still sign in '
    'to this wallet. To delete it too, use Delete wallet backup in Sign-in '
    'keys.';

/// The blocking warning for a wallet backup whose deletion is pending.
/// [date] is when it would be applied, formatted for display.
String pendingDeletionMessage(String date) =>
    'Your wallet backup is scheduled for deletion on $date. If you did not '
    'ask for this, keep it.';

/// One line of the new-key notice. [date] is when the key was added,
/// formatted for display.
String signInKeyAddedMessage(String date, String label) =>
    'A sign-in key was added on $date: $label';

/// Said once when a check in the background found that this device's own
/// sign-in key no longer opens the wallet backup: the keys were replaced on
/// another device. The wallet itself still works here; what stopped is
/// managing the backup, and hearing about changes to it, from this device.
String signInKeyReplacedMessage(String providerName) =>
    'This device’s sign-in key for your $providerName wallet was replaced '
    'on another device. Your wallet still works here. Sign in again with '
    '$providerName to manage its backup on this device.';

/// A name for a sign-in key that is longer than the backup keeps.
const signInKeyNameTooLongMessage =
    'That name is too long. Shorten it and try again.';

// ── The phone backup of a sign-in key (Android) ─────────────────────────────
//
// On Android a wallet's device key rides in Google's backup of the phone,
// which is end-to-end encrypted only while the phone has a screen lock. The
// app re-checks that every time it comes forward. None of this is ever shown
// on iOS.

/// The banner while the phone has no screen lock: the sign-in keys are kept
/// on the phone alone until it has one.
const backupPausedTitle = 'Your backup is paused: set a screen lock';

/// What the paused banner means and what ends it.
const backupPausedMessage =
    'Without a screen lock, Google cannot encrypt this phone’s backup end to '
    'end, so your wallet’s sign-in key is kept on this phone only. Set a '
    'screen lock and the backup resumes.';

/// Offered once after the phone's backup was seen without end-to-end
/// encryption while a sign-in key was in it.
///
/// It says what replacing the keys does and no more. A replacement makes a
/// new key for the wallet backup and seals the SAME recovery phrase under
/// it, so a sign-in key read out of that phone backup opens nothing from
/// then on. It cannot undo a read that already happened and was already
/// used to open the wallet backup: the phrase is the wallet. For that the
/// only remedy is a new wallet, and the message says so.
const backupWasUnprotectedTitle = 'Replace your sign-in keys?';
const backupWasUnprotectedMessage =
    'Your phone backup was unprotected for a while, with a sign-in key in '
    'it. Replacing your sign-in keys stops that key from opening your wallet '
    'backup from now on.\n\n'
    'If you think the phone backup was already read, move your funds to a '
    'new wallet instead.';

/// The action that replaces them: a rotation that makes a new key for this
/// phone and keeps each passkey the user confirms.
const replaceSignInKeysLabel = 'Replace sign-in keys';

/// Said when a replacement is asked for while the phone still has no screen
/// lock: a new device key could not be backed up, so none would be made.
const replaceNeedsScreenLockMessage =
    'Set a screen lock on this phone first, then replace your sign-in keys.';

/// A wallet cannot be created on Android 8: it has neither an end-to-end
/// encrypted phone backup nor passkeys, and a screen lock changes neither.
const androidTooOldForSocialWalletMessage =
    'This Android version cannot back up a Google or Apple wallet. Use a '
    'recovery phrase wallet, or a newer device.';

/// Said once when a wallet was unlinked from its vault because the backend
/// no longer has it.
const backupNoLongerStoredMessage =
    'This wallet’s backup is no longer stored with mallow. The wallet stays '
    'on this phone: its recovery phrase is now the only backup.';
