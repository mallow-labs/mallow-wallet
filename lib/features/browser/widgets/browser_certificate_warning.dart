import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/signing_review_layout.dart';
import '../services/browser_certificate_exceptions.dart';

/// The page shown instead of a website whose certificate is not trusted.
///
/// Opaque, so nothing of a half-loaded page shows through. The safe choice
/// is the only prominent one; proceeding sits behind "Advanced", and is
/// absent altogether when [BrowserCertificateFailure.overridable] is false.
class BrowserCertificateWarning extends StatefulWidget {
  const BrowserCertificateWarning({
    required this.failure,
    required this.onBack,
    required this.onProceed,
    super.key,
  });

  final BrowserCertificateFailure failure;
  final VoidCallback onBack;
  final VoidCallback onProceed;

  @override
  State<BrowserCertificateWarning> createState() =>
      _BrowserCertificateWarningState();
}

class _BrowserCertificateWarningState extends State<BrowserCertificateWarning> {
  bool _advanced = false;

  @override
  void didUpdateWidget(BrowserCertificateWarning old) {
    super.didUpdateWidget(old);
    if (old.failure.url != widget.failure.url) _advanced = false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final failure = widget.failure;
    final host = failure.url.hasPort
        ? '${failure.url.host}:${failure.url.port}'
        : failure.url.host;
    final body = MallowTheme.uiBody.copyWith(color: colors.textSecondary);
    return ColoredBox(
      color: colors.bgPrimary,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            MallowTheme.spacingLg,
            MallowTheme.spacingLg * 2,
            MallowTheme.spacingLg,
            MallowTheme.spacingLg * 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReviewIcon(ReviewGlyph.warning, size: 40, color: colors.error),
              const SizedBox(height: MallowTheme.spacingMd),
              Text(
                'Your connection is not private',
                style: MallowTheme.uiTitle.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                'Attackers might be trying to steal your information from '
                '$host, such as passwords, messages or access to your wallet.',
                style: body,
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                failure.reason,
                style: MallowTheme.uiMeta.copyWith(color: colors.textTertiary),
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(
                key: const Key('certificate-back'),
                label: 'Back to safety',
                isFullWidth: true,
                onPressed: widget.onBack,
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              MallowButton(
                key: const Key('certificate-advanced'),
                label: _advanced ? 'Hide advanced' : 'Advanced',
                variant: MallowButtonVariant.text,
                isFullWidth: true,
                onPressed: () => setState(() => _advanced = !_advanced),
              ),
              if (_advanced) ...[
                const SizedBox(height: MallowTheme.spacingSm),
                if (failure.overridable) ...[
                  Text(
                    "This device can't confirm that the server is $host: its "
                    'security certificate is not trusted. This can be a '
                    'misconfiguration, or someone intercepting your connection.',
                    style: body,
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'Continue only to a site you run yourself, such as a '
                    'development server on your own network. Never connect '
                    'your wallet or approve a transaction on a site you '
                    "aren't sure of. Once you proceed, $host won't warn "
                    'again for this certificate until you clear browsing '
                    'data. A different certificate warns again.',
                    style: body,
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  MallowButton(
                    key: const Key('certificate-proceed'),
                    label: 'Proceed to $host (unsafe)',
                    variant: MallowButtonVariant.secondary,
                    foregroundColor: colors.error,
                    isFullWidth: true,
                    onPressed: widget.onProceed,
                  ),
                ] else
                  Text(
                    "$host's certificate can't be verified, and this error "
                    "can't be bypassed.",
                    style: body,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
