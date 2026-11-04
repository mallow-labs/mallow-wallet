import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'mallow_network_image.dart';

import '../../core/data/mallow_tokens.dart'
    show isRegistryMint, solMint, tokenByMint;
import '../../core/models/simulation_review.dart';
import '../../core/services/program_label_service.dart';
import '../../core/utils/address_format.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import '../utils/chain.dart';
import '../utils/price_format.dart';
import '../utils/token_image_utils.dart';
import 'balance_change_hero.dart';
import 'loading_indicator.dart' show ShimmerBox;
import 'mallow_button.dart';
import 'review_risk_card.dart';
import 'review_wallet_identity.dart';
import 'signing_review_layout.dart';
import 'transaction_expiry.dart';

const _u64Max = '18446744073709551615';
const _defaultTitle = 'Review transaction';

/// An allowance no one would grant as an amount: Solana's u64 maximum, or
/// anything from 2^128 up, which covers the uint256 maximum and the other
/// "infinite" values EVM websites send.
bool _isUnlimited(BigInt allowance) =>
    allowance == BigInt.parse(_u64Max) || allowance >= BigInt.one << 128;

/// Native review shared by transaction surfaces. Warnings describe uncertainty;
/// the caller alone applies signer/network validity and authentication policy.
///
/// Layout: origin, title and estimate caption, balance and asset actions,
/// fee / wallet / network, then the program calls behind a disclosure. When the simulation failed, rejecting
/// becomes the primary action and approving needs a press-and-hold. Without
/// [onApprove] the wallet cannot sign: the review still shows, under a
/// view-only warning, with Close as its only action.
class SimulationReviewSheet extends StatelessWidget {
  const SimulationReviewSheet({
    required this.review,
    required this.onReject,
    this.onApprove,
    this.title = _defaultTitle,
    this.approveLabel = 'Approve',
    this.batchNotice,
    this.priceOf,
    this.originIcon,
    this.wallet,
    this.openExternal,
    this.programLabels,
    this.networkFeeAction,
    this.operationDetails,
    this.expiry,
    super.key,
  });
  final SimulationReview review;
  final VoidCallback onReject;
  final VoidCallback? onApprove;
  final String title;
  final String approveLabel;
  final String? batchNotice;

  /// USD price per whole token by asset id. Unknown prices stay unknown: the
  /// value is hidden, never estimated.
  final double? Function(String assetId)? priceOf;

  /// 22 dp icon for the origin chip. Decoration only.
  final Widget? originIcon;

  /// Defaults to resolving [SimulationReview.address] against the session.
  final ReviewWalletIdentity? wallet;

  /// Opens the Explorer link. Defaults to [launchUrl]; a host that tears
  /// itself down when the app is backgrounded supplies one that marks the
  /// hop as deliberate first.
  final Future<void> Function(Uri url)? openExternal;

  /// Names for well-known programs, by address. Defaults to the published
  /// list in [ProgramLabelService]. Every program shows its address; an
  /// unnamed one shows it alone.
  final ValueListenable<Map<String, String>>? programLabels;

  /// A control for changing the fee, shown as the Speed row under an EVM
  /// network fee. Null leaves the fee read-only.
  final Widget? networkFeeAction;

  /// Canonical operation fields, including contract arguments, before signing.
  final String? operationDetails;

  /// How long the transaction stays acceptable to its network. Shown as an
  /// Expires row, with a card when time is short or gone; once it has passed,
  /// Approve gives way to Close.
  final TransactionExpiryView? expiry;

  bool get _failed => review.execution == SimulationExecution.failed;

  /// A Solana review whose simulation failed or could not be decoded turns
  /// reject-first, with press-and-hold approval. Ethereum and Tezos reviews
  /// keep the ordinary title and decision bar; their caution cards still say
  /// what went wrong. A Tezos contract call is never fully decoded, so on
  /// Tezos the hold would stand in front of every contract call.
  bool get _needsCaution =>
      !_evm &&
      !review.chain.startsWith('tezos:') &&
      (_failed || review.effectsUndecodable);
  bool get _viewOnly => onApprove == null;

  bool get _evm => review.chain.startsWith('eip155:');

  /// A batch approved as a whole, its effects combined across transactions.
  bool get _batch => review.transactions.length > 1;

  /// Every EVM approval is a lasting grant a contract can use without asking,
  /// so each gets a card. On Solana the ones that hand over what the account
  /// holds do: an unlimited allowance, an NFT, or the whole balance.
  bool _hasRiskCard(AccountChange change) =>
      change.kind == AccountChangeKind.authority ||
      (change.kind == AccountChangeKind.approve &&
          (_evm ||
              (change.rawAllowance != null &&
                  _isUnlimited(change.rawAllowance!)) ||
              _coversHolding(change)));

  /// The asset an account change is about: its own mint, else one a sibling
  /// change or a balance change on the same account names.
  String? _assetOf(AccountChange change) =>
      change.assetId ??
      review.accounts
          .where((a) => a.address == change.address && a.assetId != null)
          .firstOrNull
          ?.assetId ??
      review.funds
          .where((f) => f.address == change.address)
          .firstOrNull
          ?.asset
          .id;

  bool _isNft(String? id) =>
      id != null &&
      (review.nftMetadata.containsKey(id) ||
          review.nfts.any((n) => n.assetId == id));

