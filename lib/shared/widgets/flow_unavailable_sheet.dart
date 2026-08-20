import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/analytics/analytics_events.dart';
import '../../core/analytics/analytics_service.dart';
import '../../core/config/remote_config.dart';
import '../../core/config/remote_config_service.dart';
import '../../core/result/app_failure.dart';
import '../../core/security/transaction_auth_gate.dart'
    show kFlowDisabledFallbackMessage;
import '../../di.dart';
import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';

/// Explains why a flow the user just tried to enter is switched off.
///
/// [message] is the operator's copy from `GET /v2/config/mobile`
/// ([RemoteConfig.disabledMessage]) and is rendered **verbatim** — it is
/// written for the specific incident and is the only thing that can tell the
/// user whether their funds are safe. Falls back to
/// [kFlowDisabledFallbackMessage] only when the server sent a blank string.
///
/// Acknowledgement-only: there is nothing for the user to decide, so the sheet
/// has a single "OK" rather than the Cancel/Confirm pair of
/// [GenericConfirmationSheet].
Future<void> showFlowUnavailableSheet(BuildContext context, String message) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FlowUnavailableSheet(message: message),
  );
}

/// The operator's message for [flow], or null when the cell is live.
///
/// A synchronous read of the cached config — entry gates must never block a
/// tap on the network. Pure, so it is safe to
/// call from `build` when rendering a disabled row; [guardFlowDisabled] and
/// [flowGatedScreen] are the entry-point wrappers that also kick the refresh.
///
/// Deliberately **not** [RemoteConfig.isFlowAvailable]: an unimplemented cell
/// is a bug that must reach the signing backstop and fail loud there, not
/// be quietly swallowed by an entry gate that has no message to show.
String? flowDisabledMessage(FlowKey flow) => sl<RemoteConfigService>()
    .config
    .value
    .disabledMessage(flow.chain, flow.flow);

/// item 1 — every flow entry point nudges the config, fire-and-forget, so
/// an hours-old foreground session still picks up a kill within one TTL of
/// touching a gated flow. Never awaited: the tap path reads the cached value
/// and a network round trip on tap would be a dead-feeling button.
///
/// [guardFlowDisabled] and [flowGatedScreen] call it for you; call it directly
/// only at an entry point that reads [flowDisabledMessage] itself (a sheet
/// fronting two cells, a menu rendering disabled rows).
void refreshRemoteConfigOnFlowEntry() =>
    unawaited(sl<RemoteConfigService>().refreshIfStale());

/// Records that a kill was **presented** to a user, for incident-reach
/// measurement. Fire-and-forget.
///
/// A kill is not a failure — it is deliberately not a [FailureReason], so it
/// can't corrupt rejection metrics. [flow] is null only where the presenting
/// code genuinely doesn't know the cell (a mid-flow failure carries the
/// operator's message, not the key); the `surface` dimension still lands.
///
/// Only explicit presentations may call this. Reactive row/button disabling
/// rebuilds on every config emission and would inflate the count.
///
/// Registration-guarded: widget tests routinely register only
/// [RemoteConfigService], and a missing [AnalyticsService] must not turn a
/// kill presentation into a crash.
void trackFlowDisabledHit(FlowKey? flow, FlowDisabledSurface surface) {
  if (!sl.isRegistered<AnalyticsService>()) return;
  unawaited(
    sl<AnalyticsService>().track(
      AnalyticsEvent.flowDisabledHit,
      properties: {
        if (flow != null) AnalyticsProp.flow: flow.toString(),
        AnalyticsProp.surface: surface.wire,
      },
    ),
  );
}

/// Shared mid-flow presentation for a kill that got past the entry gates and
/// was caught by the signing backstop.
///
/// Returns `false` when [failure] is not a kill, so the caller falls through to
/// its normal handling; returns `true` once the explanation sheet has been
/// shown. **Every gated surface's failure branch calls this before its generic
/// (or silent) error handling** — that is what makes the kill UX identical
/// whether the user is stopped at entry or mid-flow.
///
/// After dismissal the underlying surface stays **open and idle**: form state
/// intact, action reset, no auto-pop and no quote-refetch loop. Tapping the
/// action again re-shows the sheet via [guardFlowDisabled]. The message is the
/// response — never destroy user state.
///
/// [flow] is optional because an [AppFailure] carries the operator's copy but
/// not the cell key; pass it where the call site already has one so the
/// event gets its `flow` dimension.
bool handleFlowDisabled(
  BuildContext context,
  AppFailure failure, {
  FlowKey? flow,
}) {
  if (failure.kind != AppFailureKind.flowDisabled) return false;
  trackFlowDisabledHit(flow, FlowDisabledSurface.midFlow);
  // Not awaited: callers are synchronous failure branches (bloc listeners,
  // `switch` arms) and must not be forced async to present a sheet.
  unawaited(showFlowUnavailableSheet(context, failure.message));
  return true;
}

