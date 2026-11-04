import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

/// A line the welcome screen shows when it is non-null.
///
/// `SessionInitializer` is not mounted during onboarding, so a feature that
/// holds something for a user without a wallet has no other way to say so.
/// Nothing sets it by default, which leaves the welcome screen unchanged.
@lazySingleton
class OnboardingNoticeSlot {
  /// The text to show, or null for none.
  final ValueNotifier<String?> notice = ValueNotifier<String?>(null);
}