  /// A Solana delegation of everything the token account holds: a nonzero
  /// allowance over an NFT, which is the whole of it, or an allowance of at
  /// least the account's balance. The delegate can then move all of it, even
  /// out of a frozen account once it is thawed, without asking again.
  bool _coversHolding(AccountChange change) {
    if (_evm || change.kind != AccountChangeKind.approve) return false;
    final allowance = change.rawAllowance;
    if (allowance != null && allowance <= BigInt.zero) return false;
    if (_isNft(_assetOf(change))) return true;
    final balance = change.balance;
    return allowance != null &&
        balance != null &&
        balance > BigInt.zero &&
        allowance >= balance;
  }

  bool _isAction(AccountChange change) => !_evm && _isActionKind(change);

  @override
  Widget build(BuildContext context) {
    final expiry = this.expiry;
    if (expiry == null) return _build(context, null);
    return ValueListenableBuilder<TransactionExpiry>(
      valueListenable: expiry.state,
      builder: (context, state, _) => _build(context, state),
    );
  }

  Widget _build(BuildContext context, TransactionExpiry? expiryState) {
    final c = context.mallowColors;
    final expiry = this.expiry;
    final expired = expiryState is ExpiryPassed;
    final permissions = review.accounts
        .where(
          (a) =>
              a.kind == AccountChangeKind.approve ||
              a.kind == AccountChangeKind.authority,
        )
        .toList();
    final remaining = review.accounts
        .where(
          (a) =>
              !permissions.contains(a) &&
              !_isAction(a) &&
              a.kind != AccountChangeKind.contractCall,
        )
        .toList();
    final deltas = review.funds.where((f) => f.isNet).toList()
      ..sort(
        (a, b) => (b.rawAmount.isNegative ? 1 : 0).compareTo(
          a.rawAmount.isNegative ? 1 : 0,
        ),
      );
    final transfers = review.funds.where((f) => !f.isNet).toList();
    final warnings = review.warnings
        .where((w) => !w.startsWith('Some effects could not be decoded.'))
        .where((w) => w != kSimulationSnapshotSlotsWarning)
        .toSet()
        .toList();
    final mixedSlots = review.warnings.contains(
      kSimulationSnapshotSlotsWarning,
    );
    final movementFunds = deltas.isNotEmpty ? deltas : transfers;
    final movements = [
      for (final fund in movementFunds)
        if (fund.rawAmount != BigInt.zero) _balanceChange(context, fund),
      for (final nft in review.nfts)
        if (_isNftMovement(nft) &&
            !movementFunds.any((f) => f.asset.id == nft.assetId))
          _nftMovement(context, nft),
    ];
    final actions = _actionChanges(context);
    final identity = wallet ?? ReviewWalletIdentity.resolve(review.address);

    return SigningReviewLayout(
      footer: _viewOnly || expired
          ? MallowButton(
              key: const Key('reject-signing'),
              label: 'Close',
              isFullWidth: true,
              onPressed: onReject,
            )
          : ReviewDecisionBar(
              rejectKey: const Key('reject-signing'),
              approveKey: const Key('approve-signing'),
              onReject: onReject,
              onApprove: onApprove!,
              approveLabel: approveLabel,
              holdToApprove: _needsCaution,
            ),
      children: [
        const SizedBox(height: 4),
        ReviewOriginChip(origin: review.origin, icon: originIcon),
        const SizedBox(height: 14),
        if (_viewOnly) ...[
          const ReviewCautionCard(
            key: Key('review-view-only'),
            title: 'View-only wallet',
            messages: [
              'This wallet cannot sign, so this transaction cannot be approved. You can still review what it would do.',
            ],
          ),
          const SizedBox(height: 14),
        ],
        // "Review carefully" urges caution before approving; a view-only
        // review has nothing to approve.
        ReviewTitle(_needsCaution && !_viewOnly ? 'Review carefully' : title),
        if (_needsCaution && !_viewOnly && title != _defaultTitle)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: MallowTheme.uiMeta.copyWith(color: c.textSecondary),
            ),
          ),
        const SizedBox(height: 8),
        ReviewInfoLine(
          review.execution == SimulationExecution.succeeded
              ? _deltaCaption(movementFunds, mixedSlots: mixedSlots)
              : _batch
              ? 'Effects requested by these transactions'
              : 'Effects requested by this transaction',
        ),
        const SizedBox(height: 4),
        if (expiry != null &&
            expiryState != null &&
            transactionExpiryHasNotice(expiry, expiryState)) ...[
          const SizedBox(height: 14),
          transactionExpiryNotice(expiry, expiryState),
        ],
        if (review.error != null) ...[
          const SizedBox(height: 14),
          _errorCard(review),
        ],
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 14),
          ReviewCautionCard(messages: warnings),
        ],
        for (final permission in permissions.where(_hasRiskCard)) ...[
          const SizedBox(height: 14),
          _riskCard(context, permission),
        ],
        // An expired transaction will do none of this; the effects stay
        // readable but no longer look current.
        if (movements.isNotEmpty) ...[
          const SizedBox(height: 18),
          Opacity(
            opacity: expired ? 0.45 : 1,
            child: BalanceChangeHero(changes: movements),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Opacity(
            opacity: expired ? 0.45 : 1,
            child: BalanceChangeHero(changes: actions),
          ),
        ],
        if (movements.isEmpty && actions.isEmpty) ...[
          const SizedBox(height: 14),
          const ReviewInfoLine('No asset changes could be identified.'),
        ],
        for (final nft in review.nfts)
          if (!_isNftMovement(nft) &&
              !(nft.kind == NftChangeKind.transfer &&
                  movementFunds.any((f) => f.asset.id == nft.assetId)))
            _nftRow(context, nft),
        if (remaining.isNotEmpty) ...[
          const ReviewSectionLabel('Account changes'),
          for (final change in remaining) _accountRow(context, change),
        ],
        const SizedBox(height: 10),
        if (_evm) ...[
          ReviewKvRow(
            label: 'Network fee',
            value: review.networkFee == null
                ? 'Unavailable'
                : '≈ ${_ether(review.networkFee!)} ETH',
            valueColor: review.networkFee == null ? c.textSecondary : null,
          ),
          if (review.maxNetworkFee != null &&
              review.maxNetworkFee != review.networkFee)
            ReviewKvRow(
              label: 'Max network fee',
              value: '${_ether(review.maxNetworkFee!)} ETH',
              valueColor: c.textSecondary,
            ),
          if (networkFeeAction != null)
            ReviewKvRow(label: 'Speed', valueWidget: networkFeeAction!),
        ] else if (review.chain.startsWith('tezos:')) ...[
          ReviewKvRow(
            label: 'Fee and storage burn',
            value: review.networkFee == null
                ? 'Unavailable'
                : '≈ ${formatReviewAmount(review.networkFee!, 6)} XTZ',
          ),
          if (review.maxNetworkFee != null &&
              review.maxNetworkFee != review.networkFee)
            ReviewKvRow(
              label: 'Max fee and storage burn',
              value: '${formatReviewAmount(review.maxNetworkFee!, 6)} XTZ',
            ),
        ] else
          ReviewKvRow(
            label: 'Network fee',
            value: review.feeLamports == null
                ? 'Unavailable'
                : '${formatReviewAmount(BigInt.from(review.feeLamports!), 9)} SOL',
            valueColor: review.feeLamports == null ? c.textSecondary : null,
          ),
        if (expiry != null && expiryState != null)
          ...transactionExpiryRows(context, expiry, expiryState),
        _WalletRow(identity),
        ReviewKvRow(label: 'Network', value: caip2NetworkLabel(review.chain)),
        if (batchNotice != null) ...[
          const SizedBox(height: 12),
          ReviewInfoLine(batchNotice!),
          const SizedBox(height: 4),
        ],
        if (operationDetails != null)
          ReviewDisclosure(
            label: 'Operation details',
            child: SelectableText(
              operationDetails!,
              style: reviewMonoStyle.copyWith(color: c.textPrimary),
            ),
          ),
        ReviewDisclosure(
          key: const Key('review-program-calls'),
          label: 'Program calls',
          child: _ProgramCalls(
            review: review,
            labels:
                programLabels ??
                (sl.isRegistered<ProgramLabelService>()
                    ? sl<ProgramLabelService>().labels
                    : null),
            openExternal: openExternal,
          ),
        ),
      ],
    );
  }

  Widget _errorCard(SimulationReview review) {
    final error = review.error!;
    if (review.effectsUndecodable) {
      return const ReviewCautionCard(
        title: 'Simulation effects unavailable',
        messages: [
          'This wallet could not decode the simulation\'s effects. Assets or permissions not shown here can change if you approve.',
        ],
      );
    }
    if (!_failed) {
      return ReviewCautionCard(
        title: review.execution == SimulationExecution.unavailable
            ? 'Simulation unavailable'
            : null,
        messages: [error],
      );
    }
    const prefix = 'Simulation failed: ';
    final detail = error.startsWith(prefix)
        ? error.substring(prefix.length)
        : error == 'Simulation failed'
        ? null
        : error;
    return ReviewCautionCard(
      title: 'Simulation failed',
      messages: [
        _batch
            ? 'A transaction in this batch fails when simulated on its own. It may rely on an earlier transaction in the batch, or it would fail right now. Its effects below are taken from the request itself and may be incomplete.'
            : 'This transaction would fail right now. The effects below are taken from the request itself and may be incomplete.',
      ],
      detail: detail,
    );
  }

  Widget _riskCard(BuildContext context, AccountChange change) {
    final beneficiary = change.beneficiary;
    final allowance = change.rawAllowance;
    // Without simulated effects, approve's zero may be an ERC-721 token ID.
    if (_evm &&
        change.kind == AccountChangeKind.approve &&
        change.evidence == ReviewEvidence.requestedInstruction &&
        allowance == BigInt.zero) {
      return ReviewRiskCard(
        tag: 'Permission',
        title: change.description,
        body: Text.rich(
          TextSpan(
            children: [
              if (beneficiary != null)
                reviewAddressSpan(context, beneficiary)
              else
                const TextSpan(text: 'Another account'),
              const TextSpan(
                text:
                    ' will receive either a zero token allowance or the right to transfer NFT #0 of contract ',
              ),
              reviewAddressSpan(context, change.address),
              const TextSpan(text: ' if you approve.'),
            ],
          ),
        ),
      );
    }
    final assetId = _assetOf(change);
    if (!_evm &&
        change.kind == AccountChangeKind.approve &&
        _isNft(assetId) &&
        _coversHolding(change)) {
      final frozen = review.accounts.any(
        (a) =>
            a.kind == AccountChangeKind.freeze && a.address == change.address,
      );
      return ReviewRiskCard(
        tag: 'Permission',
        title: 'Permission to transfer ${_nftName(assetId!)}',
        body: Text.rich(
          TextSpan(
            children: [
              if (beneficiary != null)
                reviewAddressSpan(context, beneficiary)
              else
                const TextSpan(text: 'Another account'),
              TextSpan(
                text: frozen
                    ? ' can transfer this NFT out of your wallet at any time, until the permission is revoked. It is also frozen, so you cannot move it yourself until it is unlocked.'
                    : ' can transfer this NFT out of your wallet at any time, until the permission is revoked.',
              ),
            ],
          ),
        ),
      );
    }
    if (change.kind == AccountChangeKind.approve && allowance != null) {
      // The permission names a token account, not a mint; borrow the symbol
      // from a balance change on the same account when there is one. An EVM
      // allowance names the token contract itself.
      final asset =
          review.funds
              .where(
                (f) =>
                    f.address == change.address ||
                    (_evm && f.asset.id == change.assetId),
              )
              .map((f) => f.asset)
              .firstOrNull ??
          review.assets[change.assetId];
      final symbol = asset == null
          ? 'token'
          : _symbol(asset, review.tokenMetadata);
      final unlimited = _isUnlimited(allowance);
      final whole = !unlimited && _coversHolding(change);
      final amount = asset?.decimals == null
          ? '$allowance base units'
          : '${groupThousands(formatReviewAmount(allowance, asset!.decimals))} $symbol';
      return ReviewRiskCard(
        tag: 'Permission',
        title: unlimited ? 'Unlimited $symbol allowance' : '$amount allowance',
        body: beneficiary == null
            ? Text(change.description)
            : Text.rich(
                TextSpan(
                  children: [
                    reviewAddressSpan(context, beneficiary),
                    TextSpan(
                      text: unlimited
                          ? ' can spend all of your $symbol at any time, until you revoke it.'
                          : whole
                          ? ' can spend all of the $symbol in this account at any time, until you revoke it.'
                          : ' can spend up to this amount of your $symbol at any time, until you revoke it.',
                    ),
                  ],
                ),
              ),
      );
    }
    if (change.kind == AccountChangeKind.approve && _evm) {
      final collection = change.assetId == change.address;
      return ReviewRiskCard(
        tag: 'Permission',
        title: change.description,
        body: Text.rich(
          TextSpan(
            children: [
              if (beneficiary != null)
                reviewAddressSpan(context, beneficiary)
              else
                const TextSpan(text: 'Another account'),
              TextSpan(
                text: collection
                    ? ' can transfer every NFT you hold in collection '
                    : ' can transfer this NFT from collection ',
              ),
              reviewAddressSpan(context, change.address),
              const TextSpan(text: ' at any time, until you revoke it.'),
            ],
          ),
        ),
      );
    }
    if (change.kind == AccountChangeKind.approve) {
      return ReviewRiskCard(
        tag: 'Permission',
        title: change.description,
        body: Text.rich(
          TextSpan(
            children: [
              if (beneficiary != null) ...[
                reviewAddressSpan(context, beneficiary),
                const TextSpan(text: ' can spend from token account '),
              ] else
                const TextSpan(text: 'Token account '),
              reviewAddressSpan(context, change.address),
              TextSpan(
                text: beneficiary != null
                    ? ' until you revoke it.'
                    : ' changes who can spend from it.',
              ),
            ],
          ),
        ),
      );
    }
    return ReviewRiskCard(
      tag: 'Authority',
      title: change.description,
      body: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Account '),
            reviewAddressSpan(context, change.address),
            if (beneficiary != null) ...[
              const TextSpan(text: ' will be controlled by '),
              if (beneficiary == 'Remove authority')
                const TextSpan(text: 'no one (authority removed)')
              else
                reviewAddressSpan(context, beneficiary),
            ],
            const TextSpan(text: '.'),
          ],
        ),
      ),
    );
  }

  bool _isWalletAddress(String? address) => _evm
      ? address?.toLowerCase() == review.address.toLowerCase()
      : address == review.address;

  bool _isNftMovement(NftChange nft) =>
      (nft.kind == NftChangeKind.transfer ||
          nft.kind == NftChangeKind.mint ||
          nft.kind == NftChangeKind.burn) &&
      (_isWalletAddress(nft.from) || _isWalletAddress(nft.to));

  String _nftName(String id) =>
      review.nftMetadata[id]?.name ??
      'NFT · ${truncateAddress(id, lead: 6, trail: 6)}';

  Widget _nftIcon(String id) => _NftIcon(metadata: review.nftMetadata[id]);

  BalanceChange _nftMovement(BuildContext context, NftChange nft) {
    final name = _nftName(nft.assetId);
    final quantity = nft.quantity;
    return BalanceChange(
      label: _isWalletAddress(nft.from) ? 'You send' : 'You receive',
      amount: !nft.isMultiCopy
          ? name
          : quantity == null
          ? 'Unknown quantity · $name'
          : '${groupThousands(quantity.toString())} × $name',
      icon: _nftIcon(nft.assetId),
      outgoing: _isWalletAddress(nft.from),
      detailWidget: _detailLine(context, [
        reviewAddressSpan(context, nft.assetId),
      ]),
    );
  }

  List<BalanceChange> _actionChanges(BuildContext context) {
    final grouped = <String, Map<AccountChangeKind, AccountChange>>{};
    for (final change in review.accounts.where(_isAction)) {
      final group = grouped.putIfAbsent(
        '${change.program}:${change.address}',
        () => {},
      );
      if (group[change.kind]?.evidence != ReviewEvidence.simulatedState) {
        group[change.kind] = change;
      }
    }
    final result = <BalanceChange>[];
    for (final group in grouped.values) {
      void add(String label, AccountChange change) {
        final id =
            change.assetId ??
            group.values
                .map((a) => a.assetId)
                .whereType<String>()
                .firstOrNull ??
            review.funds
                .where((f) => f.address == change.address)
                .firstOrNull
                ?.asset
                .id;
        final nft =
            id != null &&
            (review.nftMetadata.containsKey(id) ||
                review.nfts.any((n) => n.assetId == id));
        result.add(
          BalanceChange(
            label: label,
            amount: nft
                ? _nftName(id)
                : id != null && isRegistryMint(id)
                ? tokenByMint(id)!.symbol
                : id != null && review.tokenMetadata[id] != null
                ? '${review.tokenMetadata[id]!.symbol} token account'
                : 'Token account',
            icon: nft ? _nftIcon(id) : _glyphTile(context, ReviewGlyph.code),
            detailWidget: _detailLine(context, [
              reviewAddressSpan(context, change.address),
              if (change.beneficiary != null) ...[
                const TextSpan(text: ' · Delegate '),
                reviewAddressSpan(context, change.beneficiary!),
                if (nft &&
                    change.kind == AccountChangeKind.approve &&
                    (change.rawAllowance ?? BigInt.one) > BigInt.zero)
                  const TextSpan(text: ' can transfer it until revoked'),
              ],
              if (change.rawAllowance != null && !nft)
                TextSpan(
                  text: ' · Allowance: ${change.rawAllowance} base units',
                ),
            ]),
          ),
        );
      }

      if (group.containsKey(AccountChangeKind.approve) &&
          group.containsKey(AccountChangeKind.freeze)) {
        // Freezing stops the owner, not the delegate: the label names both.
        add('Lock and delegate', group.remove(AccountChangeKind.approve)!);
        group.remove(AccountChangeKind.freeze);
      }
      if (group.containsKey(AccountChangeKind.thaw) &&
          group.containsKey(AccountChangeKind.revoke)) {
        add('Unlock', group.remove(AccountChangeKind.revoke)!);
        group.remove(AccountChangeKind.thaw);
      }
      for (final change in group.values) {
        add(switch (change.kind) {
          AccountChangeKind.approve => 'Delegating',
          AccountChangeKind.revoke => 'Revoking',
          AccountChangeKind.freeze => 'Freezing',
          AccountChangeKind.thaw => 'Thawing',
          _ => '',
        }, change);
      }
    }
    return result;
  }

  BalanceChange _balanceChange(BuildContext context, FundChange fund) {
    if (review.nftMetadata.containsKey(fund.asset.id) ||
        review.nfts.any((n) => n.assetId == fund.asset.id)) {
      return BalanceChange(
        label: fund.rawAmount.isNegative ? 'You send' : 'You receive',
        amount: _nftName(fund.asset.id),
        icon: _nftIcon(fund.asset.id),
        outgoing: fund.rawAmount.isNegative,
        detailWidget: _detailLine(context, [
          reviewAddressSpan(context, fund.asset.id),
        ]),
      );
    }
    final amount = fund.rawAmount.abs();
    final price =
        (review.chain == 'solana:mainnet' ||
                review.chain == 'eip155:1' ||
                review.chain == 'tezos:NetXdQprcVkpaWU') &&
            fund.asset.decimals != null
        ? priceOf?.call(fund.asset.id)
        : null;
    final units = double.tryParse(
      formatReviewAmount(amount, fund.asset.decimals),
    );
    final usd = price != null && price.isFinite && price >= 0 && units != null
        ? units * price
        : null;
    final counterparty = fund.rawAmount.isNegative ? fund.to : fund.from;
    return BalanceChange(
      label: fund.rawAmount.isNegative ? 'You send' : 'You receive',
      amount: _amount(amount, fund.asset, review.tokenMetadata),
      icon: _TokenIcon(
        asset: fund.asset,
        size: 40,
        metadata: review.tokenMetadata[fund.asset.id],
      ),
      outgoing: fund.rawAmount.isNegative,
      detailWidget: _verified(fund.asset) && counterparty == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_verified(fund.asset))
                  _detailLine(context, [
                    const TextSpan(text: 'Unverified token · '),
                    reviewAddressSpan(context, fund.asset.id),
                  ]),
                if (counterparty != null)
                  _counterparty(
                    context,
                    fund.rawAmount.isNegative ? 'To ' : 'From ',
                    counterparty,
                  ),
              ],
            ),
      fiat: usd != null && usd.isFinite ? formatUsd(usd) : null,
    );
  }

  Widget _accountRow(BuildContext context, AccountChange change) {
    final c = context.mallowColors;
    final beneficiary = change.beneficiary;
    return _ShortRow(
      icon: _glyphTile(context, switch (change.kind) {
        AccountChangeKind.create => ReviewGlyph.plus,
        AccountChangeKind.close ||
        AccountChangeKind.revoke => ReviewGlyph.cross,
        _ => ReviewGlyph.code,
      }),
      title: change.description,
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: _evm ? 'Contract ' : 'Account '),
            reviewAddressSpan(context, change.address),
            if (beneficiary != null) ...[
              const TextSpan(text: ' · to '),
              reviewAddressSpan(context, beneficiary),
            ],
          ],
        ),
        style: MallowTheme.uiMeta.copyWith(
          letterSpacing: 0,
          height: 1.6,
          color: c.textSecondary,
        ),
      ),
    );
  }

  /// "to <address>", with the address as a copyable chip.
  Widget _counterparty(BuildContext context, String prefix, String? address) =>
      _detailLine(context, [
        TextSpan(text: prefix),
        if (address != null) reviewAddressSpan(context, address),
      ]);

  /// A small secondary line under a row's title, whose addresses are
  /// copyable chips.
  Widget _detailLine(BuildContext context, List<InlineSpan> spans) => Text.rich(
    TextSpan(children: spans),
    style: MallowTheme.uiMeta.copyWith(
      letterSpacing: 0,
      height: 1.6,
      color: context.mallowColors.textSecondary,
    ),
  );

  Widget _glyphTile(BuildContext context, ReviewGlyph glyph) {
    final c = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
      alignment: Alignment.center,
      child: ReviewIcon(glyph, size: 16, color: c.textSecondary),
    );
  }

  Widget _nftRow(BuildContext context, NftChange nft) {
    if (nft.kind == NftChangeKind.authority) {
      // The description says what the authority becomes; the row keeps it
      // beside the NFT's name rather than letting the name replace it.
      return _ShortRow(
        icon: _nftIcon(nft.assetId),
        title: _nftName(nft.assetId),
        subtitle: _detailLine(context, [
          TextSpan(text: nft.description),
          if (nft.to != null) ...[
            const TextSpan(text: ' · '),
            reviewAddressSpan(context, nft.to!),
          ] else if (nft.from != null) ...[
            const TextSpan(text: ' · was '),
            reviewAddressSpan(context, nft.from!),
          ],
        ]),
      );
    }
    return _ShortRow(
      icon: _nftIcon(nft.assetId),
      title: review.nftMetadata[nft.assetId]?.name ?? nft.description,
      subtitle: nft.to != null
          ? _counterparty(context, 'To ', nft.to)
          : nft.from != null
          ? _counterparty(context, 'From ', nft.from)
          : null,
    );
  }
}

