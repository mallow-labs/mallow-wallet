import 'dart:async';

import 'package:flutter/material.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../services/block_store.dart';
import '../services/moderation_actions.dart';
import 'unblock_pill.dart';

/// Wraps a profile body and swaps it for [BlockedProfileInterstitial] while the
/// viewed account is on the viewer's block list.
///
/// A blocked profile must render *as blocked* — not as a 404 and not as normal
/// content. Both alternatives are worse: a 404 reads as "this person is gone"
/// and normal content reads as "the block didn't work", and neither offers a
/// way back.
///
/// The gate rebuilds off [BlockStore.blocked] (a [ValueNotifier], so the
/// current value is available on first build — a broadcast stream would miss
/// the state for a profile opened before the listener attached).
class BlockedProfileGate extends StatefulWidget {
  const BlockedProfileGate({
    required this.address,
    required this.label,
    required this.child,
    super.key,
  });

  /// The viewed account's address.
  final String address;

  /// Human label for the copy — display name, @handle, or truncated address.
  final String label;

  final Widget child;

  @override
  State<BlockedProfileGate> createState() => _BlockedProfileGateState();
}

class _BlockedProfileGateState extends State<BlockedProfileGate> {
  @override
  void initState() {
    super.initState();
    // Fire-and-forget: the set starts empty, so the worst case before it lands
    // is one frame of normal content on a profile the viewer blocked.
    unawaited(sl<BlockStore>().ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: sl<BlockStore>().blocked,
      builder: (context, _, child) {
        if (!sl<BlockStore>().isBlocked(widget.address)) return child!;
        return BlockedProfileInterstitial(
          address: widget.address,
          label: widget.label,
        );
      },
      child: widget.child,
    );
  }
}

/// Full-page "You blocked this account" state with an Unblock action.
class BlockedProfileInterstitial extends StatefulWidget {
  const BlockedProfileInterstitial({
    required this.address,
    required this.label,
    super.key,
  });

  final String address;
  final String label;

  @override
  State<BlockedProfileInterstitial> createState() =>
      _BlockedProfileInterstitialState();
}

class _BlockedProfileInterstitialState
    extends State<BlockedProfileInterstitial> {
  bool _working = false;

  Future<void> _unblock() async {
    setState(() => _working = true);
    await runUnblockUserFlow(
      context,
      address: widget.address,
      label: widget.label,
    );
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
            child: MallowHeader(title: ''),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacingXl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MallowSvgIcon(
                      'assets/icons/shield_alert.svg',
                      width: 40,
                      height: 40,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(height: MallowTheme.spacingLg),
                    Text(
                      'You blocked this account',
                      textAlign: TextAlign.center,
                      style: MallowTheme.editorialSubhead.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    Text(
                      'Their artworks, curations, and offers are filtered out '
                      'of your view, and they can’t reach you with '
                      'notifications. Blocking is one-directional — it doesn’t '
                      'stop them bidding on or buying your artwork on-chain.',
                      textAlign: TextAlign.center,
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingXl),
                    UnblockPill(onTap: _unblock, isLoading: _working),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
