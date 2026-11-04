import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/review_wallet_identity.dart';
import '../../../shared/widgets/signing_review_layout.dart';
import '../models/dapp_message_review.dart';
import 'browser_site_tile.dart';

/// Native review for a website's message signature (`signMessage`,
/// `personal_sign`). A Sign In With Solana or Ethereum message gets a
/// structured card only when the whole message fits the sign-in grammar
/// ([DappMessageReview.signInFields] is strict), so no line can hide behind
/// it; anything else is shown verbatim (UTF-8, or hex in
/// the monospace face) under the off-chain authorization warning. The exact
/// bytes and digest are always one tap away.
///
/// The host in the title comes from [DappMessageReview.origin], the native
/// committed origin; the message's own domain claim is only ever compared
/// against it, never shown in its place.
class MessageSigningReview extends StatelessWidget {
  const MessageSigningReview({
    required this.review,
    required this.onReject,
    required this.onApprove,
    this.iconUrl,
    this.wallet,
    super.key,
  });

  final DappMessageReview review;
  final VoidCallback onReject, onApprove;

  /// The requesting tab's icon. Decoration only.
  final Uri? iconUrl;

  /// Defaults to resolving [DappMessageReview.address] against the session.
  final ReviewWalletIdentity? wallet;

  @override
  Widget build(BuildContext context) {
    final identity = wallet ?? ReviewWalletIdentity.resolve(review.address);
    final fields = review.signInFields;
    return fields.isEmpty
        ? _message(context, identity)
        : _signIn(context, identity, fields);
  }

  Uri get _origin => Uri.parse(review.origin);