/// A known mint takes its symbol from the bundled registry. An unverified one
/// may show its own metadata symbol, which [ReviewTokenMetadata] has already
/// refused when it copies a known token's; the row keeps its "Unverified
/// token" line either way.
String _symbol(ReviewAsset asset, Map<String, ReviewTokenMetadata> metadata) =>
    isRegistryMint(asset.id)
    ? tokenByMint(asset.id)!.symbol
    : metadata[asset.id]?.symbol ?? asset.symbol;

bool _verified(ReviewAsset asset) =>
    asset.verified || asset.id == solMint || isRegistryMint(asset.id);

/// Wei as ETH to at most six decimals; a dust fee reads as "< 0.000001".
String _ether(BigInt wei) {
  final micro = (wei + BigInt.from(500000000000)) ~/ BigInt.from(1000000000000);
  if (micro == BigInt.zero && wei > BigInt.zero) return '< 0.000001';
  return formatReviewAmount(micro, 6);
}

String _amount(
  BigInt amount,
  ReviewAsset asset,
  Map<String, ReviewTokenMetadata> metadata,
) => asset.decimals == null
    ? '${formatReviewAmount(amount, null)} ${_symbol(asset, metadata)}'
    : '${groupThousands(formatReviewAmount(amount, asset.decimals))} ${_symbol(asset, metadata)}';

