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
/// parsed payload whose digest is signed, never from the website's JSON: the
/// rows are the fields the primary type declares, in declared order (see
/// [typedDataReviewRows]), and the parser has already refused a payload that
/// holds any other key, so a page cannot put a row on screen that the
/// signature does not cover.
///
/// A permit (EIP-2612 or Permit2) leads with a spending-permission card, a
/// transfer authorization with a transfer card, and a marketplace order
/// with an order card, because those signatures move
/// assets later without asking again. Any other payload is shown field by
/// field under a caution: the wallet cannot say what a contract will do with
/// a signature it does not recognise, so that one is not presumed harmless.
/// Either way the domain names the contract the signature is for, and every
/// typed-data signature is offered reject-first and takes a press-and-hold.
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

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final identity = wallet ?? ReviewWalletIdentity.resolve(review.address);
    final host = Uri.parse(review.origin).host;
    final data = review.data;
    final revokes =
        review.unsummarizedPermissionCount == 0 &&
        review.permissions.isNotEmpty &&
        review.permissions.every(
          (permission) => permission.amount == BigInt.zero,
        );
    final (:rows, :more) = typedDataReviewRows(data);
    final domain = data.domain;
    return SigningReviewLayout(
      footer: ReviewDecisionBar(
        rejectKey: const Key('reject-signing'),
        approveKey: const Key('approve-signing'),
        approveLabel: 'Sign',
        holdToApprove: true,
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
        if (review.kind == TypedDataKind.generic) ...[
          const SizedBox(height: 14),
          ReviewCautionCard(
            key: const Key('unrecognised-typed-data'),
            title: 'The wallet does not recognise this request.',
            messages: [
              data.verifyingContract == null
                  ? 'It cannot tell what this signature will be used for. It could move tokens or grant a permission.'
                  : 'It cannot tell what the contract below will do with this signature. It could move tokens or grant a permission.',
              'Check every field, and reject unless you know what you are signing.',
            ],
          ),
        ],
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
          for (final (path, value) in rows)
            ReviewKvRow(
              label: path,
              dense: true,
              valueWidget: _value(context, value),
            ),
          if (more > 0) ...[
            const SizedBox(height: 10),
            ReviewInfoLine(
              key: const Key('typed-data-more-fields'),
              'and $more more field${more == 1 ? '' : 's'}, all signed. The full data is under Exact data and digest.',
              iconColor: colors.warning,
            ),
          ],
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

  /// From, to, amount, validity and the token contract, each on its own
  /// row: these five decide where the tokens go and for how long the
  /// signature can be used.
  Widget _transferCard(BuildContext context, TypedDataTransfer transfer) {
    final colors = context.mallowColors;
    final asset = review.tokens[transfer.token];
    final verified = asset != null && asset.verified;
    final symbol = verified ? asset.symbol : 'token';
    final amount = groupThousands(
      formatReviewAmount(transfer.amount, asset?.decimals),
    );
    final own = transfer.from == review.address.toLowerCase();
    final validFrom = transfer.validFrom, expires = transfer.expires;
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: colors.textSecondary)),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: value),
          ),
        ],
      ),
    );
    return ReviewRiskCard(
      key: const Key('typed-data-transfer'),
      tag: 'Transfer',
      title: 'Transfer $amount $symbol',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('From', ReviewAddress(transfer.from)),
          row('To', ReviewAddress(transfer.recipient)),
          row(
            verified ? '$symbol contract' : 'Token contract',
            ReviewAddress(transfer.token),
          ),
          row(
            'Valid',
            Text(
              [
                if (validFrom != null) 'from ${_date(validFrom)}',
                expires == null
                    ? 'end date not readable'
                    : 'until ${_date(expires)}',
              ].join(' '),
              textAlign: TextAlign.right,
            ),
          ),
          if (!own)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('The account the tokens leave is not this wallet.'),
            ),
          const Text(
            'Whoever holds this signature can submit it to move these tokens, without asking you again.',
          ),
          if (expires == null)
            const Text(
              'Treat it as never expiring, and check validBefore under Exact data and digest.',
            ),
        ],
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

/// The most field rows a review lists before it says how many are left.
const kMaxTypedDataRows = 120;

/// The rows of a typed-data review: one per leaf value the signature covers,
/// labelled by its path, at most [limit] of them, and how many [more] the
/// payload holds past that.
///
/// The walk follows the fields the primary type declares, in declared order,
/// into each struct and array they reference. It never reads the keys of the
/// message the website sent, so a row exists only for a value that is hashed
/// into the digest, and no signed value is left out of the count.
({List<(String, Object?)> rows, int more}) typedDataReviewRows(
  Eip712TypedData data, {
  int limit = kMaxTypedDataRows,
}) {
  final rows = <(String, Object?)>[];
  var total = 0;
  void add(String path, Object? value) {
    if (total++ < limit) {
      rows.add((path.isEmpty ? data.primaryType : path, value));
    }
  }

  void walk(String type, Object? value, String path, int depth) {
    final fields = data.types[type];
    if (type.endsWith(']') && value is List) {
      final item = type.substring(0, type.lastIndexOf('['));
      if (value.isEmpty) add(path, '(empty)');
      for (final (i, element) in value.indexed) {
        walk(item, element, '$path[$i]', depth + 1);
      }
    } else if (fields != null && value is Map) {
      // The parser bounds nesting well below this; past it a struct is named
      // rather than walked, and still counted.
      if (depth >= _maxRowDepth) {
        add(path, '(nested data)');
        return;
      }
      if (fields.isEmpty) add(path, '(no fields)');
      for (final field in fields) {
        walk(
          field.type,
          value[field.name],
          path.isEmpty ? field.name : '$path.${field.name}',
          depth + 1,
        );
      }
    } else {
      add(path, _display(value));
    }
  }

  // The canonical values are the ones the digest was computed from, so an
  // integer reads as decimal however the site wrote it (`0x…`, a string or a
  // JSON number).
  if (data.primaryType != 'EIP712Domain') {
    walk(data.primaryType, data.canonicalMessage, '', 0);
  }
  return (rows: rows, more: total - rows.length);
}

const _maxRowDepth = 16;

/// A canonical leaf as review text: integers in decimal, addresses and bytes
/// as `0x` hex.
Object? _display(Object? value) => switch (value) {
  BigInt() => value.toString(),
  Uint8List() =>
    '0x${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
  _ => value,
};

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
