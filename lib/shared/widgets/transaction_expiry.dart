import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'signing_review_layout.dart';

/// How long the transaction under review stays acceptable to its network.
sealed class TransactionExpiry {
  const TransactionExpiry();
}

/// The first measurement is still in flight.
final class ExpiryChecking extends TransactionExpiry {
  const ExpiryChecking();
}

/// Expires in about [remaining]. A conservative estimate: it runs out before
/// the network stops accepting the transaction, never after.
final class ExpiryCountdown extends TransactionExpiry {
  const ExpiryCountdown(this.remaining);
  final Duration remaining;
}

/// Still valid, but how long for could not be measured. It lasts at most
/// [atMost] from when it was created.
final class ExpiryUnmeasured extends TransactionExpiry {
  const ExpiryUnmeasured(this.atMost);
  final Duration atMost;
}

/// The network never expires it: a durable nonce stands in for the blockhash.
/// The wallet's own review window still closes, in [reviewRemaining] once the
/// review is shown.
final class ExpiryNever extends TransactionExpiry {
  const ExpiryNever({this.reviewRemaining});
  final Duration? reviewRemaining;
}

/// The network no longer accepts it. Final: a review never leaves this state.
final class ExpiryPassed extends TransactionExpiry {
  const ExpiryPassed();
}

/// What a review sheet needs to show a transaction's expiry: the ticking
/// [state] and the facts the copy depends on.
class TransactionExpiryView {
  const TransactionExpiryView({
    required this.state,
    required this.origin,
    this.slowSigner,
    this.siteSubmits = false,
  });

  final ValueListenable<TransactionExpiry> state;

  /// The site's host, as the copy names it.
  final String origin;

  /// A signer whose signature takes long enough to matter, such as `Ledger`.
  /// Its warning shows for the whole countdown, not only near the end.
  final String? slowSigner;

  /// The site receives the signed transaction and submits it itself. Without
  /// an expiry it can then submit it at any time, which the review says.
  final bool siteSubmits;

  /// With less than this left the review warns. Long enough to read the
  /// warning; short of a blockhash's whole life, which at the current block
  /// rate is about half a minute.
  static const warnBelow = Duration(seconds: 10);

  bool warns(TransactionExpiry expiry) =>
      expiry is ExpiryCountdown &&
      (slowSigner != null || expiry.remaining <= warnBelow);
}

/// The Expires row, plus a Review closes row for a durable-nonce transaction.
List<Widget> transactionExpiryRows(
  BuildContext context,
  TransactionExpiryView view,
  TransactionExpiry expiry,
) {
  final colors = context.mallowColors;
  final warning = view.warns(expiry);
  return [
    ReviewKvRow(
      key: const Key('review-expires'),
      label: 'Expires',
      value: switch (expiry) {
        ExpiryChecking() => 'Checking…',
        ExpiryCountdown(:final remaining) => _countdown(remaining),
        ExpiryUnmeasured(:final atMost) => 'Within about ${_span(atMost)}',
        ExpiryNever() => 'Never (durable nonce)',
        ExpiryPassed() => 'Expired',
      },
      valueColor: switch (expiry) {
        ExpiryPassed() => colors.error,
        ExpiryChecking() || ExpiryUnmeasured() => colors.textSecondary,
        _ when warning => colors.warning,
        _ => null,
      },
    ),
    if (expiry case ExpiryNever(:final reviewRemaining?))
      ReviewKvRow(
        key: const Key('review-closes'),
        label: 'Review closes',
        value: 'in ${_clock(reviewRemaining)}',
      ),
  ];
}

/// The card that explains a short, passed or absent expiry, or nothing.
Widget transactionExpiryNotice(
  TransactionExpiryView view,
  TransactionExpiry expiry,
) {
  const key = Key('review-expiry-notice');
  final origin = view.origin;
  if (expiry is ExpiryPassed) {
    return ReviewCautionCard(
      key: key,
      title: 'This transaction expired',
      messages: [
        'The network no longer accepts it. Close this and try again on $origin.',
      ],
    );
  }
  if (expiry is ExpiryNever && view.siteSubmits) {
    return ReviewCautionCard(
      key: key,
      title: "This transaction doesn't expire",
      messages: [
        'It uses a durable nonce, so $origin can submit the signed transaction at any time, not just now.',
      ],
    );
  }
  if (expiry is ExpiryCountdown && view.warns(expiry)) {
    final seconds = _seconds(expiry.remaining);
    final unit = seconds == 1 ? 'second' : 'seconds';
    return ReviewCautionCard(
      key: key,
      title: switch (view.slowSigner) {
        final signer? => 'About $seconds $unit left to sign on your $signer',
        null => 'Expires in about $seconds $unit',
      },
      messages: [
        view.slowSigner == null
            ? 'After that the network rejects it, and $origin has to create a new one.'
            : 'If it runs out first, $origin has to create a new transaction.',
      ],
    );
  }
  return const SizedBox.shrink();
}

/// Whether [transactionExpiryNotice] shows a card for [expiry].
bool transactionExpiryHasNotice(
  TransactionExpiryView view,
  TransactionExpiry expiry,
) =>
    expiry is ExpiryPassed ||
    (expiry is ExpiryNever && view.siteSubmits) ||
    view.warns(expiry);

int _seconds(Duration d) => d.inSeconds;

String _countdown(Duration remaining) {
  if (remaining.inSeconds < 1) return 'Expiring…';
  return 'in ~${_span(remaining)}';
}

/// `41 s`, or `1:05` from a minute up.
String _span(Duration d) => d.inSeconds < 60 ? '${d.inSeconds} s' : _clock(d);

String _clock(Duration d) {
  final seconds = d.isNegative ? 0 : d.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
