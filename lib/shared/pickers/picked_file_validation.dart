import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../../core/observability/app_logger.dart';
import '../utils/heic_import.dart';
import '../utils/heic_transcoder.dart';

const _tag = 'PickedFileValidation';

/// A picked file's bytes and name once validation — and any import-time
/// conversion — has run.
typedef ValidatedFile = ({Uint8List bytes, String fileName});

/// Shared validation tail for every upload box in the app: the mint slots and
/// the image-only boxes both land here, so the allowlist, the size cap and the
/// wording of each rejection are applied in exactly one place. Returns null
/// when the pick is rejected — [onError] has already reported the reason.
///
/// [pickable] is the caller's allowlist (no leading dots) *including* the
/// formats it only tolerates because they are converted on the way in, and
/// [typeSummary] the tail of the "File must be …" message.
///
/// The extension check is what enforces [pickable]; neither system picker
/// narrows all the way down to it. The document browser filters by UTI and
/// MIME, which are coarser than the allowlist and absent entirely on the mint
/// slots, and the system photo picker has no notion of the allowlist at all —
/// a `.gif` / `.webp` item can come back from it even where the caller takes
/// neither.
///
/// HEIC is the one format converted rather than rejected: it is what an iPhone
/// camera roll is full of, and it is not a format the platform will render, so
/// it is transcoded to JPEG here and continues on as one.
Future<ValidatedFile?> validatePickedFile({
  required String fileName,
  required Uint8List? bytes,
  required List<String> pickable,
  required int maxSizeBytes,
  required String typeSummary,
  required void Function(String message) onError,
}) async {
  if (bytes == null || bytes.isEmpty) {
    onError('File is empty or unreadable');
    return null;
  }
  if (rejectsNameOrSize(
    fileName: fileName,
    sizeBytes: bytes.lengthInBytes,
    pickable: pickable,
    maxSizeBytes: maxSizeBytes,
    typeSummary: typeSummary,
    onError: onError,
  )) {
    return null;
  }

  var name = fileName;
  var data = bytes;
  if (isHeicFileName(name)) {
    final jpeg = await transcodeHeicToJpeg(data);
    if (jpeg == null) {
      onError('File must be $typeSummary');
      return null;
    }
    // Re-check the cap: the JPEG is a different size than the HEIC was, and on
    // a 30mb collection slot it can land the wrong side of it. The rename is
    // what puts the result back inside the caller's own allowlist.
    name = heicNameAsJpeg(name);
    data = jpeg;
    if (rejectsNameOrSize(
      fileName: name,
      sizeBytes: data.lengthInBytes,
      pickable: pickable,
      maxSizeBytes: maxSizeBytes,
      typeSummary: typeSummary,
      onError: onError,
    )) {
      return null;
    }
  }

  return (bytes: data, fileName: name);
}

/// Rejects on facts knowable without the bytes — extension and size —
/// reporting the matching error. Split out so the Photos path can refuse a
/// huge camera-roll item on `length()`, before `readAsBytes` pulls the whole
/// thing into memory.
bool rejectsNameOrSize({
  required String fileName,
  required int sizeBytes,
  required List<String> pickable,
  required int maxSizeBytes,
  required String typeSummary,
  required void Function(String message) onError,
}) {
  final extension = _extensionOf(fileName);
  if (extension == null || !pickable.contains(extension)) {
    onError('File must be $typeSummary');
    return true;
  }
  if (sizeBytes > maxSizeBytes) {
    final mb = (maxSizeBytes / (1024 * 1024)).round();
    onError('File must be ${mb}MB or smaller');
    return true;
  }
  return false;
}

/// Bytes of [file], or null when the read fails — which
/// [validatePickedFile] reports as an unreadable file.
///
/// Both pickers hand back a handle rather than bytes, and the read behind it
/// fails for reasons the pick itself never surfaced: an Android content Uri
/// whose provider throws, or an iOS security-scoped copy reaped before we got
/// to it. Letting that throw escape would take out the tap handler with no
/// snackbar and no picked file.
Future<Uint8List?> readPickedBytes(XFile file) async {
  try {
    return await file.readAsBytes();
  } catch (error) {
    AppLogger.error(_tag, 'readAsBytes failed', error);
    return null;
  }
}

/// The lowercased extension of [fileName], or null when it has none.
///
/// A name with no dot — or one whose only dot leads it, like `.heic` — has no
/// extension. Taking the whole name as one is what let a file literally named
/// `heic` past the allowlist: it matches the HEIC entry every stills caller
/// appends, while [isHeicFileName] is deliberately stricter and left the HEIF
/// bytes unconverted, so raw HEIF went up under an extensionless name for the
/// backend to refuse with an opaque 400.
String? _extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return null;
  return fileName.substring(dot + 1).toLowerCase();
}
