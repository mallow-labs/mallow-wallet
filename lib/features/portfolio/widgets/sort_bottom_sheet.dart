import 'package:flutter/material.dart';

import '../../../shared/widgets/sort_options_sheet.dart';
import '../services/portfolio_bloc.dart';

/// Shows a bottom sheet with sort options and returns the selected option.
/// Thin [PortfolioSortOption] wrapper over the shared [showSortOptionsSheet].
Future<PortfolioSortOption?> showSortBottomSheet(
  BuildContext context, {
  required PortfolioSortOption currentSort,
  List<PortfolioSortOption> options = PortfolioSortOption.values,
}) {
  return showSortOptionsSheet(
    context,
    options: options,
    currentSort: currentSort,
    labelFor: (option) => switch (option) {
      PortfolioSortOption.count => 'Count',
      PortfolioSortOption.name => 'Name',
      PortfolioSortOption.recent => 'Recent',
    },
  );
}
