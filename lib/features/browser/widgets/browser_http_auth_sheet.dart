import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../models/browser_http_credentials.dart';

export '../models/browser_http_credentials.dart';

/// Asks for the username and password a site's HTTP authentication
/// (`WWW-Authenticate: Basic`, Digest, …) demands. Pops with the entered
/// credentials, or null when cancelled.
///
/// Names only [host], the server the credentials go to. The realm is text
/// the server chooses, so it is not shown: it could pose as anyone.
class BrowserHttpAuthSheet extends StatefulWidget {
  const BrowserHttpAuthSheet({
    required this.host,
    this.pageHost,
    this.failed = false,
    this.username,
    super.key,
  });

  final String host;

  /// The host of the page that triggered the request, when it is not [host].
  final String? pageHost;

  /// The last credentials for this server were rejected.
  final bool failed;

  /// Prefills the username, e.g. the one just rejected.
  final String? username;

  @override
  State<BrowserHttpAuthSheet> createState() => _BrowserHttpAuthSheetState();
}

class _BrowserHttpAuthSheetState extends State<BrowserHttpAuthSheet> {
  late final _username = TextEditingController(text: widget.username ?? '');
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _submit() {
    TextInput.finishAutofillContext();
    Navigator.of(context).pop<BrowserHttpCredentials>((
      username: _username.text,
      password: _password.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final body = MallowTheme.uiBody.copyWith(color: colors.textSecondary);
    final pageHost = widget.pageHost;
    final cancel = MallowButton(
      key: const Key('http-auth-cancel'),
      label: 'Cancel',
      variant: MallowButtonVariant.secondary,
      isFullWidth: true,
      onPressed: () => Navigator.of(context).pop(),
    );
    final signIn = MallowButton(
      key: const Key('http-auth-sign-in'),
      label: 'Sign in',
      isFullWidth: true,
      onPressed: _submit,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: AutofillGroup(
          // Offer to save only on Sign in, never on Cancel.
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetDragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacingSm,
                  MallowTheme.spacing20,
                  0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Sign in',
                      style: MallowTheme.editorialSection.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingSm),
                    Text(
                      '${widget.host} requires a username and password.',
                      style: body,
                    ),
                    if (pageHost != null) ...[
                      const SizedBox(height: MallowTheme.spacingXs),
                      Text(
                        'It was asked for by $pageHost, a different site.',
                        style: body,
                      ),
                    ],
                    if (widget.failed) ...[
                      const SizedBox(height: MallowTheme.spacingSm),
                      Text(
                        'That username or password was not accepted.',
                        key: const Key('http-auth-failed'),
                        style: MallowTheme.uiBody.copyWith(color: colors.error),
                      ),
                    ],
                    const SizedBox(height: MallowTheme.spacing20),
                    const MallowSectionLabel(label: 'Username'),
                    const SizedBox(height: MallowTheme.spacingSm),
                    MallowPillField(
                      key: const Key('http-auth-username'),
                      controller: _username,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      height: 48,
                      onSubmitted: (_) => _passwordFocus.requestFocus(),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    const MallowSectionLabel(label: 'Password'),
                    const SizedBox(height: MallowTheme.spacingSm),
                    MallowPillField(
                      key: const Key('http-auth-password'),
                      controller: _password,
                      focusNode: _passwordFocus,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.done,
                      height: 48,
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: MallowTheme.spacingLg),
                    // Large text stacks the buttons so neither label breaks.
                    if (MediaQuery.textScalerOf(context).scale(15) > 22) ...[
                      signIn,
                      const SizedBox(height: MallowTheme.spacingSm),
                      cancel,
                    ] else
                      Row(
                        children: [
                          Expanded(child: cancel),
                          const SizedBox(width: MallowTheme.spacingSm),
                          Expanded(child: signIn),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
