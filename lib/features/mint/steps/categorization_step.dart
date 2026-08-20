import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/text_span_tap_targets.dart';
import '../models/mint_form_models.dart';
import '../pickers/category_picker_sheet.dart';
import '../services/mint_bloc.dart';
import '../widgets/mint_trait_row.dart';

/// Categorization step.
///
/// Captures tags (free-form input + bulk-add via the categories picker) and
/// traits. Categories are stored as canonical-id entries inside [MintState.tags]
/// (e.g. `"Short Film" → "short-film"`) so the metadata payload stays a single
/// flat tag list — see `mintCategoryIdFor` for the mapping.
class CategorizationStep extends StatefulWidget {
  const CategorizationStep({super.key});

  @override
  State<CategorizationStep> createState() => _CategorizationStepState();
}

class _CategorizationStepState extends State<CategorizationStep> {
  final _tagsController = TextEditingController();
  final _traitController = TextEditingController();
  final _tagRecognizers = <String, TapGestureRecognizer>{};

  @override
  void dispose() {
    _tagsController.dispose();
    _traitController.dispose();
    for (final r in _tagRecognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _recognizerFor(String key, VoidCallback onTap) {
    final existing = _tagRecognizers[key];
    if (existing != null) {
      existing.onTap = onTap;
      return existing;
    }
    final created = TapGestureRecognizer()..onTap = onTap;
    _tagRecognizers[key] = created;
    return created;
  }

  void _pruneRecognizerKeys(Set<String> keep) {
    _tagRecognizers.removeWhere((key, recognizer) {
      if (keep.contains(key)) return false;
      recognizer.dispose();
      return true;
    });
  }

  void _addTag(BuildContext context) {
    final raw = _tagsController.text.trim();
    if (raw.isEmpty) return;
    context.read<MintBloc>().add(MintEvent.addTag(raw));
    _tagsController.clear();
  }

  void _addTrait(BuildContext context) {
    final raw = _traitController.text.trim();
    if (raw.isEmpty) return;
    context.read<MintBloc>().add(MintEvent.addTrait(raw));
    _traitController.clear();
  }

  Future<void> _openCategoryPicker(
    BuildContext context,
    List<String> currentTags,
  ) async {
    final bloc = context.read<MintBloc>();
    final initial = mintCategoryDisplayNamesFromTags(currentTags);
    final picked = await showMintCategoryPicker(
      context: context,
      initial: initial,
    );
    if (picked != null) {
      bloc.add(MintEvent.setCategories(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MintBloc, MintState>(
      buildWhen: (prev, next) =>
          prev.tags != next.tags ||
          prev.traits != next.traits ||
          prev.mintType != next.mintType,
      builder: (context, state) {
        final colors = context.mallowColors;
        final isCollection = state.mintType == MintCreateType.collection;
        final categoryNames = mintCategoryDisplayNamesFromTags(state.tags);
        // The Tags chip list intentionally hides category ids and the
        // disclosure tags ("nsfw", "ai") since those are surfaced via the
        // Categories pill and the Details-step checkboxes.
        final visibleTags = mintFilterOutCategories(
          state.tags,
        ).where((t) => t != 'nsfw' && t != 'ai').toList(growable: false);
        // Recognizers are pooled across both the tag list and (for collections)
        // the trait list — prefix keys so they don't collide.
        final activeRecognizerKeys = <String>{
          ...visibleTags.map((t) => 'tag:$t'),
          if (isCollection)
            for (var i = 0; i < state.traits.length; i++)
              'trait:$i:${state.traits[i].name}',
        };
        _pruneRecognizerKeys(activeRecognizerKeys);
        return ListView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          children: [
            const MallowSectionLabel(label: 'Categories', optional: true),
            const SizedBox(height: MallowTheme.spacingMd),
            _CategoriesPill(
              categoryNames: categoryNames,
              onTap: () => _openCategoryPicker(context, state.tags),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              'Categories help improve discoverability',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            const MallowSectionLabel(label: 'Tags', optional: true),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _tagsController,
              hintText: 'Add a tag and press enter',
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addTag(context),
            ),
            if (visibleTags.isNotEmpty) ...[
              const SizedBox(height: MallowTheme.spacingSm),
              _buildTagsList(context, visibleTags),
            ],
            const SizedBox(height: MallowTheme.spacingLg),
            const MallowSectionLabel(label: 'Traits', optional: true),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _traitController,
              hintText: 'Add a trait name and press enter',
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _addTrait(context),
            ),
            if (state.traits.isNotEmpty) ...[
              if (isCollection) ...[
                const SizedBox(height: MallowTheme.spacingSm),
                _buildTraitNamesList(context, state.traits),
              ] else ...[
                const SizedBox(height: MallowTheme.spacingLg),
                Text(
                  'Trait Details',
                  style: MallowTheme.uiLabel.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingMd),
                for (var i = 0; i < state.traits.length; i++) ...[
                  MintTraitRow(
                    name: state.traits[i].name,
                    value: state.traits[i].value,
                    onChanged: (value) => context.read<MintBloc>().add(
                      MintEvent.setTraitValue(i, value),
                    ),
                    onRemove: () =>
                        context.read<MintBloc>().add(MintEvent.removeTrait(i)),
                  ),
                  if (i < state.traits.length - 1)
                    const SizedBox(height: MallowTheme.spacingSm),
                ],
                if (state.traitsError != null) ...[
                  const SizedBox(height: MallowTheme.spacingXs),
                  Text(
                    state.traitsError!,
                    style: MallowTheme.uiCaption.copyWith(color: colors.error),
                  ),
                ],
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _buildTagsList(BuildContext context, List<String> tags) {
    final colors = context.mallowColors;
    final primaryStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textPrimary,
    );
    final secondaryStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );

    final spans = <InlineSpan>[
      TextSpan(text: 'Added (click to remove): ', style: secondaryStyle),
    ];
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i];
      final recognizer = _recognizerFor(
        'tag:$tag',
        () => context.read<MintBloc>().add(MintEvent.removeTag(tag)),
      );
      spans.add(
        TextSpan(text: '#$tag', style: primaryStyle, recognizer: recognizer),
      );
      if (i < tags.length - 1) {
        spans.add(TextSpan(text: ', ', style: secondaryStyle));
      }
    }
    return TextSpanTapTargets(span: TextSpan(children: spans));
  }

  /// Inline removable list for collection traits — keys-only, no `#` prefix.
  /// Mirrors `_buildTagsList` shape so the two read the
  /// same way visually.
  Widget _buildTraitNamesList(
    BuildContext context,
    List<MintTraitInput> traits,
  ) {
    final colors = context.mallowColors;
    final primaryStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textPrimary,
    );
    final secondaryStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );

    final spans = <InlineSpan>[
      TextSpan(text: 'Added (click to remove): ', style: secondaryStyle),
    ];
    for (var i = 0; i < traits.length; i++) {
      final name = traits[i].name;
      final recognizer = _recognizerFor(
        'trait:$i:$name',
        () => context.read<MintBloc>().add(MintEvent.removeTrait(i)),
      );
      spans.add(
        TextSpan(text: name, style: primaryStyle, recognizer: recognizer),
      );
      if (i < traits.length - 1) {
        spans.add(TextSpan(text: ', ', style: secondaryStyle));
      }
    }
    return TextSpanTapTargets(span: TextSpan(children: spans));
  }
}

class _CategoriesPill extends StatelessWidget {
  const _CategoriesPill({required this.categoryNames, required this.onTap});

  final List<String> categoryNames;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isEmpty = categoryNames.isEmpty;
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
                isEmpty ? 'Choose Categories' : categoryNames.join(', '),
                style: MallowTheme.uiBody.copyWith(
                  color: isEmpty ? colors.textSecondary : colors.textPrimary,
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
