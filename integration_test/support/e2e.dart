// Barrel for the shared E2E harness. One import per flow file:
//
//     import 'support/e2e.dart';
//
// See `test/e2e/README.md` -> "Adding a flow" for the file layout rules, and
// `harness.dart` for why `pumpAndSettle` is banned and why many cases belong
// in one file.

export 'harness.dart';
export 'mock_control.dart';
export 'navigation.dart';
export 'test_wallet.dart';
