import 'package:flutter/material.dart';

import 'error_view.dart';
import 'loading_indicator.dart';

/// A shared loading / error / empty / content frame.
///
/// Most screens render four flavors of the same scaffold: a spinner while
/// data is loading, an error view with retry on failure, an empty state when
/// the loaded payload has no items, and the actual content otherwise. This
/// widget centralizes that branching so each screen only declares the
/// signals (`isLoading`, `error`, `isEmpty`) and the content to show.
///
/// Defaults match the mallow design system ([MallowLoadingIndicator],
/// [MallowErrorView], [MallowEmptyView]). Screens with bespoke skeletons or
/// empty states can override individual builders.
class StateViewer extends StatelessWidget {
  const StateViewer({
    required this.isLoading,
    required this.child,
    super.key,
    this.error,
    this.isEmpty = false,
    this.onRetry,
    this.loadingBuilder,
    this.errorBuilder,
    this.emptyBuilder,
    this.emptyTitle,
    this.emptyMessage,
    this.emptyIconAsset,
    this.emptyActionLabel,
    this.onEmptyAction,
  });

  /// Whether the underlying state is currently loading.
  final bool isLoading;

  /// Non-null error message switches the frame into the error branch.
  final String? error;

  /// Whether the loaded payload is empty.
  final bool isEmpty;

  /// Retry callback wired to the default error view.
  final VoidCallback? onRetry;

  /// Override the default loading widget.
  final WidgetBuilder? loadingBuilder;

  /// Override the default error widget. Receives the [error] message.
  final Widget Function(BuildContext context, String error)? errorBuilder;

  /// Override the default empty widget.
  final WidgetBuilder? emptyBuilder;

  final String? emptyTitle;
  final String? emptyMessage;
  final String? emptyIconAsset;
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  /// Content rendered when none of the above branches apply.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return loadingBuilder?.call(context) ??
          const Center(child: MallowLoadingIndicator());
    }
    final err = error;
    if (err != null) {
      return errorBuilder?.call(context, err) ??
          MallowErrorView(message: err, onRetry: onRetry);
    }
    if (isEmpty) {
      return emptyBuilder?.call(context) ??
          MallowEmptyView(
            title: emptyTitle,
            message: emptyMessage ?? 'Nothing to show yet.',
            iconAsset: emptyIconAsset,
            actionLabel: emptyActionLabel,
            onAction: onEmptyAction,
          );
    }
    return child;
  }
}
