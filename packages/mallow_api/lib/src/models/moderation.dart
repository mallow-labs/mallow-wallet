import 'package:freezed_annotation/freezed_annotation.dart';

import '../generated/openapi.enums.swagger.dart';

part 'moderation.freezed.dart';
part 'moderation.g.dart';

/// The report reasons that are legal to *send*, in spec order.
///
/// The generated enums append a `swaggerGeneratedUnknown` member so an
/// unrecognised value off the wire parses instead of throwing. It is an inbound
/// fallback only — it has no wire value, so sending it would 400. Anything
/// rendering a picker or iterating the taxonomy must use these lists rather
/// than `.values`.
final List<ReportReason> reportableReasons = List.unmodifiable(
  ReportReason.values.where((r) => r != ReportReason.swaggerGeneratedUnknown),
);

/// The report target types that are legal to send. See [reportableReasons].
final List<ReportTargetType> reportableTargetTypes = List.unmodifiable(
  ReportTargetType.values.where((t) => t != ReportTargetType.swaggerGeneratedUnknown),
);

/// Where the report was filed from, attached automatically by the client so a
/// human triaging the report can reproduce what the reporter saw.
///
/// Hand-written on purpose, and the only moderation model that is: the spec
/// types `ReportRequest.context` as a free-form object (`properties: {}`) so
/// the client can add fields without a server deploy, which generates as a
/// bare `Object?`. This gives that blob a shape on the client side. It is
/// serialised with [toJson] at the call site and is *not* a wire contract —
/// nothing server-side validates it.
///
/// Everything else on the moderation surface (`ReportRequest`, `BlockRequest`,
/// `BlockedAccount`, `ReportTargetType`, `ReportReason`) comes from the
/// generated spec models, re-exported by `models/models.dart`.
@freezed
sealed class ReportContext with _$ReportContext {
  const factory ReportContext({
    /// Route/screen name the report sheet was opened from.
    @JsonKey(includeIfNull: false) String? screen,

    /// App version string (e.g. `1.4.0+312`).
    @JsonKey(includeIfNull: false) String? appVersion,

    /// `ios` | `android`.
    @JsonKey(includeIfNull: false) String? platform,
  }) = _ReportContext;

  factory ReportContext.fromJson(Map<String, dynamic> json) => _$ReportContextFromJson(json);
}
