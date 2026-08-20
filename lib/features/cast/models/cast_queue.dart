import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../shared/utils/artwork_display.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import 'cast_display_type.dart';
import 'cast_media_type.dart';

part 'cast_queue.freezed.dart';
part 'cast_queue.g.dart';

/// A single item in the cast queue, representing one artwork.
@freezed
sealed class CastQueueItem with _$CastQueueItem {
  const factory CastQueueItem({
    required String mintAccount,
    required String title,

    /// **Raw** still-image URL exactly as the API returned it — frequently an
    /// `ipfs://` / `ar://` URI, and when https the full-size original. Nothing
    /// may fetch it directly; render it through `MallowNetworkImage`, or via
    /// `ArtworkMediaResolver.posterUrl` / `.originalCastUrl` on the receivers.
    required String imageUrl,

    /// **Raw** animation/video URL, if available. Same handling as [imageUrl].
    String? animationUrl,

    /// Display name for the artist (e.g. "John Doe"), used as a fallback
    /// when [artistUsername] is not available.
    String? artistName,

    /// Bare handle (no leading `@`). Preferred when present — the queue
    /// rows render `@$artistUsername` rather than the display name.
    String? artistUsername,

    /// Whether the artist has a verified badge — drives the checkmark next
    /// to the byline on the Now Playing screen.
    @Default(false) bool isVerified,

    /// Whether the artist has the `admin` role — tints the verified badge
    /// with [MallowColors.selected] when true.
    @Default(false) bool isAdmin,

    /// Resolved media type — set lazily by [ArtworkMediaResolver].
    /// Defaults to [CastMediaType.unknown] until resolved.
    @Default(CastMediaType.unknown) CastMediaType mediaType,
  }) = _CastQueueItem;

  factory CastQueueItem.fromJson(Map<String, dynamic> json) =>
      _$CastQueueItemFromJson(json);
}

/// Repeat behaviour for the slideshow.
///
/// - [off]: queue ends after the last item; skip controls disable at edges.
/// - [all]: auto-advance and manual skip wrap around the queue.
/// - [one]: the current item replays indefinitely; manual skip is still
///   bounded by the queue (skip-next from the last item is disabled unless
///   the user also wants to wrap, which they don't with `one`).
enum CastRepeatMode { off, all, one }

/// The full cast queue with playback state.
@freezed
sealed class CastQueue with _$CastQueue {
  const factory CastQueue({
    @Default([]) List<CastQueueItem> items,
    @Default(0) int currentIndex,

    /// Seconds between auto-advancing slides.
    @Default(30) int slideshowIntervalSeconds,

    @Default(false) bool isPaused,

    /// Show the QR code overlay on the receiver. Session-scoped toggle.
    @Default(true) bool showQr,

    /// Show the title + artist caption overlay on the receiver. Session-scoped.
    @Default(true) bool showCaption,

    /// True when [items] has been shuffled. Toggling off restores
    /// [originalItems], so flipping shuffle is non-destructive.
    @Default(false) bool isShuffled,

    /// Pre-shuffle order. Empty when not shuffled. Mutated alongside [items]
    /// so add/remove during a shuffled session keep the unshuffled view in sync.
    @Default([]) List<CastQueueItem> originalItems,

    /// Repeat behaviour. Affects auto-advance wrap behaviour and manual
    /// skip-edge behaviour — see [CastRepeatMode].
    @Default(CastRepeatMode.all) CastRepeatMode repeatMode,

    /// How the receiver should fit each artwork into the screen above the
    /// bottom info bar. Session-scoped; persists across sessions via prefs.
    @Default(CastDisplayType.fillScreen) CastDisplayType displayType,
  }) = _CastQueue;

  factory CastQueue.fromJson(Map<String, dynamic> json) =>
      _$CastQueueFromJson(json);
}

// ---------------------------------------------------------------------------
// Factories from existing app models
// ---------------------------------------------------------------------------

extension CastQueueItemFromArtwork on CastQueueItem {
  /// Build from the portfolio UI model.
  static CastQueueItem fromPortfolioArtwork(PortfolioArtwork artwork) =>
      CastQueueItem(
        mintAccount: artwork.mintAccount,
        title: formatArtworkName(
          name: artwork.title,
          editionNumber: artwork.editionNumber,
        ),
        imageUrl: artwork.imageUrl,
        animationUrl: artwork.animationUrl,
        artistName: artwork.artistName,
        artistUsername: artwork.artistUsername,
        isVerified: artwork.isVerified,
        isAdmin: artwork.isAdmin,
      );

  /// Build from the artwork detail model.
  static CastQueueItem fromArtworkDetails(ArtworkDetails details) =>
      CastQueueItem(
        mintAccount: details.mintAccount,
        title: formatArtworkName(
          name: details.title,
          editionNumber: details.editionNumber,
        ),
        imageUrl: details.imageUrl,
        animationUrl: details.animationUrl,
        artistName: details.artistName,
        artistUsername: details.artistUsername,
        isVerified: details.isVerified,
        isAdmin: details.isAdmin,
      );
}

extension CastQueueHelpers on CastQueue {
  /// The item currently being cast, or null if the queue is empty.
  CastQueueItem? get currentItem =>
      items.isEmpty ? null : items[currentIndex.clamp(0, items.length - 1)];

  /// The item one slot ahead of [currentItem], wrapping when [repeatMode]
  /// is [CastRepeatMode.all]. Used by the tile-mode carousel to render the
  /// right peek; null when the queue ends and wrap is off.
  CastQueueItem? get nextItem {
    if (items.isEmpty) return null;
    if (hasNext) return items[currentIndex + 1];
    if (repeatMode == CastRepeatMode.all) return items.first;
    return null;
  }

