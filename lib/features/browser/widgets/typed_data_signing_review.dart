import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/account.dart' show WalletType;
import '../../../core/models/simulation_review.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/review_risk_card.dart';
import '../../../shared/widgets/review_wallet_identity.dart';
import '../../../shared/widgets/signing_review_layout.dart';
import '../../../core/crypto/eip712.dart';
import '../services/ethereum_dapp_adapter.dart';
import 'browser_site_tile.dart';

/// Native review for `eth_signTypedData_v4`. Everything shown is read from the
/// parsed payload whose digest is signed, never from the website's JSON.
///
/// A permit (EIP-2612 or Permit2) leads with a spending-permission card, a
/// transfer authorization with a transfer card, and a marketplace order
/// with an order card, because those signatures move
/// assets later without asking again. Any other payload is shown field by
/// field. Either way the domain names the contract the signature is for, and
/// approving a permission, transfer or order takes a press-and-hold.
class TypedDataSigningReview extends StatelessWidget {
  const TypedDataSigningReview({
    required this.review,
    required this.onReject,
    required this.onApprove,
    this.iconUrl,
    this.wallet,
    this.signer,
    super.key,
  });

  final EthereumTypedDataReview review;
  final VoidCallback onReject, onApprove;

  /// The signing wallet's type. A Ledger shows the fields itself, and an
  /// outdated Ethereum app shows the two hashes instead, so the review says
  /// what to compare on the device.
  final WalletType? signer;

  /// The requesting tab's icon. Decoration only.
  final Uri? iconUrl;

  /// Defaults to resolving [EthereumTypedDataReview.address] against the
  /// session.
  final ReviewWalletIdentity? wallet;

  static const _maxRows = 120;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final identity = wallet ?? ReviewWalletIdentity.resolve(review.address);
    final host = Uri.parse(review.origin).host;
    final data = review.data;
    final grants = review.kind != TypedDataKind.generic;
    final revokes =
        review.unsummarizedPermissionCount == 0 &&
        review.permissions.isNotEmpty &&
        review.permissions.every(
          (permission) => permission.amount == BigInt.zero,
        );
    final rows = <(String, Object?)>[];
    void flatten(String type, Object? value, String path, int depth) {
      if (rows.length > _maxRows) return;
      final fields = data.types[_base(type)];
      if (type.endsWith(']') && value is List) {
        final item = type.substring(0, type.lastIndexOf('['));
        for (final (i, element) in value.indexed) {
          flatten(item, element, '$path[$i]', depth + 1);
        }
        if (value.isEmpty) rows.add((path, '(empty)'));
      } else if (fields != null && value is Map && depth < 8) {
        for (final field in fields) {
          flatten(
            field.type,
            value[field.name],
            path.isEmpty ? field.name : '$path.${field.name}',
            depth + 1,
          );
        }
      } else {
        rows.add((path, _display(value)));
      }
    }