  Widget _hero(BuildContext context) {
    final colors = context.mallowColors;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.18),
              offset: const Offset(0, 8),
              blurRadius: 20,
            ),
          ],
        ),
        child: BrowserSiteTile(host: _origin.host, iconUrl: iconUrl, size: 60),
      ),
    );
  }

  Widget _subtitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: MallowTheme.uiBody.copyWith(
        fontSize: 14,
        height: 1.45,
        color: context.mallowColors.textSecondary,
      ),
    ),
  );

  Widget _signIn(
    BuildContext context,
    ReviewWalletIdentity identity,
    Map<String, String> fields,
  ) {
    final colors = context.mallowColors;
    final matches = fields['Domain'] == _origin.authority;
    final networkWarning = review.signInNetworkWarning;
    final statement = review.signInStatement;
    final expires = fields['Expiration Time'];
    final nonce = fields['Nonce'];
    const shown = {'Domain', 'Account', 'Expiration Time', 'Nonce'};
    // Each row takes whether it closes the card, which drops its hairline.
    final rows = <Widget Function(bool last)>[
      (last) => ReviewKvRow(
        // The domain is the message's own claim; it is only called the
        // website when it equals the committed origin.
        label: matches ? 'Website' : 'Message domain',
        dense: true,
        divider: !last,
        valueWidget: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                fields['Domain']!,
                textAlign: TextAlign.right,
                style: MallowTheme.uiBody.copyWith(
                  fontSize: 14,
                  color: matches ? colors.textPrimary : colors.warning,
                ),
              ),
            ),
            if (matches) ...[
              const SizedBox(width: 6),
              Semantics(
                label: 'matches this website',
                child: ReviewIcon(
                  ReviewGlyph.check,
                  size: 15,
                  color: colors.positive,
                ),
              ),
            ],
          ],
        ),
      ),
      (last) => ReviewKvRow(
        label: 'Wallet',
        dense: true,
        divider: !last,
        value: identity.name == null
            ? identity.shortAddress
            : '${identity.label} · ${identity.shortAddress}',
      ),
      if (statement != null)
        (last) => Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            border: last
                ? null
                : Border(bottom: BorderSide(color: colors.dividerLight)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Statement',
                style: MallowTheme.uiBody.copyWith(
                  fontSize: 14,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                '“$statement”',
                style: MallowTheme.editorialSubhead.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      for (final field in fields.entries)
        if (!shown.contains(field.key))
          (last) => ReviewKvRow(
            label: field.key,
            value: field.value,
            dense: true,
            divider: !last,
          ),
      if (expires != null)
        (last) => ReviewKvRow(
          label: 'Expires',
          value: _expiry(expires),
          dense: true,
          divider: !last,
        ),
      if (nonce != null)
        (last) => ReviewKvRow(
          label: 'Nonce',
          dense: true,
          divider: !last,
          valueWidget: Text(
            nonce.length > 12
                ? '${nonce.substring(0, 4)}…${nonce.substring(nonce.length - 4)}'
                : nonce,
            style: reviewMonoStyle.copyWith(
              fontSize: 13,
              color: colors.textPrimary,
            ),
          ),
        ),
    ];
    return SigningReviewLayout(
      footerDivider: false,
      footer: ReviewDecisionBar(
        rejectKey: const Key('reject-signing'),
        approveKey: const Key('approve-signing'),
        rejectLabel: 'Cancel',
        approveLabel: matches ? 'Sign in' : 'Sign',
        onReject: onReject,
        onApprove: onApprove,
      ),
      children: [
        const SizedBox(height: 12),
        _hero(context),
        const SizedBox(height: 18),
        ReviewTitle(
          matches ? 'Sign in to ${_origin.host}' : 'Review sign-in request',
        ),
        _subtitle(
          context,
          'This proves you own ${identity.label}. It is a signature, not a transaction, and costs nothing.',
        ),
        if (!matches) ...[
          const SizedBox(height: 18),
          ReviewCautionCard(
            title: 'The sign-in domain does not match this website.',
            messages: [
              'The message asks to sign in to ${fields['Domain']}, but this request comes from ${review.origin}.',
            ],
          ),
        ],
        if (networkWarning != null) ...[
          const SizedBox(height: 18),
          ReviewCautionCard(
            title: 'The sign-in network does not match this wallet.',
            messages: [networkWarning],
          ),
        ],
        const SizedBox(height: 20),
        _Card(
          children: [
            for (final (i, row) in rows.indexed) row(i == rows.length - 1),
          ],
        ),
        const SizedBox(height: 6),
        ReviewDisclosure(
          key: const Key('message-full'),
          label: 'View full message',
          dense: true,
          child: _Exact(review: review, showText: true),
        ),
      ],
    );
  }

  Widget _message(BuildContext context, ReviewWalletIdentity identity) {
    final colors = context.mallowColors;
    final text = review.text;
    return SigningReviewLayout(
      footer: ReviewDecisionBar(
        rejectKey: const Key('reject-signing'),
        approveKey: const Key('approve-signing'),
        approveLabel: 'Sign',
        onReject: onReject,
        onApprove: onApprove,
      ),
      children: [
        const SizedBox(height: 12),
        _hero(context),
        const SizedBox(height: 18),
        const ReviewTitle('Sign a message'),
        const SizedBox(height: 8),
        ReviewInfoLine(
          '${_origin.host} is asking for your signature. It is not a transaction and costs nothing to sign, but a message signature can authorize off-chain actions, orders, or future asset movement. Only sign if you trust this website.',
          iconColor: colors.warning,
        ),
        const SizedBox(height: 4),
        ReviewSectionLabel(text == null ? 'Message bytes (hex)' : 'Message'),
        _Card(
          padding: const EdgeInsets.all(14),
          children: [
            SelectableText(
              review.display,
              style: text == null
                  ? reviewMonoStyle.copyWith(color: colors.textPrimary)
                  : MallowTheme.uiBody.copyWith(
                      height: 1.45,
                      color: colors.textPrimary,
                    ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ReviewKvRow(
          label: 'Wallet',
          value: identity.name == null
              ? identity.shortAddress
              : '${identity.label} · ${identity.shortAddress}',
        ),
        ReviewDisclosure(
          key: const Key('message-full'),
          label: 'Exact bytes and digest',
          child: _Exact(review: review, showText: false),
        ),
      ],
    );
  }
}

/// "in 10 minutes" for a parseable ISO time, else the raw value.
String _expiry(String raw) {
  final at = DateTime.tryParse(raw);
  if (at == null) return raw;
  final left = at.toUtc().difference(DateTime.now().toUtc());
  if (left.isNegative) return 'Expired';
  if (left.inMinutes < 1) return 'in under a minute';
  if (left.inMinutes < 60) {
    return 'in ${left.inMinutes} minute${left.inMinutes == 1 ? '' : 's'}';
  }
  if (left.inHours < 48) {
    return 'in ${left.inHours} hour${left.inHours == 1 ? '' : 's'}';
  }
  return raw;
}

class _Card extends StatelessWidget {
  const _Card({
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
  });
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.dividerLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _Exact extends StatelessWidget {
  const _Exact({required this.review, required this.showText});
  final DappMessageReview review;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final mono = reviewMonoStyle.copyWith(color: colors.textPrimary);
    final label = MallowTheme.uiLabel.copyWith(color: colors.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showText && review.text != null) ...[
          Text('Message', style: label),
          const SizedBox(height: 4),
          SelectableText(
            review.text!,
            style: MallowTheme.uiMeta.copyWith(
              height: 1.45,
              letterSpacing: 0,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
        ],
        _CopyBlock(
          label: review.digestLabel,
          value: review.digest,
          style: mono,
        ),
        const SizedBox(height: 12),
        _CopyBlock(
          label: 'Hex',
          value: review.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          style: mono,
        ),
      ],
    );
  }
}

/// A labelled value copied whole with one tap, confirmed by a toast.
class _CopyBlock extends StatelessWidget {
  const _CopyBlock({
    required this.label,
    required this.value,
    required this.style,
  });
  final String label;
  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Semantics(
      button: true,
      label: 'Copy $label',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          AppSnackBar.show(context, '$label copied');
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: MallowTheme.uiLabel.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                ReviewIcon(
                  ReviewGlyph.copy,
                  size: 14,
                  color: colors.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(value, style: style),
          ],
        ),
      ),
    );
  }
}
