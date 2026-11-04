import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/models/account.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/wallet_type_badge.dart';
import '../../wallets/services/profile_lookup_service.dart';
import '../../wallets/services/wallet_drawer_bloc.dart';
import 'browser_site_tile.dart';
import 'browser_tap.dart';

/// What the wallet picker hands back to the browser.
sealed class BrowserWalletPickerResult {
  const BrowserWalletPickerResult();
}

/// A tapped address, with the Account or Profile it was listed under: the
/// browser switches the app's session to that context and uses the wallet
/// for its chain and highlights it in the pill. A Solana pick becomes the
/// app's active wallet; Ethereum and Tezos use explicit wallet ids to sign.
class BrowserWalletPicked extends BrowserWalletPickerResult {
  const BrowserWalletPicked(this.wallet, {this.account, this.profile})
    : assert((account == null) != (profile == null));

  final WalletInfo wallet;
  final Account? account;
  final ProfileGroup? profile;
}

/// The footer's Disconnect for the committed site.
class BrowserWalletDisconnect extends BrowserWalletPickerResult {
  const BrowserWalletDisconnect();
}

/// How many groups, and addresses in each, the two tabs will list: known
/// from the device before the drawer's profile lookup returns, it sizes the
/// loading shimmers.
class BrowserWalletPickerShape {
  const BrowserWalletPickerShape({this.accounts = const [], this.profiles});

  /// Addresses per Account, in order.
  final List<int> accounts;

  /// Addresses per Profile, or null before any profile lookup this session.
  final List<int>? profiles;

  /// Reads the shape from the wallet database and the last profile lookup.
  /// Never throws: an unknown shape just draws one placeholder group.
  static Future<BrowserWalletPickerShape> load() async {
    try {
      final repository = sl<WalletRepository>();
      final accounts = [
        for (final account in await repository.getAccountViews())
          if (_pickable(account.wallets).length case final n when n > 0) n,
      ];
      List<int>? profiles;
      final lookup = sl<ProfileLookupService>();
      if (lookup.lastResponse case final response?) {
        final (groups, _) = lookup.buildProfileGroups(
          await repository.getAllWallets(),
          response,
        );
        profiles = [
          for (final group in groups)
            if (_pickable(group.wallets).length case final n when n > 0) n,
        ];
      }
      return BrowserWalletPickerShape(accounts: accounts, profiles: profiles);
    } catch (_) {
      return const BrowserWalletPickerShape();
    }
  }
}

/// The chains a website can connect to, in the order the picker lists them.
const browserPickerChains = [Chain.solana, Chain.ethereum, Chain.tezos];

/// Wallets held on this device on a chain the browser connects, Solana first
/// then Ethereum and Tezos, each in the group's own order. A placeholder has nothing to
/// switch to. [only] narrows the list to one chain, and [signableOnly] drops
/// the watch-only wallets.
List<WalletInfo> _pickable(
  List<WalletInfo> wallets, {
  Chain? only,
  bool signableOnly = false,
}) => [
  for (final chain in browserPickerChains)
    if (only == null || only == chain)
      for (final w in wallets)
        if (w.chainEnum == chain &&
            !isViewOnlyPlaceholder(w) &&
            (!signableOnly || w.canSign))
          w,
];