    // The canonical values are the ones the digest was computed from, so an
    // integer reads as decimal however the site wrote it (`0x…`, a string or a
    // JSON number).
    if (data.primaryType != 'EIP712Domain') {
      flatten(data.primaryType, data.canonicalMessage, '', 0);
    }
    final truncated = rows.length > _maxRows;
    final domain = data.domain;
    return SigningReviewLayout(
      footer: ReviewDecisionBar(
        rejectKey: const Key('reject-signing'),
        approveKey: const Key('approve-signing'),
        approveLabel: 'Sign',
        holdToApprove: grants,
        onReject: onReject,
        onApprove: onApprove,
      ),
      children: [
        const SizedBox(height: 12),
        Center(
          child: BrowserSiteTile(host: host, iconUrl: iconUrl, size: 60),
        ),
        const SizedBox(height: 18),
        ReviewTitle(switch (review.kind) {
          TypedDataKind.permit || TypedDataKind.permit2 =>
            revokes
                ? 'Revoke a spending permission'
                : 'Grant a spending permission',
          TypedDataKind.order => 'Sign a marketplace order',
          TypedDataKind.transfer => 'Authorize a token transfer',
          TypedDataKind.generic => 'Sign typed data',
        }),
        const SizedBox(height: 8),
        ReviewInfoLine(
          '$host is asking for your signature. It is not a transaction and costs nothing to sign, but whoever holds this signature can submit it later to spend tokens, fill an order or move assets. Only sign if you trust this website.',
          iconColor: colors.warning,
        ),
        if (review.unsummarizedPermissionCount > 0) ...[
          const SizedBox(height: 14),
          ReviewRiskCard(
            key: const Key('unsummarized-permissions'),
            tag: 'Permissions',
            title: review.unsummarizedPermissionCount == 1
                ? '1 permission is not summarised'
                : '${review.unsummarizedPermissionCount} permissions are not summarised',
            body: const Text(
              'These permissions may allow spending tokens. Check every entry under Exact data and digest before signing.',
            ),
          ),
        ],
        for (final permission in review.permissions) ...[
          const SizedBox(height: 14),
          _permissionCard(context, permission),
        ],
        for (final transfer in review.transfers) ...[
          const SizedBox(height: 14),
          _transferCard(context, transfer),
        ],
        if (review.kind == TypedDataKind.order) ...[
          const SizedBox(height: 14),
          const ReviewRiskCard(
            tag: 'Order',
            title: 'Marketplace order',
            body: Text(
              'Anyone can fill this order until it expires or you cancel it on the marketplace. When it is filled, the items it offers leave your wallet. Check every field below.',
            ),
          ),
        ],
        const ReviewSectionLabel('Signing for'),
        if (domain['name'] is String)
          ReviewKvRow(label: 'Name', value: domain['name']! as String),
        if (domain['version'] is String)
          ReviewKvRow(label: 'Version', value: domain['version']! as String),
        if (data.verifyingContract != null)
          ReviewKvRow(
            label: 'Contract',
            valueWidget: ReviewAddress(data.verifyingContract!),
          ),
        ReviewKvRow(
          label: 'Network',
          value: data.chainId == null
              ? 'Not specified'
              : Chain.ethereum.networkLabel,
          valueColor: data.chainId == null ? colors.warning : null,
        ),
        ReviewKvRow(
          label: 'Wallet',
          value: identity.name == null
              ? identity.shortAddress
              : '${identity.label} · ${identity.shortAddress}',
        ),
        if (signer == WalletType.ledger) ...[
          const SizedBox(height: 10),
          const ReviewInfoLine(
            key: Key('ledger-typed-data-note'),
            'Your Ledger needs Raw messages or Blind signing on in the Ethereum app settings. With Raw messages it shows every field, so check them against this review. With Blind signing only, it shows the contract and a message hash, so check it matches Message hash under Exact data and digest.',
          ),
        ],
        if (rows.isNotEmpty) ...[
          ReviewSectionLabel(data.primaryType),
          for (final (path, value) in rows.take(_maxRows))
            ReviewKvRow(
              label: path,
              dense: true,
              valueWidget: _value(context, value),
            ),
          if (truncated)
            const ReviewInfoLine(
              'More fields follow. The full data is under Exact data.',
            ),
        ],
        ReviewDisclosure(
          key: const Key('typed-data-full'),
          label: 'Exact data and digest',
          child: _Exact(data: data),
        ),
      ],
    );
  }

  Widget _permissionCard(BuildContext context, TypedDataPermission grant) {
    final asset = review.tokens[grant.token];
    final symbol = asset == null || !asset.verified ? 'token' : asset.symbol;
    final revoked = grant.amount == BigInt.zero;
    final unlimited = grant.amount == null;
    final amount = unlimited
        ? null
        : asset?.decimals == null
        ? '${grant.amount} base units of'
        : '${groupThousands(formatReviewAmount(grant.amount!, asset!.decimals))} $symbol';
    final expires = grant.expires;
    return ReviewRiskCard(
      tag: 'Permission',
      title: revoked
          ? 'Revoke $symbol allowance'
          : unlimited
          ? 'Unlimited $symbol allowance'
          : '$amount allowance',
      body: Text.rich(
        TextSpan(
          children: [
            reviewAddressSpan(context, grant.spender),
            TextSpan(
              text: revoked
                  ? ' will no longer be able to spend your '
                  : unlimited
                  ? ' can spend all of your '
                  : ' can spend up to this amount of your ',
            ),
            if (asset != null && asset.verified)
              TextSpan(text: symbol)
            else ...[
              const TextSpan(text: 'token '),
              reviewAddressSpan(context, grant.token),
            ],
            TextSpan(
              text: revoked || expires == null
                  ? ' once this signature is submitted.'
                  : ' once this signature is submitted, until ${_date(expires)}.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _transferCard(BuildContext context, TypedDataTransfer transfer) {
    final asset = review.tokens[transfer.token];
    final symbol = asset == null || !asset.verified ? 'token' : asset.symbol;
    final amount = groupThousands(
      formatReviewAmount(transfer.amount, asset?.decimals),
    );
    final expires = transfer.expires;
    return ReviewRiskCard(
      tag: 'Transfer',
      title: 'Transfer $amount $symbol',
      body: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'To '),
            reviewAddressSpan(context, transfer.recipient),
            if (asset == null || !asset.verified) ...[
              const TextSpan(text: ' from token contract '),
              reviewAddressSpan(context, transfer.token),
            ],
            const TextSpan(
              text:
                  '. Submitting this signature moves these tokens without asking you again.',
            ),
            TextSpan(
              text: expires == null
                  ? ' Expiry could not be determined; check Exact data.'
                  : ' This authorization expires ${_date(expires)}.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _value(BuildContext context, Object? value) {
    final colors = context.mallowColors;
    if (value is String &&
        value.length == 42 &&
        RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(value)) {
      return ReviewAddress(value);
    }
    final text = switch (value) {
      null => '—',
      final String s => s,
      final Object other => jsonEncode(other),
    };
    return Text(
      text.length > 160 ? '${text.substring(0, 160)}…' : text,
      textAlign: TextAlign.right,
      style: MallowTheme.uiBody.copyWith(
        fontSize: 14,
        color: colors.textPrimary,
      ),
    );
  }
}

/// A canonical leaf as review text: integers in decimal, addresses and bytes
/// as `0x` hex.
Object? _display(Object? value) => switch (value) {
  BigInt() => value.toString(),
  Uint8List() =>
    '0x${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
  _ => value,
};

String _base(String type) {
  final bracket = type.indexOf('[');
  return bracket < 0 ? type : type.substring(0, bracket);
}

String _date(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

class _Exact extends StatelessWidget {
  const _Exact({required this.data});
  final Eip712TypedData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final mono = reviewMonoStyle.copyWith(color: colors.textPrimary);
    final label = MallowTheme.uiLabel.copyWith(color: colors.textSecondary);
    final digest = _hex(data.digest);
    final json = const JsonEncoder.withIndent('  ').convert({
      'primaryType': data.primaryType,
      'domain': data.domain,
      'message': data.message,
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Data', style: label),
        const SizedBox(height: 4),
        SelectableText(json, style: mono.copyWith(fontSize: 12)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: Text('EIP-712 digest', style: label)),
            IconButton(
              tooltip: 'Copy digest',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: digest));
                AppSnackBar.show(context, 'Digest copied');
              },
            ),
          ],
        ),
        SelectableText(digest, style: mono),
        const SizedBox(height: 12),
        Text('Domain hash', style: label),
        const SizedBox(height: 4),
        SelectableText(_hex(data.domainSeparator), style: mono),
        if (data.structHash.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Message hash', style: label),
          const SizedBox(height: 4),
          SelectableText(_hex(data.structHash), style: mono),
        ],
      ],
    );
  }
}

String _hex(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
