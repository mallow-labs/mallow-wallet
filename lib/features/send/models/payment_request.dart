import '../../../core/config/environment.dart';
import '../../../core/network/solana_pay_tags.dart';
import '../../../core/utils/token_amount.dart';
import '../../../shared/utils/chain.dart';
import 'recipient_address.dart';

/// A request to be paid, read from a QR code: who to pay, in which token,
/// and usually how much.
///
/// Two standards are read. A Solana Pay transfer request
/// (`solana:<recipient>?amount=…&spl-token=…&reference=…&memo=…`) and an
/// EIP-681 Ethereum request (`ethereum:<recipient>?value=<wei>`, or
/// `ethereum:<token>/transfer?address=<recipient>&uint256=<amount>`). Tezos
/// has no such standard.
class PaymentRequest {
  const PaymentRequest({
    required this.recipient,
    this.token,
    this.amount,
    this.tags = const SolanaPayTags(),
    this.label,
    this.message,
  });

  final RecipientAddress recipient;

  /// The token's mint or contract, or null for the chain's native coin. An
  /// Ethereum contract is lowercased, as token balances key them.
  final String? token;

  /// Null when the request leaves the amount to the payer.
  final RequestedAmount? amount;

  /// The references and memo a Solana Pay request asks the transfer to carry.
  final SolanaPayTags tags;

  /// Who is asking, and why, in the requester's own words. Shown as given,
  /// never trusted: anyone can print a QR code.
  final String? label;
  final String? message;
}

/// An amount as a payment request states it. Solana Pay states it in whole
/// tokens, EIP-681 in the token's smallest unit, so either needs the token's
/// decimals before it can be sent.
sealed class RequestedAmount {
  const RequestedAmount();

  /// The amount in the form the send sheet's amount field takes, for a token
  /// with [decimals] decimals. Null when the request asks for a finer
  /// fraction than the token can hold: rounding it would pay a different
  /// amount from the one requested.
  String? inDecimals(int decimals);
}

/// An amount in whole tokens, such as `1.5`.
final class DecimalAmount extends RequestedAmount {
  const DecimalAmount(this.value);
  final String value;