/// Opens the wallet picker as a full-screen sheet. It loads its own
/// [WalletDrawerBloc]: the browser's route sits above the tab navigator that
/// provides the drawer's.
///
/// [connectMode] is the picker opened from a connection request's Switch: it
/// asks which wallet to connect with, and has no site footer. [onlyChain]
/// lists one chain's wallets, for a request that can only use that chain.
/// [signableOnly] lists only wallets that can sign, for a caller that is
/// about to sign with the pick.
///
/// [displayWallet] is the single highlighted wallet. The per-chain selections
/// and connection flags describe the providers and their existing site grants.
Future<BrowserWalletPickerResult?> showBrowserWalletPicker({
  required BuildContext context,
  required WalletInfo? selected,
  required bool profileMode,
  WalletInfo? displayWallet,
  WalletInfo? selectedEthereum,
  WalletInfo? selectedTezos,
  String? activeAccountId,
  String? activeProfileId,
  String? host,
  Uri? iconUrl,
  bool siteConnected = false,
  bool ethereumConnected = false,
  bool tezosConnected = false,
  bool connectMode = false,
  Chain? onlyChain,
  bool signableOnly = false,
}) => showMallowSheet<BrowserWalletPickerResult>(
  context: context,
  isScrollControlled: true,
  builder: (_) => BlocProvider(
    create: (_) => sl<WalletDrawerBloc>()..add(const WalletDrawerEvent.load()),
    child: _PickerShapeLoader(
      builder: (shape) => BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
        builder: (context, state) => BrowserWalletPicker(
          state: state,
          shape: shape,
          selected: selected,
          displayWallet: displayWallet,
          selectedEthereum: selectedEthereum,
          selectedTezos: selectedTezos,
          activeAccountId: profileMode ? null : activeAccountId,
          activeProfileId: profileMode ? activeProfileId : null,
          initialTab: profileMode ? 1 : 0,
          host: host,
          iconUrl: iconUrl,
          siteConnected: siteConnected,
          ethereumConnected: ethereumConnected,
          tezosConnected: tezosConnected,
          connectMode: connectMode,
          onlyChain: onlyChain,
          signableOnly: signableOnly,
        ),
      ),
    ),
  ),
);

class _PickerShapeLoader extends StatefulWidget {
  const _PickerShapeLoader({required this.builder});

  final Widget Function(BrowserWalletPickerShape shape) builder;

  @override
  State<_PickerShapeLoader> createState() => _PickerShapeLoaderState();
}

class _PickerShapeLoaderState extends State<_PickerShapeLoader> {
  BrowserWalletPickerShape _shape = const BrowserWalletPickerShape();