/// The caption under the hero names where the numbers came from: only
/// simulated balances are "estimated from a simulation". [mixedSlots] adds
/// that the before and after balances were read at different slots.
String _deltaCaption(List<FundChange> deltas, {bool mixedSlots = false}) {
  final sources = deltas.map((f) => f.evidence).toSet();
  const slots = 'Balance snapshots use different slots.';
  if (sources.contains(ReviewEvidence.inferred)) {
    return 'Some amounts are inferred and not verified. The final amounts can differ.${mixedSlots ? ' $slots' : ''}';
  }
  if (sources.contains(ReviewEvidence.requestedInstruction)) {
    return 'Some amounts are read from the request itself, not confirmed by a simulation. The final amounts can differ.${mixedSlots ? ' $slots' : ''}';
  }
  if (sources.contains(ReviewEvidence.event)) {
    return 'Some amounts are reported by the programs involved. The final amounts can change before the transaction lands.${mixedSlots ? ' $slots' : ''}';
  }
  return mixedSlots
      ? 'Estimated from simulation; balance snapshots use different slots.'
      : 'Estimated from simulation';
}

bool _isActionKind(AccountChange change) => const {
  AccountChangeKind.approve,
  AccountChangeKind.revoke,
  AccountChangeKind.freeze,
  AccountChangeKind.thaw,
}.contains(change.kind);

