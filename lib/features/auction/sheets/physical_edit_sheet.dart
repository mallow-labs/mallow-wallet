import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mime/mime.dart';

import '../../../shared/pickers/image_source_picker.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../../../shared/widgets/tappable.dart';
import '../../mint/models/picked_mint_asset.dart';
import '../../mint/widgets/mint_drop_zone.dart';

/// Outcome of [showPhysicalEditSheet].
sealed class PhysicalEditResult {
  const PhysicalEditResult();
}

/// User saved their changes — apply [payload] to the listing.
class PhysicalEditSaved extends PhysicalEditResult {
  const PhysicalEditSaved(this.payload);
  final PhysicalDetailsPayload payload;
}

/// User chose to remove the physical from the sale.
class PhysicalEditRemoved extends PhysicalEditResult {
  const PhysicalEditRemoved();
}

/// Full-screen sheet for editing physical-artwork details on a sale.
///
/// Returns [PhysicalEditSaved] when Done is tapped with valid input,
/// [PhysicalEditRemoved] when "Remove physical from sale" is tapped, or
/// `null` when the sheet is dismissed without action.
///
/// [showUnlockPrice] gates the optional unlock-price field — auction listings
/// surface it, fixed-price ones don't (matches the webapp's
/// `PhysicalSection`).
Future<PhysicalEditResult?> showPhysicalEditSheet(
  BuildContext context, {
  required bool showUnlockPrice,
  PhysicalDetailsPayload? initial,
}) {
  return showFullScreenSheet<PhysicalEditResult>(
    context: context,
    child: _PhysicalEditSheet(
      initial: initial,
      showUnlockPrice: showUnlockPrice,
    ),
  );
}

class _PhysicalEditSheet extends StatefulWidget {
  const _PhysicalEditSheet({required this.showUnlockPrice, this.initial});

  final PhysicalDetailsPayload? initial;
  final bool showUnlockPrice;

  @override
  State<_PhysicalEditSheet> createState() => _PhysicalEditSheetState();
}

class _PhysicalEditSheetState extends State<_PhysicalEditSheet> {
  static const _imageExtensions = ['png', 'jpeg', 'jpg', 'webp'];
  static const _maxBytes = 30 * 1024 * 1024;