  @override
  void initState() {
    super.initState();
    BrowserWalletPickerShape.load().then((shape) {
      if (mounted) setState(() => _shape = shape);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(_shape);
}

/// The browser's wallet picker: `Accounts | Profiles` tabs, each Account or
/// Profile followed by every Solana, Ethereum and Tezos address it holds, each with
/// its chain's mark and its USD value. Tapping an address pops
/// [BrowserWalletPicked]. Only the wallet shown in the pill is highlighted.
///
/// Only Account and Profile names and addresses are shown; a wallet's own
/// stored name is an internal label and never appears. Linked-but-not-imported
/// profile addresses are left out: there is nothing on the device to switch to.
class BrowserWalletPicker extends StatefulWidget {
  const BrowserWalletPicker({
    required this.state,
    required this.selected,
    this.displayWallet,
    this.selectedEthereum,
    this.selectedTezos,
    this.shape = const BrowserWalletPickerShape(),
    this.activeAccountId,
    this.activeProfileId,
    this.initialTab = 0,
    this.host,
    this.iconUrl,
    this.siteConnected = false,
    this.ethereumConnected = false,
    this.tezosConnected = false,
    this.connectMode = false,
    this.onlyChain,
    this.signableOnly = false,
    super.key,
  });

  final WalletDrawerState state;

  /// The wallet shown in the browser's pill.
  final WalletInfo? displayWallet;

  /// The browser's Solana wallet.
  final WalletInfo? selected;

  /// The wallet `window.ethereum` acts for.
  final WalletInfo? selectedEthereum;
  final WalletInfo? selectedTezos;

  /// Sizes the shimmers while [state] is still loading.
  final BrowserWalletPickerShape shape;

  /// The session's Account (Account mode) or Profile (Profile mode): the
  /// same wallet can be listed under both, and only the group in use marks
  /// it selected.
  final String? activeAccountId;
  final String? activeProfileId;

  /// 0 Accounts, 1 Profiles.
  final int initialTab;

  /// The committed site's host, or null with no website open.
  final String? host;
  final Uri? iconUrl;

  /// The committed site is connected to [selected]; only that row says so.
  final bool siteConnected;

  /// The committed site is connected to [selectedEthereum].
  final bool ethereumConnected;
  final bool tezosConnected;
  final bool connectMode;

  /// Lists only this chain's wallets.
  final Chain? onlyChain;

  /// Lists only wallets that can sign.
  final bool signableOnly;

  @override
  State<BrowserWalletPicker> createState() => _BrowserWalletPickerState();
}

class _BrowserWalletPickerState extends State<BrowserWalletPicker> {
  late int _tab = widget.initialTab;

  void _pop(BrowserWalletPickerResult result) {
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Full screen, so switching tabs never changes the sheet's height.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: FullScreenSheet(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(connectMode: widget.connectMode, host: widget.host),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: MallowUnderlineTabBar(
                tabs: const ['Accounts', 'Profiles'],
                activeIndex: _tab,
                onTabSelected: (i) => setState(() => _tab = i),
              ),
            ),
            Expanded(child: _list(context)),
            if (!widget.connectMode && widget.host != null)
              _SiteFooter(
                host: widget.host!,
                iconUrl: widget.iconUrl,
                addresses: [
                  if (widget.siteConnected) ?widget.selected?.address,
                  if (widget.ethereumConnected)
                    ?widget.selectedEthereum?.address,
                  if (widget.tezosConnected) ?widget.selectedTezos?.address,
                ],
                onDisconnect: () => _pop(const BrowserWalletDisconnect()),
              )
            else
              SizedBox(height: sheetBottomInset(context)),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (widget.state.maybeWhen(error: (_) => true, orElse: () => false)) {
      return const _Empty('Wallets could not be loaded');
    }
    final groups = switch (widget.state) {
      WalletDrawerLoaded(:final accounts, :final profileGroups) =>
        _tab == 0 ? _accountGroups(accounts) : _profileGroups(profileGroups),
      WalletDrawerOffline(:final accounts) =>
        _tab == 0 ? _accountGroups(accounts) : null,
      _ => null,
    };
    if (groups == null) {
      return widget.state is WalletDrawerOffline
          ? const _Empty('Profiles are unavailable offline')
          : _Shimmers(
              counts: _tab == 0
                  ? widget.shape.accounts
                  : widget.shape.profiles ?? const [1],
            );
    }
    if (groups.isEmpty) {
      return _Empty(
        _tab == 0
            ? switch (widget.onlyChain) {
                Chain.solana => 'No Solana wallets yet',
                Chain.ethereum => 'No Ethereum wallets yet',
                Chain.tezos => 'No Tezos wallets yet',
                _ => 'No wallets yet',
              }
            : 'No profiles yet',
      );
    }
    final balances = _balances(widget.state);
    final highlighted = switch (widget.onlyChain) {
      Chain.solana => widget.selected,
      Chain.ethereum => widget.selectedEthereum,
      Chain.tezos => widget.selectedTezos,
      null =>
        widget.displayWallet ??
            (widget.siteConnected ? widget.selected : null) ??
            (widget.ethereumConnected ? widget.selectedEthereum : null) ??
            (widget.tezosConnected ? widget.selectedTezos : null) ??
            widget.selected ??
            widget.selectedEthereum ??
            widget.selectedTezos,
    };
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final group in groups)
          _GroupSection(
            group: group,
            balances: balances,
            selectedIds: {?highlighted?.id},
            connectedIds: {
              if (widget.siteConnected) ?widget.selected?.id,
              if (widget.ethereumConnected) ?widget.selectedEthereum?.id,
              if (widget.tezosConnected) ?widget.selectedTezos?.id,
            },
            onPick: _pop,
          ),
      ],
    );
  }

  /// Known USD balances by address. Only the profile grouping streams them
  /// in (cached first, then fresh); an Account's wallets carry none, so the
  /// drawer reads them from here the same way.
  static Map<String, double> _balances(WalletDrawerState state) => {
    if (state case WalletDrawerLoaded(:final profileGroups, :final anonGroup))
      for (final group in [...profileGroups, anonGroup])
        for (final w in group.wallets) w.address: ?w.balanceUsd,
  };

  List<_Group> _accountGroups(List<Account> accounts) => [
    for (final account in accounts)
      if (_pickable(
            account.wallets,
            only: widget.onlyChain,
            signableOnly: widget.signableOnly,
          )
          case final wallets when wallets.isNotEmpty)
        _Group(
          name: account.name,
          italic: false,
          badge: account.typeBadge,
          avatar: _SeedAvatar(seed: account.avatarSeed, size: 28),
          wallets: wallets,
          active: account.id == widget.activeAccountId,
          pick: (w) => BrowserWalletPicked(w, account: account),
        ),
  ];

  List<_Group> _profileGroups(List<ProfileGroup> profiles) => [
    for (final profile in profiles)
      if (_pickable(
            profile.wallets,
            only: widget.onlyChain,
            signableOnly: widget.signableOnly,
          )
          case final wallets when wallets.isNotEmpty)
        _Group(
          name: _profileName(profile),
          italic: true,
          avatar: _ProfileAvatar(profile: profile, size: 28),
          wallets: wallets,
          active:
              profile.userId != null &&
              profile.userId == widget.activeProfileId,
          pick: (w) => BrowserWalletPicked(w, profile: profile),
        ),
  ];

  static String _profileName(ProfileGroup profile) {
    if (profile.username case final name? when name.isNotEmpty) return name;
    if (profile.displayName case final name? when name.isNotEmpty) return name;
    return 'Profile';
  }
}