  /// The item one slot behind [currentItem], wrapping when [repeatMode]
  /// is [CastRepeatMode.all]. Used by the tile-mode carousel to render
  /// the left peek; null at the start of an unwrapped queue.
  CastQueueItem? get previousItem {
    if (items.isEmpty) return null;
    if (hasPrevious) return items[currentIndex - 1];
    if (repeatMode == CastRepeatMode.all) return items.last;
    return null;
  }

  /// True when there is a next item to advance to (ignoring repeat).
  bool get hasNext => currentIndex < items.length - 1;

  /// True when there is a previous item (ignoring repeat).
  bool get hasPrevious => currentIndex > 0;

  /// True when the skip-next control should be tappable. Repeat-all lets
  /// users wrap from the last item; repeat-one disables wrap (the user
  /// chose to stay on the current item).
  bool get canSkipNext =>
      items.length > 1 && (hasNext || repeatMode == CastRepeatMode.all);

  /// True when the skip-previous control should be tappable.
  bool get canSkipPrevious =>
      items.length > 1 && (hasPrevious || repeatMode == CastRepeatMode.all);

  /// Advance to the next index, wrapping when [repeatMode] is
  /// [CastRepeatMode.all]. Returns `this` if there is nowhere to go.
  CastQueue withNextIndex() {
    if (items.isEmpty) return this;
    if (hasNext) return copyWith(currentIndex: currentIndex + 1);
    if (repeatMode == CastRepeatMode.all) return copyWith(currentIndex: 0);
    return this;
  }

  /// Step back one index, wrapping when [repeatMode] is
  /// [CastRepeatMode.all]. Returns `this` if there is nowhere to go.
  CastQueue withPreviousIndex() {
    if (items.isEmpty) return this;
    if (hasPrevious) return copyWith(currentIndex: currentIndex - 1);
    if (repeatMode == CastRepeatMode.all) {
      return copyWith(currentIndex: items.length - 1);
    }
    return this;
  }

  CastQueue withItemAdded(CastQueueItem item) {
    // Skip duplicates so re-tapping "Add to cast" on the same artwork is a
    // no-op rather than padding the queue with copies.
    if (items.any((it) => it.mintAccount == item.mintAccount)) return this;
    return copyWith(
      items: [...items, item],
      // Keep the unshuffled view consistent so toggling shuffle off later
      // doesn't drop items added during a shuffled session.
      originalItems: isShuffled ? [...originalItems, item] : originalItems,
    );
  }

  /// Append [newItems] to the queue, skipping any whose [mintAccount]
  /// already exists. Used when adding a collection/curation/profile-all
  /// batch to the active session.
  CastQueue withItemsAdded(List<CastQueueItem> newItems) {
    if (newItems.isEmpty) return this;
    final existing = items.map((it) => it.mintAccount).toSet();
    final additions = <CastQueueItem>[];
    for (final item in newItems) {
      if (existing.add(item.mintAccount)) additions.add(item);
    }
    if (additions.isEmpty) return this;
    return copyWith(
      items: [...items, ...additions],
      originalItems: isShuffled
          ? [...originalItems, ...additions]
          : originalItems,
    );
  }

  CastQueue withItemRemoved(int index) {
    final removed = items[index];
    final newItems = List<CastQueueItem>.from(items)..removeAt(index);
    final newIndex = currentIndex >= newItems.length
        ? (newItems.isEmpty ? 0 : newItems.length - 1)
        : currentIndex;
    final newOriginalItems = isShuffled
        ? (List<CastQueueItem>.from(originalItems)
            ..removeWhere((it) => it.mintAccount == removed.mintAccount))
        : originalItems;
    return copyWith(
      items: newItems,
      currentIndex: newIndex,
      originalItems: newOriginalItems,
    );
  }

  CastQueue withItemReordered(int oldIndex, int newIndex) {
    final newItems = List<CastQueueItem>.from(items);
    final item = newItems.removeAt(oldIndex);
    newItems.insert(newIndex, item);
    return copyWith(items: newItems);
  }

  /// Snapshot the current order into [originalItems] and shuffle [items].
  /// [currentIndex] is rewritten to track the same playing item by mintAccount.
  CastQueue withShuffleOn() {
    if (items.isEmpty) {
      return copyWith(isShuffled: true, originalItems: const []);
    }
    final snapshot = List<CastQueueItem>.from(items);
    final shuffled = List<CastQueueItem>.from(items)..shuffle();
    final playingMint = currentItem?.mintAccount;
    final newIndex = playingMint == null
        ? 0
        : shuffled.indexWhere((it) => it.mintAccount == playingMint);
    return copyWith(
      items: shuffled,
      originalItems: snapshot,
      currentIndex: newIndex < 0 ? 0 : newIndex,
      isShuffled: true,
    );
  }

  /// Restore [originalItems] as [items], adjusting [currentIndex] so the
  /// same item keeps playing. Clears [originalItems] and [isShuffled].
  CastQueue withShuffleOff() {
    if (originalItems.isEmpty) {
      return copyWith(isShuffled: false, originalItems: const []);
    }
    final playingMint = currentItem?.mintAccount;
    final newIndex = playingMint == null
        ? 0
        : originalItems.indexWhere((it) => it.mintAccount == playingMint);
    return copyWith(
      items: List<CastQueueItem>.from(originalItems),
      originalItems: const [],
      currentIndex: newIndex < 0 ? 0 : newIndex,
      isShuffled: false,
    );
  }
}
