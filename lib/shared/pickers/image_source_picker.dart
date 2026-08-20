import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/observability/app_logger.dart';
import '../utils/heic_import.dart';
import 'asset_source_sheet.dart';
import 'picked_file_validation.dart';

const _tag = 'ImageSourcePicker';

/// A picked, in-memory image awaiting upload.
typedef PickedImage = ValidatedFile;

/// Entry point for the app's still-image upload boxes: asks where the bytes
/// should come from, runs the matching system picker, and validates whatever
/// comes back. Returns null when the user dismisses either step or the pick is
/// rejected — [onError] has already reported the reason in that case.
///
/// [allowedExtensions] is the caller's own allowlist (no leading dots), and
/// [typeSummary] the tail of the "File must be …" message shown when a pick
/// falls outside it. Reporting goes through [onError] rather than a snackbar
/// here because the call sites present errors differently.
///
/// The mint flow does not use this: its slots accept video, html and glb, and
/// their rules drive which system picker opens. It shares
/// [showAssetSourceSheet] and [validatePickedFile], not this function.
Future<PickedImage?> pickImageFromSource(
  BuildContext context, {
  required List<String> allowedExtensions,
  required int maxSizeBytes,
  required String typeSummary,
  required void Function(String message) onError,
}) async {
  final source = await showAssetSourceSheet(context);
  if (source == null || !context.mounted) return null;

  // HEIC is offered to the pickers but never returned as such — an iPhone
  // camera roll is full of it, so it is transcoded on the way in rather than
  // being greyed out. See [validatePickedFile].
  final pickable = [...allowedExtensions, ...kHeicExtensions];

  return switch (source) {
    AssetSource.photos => _pickFromPhotos(
      pickable: pickable,
      maxSizeBytes: maxSizeBytes,
      typeSummary: typeSummary,
      onError: onError,
    ),
    AssetSource.files => _pickFromFiles(
      pickable: pickable,
      maxSizeBytes: maxSizeBytes,
      typeSummary: typeSummary,
      onError: onError,
    ),
  };
}

/// How the still-image extensions the upload boxes accept are spelled in the
/// other two type vocabularies.
///
/// iOS filters the document browser by UTI, not by extension — passing
/// `extensions` alone makes `openFile` throw there — so anything the browser
/// should offer has to be named as a UTI too. Android reads `mimeTypes`.
const _imageTypeSpellings = <String, ({String uti, String mime})>{
  'png': (uti: 'public.png', mime: 'image/png'),
  'jpg': (uti: 'public.jpeg', mime: 'image/jpeg'),
  'jpeg': (uti: 'public.jpeg', mime: 'image/jpeg'),
  'webp': (uti: 'org.webmproject.webp', mime: 'image/webp'),
  'gif': (uti: 'com.compuserve.gif', mime: 'image/gif'),
  'heic': (uti: 'public.heic', mime: 'image/heic'),
  'heif': (uti: 'public.heif', mime: 'image/heif'),
};

/// The document-browser filter for the entries of [pickable] that
/// [_imageTypeSpellings] can name, or null — meaning "open unfiltered" — when
/// it can name none of them.
///
/// An unspelled entry is dropped rather than collapsing the whole group.
/// Dropping costs that one format: it is greyed out in the browser, so a
/// caller that adds `avif` to its allowlist can only reach it from Photos
/// until a spelling is added here. Collapsing costs the filter entirely — one
/// missing spelling would open the browser on every file on the device for
/// every caller, which is the same wholesale trade the mint slots make on
/// purpose (`.glb` / `.webm` have no system UTI to name at all) but which
/// nothing about editing an allowlist says you are opting into. The drop is
/// logged so the cause is not "the picker looks different on device".
XTypeGroup? _imageTypeGroup(List<String> pickable) {
  final spelled = <String>[];
  final spellings = <({String uti, String mime})>[];
  for (final extension in pickable) {
    final spelling = _imageTypeSpellings[extension.toLowerCase()];
    if (spelling == null) {
      AppLogger.warn(
        _tag,
        'no UTI/MIME spelling for .$extension — not offered',
      );
      continue;
    }
    spelled.add(extension);
    spellings.add(spelling);
  }
  if (spellings.isEmpty) return null;
  return XTypeGroup(
    label: 'Images',
    extensions: spelled,
    mimeTypes: {for (final s in spellings) s.mime}.toList(),
    uniformTypeIdentifiers: {for (final s in spellings) s.uti}.toList(),
  );
}

Future<PickedImage?> _pickFromFiles({
  required List<String> pickable,
  required int maxSizeBytes,
  required String typeSummary,
  required void Function(String message) onError,
}) async {
  final group = _imageTypeGroup(pickable);
  XFile? file;
  try {
    file = await openFile(acceptedTypeGroups: [?group]);
  } catch (error) {
    // Logged because far more than a failed launch arrives here, and the throw
    // alone does not say which: `file_selector_android` reads the picked
    // content Uri itself inside this call, so an unknown `SIZE` (routine for
    // cloud providers), a failed copy into the cache dir, or a SecurityException
    // on the Uri all surface as a throw from a picker the user did see open.
    // `channel-error` is the opposite end — the native handler never answered.
    AppLogger.error(_tag, 'openFile failed', error);
    onError('Could not open file picker');
    return null;
  }
  if (file == null) return null;

  // The browser hands back a handle, not bytes; a read failure here is
  // reported by [validatePickedFile] as an unreadable file.
  return validatePickedFile(
    fileName: file.name,
    bytes: await readPickedBytes(file),
    pickable: pickable,
    maxSizeBytes: maxSizeBytes,
    typeSummary: typeSummary,
    onError: onError,
  );
}

/// Photo-library source. On iOS 14+ `image_picker` presents
/// `PHPickerViewController`, which is out of process — no photo-library
/// permission is requested and none is needed, so `requestFullMetadata` is off
/// (we only want the bytes; asking for EXIF is what would pull the permission
/// back in).
Future<PickedImage?> _pickFromPhotos({
  required List<String> pickable,
  required int maxSizeBytes,
  required String typeSummary,
  required void Function(String message) onError,
}) async {
  XFile? file;
  try {
    file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
  } catch (error) {
    AppLogger.error(_tag, 'pickImage failed', error);
    onError('Could not open photo library');
    return null;
  }
  if (file == null) return null;

  // Refuse on name/stat before buffering: the system picker has no notion of
  // our allowlist or size cap, and a huge still must be rejected on `length()`
  // rather than after `readAsBytes` pulls the whole file into memory.
  int sizeBytes;
  try {
    sizeBytes = await file.length();
  } catch (_) {
    sizeBytes = 0; // Unreadable — fall through and let readAsBytes decide.
  }
  if (rejectsNameOrSize(
    fileName: file.name,
    sizeBytes: sizeBytes,
    pickable: pickable,
    maxSizeBytes: maxSizeBytes,
    typeSummary: typeSummary,
    onError: onError,
  )) {
    return null;
  }

  // Unlike the Files path there is no `withData` — the bytes are read off the
  // temp file only once the cheap checks above have passed.
  return validatePickedFile(
    fileName: file.name,
    bytes: await readPickedBytes(file),
    pickable: pickable,
    maxSizeBytes: maxSizeBytes,
    typeSummary: typeSummary,
    onError: onError,
  );
}
