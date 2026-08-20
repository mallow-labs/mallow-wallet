import 'dart:async';

import 'package:flutter/material.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../models/recipient_suggestion.dart';
import '../services/recipient_search_service.dart';
import 'send_sheet_widgets.dart';

/// Shortest and longest input that can be a username. Below the floor every
/// query matches half the userbase; above the ceiling the input is an address
/// or a typo, not a handle.
const int kRecipientSearchMinLength = 3;
const int kRecipientSearchMaxLength = 32;

/// Time after the last keystroke before a search is issued.
const Duration kRecipientSearchDebounce = Duration(milliseconds: 500);

/// Key of the dropdown row offering [address].
///
/// Keyed on the address rather than the handle because one profile can occupy
/// several rows, and because the handle is also the field's own text — a
/// text-based finder would match both.
Key recipientSuggestionKey(String address) =>
    ValueKey('recipient-suggestion-$address');

/// Owns the username-search lifecycle for one recipient field: the trigger
/// gate, the debounce, the request, and the open/closed state the dropdown
/// renders from.
///
/// Kept apart from the widget so the two recipient fields — which hold their
/// own address state in quite different shapes — can drive identical search
/// behaviour from inside their existing `onChanged` handlers.
class RecipientSearchController extends ChangeNotifier {
  RecipientSearchController({RecipientSearchService? service, this.isExcluded})
    : _serviceOverride = service;

  final RecipientSearchService? _serviceOverride;

  /// Resolved on the first search rather than in the constructor: the field
  /// renders — and every existing recipient-step test drives it — without ever
  /// searching, and merely showing an address input should not require the
  /// search service to be registered.
  RecipientSearchService get _service =>
      _serviceOverride ?? sl<RecipientSearchService>();

  /// Addresses to hide from results — the caller's own wallets. Filtering here
  /// rather than at pick time means the user is never offered a row that would
  /// be rejected with "You can't send to your own wallet".
  final bool Function(String address)? isExcluded;

  Timer? _debounce;

  /// Incremented per issued request; a response whose token is stale is
  /// dropped. The webapp compares query strings instead, which cannot tell two
  /// identical queries apart — type "alice", backspace, retype, and the first
  /// response can land last and overwrite the newer one.
  int _sequence = 0;

  bool _isOpen = false;
  bool _isLoading = false;
  List<RecipientSuggestion> _results = const [];
  Chain _chain = Chain.solana;

  bool get isOpen => _isOpen;
  bool get isLoading => _isLoading;
  List<RecipientSuggestion> get results => _results;

  /// Chain the visible results were fetched for — drives the empty-state copy.
  Chain get chain => _chain;

  /// Whether [text] should trigger a username search on [chain].
  ///
  /// Static so the gate can be unit-tested and reasoned about on its own: it is
  /// what decides between "this is a handle" and "this is an address", and both
  /// call sites suppress their address validation on its answer.
  static bool shouldSearch(String text, Chain chain) {
    final trimmed = text.trim();
    final query = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
    if (query.length < kRecipientSearchMinLength) return false;
    if (query.length > kRecipientSearchMaxLength) return false;
    // A dot means a `.sol`/`.eth` domain or a typo — never a mallow username.
    if (query.contains('.')) return false;
    // Most addresses are longer than the ceiling, but not all: base58 drops a
    // character per leading zero byte, so a pubkey like the System Program's
    // `1111…` is exactly 32 and clears the gate above. Searching for an address
    // the user already holds is a wasted request either way.
    return !chain.isValidAddress(query);
  }

  /// Feed every keystroke here, from inside the field's existing `onChanged`.
  ///
  /// Opens immediately when the gate passes so the dropdown appears with a
  /// loading state on the first qualifying character, rather than 500 ms later.
  void onInput(String text, Chain chain) {
    _debounce?.cancel();

    if (!shouldSearch(text, chain)) {
      close();
      return;
    }

    // Bump the sequence on every accepted keystroke, not just on dispatch, so a
    // request already in flight cannot deliver into a newer query's dropdown.
    _sequence++;
    final token = _sequence;

    _chain = chain;
    _isOpen = true;
    _isLoading = true;
    _results = const [];
    notifyListeners();

    _debounce = Timer(kRecipientSearchDebounce, () => _run(text, chain, token));
  }

  Future<void> _run(String text, Chain chain, int token) async {
    final found = await _service.search(text, chain);
    if (token != _sequence) return;

    final exclude = isExcluded;
    _results = exclude == null
        ? found
        : found.where((s) => !exclude(s.address)).toList();
    _isLoading = false;
    notifyListeners();
  }

