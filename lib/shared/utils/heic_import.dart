/// Naming rules for the HEIC import path.
///
/// Apple HEIF stills are accepted by the app's pickers only so camera-roll
/// photos can be used — they are transcoded to JPEG on the way in (see
/// `heic_transcoder.dart`) and never reach IPFS as HEIC, which is not
/// on the platform's upload whitelist.
library;

/// Extensions the transcoder recognises as Apple HEIF stills.
const kHeicExtensions = <String>['heic', 'heif'];

/// True when [fileName]'s extension is one of [kHeicExtensions].
///
/// Deliberately stricter than the allowlist check in the upload step, which
/// treats a dotless name as its own extension: this one gates a re-encode and
/// a rename, so a file literally named `heic` — or the dotfile `.heic` — is
/// left alone rather than transformed on a guess.
bool isHeicFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return false;
  return kHeicExtensions.contains(fileName.substring(dot + 1).toLowerCase());
}

/// `IMG_0042.heic` → `IMG_0042.jpg`. Applied together with the transcode so
/// the name, the mime type and the bytes all agree — `properties.files[].type`
/// in the pinned metadata JSON is derived from the name downstream, and a
/// `.heic` name on JPEG bytes would classify the artwork with a mime the
/// indexer has no category for.
String heicNameAsJpeg(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
  return '$stem.jpg';
}