/// Pre-flight kill-switch guard, shaped like [guardViewOnly]: returns `true`
/// when the caller must **abort** (the cell is off and the explanation sheet
/// has been shown), `false` when the flow may proceed.
///
/// Place it at the top of the handler — before signer re-pointing and the
/// view-only guard — so a user is told the action is off *before* being made
/// to switch wallets for it.
///
/// Always re-check `context.mounted` after awaiting.
Future<bool> guardFlowDisabled(BuildContext context, FlowKey flow) async {
  refreshRemoteConfigOnFlowEntry();
  final message = flowDisabledMessage(flow);
  if (message == null) return false;
  trackFlowDisabledHit(flow, FlowDisabledSurface.entryGate);
  await showFlowUnavailableSheet(context, message);
  return true;
}

/// Route-level gate: [builder]'s screen when the flow is live, otherwise a
/// [FlowUnavailableScreen] that explains and leaves.
///
/// Thin wrapper over [FlowGatedScreen] so `GoRoute` builders read the same as
/// before; all of the behaviour (and the reason it is stateful) is documented
/// there.
Widget flowGatedScreen(List<FlowKey> flows, Widget Function() builder) =>
    FlowGatedScreen(flows: flows, builder: builder);

/// Decides gated-vs-real **once, at route entry**, and never flips while this
/// [State] lives.
///
/// [flows] is the set of cells the destination fronts. A chooser screen
/// offering several actions is blocked only when **every** one of them is
/// killed — killing fixed-price listing creation must not also close the
/// route to auction creation. The first killed cell's message is the one shown.
///
/// Presenting beats redirecting: silently bouncing a tap back is exactly the
/// dead end exists to remove.
///
/// **Why a snapshot rather than a read inside the `GoRoute` builder:**
/// go_router re-invokes *every stacked route's* builder whenever the
/// `RouteMatchList` changes, so a plain read re-evaluates on any push/pop in
/// that navigator. A kill landing mid-session (delivered by this gate's own
/// [refreshRemoteConfigOnFlowEntry]) would then swap a live form for
/// [FlowUnavailableScreen] at the next navigation, and the differing
/// `runtimeType` tears down the form `State` — every typed field and in-flight
/// upload lost. With the snapshot, a mid-session kill affects only the *next*
/// entry to the screen; users already inside are stopped at submit by the
/// `authorize()` backstop. That is the deliberate tradeoff: **never destroy
/// user state from a rebuild artifact.**
class FlowGatedScreen extends StatefulWidget {
  const FlowGatedScreen({
    required this.flows,
    required this.builder,
    super.key,
  });

  final List<FlowKey> flows;
  final Widget Function() builder;

  @override
  State<FlowGatedScreen> createState() => _FlowGatedScreenState();
}

class _FlowGatedScreenState extends State<FlowGatedScreen> {
  /// Non-null ⇒ gated. Decided once; `late final` so a stray reassignment is
  /// a compile error rather than a silent mid-life flip.
  late final String? _disabledMessage;

  @override
  void initState() {
    super.initState();
    refreshRemoteConfigOnFlowEntry();
    final messages = [
      for (final flow in widget.flows) flowDisabledMessage(flow),
    ];
    _disabledMessage = messages.any((m) => m == null) ? null : messages.first;
    if (_disabledMessage != null) {
      // One event per route entry — the snapshot guarantees this can't fire
      // again on rebuild. Only an explicit presentation of a kill is counted,
      // never a reactive row/button disable: render-driven inflation would
      // ruin the hit count as a measure of how far an incident reached.
      trackFlowDisabledHit(widget.flows.first, FlowDisabledSurface.routeGate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _disabledMessage;
    return message == null
        ? widget.builder()
        : FlowUnavailableScreen(message: message);
  }
}

/// Route-level counterpart of [showFlowUnavailableSheet]: presents the same
/// sheet over an empty page, then pops the route once it is acknowledged, so
/// the user lands back where they tapped with an explanation rather than on a
/// screen they can't use.
class FlowUnavailableScreen extends StatefulWidget {
  const FlowUnavailableScreen({required this.message, super.key});

  final String message;

  @override
  State<FlowUnavailableScreen> createState() => _FlowUnavailableScreenState();
}

class _FlowUnavailableScreenState extends State<FlowUnavailableScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame — the route is still animating in, and a sheet
    // pushed during build would race the route it belongs to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_explainThenLeave());
    });
  }

  Future<void> _explainThenLeave() async {
    if (!mounted) return;
    await showFlowUnavailableSheet(context, widget.message);
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(backgroundColor: context.mallowColors.bgPrimary);
}

class _FlowUnavailableSheet extends StatelessWidget {
  const _FlowUnavailableSheet({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final body = message.trim().isEmpty
        ? kFlowDisabledFallbackMessage
        : message;

    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
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
                MallowTheme.spacingMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Temporarily unavailable',
                    style: MallowTheme.uiTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  // Operator copy is arbitrary length — let the sheet grow to
                  // [maxSheetHeight] and scroll only past that, per the
                  // shrink-wrap convention in [showMallowSheet].
                  Flexible(
                    child: SingleChildScrollView(
                      child: Text(
                        body,
                        style: MallowTheme.uiBody.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  MallowButton(
                    label: 'OK',
                    isFullWidth: true,
                    onPressed: () => Navigator.of(context).pop(),
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