class _NftIcon extends StatelessWidget {
  const _NftIcon({this.metadata});
  final ReviewNftMetadata? metadata;
  @override
  Widget build(BuildContext context) {
    final url = metadata?.imageUrl;
    if (url != null)
      return MallowNetworkImage(
        imageUrl: url,
        logicalSize: 40,
        width: 40,
        height: 40,
        borderRadius: BorderRadius.circular(8),
      );
    return Container(
      decoration: BoxDecoration(
        color: context.mallowColors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const ReviewIcon(ReviewGlyph.image, size: 20),
    );
  }
}

class _ShortRow extends StatelessWidget {
  const _ShortRow({required this.icon, required this.title, this.subtitle});
  final Widget icon;
  final String title;

  /// Carries copyable address chips, so the row is not merged for semantics.
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.mallowColors;
    return Semantics(
      container: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.dividerLight)),
        ),
        child: Row(
          children: [
            SizedBox.square(dimension: 32, child: icon),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: MallowTheme.uiBody.copyWith(
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: c.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: subtitle,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bundled logo when the mint is known to the app; otherwise the token's own
/// image when its metadata passed [ReviewTokenMetadata.fromCreator] (which
/// refuses a known token's symbol, so a look-alike cannot pair a real name
/// with its logo); otherwise a neutral coin.
class _TokenIcon extends StatelessWidget {
  const _TokenIcon({required this.asset, required this.size, this.metadata});
  final ReviewAsset asset;
  final double size;
  final ReviewTokenMetadata? metadata;

  @override
  Widget build(BuildContext context) {
    final c = context.mallowColors;
    if (localTokenImagePath(asset.id) != null) {
      return ClipOval(
        child: tokenImageWidget(
          mint: asset.id,
          size: size,
          symbol: isRegistryMint(asset.id)
              ? tokenByMint(asset.id)!.symbol
              : asset.symbol,
          useChainSvg: false,
        ),
      );
    }
    final coin = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surfaceMuted, shape: BoxShape.circle),
      child: ReviewIcon(
        ReviewGlyph.coin,
        size: size * 0.5,
        color: c.textSecondary,
      ),
    );
    final imageUrl = isRegistryMint(asset.id) ? null : metadata?.imageUrl;
    if (imageUrl == null) return coin;
    return MallowNetworkImage(
      imageUrl: imageUrl,
      logicalSize: size,
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(size / 2),
      placeholderBuilder: (_) => coin,
      errorBuilder: (_) => coin,
    );
  }
}

Future<void> _launch(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// The programs the transaction calls, then the network-specific Explorer
/// simulation link. Every program shows its shortened address as a copy chip,
/// under its name when the label list has one or under "Unknown Program"
/// when it does not, so a name never hides the thing it names. A batch gets one section per
/// transaction, each with its own calls and link.
class _ProgramCalls extends StatelessWidget {
  const _ProgramCalls({required this.review, this.labels, this.openExternal});
  final SimulationReview review;
  final ValueListenable<Map<String, String>>? labels;
  final Future<void> Function(Uri url)? openExternal;

  @override
  Widget build(BuildContext context) {
    final labels = this.labels;
    if (labels == null) return _build(context, const {});
    return ValueListenableBuilder<Map<String, String>>(
      valueListenable: labels,
      builder: (context, names, _) => _build(context, names),
    );
  }

  Widget _build(BuildContext context, Map<String, String> names) {
    final transactions = review.transactions;
    if (transactions.length > 1) {
      final c = context.mallowColors;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < transactions.length; i++)
            Container(
              key: Key('program-calls-transaction-${i + 1}'),
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(top: BorderSide(color: c.dividerLight)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TransactionHeading(
                    index: i + 1,
                    count: transactions.length,
                    execution: transactions[i].execution,
                  ),
                  ..._calls(transactions[i].programCalls, names),
                  if (transactions[i].explorerUrl != null)
                    _explorerLink(transactions[i].explorerUrl!),
                ],
              ),
            ),
        ],
      );
    }
    final calls = review.programCalls.isNotEmpty
        ? review.programCalls
        : [
            for (final account in review.accounts)
              if (account.kind == AccountChangeKind.contractCall)
                ReviewProgramCall(program: account.program),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._calls(calls, names),
        if (review.explorerUrl != null && !review.chain.startsWith('eip155:'))
          _explorerLink(review.explorerUrl!),
      ],
    );
  }

  Iterable<Widget> _calls(
    List<ReviewProgramCall> calls,
    Map<String, String> names,
  ) => calls.map(
    (call) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _ProgramCallRow(call: call, name: names[call.program]),
    ),
  );

  Widget _explorerLink(Uri url) => TextButton.icon(
    onPressed: () => (openExternal ?? _launch)(url),
    icon: const Icon(Icons.open_in_new, size: 16),
    label: const Text('Open simulation in Solana Explorer'),
  );
}

