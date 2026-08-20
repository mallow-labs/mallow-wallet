import '../../../core/analytics/analytics_events.dart';
import '../../../core/result/app_failure.dart';

/// Maps an [AppFailure] onto the bounded analytics [FailureReason] taxonomy.
///
/// The kinds carry only coarse information, so this is a best-effort bucketing
/// (anything unclassifiable → [FailureReason.unknown]). Shared by the market /
/// listing / burn flows that surface an [AppFailure] on their terminal failure
/// state.
FailureReason analyticsFailureReason(AppFailure failure) =>
    FailureReason.fromAppFailureKind(failure.kind);
