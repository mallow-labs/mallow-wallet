import 'package:mallow_api/mallow_api.dart' as api;

/// UI-side companions to the moderation wire types.
///
/// The taxonomy itself (`ReportTargetType`, `ReportReason`), the request bodies
/// and the `GET /v2/blocks` row are all generated from the OpenAPI spec and
/// re-exported by `packages/mallow_api` — the spec is the contract. Nothing in
/// this file redeclares them; it adds only what the wire has no opinion about:
/// display copy and the outcome the UI branches on.
///
/// Both generated enums carry a `swaggerGeneratedUnknown` member for values
/// the spec doesn't list. It is never a legal thing to *send*, so the report
/// sheet filters it out of the picker (`api.reportableReasons`) and the
/// switches below map it to `other`/`content` rather than throwing.

/// Lower-case noun used in user-facing copy ("Report artwork").
extension ReportTargetNoun on api.ReportTargetType {
  String get noun => switch (this) {
    api.ReportTargetType.artwork => 'artwork',
    api.ReportTargetType.user => 'account',
    api.ReportTargetType.curation => 'curation',
    api.ReportTargetType.swaggerGeneratedUnknown => 'content',
  };
}

/// Row label in the report sheet, in the order the sheet renders them
/// (`api.reportableReasons`).
extension ReportReasonLabel on api.ReportReason {
  String get label => switch (this) {
    api.ReportReason.sexualContent => 'Sexual content',
    api.ReportReason.violenceGore => 'Violence or gore',
    api.ReportReason.hate => 'Hate',
    api.ReportReason.spamScam => 'Spam or scam',
    api.ReportReason.copyrightImpersonation => 'Copyright or impersonation',
    api.ReportReason.other => 'Other',
    api.ReportReason.swaggerGeneratedUnknown => 'Other',
  };
}

/// Best available human label for a blocked account, falling back to the raw
/// address — a blocked address may have no mallow profile at all.
extension BlockedAccountLabel on api.BlockedAccount {
  String get label {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final handle = username?.trim();
    if (handle != null && handle.isNotEmpty) return '@$handle';
    return address;
  }
}

/// Where the note counter starts warning. **Not a hard cap** — the backend
/// trims and truncates on a char boundary and never 400s, so blocking input at
/// the boundary would silently eat the tail of a pasted report. Losing a whole
/// report to a long paste is the worse trade.
const int reportNoteSoftLimit = 1000;

/// Outcome of a `POST /v2/reports` attempt.
///
/// [rateLimited] is a *soft success*: the daily cap was hit, but the UI must
/// behave exactly as [submitted] — same confirmation, same local hide — so a
/// spammer is never told how the limit works.
enum ReportOutcome { submitted, rateLimited, failed }