/// "Transaction 2 of 3", and whether its own simulation ran.
class _TransactionHeading extends StatelessWidget {
  const _TransactionHeading({
    required this.index,
    required this.count,
    required this.execution,
  });
  final int index;
  final int count;
  final SimulationExecution execution;

  @override
  Widget build(BuildContext context) {
    final c = context.mallowColors;
    final status = switch (execution) {
      SimulationExecution.succeeded => null,
      SimulationExecution.failed => 'Simulation failed',
      SimulationExecution.unavailable => 'Not simulated',
    };
    return Row(
      children: [
        Expanded(
          child: Text(
            'Transaction $index of $count',
            style: MallowTheme.uiLabel.copyWith(color: c.textSecondary),
          ),
        ),
        if (status != null)
          Text(
            status,
            style: MallowTheme.uiMeta.copyWith(
              color: execution == SimulationExecution.failed
                  ? c.warning
                  : c.textSecondary,
            ),
          ),
      ],
    );
  }
}

/// "Program name ✓ [Instruction]" over the program's copyable address. A
/// program the label list does not name is headed "Unknown Program", with no
/// verified mark.
class _ProgramCallRow extends StatelessWidget {
  const _ProgramCallRow({required this.call, this.name});
  final ReviewProgramCall call;

  /// The program's listed name, or null when it is not on the list.
  final String? name;

