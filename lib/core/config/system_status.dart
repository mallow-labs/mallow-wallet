import 'package:flutter/foundation.dart';

/// Scheduled-maintenance window, from the asset CDN's `status.json`.
///
/// The feed carries no `enabled` flag: the presence of a window plus the
/// current clock is the whole state machine, exactly as on the webapp
/// (its shared `ServerStatus` type). Both fields are required — a window
/// missing either end can't be rendered or bounded, so it is dropped at parse
/// time rather than shown with a hole in it.
@immutable
class MaintenanceWindow {
  const MaintenanceWindow({required this.startsAt, required this.endsAt});

  final DateTime startsAt;
  final DateTime endsAt;

  /// The webapp's dismissal key: dismissing one window must not suppress the
  /// *next* one, so the stored value is the window's own start instant.
  String get dismissKey => startsAt.toIso8601String();

  static MaintenanceWindow? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final maintenance = json['maintenance'];
    if (maintenance is! Map) return null;
    final startsAt = DateTime.tryParse('${maintenance['startsAt']}');
    final endsAt = DateTime.tryParse('${maintenance['endsAt']}');
    if (startsAt == null || endsAt == null) return null;
    return MaintenanceWindow(
      startsAt: startsAt.toLocal(),
      endsAt: endsAt.toLocal(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MaintenanceWindow &&
      other.startsAt == startsAt &&
      other.endsAt == endsAt;

  @override
  int get hashCode => Object.hash(startsAt, endsAt);
}

/// Operator broadcast, from the asset CDN's `notification-v2.json`.
///
/// [message] may contain `[text](url)` markdown links, which is the only
/// markup the webapp renders — see `parseMarkdownLinks`.
@immutable
class OperatorNotice {
  const OperatorNotice({required this.id, required this.message, this.endsAt});

  /// Bumping the id is how an operator re-shows a notice to users who
  /// dismissed the previous one, so it doubles as the dismissal key.
  final int id;
  final String message;

  /// When the notice stops showing. Null means "until the feed changes".
  final DateTime? endsAt;

  String get dismissKey => '$id';

  static OperatorNotice? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id'];
    final message = json['message'];
    if (id is! num || message is! String || message.trim().isEmpty) return null;
    final endsAtRaw = json['endsAt'];
    return OperatorNotice(
      id: id.toInt(),
      message: message,
      endsAt: endsAtRaw is String
          ? DateTime.tryParse(endsAtRaw)?.toLocal()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OperatorNotice &&
      other.id == id &&
      other.message == message &&
      other.endsAt == endsAt;

  @override
  int get hashCode => Object.hash(id, message, endsAt);
}

/// What the two CDN feeds currently say. Empty is the cold-start value —
/// nothing is announced. A failed fetch keeps whatever the last good one said,
/// so an outage in the CDN cannot retract a live announcement.
@immutable
class SystemStatus {
  const SystemStatus({this.maintenance, this.notice});

  static const empty = SystemStatus();

  final MaintenanceWindow? maintenance;
  final OperatorNotice? notice;

  @override
  bool operator ==(Object other) =>
      other is SystemStatus &&
      other.maintenance == maintenance &&
      other.notice == notice;

  @override
  int get hashCode => Object.hash(maintenance, notice);
}

/// How far ahead of a maintenance window the banner starts warning. The webapp
/// uses two days, which is the whole point of the feed: users get notice
/// *before* the outage rather than an unexplained failure during it.
const Duration kMaintenanceLeadTime = Duration(days: 2);

/// Which banner (if any) should be showing, given the feeds, the clock, and
/// what the user has already dismissed.
///
/// Maintenance outranks a notice, matching the webapp's `if / else if` order —
/// only ever one banner, and a scheduled outage is the more actionable of the
/// two.
sealed class SystemBanner {
  const SystemBanner();

  /// Key under which a dismissal is stored. Value-scoped, never a bare
  /// boolean: a new window or a bumped notice id has to re-show.
  String get dismissKey;
}

class MaintenanceBanner extends SystemBanner {
  const MaintenanceBanner(this.window);

  final MaintenanceWindow window;

  @override
  String get dismissKey => window.dismissKey;
}

class NoticeBanner extends SystemBanner {
  const NoticeBanner(this.notice);

  final OperatorNotice notice;

  @override
  String get dismissKey => notice.dismissKey;
}

/// Resolve [status] against [now] and the dismissal keys the user has stored.
///
/// A maintenance window shows only inside `[startsAt - 2 days, startsAt)`:
/// earlier is noise, and once the window has started the announcement is no
/// longer a warning. A notice shows as soon as the feed has one and until its
/// `endsAt` passes — it carries no start time.
SystemBanner? resolveSystemBanner({
  required SystemStatus status,
  required DateTime now,
  required String? dismissedMaintenanceKey,
  required String? dismissedNoticeKey,
}) {
  final window = status.maintenance;
  if (window != null &&
      now.isBefore(window.startsAt) &&
      now.isAfter(window.startsAt.subtract(kMaintenanceLeadTime)) &&
      dismissedMaintenanceKey != window.dismissKey) {
    return MaintenanceBanner(window);
  }
  final notice = status.notice;
  if (notice != null &&
      dismissedNoticeKey != notice.dismissKey &&
      (notice.endsAt == null || notice.endsAt!.isAfter(now))) {
    return NoticeBanner(notice);
  }
  return null;
}

/// One run of the banner body: either plain text or a `[text](url)` link.
@immutable
class NoticeSpan {
  const NoticeSpan(this.text, [this.url]);

  final String text;
  final String? url;

  bool get isLink => url != null;

  @override
  bool operator ==(Object other) =>
      other is NoticeSpan && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);
}

final _markdownLink = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');

/// Split [message] into plain and link runs, mirroring the webapp's
/// `parseMarkdownLinks`. Anything that isn't a `[text](url)` pair stays literal
/// text — the feed is operator-authored, not user-authored, but it is still not
/// a place to interpret arbitrary markup.
List<NoticeSpan> parseNoticeSpans(String message) {
  final spans = <NoticeSpan>[];
  var cursor = 0;
  for (final match in _markdownLink.allMatches(message)) {
    if (match.start > cursor) {
      spans.add(NoticeSpan(message.substring(cursor, match.start)));
    }
    spans.add(NoticeSpan(match.group(1)!, match.group(2)!));
    cursor = match.end;
  }
  if (cursor < message.length) {
    spans.add(NoticeSpan(message.substring(cursor)));
  }
  return spans;
}