  @override
  String? inDecimals(int decimals) {
    final fraction = value.contains('.') ? value.split('.').last : '';
    if (fraction.length > decimals) return null;
    return TokenAmount.formatTokenAmount(
      TokenAmount.parseTokenAmount(value, decimals),
      decimals,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DecimalAmount && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// An amount in the token's smallest unit, such as wei.
final class AtomicAmount extends RequestedAmount {
  const AtomicAmount(this.value);
  final BigInt value;

  @override
  String inDecimals(int decimals) =>
      TokenAmount.formatTokenAmount(value, decimals);

  @override
  bool operator ==(Object other) =>
      other is AtomicAmount && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// What a chain-scheme URI (`solana:`, `ethereum:`, `tezos:`) asks for.
sealed class PaymentUri {
  const PaymentUri();
}

/// Only an address, with nothing to pay yet.
final class PaymentUriAddress extends PaymentUri {
  const PaymentUriAddress(this.recipient);
  final RecipientAddress recipient;
}

/// A payment to make.
final class PaymentUriRequest extends PaymentUri {
  const PaymentUriRequest(this.request);
  final PaymentRequest request;
}

/// A request in a chain's scheme that cannot be paid. [message] says why.
final class PaymentUriRefused extends PaymentUri {
  const PaymentUriRefused(this.message);
  final String message;
}

const _invalid = PaymentUriRefused("This payment request isn't valid");

/// Reads [text] as a chain-scheme URI, or returns null when it is not one.
///
/// A URI that names only an address, with nothing else, is an address and
/// not a request: most wallets print one as their receive code. Anything a
/// request adds that this app cannot honour (a Solana Pay transaction
/// request, another EVM network, a contract call other than an ERC-20
/// transfer, a malformed field) refuses the whole request rather than paying
/// part of it.
///
/// [ethereumChainId] is the network an EIP-681 `@chainId` must name; it
/// defaults to the one this build signs for.
PaymentUri? parsePaymentUri(String text, {int? ethereumChainId}) {
  final colon = text.indexOf(':');
  if (colon <= 0) return null;
  final chain = Chain.tryParse(text.substring(0, colon).toLowerCase());
  if (chain == null) return null;
  final rest = text.substring(colon + 1);
  final query = rest.indexOf('?');
  final path = query < 0 ? rest : rest.substring(0, query);
  final Map<String, List<String>> params;
  try {
    params = query < 0
        ? const {}
        : Uri(query: rest.substring(query + 1)).queryParametersAll;
  } on FormatException {
    return _invalid;
  } on ArgumentError {
    return _invalid;
  }
  return switch (chain) {
    Chain.solana => _solanaPay(path, params),
    Chain.ethereum => _eip681(
      path,
      params,
      ethereumChainId ?? Config.ethereumChainId,
    ),
    Chain.tezos =>
      Chain.tezos.isValidAddress(path) && params.isEmpty
          ? PaymentUriAddress(RecipientAddress(address: path, chain: chain))
          : const PaymentUriRefused("Tezos payment requests aren't supported"),
  };
}

/// The single value of [key], or null when absent. Throws [FormatException]
/// when it is given more than once, which no standard here allows.
String? _single(Map<String, List<String>> params, String key) {
  final values = params[key];
  if (values == null || values.isEmpty) return null;
  if (values.length > 1) throw const FormatException('repeated parameter');
  return values.single;
}

final _solanaPayAmount = RegExp(r'^\d+(\.\d+)?$');

PaymentUri _solanaPay(String path, Map<String, List<String>> params) {
  final String recipient;
  try {
    recipient = Uri.decodeComponent(path);
  } on ArgumentError {
    return _invalid;
  }
  // A transaction request's path is a URL the wallet would fetch a
  // transaction from: a different protocol from a transfer.
  if (recipient.toLowerCase().startsWith('http')) {
    return const PaymentUriRefused(
      "Solana Pay transaction requests aren't supported yet",
    );
  }
  if (!Chain.solana.isValidAddress(recipient)) return _invalid;
  final to = RecipientAddress(address: recipient, chain: Chain.solana);
  if (params.isEmpty) return PaymentUriAddress(to);
  try {
    final amount = _single(params, 'amount');
    if (amount != null && !_solanaPayAmount.hasMatch(amount)) return _invalid;
    final token = _single(params, 'spl-token');
    if (token != null && !Chain.solana.isValidAddress(token)) return _invalid;
    final references = params['reference'] ?? const <String>[];
    if (!references.every(Chain.solana.isValidAddress)) return _invalid;
    return PaymentUriRequest(
      PaymentRequest(
        recipient: to,
        token: token,
        amount: amount == null ? null : DecimalAmount(amount),
        tags: SolanaPayTags(
          references: List.unmodifiable(references),
          memo: _single(params, 'memo'),
        ),
        label: _single(params, 'label'),
        message: _single(params, 'message'),
      ),
    );
  } on FormatException {
    return _invalid;
  }
}

/// An EIP-681 number: an integer, optionally with a fraction and a decimal
/// exponent (`2.014e18`), which must come out whole.
BigInt? _eip681Number(String text) {
  final match = RegExp(r'^(\d+)(?:\.(\d+))?(?:[eE](\d+))?$').firstMatch(text);
  if (match == null) return null;
  final whole = match.group(1)!;
  final fraction = match.group(2) ?? '';
  final exponent = int.tryParse(match.group(3) ?? '0');
  // Far past any amount that exists, and keeps the padding below bounded.
  if (exponent == null || exponent > 77) return null;
  final digits = '$whole$fraction';
  final shift = exponent - fraction.length;
  if (shift >= 0)
    return BigInt.parse(digits.padRight(digits.length + shift, '0'));
  // A fraction of the smallest unit is not an amount anyone can send.
  final dropped = digits.substring(digits.length + shift);
  if (dropped.replaceAll('0', '').isNotEmpty) return null;
  return BigInt.parse(digits.substring(0, digits.length + shift));
}

final _eip681Path = RegExp(
  r'^(?:pay-)?(0x[0-9a-fA-F]{40})(?:@(\d+))?(?:/([A-Za-z_][A-Za-z0-9_]*))?$',
);

PaymentUri _eip681(
  String path,
  Map<String, List<String>> params,
  int ethereumChainId,
) {
  final match = _eip681Path.firstMatch(path);
  if (match == null) return _invalid;
  final target = match.group(1)!;
  final chainId = match.group(2);
  final function = match.group(3);
  if (chainId != null && int.tryParse(chainId) != ethereumChainId) {
    return const PaymentUriRefused(
      'This payment request is for another network',
    );
  }
  try {
    switch (function) {
      case null:
        final value = _single(params, 'value');
        final to = RecipientAddress(address: target, chain: Chain.ethereum);
        if (value == null) return PaymentUriAddress(to);
        final wei = _eip681Number(value);
        if (wei == null) return _invalid;
        return PaymentUriRequest(
          PaymentRequest(recipient: to, amount: AtomicAmount(wei)),
        );
      case 'transfer':
        final recipient = _single(params, 'address');
        if (recipient == null || !Chain.ethereum.isValidAddress(recipient)) {
          return _invalid;
        }
        // An ERC-20 transfer moves the token, not ether: a request for both
        // is not one transfer.
        if (_single(params, 'value') != null) return _invalid;
        final amount = _single(params, 'uint256');
        final raw = amount == null ? null : _eip681Number(amount);
        if (amount != null && raw == null) return _invalid;
        return PaymentUriRequest(
          PaymentRequest(
            recipient: RecipientAddress(
              address: recipient,
              chain: Chain.ethereum,
            ),
            token: target.toLowerCase(),
            amount: raw == null ? null : AtomicAmount(raw),
          ),
        );
      default:
        return const PaymentUriRefused(
          "This Ethereum request isn't a payment mallow can make",
        );
    }
  } on FormatException {
    return _invalid;
  }
}