class _Group {
  const _Group({
    required this.name,
    required this.italic,
    required this.avatar,
    required this.wallets,
    required this.active,
    required this.pick,
    this.badge,
  });

  /// The session's current Account or Profile.
  final bool active;

  final String name;
  final bool italic;
  final WalletBadge? badge;
  final Widget avatar;
  final List<WalletInfo> wallets;
  final BrowserWalletPicked Function(WalletInfo) pick;
}

class _Header extends StatelessWidget {
  const _Header({required this.connectMode, required this.host});

  final bool connectMode;
  final String? host;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        MallowTheme.spacingSm,
        MallowTheme.spacing20,
        MallowTheme.spacingSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              connectMode ? 'Connect with' : 'Choose wallet',
              style: MallowTheme.editorialSection.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          if (connectMode) ...[
            const SizedBox(height: 4),
            Text(
              '${host ?? 'This site'} will see the address you pick.',
              style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.balances,
    required this.selectedIds,
    required this.connectedIds,
    required this.onPick,
  });

  final _Group group;
  final Map<String, double> balances;

  /// The wallet highlighted in the active group.
  final Set<String> selectedIds;

  /// The selected wallets the committed site is connected to.
  final Set<String> connectedIds;
  final ValueChanged<BrowserWalletPickerResult> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final nameStyle = group.italic
        ? GoogleFonts.newsreader(
            fontStyle: FontStyle.italic,
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: colors.textPrimary,
            height: 1.2,
          )
        : MallowTheme.uiBody.copyWith(
            fontWeight: FontWeight.w500,
            color: colors.textPrimary,
          );
    return Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MergeSemantics(
            child: SizedBox(
              height: 46,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    group.avatar,
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      ),
                    ),
                    WalletTypeBadge(group.badge),
                  ],
                ),
              ),
            ),
          ),
          for (final wallet in group.wallets) _row(wallet),
        ],
      ),
    );
  }

  Widget _row(WalletInfo wallet) {
    final selected = group.active && selectedIds.contains(wallet.id);
    return _AddressRow(
      wallet: wallet,
      balance: balances[wallet.address],
      owner: group.name,
      selected: selected,
      // Only a wallet this site sees can be connected to it.
      connected: group.active && connectedIds.contains(wallet.id),
      onTap: () => onPick(group.pick(wallet)),
    );
  }
}

