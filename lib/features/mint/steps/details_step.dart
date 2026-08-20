import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_char_counter.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/utils/utf8_byte_limit.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../pickers/collection_picker_sheet.dart';
import '../services/mint_bloc.dart';

/// Details step.
///
/// Captures artwork name (32-byte), description (1000-byte), collection
/// picker, NSFW toggle and AI-generated toggle.
///
/// The caps are **UTF-8 bytes**, not characters — webapp parity
/// (`Details` counts `Buffer.from(value).length`). Counting
/// characters let mobile submit a 32-emoji title the webapp rejects at 8.
class DetailsStep extends StatefulWidget {
  const DetailsStep({super.key});

  @override
  State<DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends State<DetailsStep> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;

  // UTF-8 byte budgets, not character counts — see the class doc.
  static const _nameMaxBytes = 32;
  static const _descriptionMaxBytes = 1000;
  static const _aiTag = 'ai';

  @override
  void initState() {
    super.initState();
    final state = context.read<MintBloc>().state;
    _nameController = TextEditingController(text: state.name);
    _descriptionController = TextEditingController(text: state.description);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MintBloc, MintState>(
      listenWhen: (prev, next) =>
          prev.name != next.name || prev.description != next.description,
      listener: (context, state) {
        _syncController(_nameController, state.name);
        _syncController(_descriptionController, state.description);
      },
      buildWhen: (prev, next) =>
          prev.name != next.name ||
          prev.description != next.description ||
          prev.collection != next.collection ||
          prev.collectionName != next.collectionName ||
          prev.nsfw != next.nsfw ||
          prev.mintType != next.mintType ||
          prev.tags.contains(_aiTag) != next.tags.contains(_aiTag),
      builder: (context, state) {
        final colors = context.mallowColors;
        final aiSelected = state.tags.contains(_aiTag);
        final isCollection = state.mintType == MintCreateType.collection;
        // A master edition CAN sit in a parent collection — its link is an
        // mpl-core Group rather than the asset's update authority, which is
        // why the create path sends `collection` + `groupSigner` and the edit
        // path sends `newParentCollection` / `newGroupSigner`.
        // Webapp parity: the picker's host
        // `Details` renders for both 1/1 and editions, on create and on
        // edit alike; only collections get the picker-less
        // `CollectionDetails` (`Create`,
        // `Edit`).
        final showCollectionPicker =
            state.mintType == MintCreateType.oneOfOne ||
            state.mintType == MintCreateType.editions;
        final nameLabel = isCollection ? 'Collection Name' : 'Artwork Name';
        final descriptionLabel = isCollection
            ? 'Collection Description'
            : 'Artwork Description';
        final namePlaceholder = isCollection
            ? 'Name your collection'
            : 'Name your artwork';
        final descriptionPlaceholder = isCollection
            ? 'Tell collectors about your collection'
            : 'Tell collectors about your work';
        final nsfwLabel = isCollection
            ? 'Images are NSFW (Contains violence, nudity etc)'
            : 'This artwork is NSFW (Contains violence, nudity etc)';
        return ListView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          children: [
            MallowSectionLabel(label: nameLabel),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _nameController,
              hintText: namePlaceholder,
              inputFormatters: const [
                Utf8ByteLimitingTextInputFormatter(_nameMaxBytes),
              ],
              textCapitalization: TextCapitalization.words,
              onChanged: (value) =>
                  context.read<MintBloc>().add(MintEvent.setName(value)),
            ),
            const SizedBox(height: MallowTheme.spacingXs),
            MallowCharCounter(
              remaining: _nameMaxBytes - utf8ByteLength(state.name),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            MallowSectionLabel(label: descriptionLabel),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowTextareaField(
              controller: _descriptionController,
              hintText: descriptionPlaceholder,
              inputFormatters: const [
                Utf8ByteLimitingTextInputFormatter(_descriptionMaxBytes),
              ],
              textCapitalization: TextCapitalization.sentences,
              onChanged: (value) =>
                  context.read<MintBloc>().add(MintEvent.setDescription(value)),
            ),
            const SizedBox(height: MallowTheme.spacingXs),
            MallowCharCounter(
              remaining:
                  _descriptionMaxBytes - utf8ByteLength(state.description),
            ),
            // Collections aren't nested inside another collection — match
            // webapp parity (CollectionDetails omits the picker).
            if (showCollectionPicker) ...[
              const SizedBox(height: MallowTheme.spacingLg),
              const MallowSectionLabel(label: 'Collection', optional: true),
              const SizedBox(height: MallowTheme.spacingMd),
              _CollectionPickerPill(
                collectionName: state.collectionName,
                onTap: () => _openCollectionPicker(context, state),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              RichText(
                text: TextSpan(
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                  children: [
                    const TextSpan(text: 'Create a new collection '),
                    TextSpan(
                      text: 'here',
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              ),
            ],
            const SizedBox(height: MallowTheme.spacingLg),
            MallowCheckbox(
              value: state.nsfw,
              onChanged: (_) =>
                  context.read<MintBloc>().add(const MintEvent.toggleNsfw()),
              label: nsfwLabel,
            ),
            // AI-generated flag only applies to a single artwork, not a
            // whole collection (webapp parity).
            if (!isCollection) ...[
              const SizedBox(height: MallowTheme.spacingMd),
              MallowCheckbox(
                value: aiSelected,
                onChanged: (_) {
                  final bloc = context.read<MintBloc>();
                  bloc.add(
                    aiSelected
                        ? const MintEvent.removeTag(_aiTag)
                        : const MintEvent.addTag(_aiTag),
                  );
                },
                label: 'This artwork was created using AI',
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _openCollectionPicker(
    BuildContext context,
    MintState state,
  ) async {
    if (state.userPubkey.isEmpty) return;
    final bloc = context.read<MintBloc>();
    final choice = await showMintCollectionPicker(
      context: context,
      userPubkey: state.userPubkey,
      current: state.collection,
    );
    // Dismissed without choosing — leave the current selection alone. For a
    // master edition, clearing it is an on-chain detach, so a stray swipe
    // must not commit one.
    if (choice == null) return;
    final selected = choice.selection;
    bloc.add(
      MintEvent.setCollection(
        collection: selected?.ref,
        name: selected?.name,
        source: selected?.source,
      ),
    );
  }
}

class _CollectionPickerPill extends StatelessWidget {
  const _CollectionPickerPill({
    required this.collectionName,
    required this.onTap,
  });

  final String? collectionName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          border: Border.all(color: colors.divider),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                collectionName ?? 'Choose a collection',
                style: MallowTheme.uiBody.copyWith(
                  color: collectionName == null
                      ? colors.textSecondary
                      : colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            MallowSvgIcon(
              'assets/icons/arrow_right.svg',
              width: 20,
              height: 20,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