  @override
  Widget build(BuildContext context) {
    final c = context.mallowColors;
    final name = this.name;
    final instruction = call.instruction;
    final address = ReviewAddress(
      call.program,
      key: Key('program-address-${call.program}'),
    );
    final heading = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        if (name == null)
          Text(
            'Unknown Program',
            key: Key('program-unknown-${call.program}'),
            style: MallowTheme.uiBody.copyWith(color: c.textSecondary),
          )
        else
          Semantics(
            label: '$name, verified program',
            excludeSemantics: true,
            child: Row(
              key: Key('program-label-${call.program}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    name,
                    style: MallowTheme.uiBody.copyWith(color: c.textPrimary),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.verified_rounded,
                  key: const Key('program-verified'),
                  size: 16,
                  color: c.positive,
                ),
              ],
            ),
          ),
        if (instruction != null)
          Container(
            key: const Key('program-instruction'),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: c.surfaceMuted,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              instruction,
              style: MallowTheme.uiMeta.copyWith(
                letterSpacing: 0,
                height: 1.3,
                color: c.textSecondary,
              ),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [heading, const SizedBox(height: 4), address],
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow(this.identity);

  final ReviewWalletIdentity identity;

  @override
  Widget build(BuildContext context) => ReviewKvRow(
    label: 'Wallet',
    valueWidget: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReviewWalletAvatar(identity: identity, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            identity.name == null
                ? identity.shortAddress
                : '${identity.label} · ${identity.shortAddress}',
            textAlign: TextAlign.right,
            style: MallowTheme.uiBody.copyWith(
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A [SimulationReviewSheet] still waiting on its simulation. It opens as
/// soon as the request arrives, with what is already known (site, wallet,
/// network) and placeholders for the effects and fee. [onApprove] approves
/// without waiting for the review; without it the footer is a lone Close, as
/// on a view-only review.
class SimulationPendingSheet extends StatelessWidget {
  const SimulationPendingSheet({
    required this.origin,
    required this.address,
    required this.chain,
    required this.onReject,
    this.onApprove,
    this.title = _defaultTitle,
    this.approveLabel = 'Approve',
    this.originIcon,
    this.expiry,
    super.key,
  });

  final String origin;
  final String address;
  final String chain;
  final VoidCallback onReject;
  final VoidCallback? onApprove;
  final String title;
  final String approveLabel;
  final Widget? originIcon;

  /// As on [SimulationReviewSheet]: the expiry is measured while the
  /// simulation runs, and an expired transaction cannot be approved early.
  final TransactionExpiryView? expiry;

  @override
  Widget build(BuildContext context) {
    final expiry = this.expiry;
    if (expiry == null) return _build(context, null);
    return ValueListenableBuilder<TransactionExpiry>(
      valueListenable: expiry.state,
      builder: (context, state, _) => _build(context, state),
    );
  }

  Widget _build(BuildContext context, TransactionExpiry? expiryState) {
    final approve = expiryState is ExpiryPassed ? null : onApprove;
    final expiry = this.expiry;
    return SigningReviewLayout(
      footer: approve == null
          ? MallowButton(
              key: const Key('reject-signing'),
              label: 'Close',
              isFullWidth: true,
              onPressed: onReject,
            )
          : ReviewDecisionBar(
              rejectKey: const Key('reject-signing'),
              approveKey: const Key('approve-signing-early'),
              onReject: onReject,
              onApprove: approve,
              approveLabel: approveLabel,
            ),
      children: [
        const SizedBox(height: 4),
        ReviewOriginChip(origin: origin, icon: originIcon),
        const SizedBox(height: 14),
        ReviewTitle(title),
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: ReviewInfoLine(
            approve == null
                ? 'Simulating this transaction…'
                : 'Simulating this transaction… You can approve without waiting for the review.',
          ),
        ),
        if (expiry != null &&
            expiryState != null &&
            transactionExpiryHasNotice(expiry, expiryState)) ...[
          const SizedBox(height: 14),
          transactionExpiryNotice(expiry, expiryState),
        ],
        const SizedBox(height: 18),
        const ShimmerBox(key: Key('review-pending'), height: 72),
        const SizedBox(height: 10),
        ReviewKvRow(
          label: chain.startsWith('tezos:')
              ? 'Fee and storage burn'
              : 'Network fee',
          valueWidget: const ShimmerBox(width: 72, height: 14),
        ),
        if (expiry != null && expiryState != null)
          ...transactionExpiryRows(context, expiry, expiryState),
        _WalletRow(ReviewWalletIdentity.resolve(address)),
        ReviewKvRow(label: 'Network', value: caip2NetworkLabel(chain)),
      ],
    );
  }
}

/// The transaction sheet when no review could be prepared: why, and Close.
/// Nothing was signed.
class SimulationUnavailableSheet extends StatelessWidget {
  const SimulationUnavailableSheet({
    required this.origin,
    required this.message,
    required this.onClose,
    this.originIcon,
    super.key,
  });

  final String origin;
  final String message;
  final VoidCallback onClose;
  final Widget? originIcon;

  @override
  Widget build(BuildContext context) => SigningReviewLayout(
    footer: MallowButton(
      key: const Key('reject-signing'),
      label: 'Close',
      isFullWidth: true,
      onPressed: onClose,
    ),
    children: [
      const SizedBox(height: 4),
      ReviewOriginChip(origin: origin, icon: originIcon),
      const SizedBox(height: 14),
      const ReviewTitle('Transaction not reviewed'),
      const SizedBox(height: 14),
      ReviewCautionCard(
        key: const Key('review-unavailable'),
        messages: [message, 'Nothing was signed.'],
      ),
    ],
  );
}