/// Placeholder groups while the drawer loads: one per known Account or
/// Profile, with a row per known address.
class _Shimmers extends StatelessWidget {
  const _Shimmers({required this.counts});

  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Semantics(
      label: 'Loading wallets',
      child: ExcludeSemantics(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(8),
          children: [
            for (final count in counts.isEmpty ? const [1] : counts)
              Container(
                padding: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: colors.surfaceMuted),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(
                      height: 46,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            ShimmerBox(
                              width: 28,
                              height: 28,
                              borderRadius: BorderRadius.all(
                                Radius.circular(14),
                              ),
                            ),
                            SizedBox(width: 10),
                            ShimmerBox(width: 96, height: 14),
                          ],
                        ),
                      ),
                    ),
                    for (var i = 0; i < count; i++)
                      const SizedBox(
                        height: 48,
                        child: Padding(
                          padding: EdgeInsets.only(left: 50, right: 12),
                          child: Row(
                            children: [
                              ShimmerBox(width: 112, height: 14),
                              Spacer(),
                              ShimmerBox(width: 52, height: 12),
                            ],
                          ),
                        ),
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

/// One address. The whole row is the tap target; the active wallet is
/// marked by the row's muted fill, not a control.
class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.wallet,
    required this.balance,
    required this.owner,
    required this.selected,
    required this.connected,
    required this.onTap,
  });

  final WalletInfo wallet;
  final double? balance;
  final String owner;
  final bool selected;
  final bool connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final address = truncateAddress(wallet.address);
    final viewOnly = !wallet.canSign;
    final chain = wallet.chainEnum;
    final semantics = [
      '$owner, ${chain.label} $address',
      if (viewOnly) 'view-only',
      if (connected) 'connected to this site',
      if (selected) 'selected',
    ].join(', ');
    return BrowserTap(
      onTap: onTap,
      label: semantics,
      child: Container(
        height: 48,
        padding: const EdgeInsets.only(left: 50, right: 12),
        decoration: BoxDecoration(
          color: selected ? colors.surfaceMuted : null,
          borderRadius: BorderRadius.circular(12),
        ),
        // The address and its marks take the free space, so the value always
        // sits flush right; a Flexible beside a Spacer would split it.
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  // The chain decides which provider this address answers
                  // for, so it is shown on every row.
                  MallowSvgIcon(
                    switch (chain) {
                      Chain.ethereum => 'assets/icons/ethereum.svg',
                      Chain.tezos => 'assets/icons/tezos.svg',
                      Chain.solana => 'assets/icons/solana.svg',
                    },
                    width: 14,
                    height: 14,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiBody.copyWith(
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  if (viewOnly) ...[
                    const SizedBox(width: 8),
                    const WalletTypeBadge(WalletBadge.watchOnly, size: 12),
                  ],
                  if (connected) ...[
                    const SizedBox(width: 10),
                    _ConnectedMark(),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (balance case final usd?)
              Text(
                formatUsd(usd),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectedMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: colors.positive,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'Connected',
          style: MallowTheme.uiCaption.copyWith(
            fontWeight: FontWeight.w600,
            // See BrowserWalletPill: the token alone is too faint as text.
            color: Color.lerp(colors.positive, colors.textPrimary, 0.3),
          ),
        ),
      ],
    );
  }
}

class _SiteFooter extends StatelessWidget {
  const _SiteFooter({
    required this.host,
    required this.iconUrl,
    required this.addresses,
    required this.onDisconnect,
  });

  final String host;
  final Uri? iconUrl;

  /// The addresses the site is connected as, at most one per chain.
  final List<String> addresses;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final connected = addresses.isNotEmpty;
    final short = addresses
        .map((a) => truncateAddress(a, lead: 4, trail: 4))
        .join(' · ');
    return Container(
      padding: EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        10,
        MallowTheme.spacing20,
        sheetBottomInset(context),
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.dividerLight)),
      ),
      child: Row(
        children: [
          BrowserSiteTile(host: host, iconUrl: iconUrl, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiLabel.copyWith(
                    fontWeight: FontWeight.w500,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  connected ? 'Connected as $short' : 'Not connected',
                  style: MallowTheme.uiCaption.copyWith(
                    fontWeight: connected ? FontWeight.w600 : FontWeight.w400,
                    color: connected
                        ? Color.lerp(colors.positive, colors.textPrimary, 0.3)
                        : colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (connected)
            BrowserTap(
              key: const Key('picker-disconnect'),
              onTap: onDisconnect,
              label: 'Disconnect $host',
              minHitSize: 44,
              child: Container(
                constraints: const BoxConstraints(minHeight: 36),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.bgSurface,
                  borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
                  border: Border.all(color: colors.divider),
                ),
                child: Text(
                  'Disconnect',
                  style: MallowTheme.uiLabel.copyWith(color: colors.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile, required this.size});

  final ProfileGroup profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final seed = avatarSeedOf(username: profile.username, id: profile.userId);
    final imageUrl = profile.imageUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: imageUrl,
        logicalSize: size,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(size / 2),
        errorBuilder: (_) => _SeedAvatar(seed: seed, size: size),
      );
    }
    return _SeedAvatar(seed: seed, size: size);
  }
}

/// The generated avatar, or a muted disc where no [AvatarService] is
/// registered (widget tests and previews).
class _SeedAvatar extends StatelessWidget {
  const _SeedAvatar({required this.seed, required this.size});

  final String seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (sl.isRegistered<AvatarService>()) {
      return AccountAvatar(seed: seed, size: size);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.mallowColors.surfaceMuted,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(MallowTheme.spacing20),
    child: Center(
      child: Text(
        text,
        style: MallowTheme.uiMeta.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      ),
    ),
  );
}
