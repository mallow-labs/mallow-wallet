import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../artwork/services/active_wallet_verification.dart';
import '../data/user_profile_repository.dart';

/// Bottom sheet that adds/verifies an email via OTP.
///
/// Step 1 collects an email and sends a one-time code (`POST /v1/otp`).
/// Step 2 collects the code and verifies it (`POST /v1/otp/verify`); on
/// success the backend attaches the email to the account. Returns the
/// verified email string, or null if the user dismissed the flow.
///
/// Not part of the Figma design — styled to match the app's other sheets.
Future<String?> showEmailOtpSheet(
  BuildContext context, {
  String? initialEmail,
}) {
  return showMallowSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EmailOtpSheet(initialEmail: initialEmail),
  );
}

class _EmailOtpSheet extends StatefulWidget {
  const _EmailOtpSheet({this.initialEmail});

  final String? initialEmail;

  @override
  State<_EmailOtpSheet> createState() => _EmailOtpSheetState();
}

enum _Step { enterEmail, enterCode }

class _EmailOtpSheetState extends State<_EmailOtpSheet> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _repo = sl<UserProfileRepository>();

  _Step _step = _Step.enterEmail;
  String _email = '';
  String? _error;
  bool _busy = false;

  static final _emailPattern = RegExp(r'^[\w.\-]+@([\w\-]+\.)+[\w\-]{2,}$');

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null) {
      _emailController.text = widget.initialEmail!;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!_emailPattern.hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Both OTP routes take a signed login. Prove the wallet on the tap, so a
    // social wallet missing its key gets its re-login, not a failed send.
    final verifyError = await ensureActiveWalletVerified();
    if (!mounted) return;
    if (verifyError != null) {
      setState(() {
        _busy = false;
        _error = verifyError;
      });
      return;
    }
    try {
      await _repo.sendEmailOtp(email);
      if (!mounted) return;
      setState(() {
        _email = email;
        _step = _Step.enterCode;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(e);
      });
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the code from your email');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final verifyError = await ensureActiveWalletVerified();
    if (!mounted) return;
    if (verifyError != null) {
      setState(() {
        _busy = false;
        _error = verifyError;
      });
      return;
    }
    try {
      await _repo.verifyEmailOtp(code);
      if (!mounted) return;
      Navigator.of(context).pop(_email);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(e);
      });
    }
  }

  Future<void> _resend() async {
    setState(() => _step = _Step.enterEmail);
  }

  /// The backend's own refusal text when it sent one (a wrong code, an
  /// address already taken, a wait before asking again), since each tells
  /// the user what to do next. The generic line is only for
  /// a failure with no message (offline, a timeout).
  String _messageFor(Object e) {
    if (e is DioException) {
      final message = _refusalMessage(e.response?.data);
      if (message != null) return message;
    }
    final text = e.toString();
    final match = RegExp(r'message: ([^,)}]+)').firstMatch(text);
    return match?.group(1)?.trim() ?? 'Something went wrong. Please try again.';
  }

  /// `error.message` (current envelope) or `err.message` (legacy).
  static String? _refusalMessage(Object? body) {
    if (body is! Map) return null;
    for (final key in const ['error', 'err']) {
      final error = body[key];
      if (error is Map) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: sheetBottomInset(context, includeKeyboard: false),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetDragHandle(),
                const SizedBox(height: 8),
                Text(
                  _step == _Step.enterEmail ? 'Add email' : 'Enter code',
                  style: MallowTheme.uiTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _step == _Step.enterEmail
                      ? 'We\'ll send a verification code to confirm it\'s yours.'
                      : 'Enter the code we sent to $_email.',
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                if (_step == _Step.enterEmail)
                  MallowPillField(
                    controller: _emailController,
                    hintText: 'you@example.com',
                    errorText: _error,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    onSubmitted: (_) => _sendCode(),
                  )
                else
                  MallowPillField(
                    controller: _codeController,
                    hintText: '123456',
                    errorText: _error,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    textAlign: TextAlign.center,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _verifyCode(),
                  ),
                const SizedBox(height: 16),
                MallowButton(
                  label: _step == _Step.enterEmail ? 'Send code' : 'Verify',
                  isFullWidth: true,
                  isLoading: _busy,
                  onPressed: _busy
                      ? null
                      : (_step == _Step.enterEmail ? _sendCode : _verifyCode),
                ),
                if (_step == _Step.enterCode) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : _resend,
                      child: Text(
                        'Use a different email',
                        style: MallowTheme.uiMeta.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