  late final TextEditingController _description;
  late final TextEditingController _unlockPrice;
  PickedMintAsset? _pickedImage;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(
      text: widget.initial?.description ?? '',
    );
    final initialPrice = widget.initial?.unlockPrice;
    _unlockPrice = TextEditingController(
      text: initialPrice == null ? '' : initialPrice.toString(),
    );
    _pickedImage = _assetFromDataUrl(widget.initial?.imageUrl);
  }

  /// The saved photo is a base64 data URL (see [_onSave]); decode it back to
  /// bytes so re-opening the sheet previews it. Returns null for non-data
  /// URLs, which render via the drop zone's network path instead.
  static PickedMintAsset? _assetFromDataUrl(String? url) {
    if (url == null || !url.startsWith('data:')) return null;
    try {
      final data = UriData.parse(url);
      final bytes = data.contentAsBytes();
      return PickedMintAsset(
        fileName: 'physical-photo',
        mimeType: data.mimeType,
        sizeBytes: bytes.lengthInBytes,
        bytes: bytes,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _unlockPrice.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await pickImageFromSource(
      context,
      allowedExtensions: _imageExtensions,
      maxSizeBytes: _maxBytes,
      typeSummary: 'a .png, .jpeg or .webp image',
      onError: (message) {
        if (mounted) _showError(message);
      },
    );
    if (picked == null || !mounted) return;
    final mimeType = lookupMimeType(picked.fileName) ?? 'image/*';
    setState(() {
      _pickedImage = PickedMintAsset(
        fileName: picked.fileName,
        mimeType: mimeType,
        sizeBytes: picked.bytes.lengthInBytes,
        bytes: picked.bytes,
      );
    });
  }

  void _showError(String message) {
    AppSnackBar.show(context, message, duration: const Duration(seconds: 2));
  }

  bool get _canSave => _description.text.trim().isNotEmpty;

  void _onSave() {
    final priceText = _unlockPrice.text.trim();
    final price = priceText.isEmpty ? null : int.tryParse(priceText);
    final picked = _pickedImage;
    Navigator.of(context).pop(
      PhysicalEditSaved(
        PhysicalDetailsPayload(
          description: _description.text.trim(),
          // Persisted as a base64 data URL inside the payload — there is no
          // separate upload endpoint; mirrors the webapp's `PhysicalSection`.
          imageUrl: picked != null
              ? Uri.dataFromBytes(
                  picked.bytes,
                  mimeType: picked.mimeType,
                ).toString()
              : widget.initial?.imageUrl,
          unlockPrice: widget.showUnlockPrice ? price : null,
        ),
      ),
    );
  }

  void _onRemove() {
    Navigator.of(context).pop(const PhysicalEditRemoved());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // Data URLs are decoded into [_pickedImage] in initState; one that's
    // still data:-prefixed here failed to decode and can't render via the
    // drop zone's Image.network path either.
    final initialUrl = widget.initial?.imageUrl;
    final initialImageUrl = (initialUrl?.startsWith('data:') ?? false)
        ? null
        : initialUrl;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Padding(
        padding: EdgeInsets.only(
          left: MallowTheme.spacing20,
          right: MallowTheme.spacing20,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Add photograph of physical',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    _PhotoDropZone(
                      pickedAsset: _pickedImage,
                      networkImageUrl: _pickedImage == null
                          ? initialImageUrl
                          : null,
                      onTap: _pickImage,
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    Center(
                      child: Text(
                        '30mb max  •  .png, .jpeg, .webp',
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    if (widget.showUnlockPrice) ...[
                      const SizedBox(height: MallowTheme.spacingXl),
                      RichText(
                        text: TextSpan(
                          style: MallowTheme.uiMeta.copyWith(
                            color: colors.textPrimary,
                          ),
                          children: [
                            TextSpan(
                              text: '(Optional) ',
                              style: MallowTheme.uiMeta.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                            const TextSpan(text: 'Set a physical unlock price'),
                          ],
                        ),
                      ),
                      const SizedBox(height: MallowTheme.spacingMd),
                      MallowPillField(
                        controller: _unlockPrice,
                        hintText: 'Leave blank if included at all sale prices',
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ],
                    const SizedBox(height: MallowTheme.spacingXl),
                    Text(
                      'Physical notes',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    MallowTextareaField(
                      controller: _description,
                      hintText:
                          'Add notes regarding the physical, including any '
                          'additional shipping costs and how to contact you',
                      maxLength: 1000,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    Text(
                      'Physicals and rewards are the responsibility of the '
                      'seller to distribute. No disputes will be resolved by '
                      'mallow. Any abuse of this feature will result in '
                      'suspension from selling on mallow.',
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingLg),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                top: MallowTheme.spacingMd,
                bottom: sheetBottomInset(context, includeKeyboard: false),
              ),
              child: Column(
                children: [
                  _SheetButton(
                    label: 'Remove physical from sale',
                    color: colors.error,
                    onTap: _onRemove,
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  _SheetButton(
                    label: 'Done',
                    color: _canSave ? colors.accent : colors.textTertiary,
                    onTap: _canSave ? _onSave : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.label, required this.color, this.onTap});

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        child: Tappable(
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: colors.textOnAccent,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoDropZone extends StatelessWidget {
  const _PhotoDropZone({
    required this.onTap,
    this.pickedAsset,
    this.networkImageUrl,
  });

  final PickedMintAsset? pickedAsset;
  final String? networkImageUrl;
  final VoidCallback onTap;

  static const _height = 176.5;

  @override
  Widget build(BuildContext context) {
    // A freshly picked asset wins; otherwise fall back to the previously
    // uploaded photo (existing listing URL). Both render "inside" (contain)
    // so the whole photo shows within the box, with 10px padding to the edge.
    return MintDropZone(
      asset: pickedAsset,
      existingUrl: networkImageUrl,
      onTap: onTap,
      height: _height,
      imagePadding: const EdgeInsets.all(10),
      emptyHint: 'Tap to upload your photo',
    );
  }
}