  /// Close and clear. Also invalidates any in-flight request, so a response
  /// arriving after the user picked a row cannot reopen the dropdown.
  void close() {
    _debounce?.cancel();
    _sequence++;
    if (!_isOpen && _results.isEmpty && !_isLoading) return;
    _isOpen = false;
    _isLoading = false;
    _results = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

/// Wraps a recipient address field in a floating suggestions dropdown.
///
/// [child] is the field itself (a `MallowPillField`); this only adds the
/// overlay, so the field keeps its own error, suffix and validation wiring.
class RecipientSearchDropdown extends StatefulWidget {
  const RecipientSearchDropdown({
    required this.controller,
    required this.focusNode,
    required this.onSelected,
    required this.child,
    super.key,
  });

  final RecipientSearchController controller;

  /// The field's focus node — losing focus closes the dropdown.
  final FocusNode focusNode;

  final ValueChanged<RecipientSuggestion> onSelected;
  final Widget child;

  @override
  State<RecipientSearchDropdown> createState() =>
      _RecipientSearchDropdownState();
}

class _RecipientSearchDropdownState extends State<RecipientSearchDropdown> {
  final _link = LayerLink();
  final _portalController = OverlayPortalController();

  /// Shared by the field and the overlay so a tap on either counts as "inside".
  /// A full-screen barrier would close the dropdown correctly but swallow the
  /// tap, so dismissing it would cost the user a second tap to reach the
  /// recents list underneath.
  late final Object _tapGroup = Object();

  /// Width of the field, captured on its layout. The overlay child is built
  /// against the Overlay's own constraints, so it cannot measure the field
  /// itself — the card would span the whole screen without this.
  double _fieldWidth = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncPortal);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(RecipientSearchDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncPortal);
      widget.controller.addListener(_syncPortal);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
    // Deliberately no _syncPortal() here: this runs during build, and
    // OverlayPortalController.show/hide marks the overlay dirty, which throws
    // if it happens mid-build. The controller's own notification syncs us.
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncPortal);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (!widget.focusNode.hasFocus) widget.controller.close();
  }

  void _syncPortal() {
    if (!mounted) return;
    final shouldShow = widget.controller.isOpen;
    if (shouldShow == _portalController.isShowing) {
      // Same visibility, different contents (results landed) — repaint.
      if (shouldShow) setState(() {});
      return;
    }
    shouldShow ? _portalController.show() : _portalController.hide();
  }

  void _select(RecipientSuggestion suggestion) {
    widget.controller.close();
    widget.onSelected(suggestion);
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => widget.controller.close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portalController,
          overlayChildBuilder: _buildOverlay,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _fieldWidth = constraints.maxWidth;
              return widget.child;
            },
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final colors = context.mallowColors;
    // Anchored to the target's bottom-left, so the card tracks the field
    // whether or not the field is currently showing an error line under it.
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      offset: const Offset(0, MallowTheme.spacingXs),
      child: Align(
        alignment: Alignment.topLeft,
        child: TapRegion(
          groupId: _tapGroup,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: _fieldWidth,
              constraints: const BoxConstraints(maxHeight: 240),
              decoration: BoxDecoration(
                color: colors.bgSurface,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                border: Border.all(color: colors.divider),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: _buildContent(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = context.mallowColors;
    final controller = widget.controller;

    if (controller.isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing12,
          vertical: MallowTheme.spacingSm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
              child: Row(
                children: [
                  ShimmerBox(width: 32, height: 32),
                  SizedBox(width: MallowTheme.spacing12),
                  Expanded(child: ShimmerBox(height: 12)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (controller.results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing12,
          vertical: MallowTheme.spacing12,
        ),
        // Names the chain: results are filtered to addresses that can receive
        // on it, so a real username with no wallet on this chain finds nothing.
        // A bare "No users found" would read as a broken search.
        child: Text(
          'No ${controller.chain.label} users found',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXs),
      // Must be set explicitly: MallowScrollBehavior makes `onDrag` the
      // app-wide default, and here that makes the list unscrollable. Dragging
      // it would unfocus the field, and losing focus closes the dropdown
      // (`_onFocusChanged`) — so the card vanishes the moment you try to reach
      // the rows below the 240px cut-off.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
      itemCount: controller.results.length,
      itemBuilder: (context, index) {
        final suggestion = controller.results[index];
        return _SuggestionRow(
          key: recipientSuggestionKey(suggestion.address),
          suggestion: suggestion,
          onTap: () => _select(suggestion),
        );
      },
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.onTap,
    super.key,
  });

  final RecipientSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing12),
        child: Row(
          children: [
            RecipientAvatar(
              size: 32,
              imageUrl: suggestion.imageUrl,
              seed: suggestion.address,
            ),
            const SizedBox(width: MallowTheme.spacing12),
            Expanded(
              child: Text(
                suggestion.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            // Load-bearing, not decoration: one profile can produce several
            // rows, and this is the only thing that tells them apart.
            Text(
              truncateAddress(suggestion.address),
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
