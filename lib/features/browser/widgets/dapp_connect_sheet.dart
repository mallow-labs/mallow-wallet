import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/review_wallet_identity.dart';
import '../../../shared/widgets/signing_review_layout.dart';
import '../../../shared/widgets/switch_pill.dart';
import '../models/dapp_request.dart';
import 'browser_site_tile.dart';

/// The connection prompt, as a route the caller pushes and keeps: cancelling
/// the request must remove exactly this route (`navigator.removeRoute`), never
/// pop whatever happens to be on top. It must stay a [PopupRoute]: a page route
/// suspends the website and cancels the request it is asking about.
///
/// Pops `true` to connect and `false` to reject; a dismissal pops null, which
/// the caller treats as a rejection. [iconUrl] is decoration only; the origin
/// shown is always [DappFrameContext.canonicalOrigin], never page-supplied.
///
/// [onSwitch] backs the wallet card's Switch. The request is pinned to the
/// wallet it was made with, so a different pick cannot approve this one: the
/// caller removes this route (a rejection) and asks the page to connect again
/// once the new wallet is active.
Route<bool> dappConnectRoute({
  required BuildContext context,
  required DappConnectionRequest request,
  Uri? iconUrl,
  VoidCallback? onSwitch,
}) => mallowSheetRoute<bool>(
  context: context,
  isScrollControlled: true,
  builder: (_) =>
      _DappConnectSheet(request: request, iconUrl: iconUrl, onSwitch: onSwitch),
);

class _DappConnectSheet extends StatelessWidget {
  const _DappConnectSheet({
    required this.request,
    required this.iconUrl,
    required this.onSwitch,
  });

  final DappConnectionRequest request;
  final Uri? iconUrl;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final origin = request.context.origin;
    final wallet = request.wallet;
    final identity = ReviewWalletIdentity.resolve(wallet.address);
    final network = wallet.chains.length == 1
        ? caip2NetworkLabel(wallet.chains.single)
        : 'Solana';
    // Mirrors the three grants the connection can carry: full signing,
    // transactions without messages, and view-only.
    final permissions = [
      const _Permission(ReviewGlyph.eye, 'See your address and balances'),
      if (!wallet.canSign)
        const _Permission(
          ReviewGlyph.cross,
          "Can't request signatures",
          detail: 'This wallet is view-only',
          muted: true,
        )
      else if (wallet.canSignMessages)
        const _Permission(
          ReviewGlyph.pencil,
          'Request transactions and signatures',
          detail: 'You approve each one here',
        )
      else
        const _Permission(
          ReviewGlyph.pencil,
          'Request transactions',
          detail:
              "You approve each one here. Message signing isn't available for this wallet.",
        ),
      _Permission(
        ReviewGlyph.cross,
        wallet.canSign
            ? 'It can never move funds without asking'
            : 'It can never move funds',
        muted: true,
      ),
    ];
    return SigningReviewLayout(
      footerDivider: false,
      footer: ReviewDecisionBar(
        rejectKey: const Key('reject-connect'),
        approveKey: const Key('approve-connect'),
        rejectLabel: 'Not now',
        approveLabel: 'Connect',
        onReject: () => _pop(context, false),
        onApprove: () => _pop(context, true),
      ),
      children: [
        const SizedBox(height: 14),
        _Hero(host: origin.host, iconUrl: iconUrl, identity: identity),
        const SizedBox(height: 22),
        ReviewTitle('Connect to ${origin.host}?'),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (request.context.certificateException) ...[
              ReviewIcon(ReviewGlyph.warning, size: 11, color: colors.error),
              const SizedBox(width: 6),
            ] else if (origin.scheme == 'https') ...[
              ReviewIcon(
                ReviewGlyph.lock,
                size: 11,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                request.context.canonicalOrigin,
                textAlign: TextAlign.center,
                style: MallowTheme.uiMeta.copyWith(
                  letterSpacing: 0,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (request.context.certificateException) ...[
          const SizedBox(height: 10),
          Text(
            "This site's certificate is not trusted, so it may not be "
            '${origin.host}. Connect only if you run this site yourself.',
            key: const Key('connect-certificate-warning'),
            textAlign: TextAlign.center,
            style: MallowTheme.uiMeta.copyWith(
              letterSpacing: 0,
              color: colors.error,
            ),
          ),
        ],
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: colors.bgPrimary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colors.dividerLight),
          ),
          child: Row(
            children: [
              // The identity reads as one node; Switch stays its own button.
              Expanded(
                child: MergeSemantics(
                  child: Row(
                    children: [
                      ReviewWalletAvatar(identity: identity, size: 36),
                      const SizedBox(width: MallowTheme.spacingMd),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              identity.label,
                              style: MallowTheme.uiBody.copyWith(
                                fontWeight: FontWeight.w500,
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${identity.shortAddress} · $network',
                              style: MallowTheme.uiMeta.copyWith(
                                letterSpacing: 0,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (onSwitch != null) ...[
                const SizedBox(width: MallowTheme.spacingSm),
                SwitchPill(
                  key: const Key('connect-switch-wallet'),
                  onTap: onSwitch,
                  semanticLabel: 'Switch wallet',
                ),
              ],
            ],
          ),
        ),
        const ReviewSectionLabel('This site will be able to'),
        for (final (i, permission) in permissions.indexed) ...[
          if (i > 0) const SizedBox(height: 14),
          permission,
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Pops only while this sheet is the top route, so a late tap can never close
/// a newer route stacked above it.
void _pop(BuildContext context, bool result) {
  if (ModalRoute.of(context)?.isCurrent ?? false) {
    Navigator.of(context).pop(result);
  }
}

/// Site tile and wallet avatar joined by a dashed link.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.host,
    required this.iconUrl,
    required this.identity,
  });

  final String host;
  final Uri? iconUrl;
  final ReviewWalletIdentity identity;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DecoratedBox(
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
            child: BrowserSiteTile(host: host, iconUrl: iconUrl, size: 64),
          ),
          SizedBox(
            width: 72,
            height: 32,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 6,
                  right: 6,
                  child: CustomPaint(
                    size: const Size.fromHeight(2),
                    painter: _DashPainter(colors.divider),
                  ),
                ),
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.bgSurface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.dividerLight),
                  ),
                  child: const ReviewIcon(ReviewGlyph.link, size: 15),
                ),
              ],
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.30),
                  offset: const Offset(0, 8),
                  blurRadius: 20,
                ),
              ],
            ),
            child: ReviewWalletAvatar(identity: identity, size: 64),
          ),
        ],
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.height;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + 4).clamp(0, size.width), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

class _Permission extends StatelessWidget {
  const _Permission(this.glyph, this.text, {this.detail, this.muted = false});

  final ReviewGlyph glyph;
  final String text;
  final String? detail;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: ReviewIcon(
              glyph,
              size: 16,
              color: muted ? colors.textSecondary : colors.textPrimary,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: MallowTheme.uiBody.copyWith(
                      height: 1.35,
                      color: muted ? colors.textSecondary : colors.textPrimary,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      style: MallowTheme.uiMeta.copyWith(
                        letterSpacing: 0,
                        height: 1.35,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
