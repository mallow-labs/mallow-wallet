import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/config/remote_config_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/state_viewer.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../portfolio/utils/token_display_order.dart';
import '../../portfolio/widgets/token_list_item.dart';
import '../../portfolio/widgets/unverified_tokens_header.dart';
import '../services/send_bloc.dart' show sendFlowKey;
import 'send_sheet_widgets.dart';

import '../../../shared/utils/chain.dart';
import '../../../shared/utils/tezos_address.dart' show parseTezosTokenRef;

/// Whether [token] can be sent through the current send flow. The token picker
/// aggregates every chain the session holds, but only some are transactional:
///  - **Solana** — all tokens (SOL + SPL) are sendable.
///  - **Tezos** — native XTZ, plus any FA1.2/FA2 holding whose `mint` still
///    decodes to its case-exact `KT1…` (+ optional FA2 `token_id`). A holding
///    that does not is one cached before the balance mapper stopped
///    lower-casing Tezos contracts: the contract cannot be recovered from the
///    string, so the row stays unsendable until the next network refresh
///    rewrites it. Hidden rather than shown-and-failing at review.
///  - **Ethereum** — native ETH and ERC-20 tokens are sendable (client-side
///    EIP-1559 build/sign/broadcast).
bool isSendableToken(TokenBalance token) => switch (token.chain) {
  Chain.solana => true,
  Chain.tezos => token.isNative || parseTezosTokenRef(token.mint) != null,
  Chain.ethereum => true,
};

/// The operator's kill message for sending [token], or null when its cell is
/// live.
///
/// This is the send flow's entry gate:
/// `showSendSheet` opens before either the chain or the native-vs-token split
/// is known, and **both** come from this picker — so the cell can only be
/// resolved once a row exists. [sendFlowKey] is the same derivation
/// [SendBloc] uses at signing time, which is what keeps the two from
/// disagreeing about whether a row is `native-send` or `token-send`.
String? sendDisabledMessage(RemoteConfig config, TokenBalance token) {
  final cell = sendFlowKey(token.chain, isNative: token.isNative);
  return config.disabledMessage(cell.chain, cell.flow);
}

/// First send step: pick the token to send from the
/// wallet's holdings, with a search filter. Tapping a row advances the flow —
/// there is no confirm button on this step.
class SendTokenSelectStep extends StatefulWidget {
  const SendTokenSelectStep({required this.onSelected, super.key});

  final ValueChanged<TokenBalance> onSelected;

  @override
  State<SendTokenSelectStep> createState() => _SendTokenSelectStepState();
}

class _SendTokenSelectStepState extends State<SendTokenSelectStep> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
          child: SendStepHeader(title: 'Send'),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: MallowPillField(
            controller: _searchController,
            hintText: 'Search',
            autocorrect: false,
            enableSuggestions: false,
            prefix: MallowSvgIcon(
              'assets/icons/search.svg',
              width: 20,
              height: 20,
              color: colors.textSecondary,
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Expanded(
          // Rebuild the rows when a config refresh lands: `showSendSheet`
          // fires one on the way in, so the answer can change a beat after
          // the picker is already on screen.
          child: ValueListenableBuilder<RemoteConfig>(
            valueListenable: sl<RemoteConfigService>().config,
            builder: (context, config, _) =>
                BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
                  builder: (context, state) {
                    return StateViewer(
                      isLoading: state.maybeWhen(
                        initial: () => true,
                        loading: () => true,
                        orElse: () => false,
                      ),
                      error: state.mapOrNull(error: (e) => e.message),
                      onRetry: () => context.read<TokenBalanceBloc>().add(
                        const TokenBalanceEvent.load(),
                      ),
                      child: state.maybeMap(
                        loaded: (s) => _tokenList(context, s.tokens, config),
                        orElse: () => const SizedBox.shrink(),
                      ),
                    );
                  },
                ),
          ),
        ),
      ],
    );
  }

  Widget _tokenList(
    BuildContext context,
    List<TokenBalance> tokens,
    RemoteConfig config,
  ) {
    final query = _query.toLowerCase();
    // Only show tokens the send flow can actually transact (see
    // [isSendableToken]) — this is the chain filter on the picker.
    final sendable = tokens.where(isSendableToken);
    final filtered = query.isEmpty
        ? sendable.toList()
        : sendable
              .where(
                (t) =>
                    t.name.toLowerCase().contains(query) ||
                    t.symbol.toLowerCase().contains(query),
              )
              .toList();

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          query.isEmpty ? 'No tokens to send' : 'No tokens found',
          style: MallowTheme.uiBody.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
      );
    }

    // Same shape as the tokens portfolio: gas tokens pinned first, the rest by
    // top USD value, unverified mints under their own header.
    final ordered = sortTokensForDisplay(filtered);
    final verified = ordered.where((t) => t.isVerified).toList();
    final unverified = ordered.where((t) => !t.isVerified).toList();

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ..._rows(context, verified, config),
        if (unverified.isNotEmpty) ...[
          const UnverifiedTokensHeader(),
          ..._rows(context, unverified, config),
        ],
      ],
    );
  }

  /// [tokens] as rows, divided between each other but not after the last —
  /// so a section header is not preceded by a dangling divider.
  List<Widget> _rows(
    BuildContext context,
    List<TokenBalance> tokens,
    RemoteConfig config,
  ) {
    final rows = <Widget>[];
    for (var index = 0; index < tokens.length; index++) {
      final token = tokens[index];
      final disabled = sendDisabledMessage(config, token);
      rows.add(
        disabled != null
            ? _DisabledTokenRow(token: token, message: disabled)
            : TokenListItem(
                token: token,
                onTap: () => widget.onSelected(token),
              ),
      );
      if (index < tokens.length - 1) {
        rows.add(
          Divider(
            height: 1,
            indent: MallowTheme.spacing20,
            endIndent: MallowTheme.spacing20,
            color: context.mallowColors.dividerLight,
          ),
        );
      }
    }
    return rows;
  }
}

/// A holding whose `(chain, native|token)` send cell an operator has killed.
///
/// Still listed, not filtered out — a token that silently vanishes from the
/// picker reads as "my funds are gone", which is the opposite of what an
/// incident notice should do. Inert (no `onTap`) and carrying the server's copy
/// verbatim, matching the `SheetMenuRow(enabled: false, subtitle: …)` treatment
/// the other disabled rows use.
class _DisabledTokenRow extends StatelessWidget {
  const _DisabledTokenRow({required this.token, required this.message});

  final TokenBalance token;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TokenListItem(token: token),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              0,
              MallowTheme.spacing20,
              MallowTheme.spacing12,
            ),
            child: Text(
              message,
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
