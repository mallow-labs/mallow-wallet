import 'package:freezed_annotation/freezed_annotation.dart';

part 'mint_form_models.freezed.dart';

/// A single `{trait_type, value}` row the user is editing in the
/// Categorization step. Value is optional while the user is still typing.
@freezed
sealed class MintTraitInput with _$MintTraitInput {
  const factory MintTraitInput({
    required String name,
    @Default('') String value,
  }) = _MintTraitInput;
}

/// A proceed-split row on the Royalties step. The creator at index 0 is
/// the current user and is rendered read-only (marked [isSelf]).
@freezed
sealed class MintCreatorInput with _$MintCreatorInput {
  const factory MintCreatorInput({
    required String address,
    @Default('100') String shareText,
    @Default(false) bool isSelf,
  }) = _MintCreatorInput;
}
