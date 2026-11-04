import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/onboarding_notice_slot.dart';
import 'package:mallow_wallet/core/services/signer_prompt_tracker.dart';

void main() {
  group('SignerPromptTracker', () {
    test('counts sheets on screen', () {
      final tracker = SignerPromptTracker();
      final seen = <int>[];
      tracker.open.addListener(() => seen.add(tracker.open.value));

      tracker
        ..opened()
        ..opened()
        ..closed()
        ..closed();

      expect(seen, [1, 2, 1, 0]);
    });

    test('never goes below zero', () {
      final tracker = SignerPromptTracker()..closed();
      expect(tracker.open.value, 0);
    });
  });

  test('OnboardingNoticeSlot starts empty', () {
    expect(OnboardingNoticeSlot().notice.value, isNull);
  });
}
