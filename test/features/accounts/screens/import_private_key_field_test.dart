import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/screens/import_private_key_screen.dart';
import 'package:mallow_wallet/features/accounts/services/import_private_key_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _MockBloc extends MockBloc<ImportPrivateKeyEvent, ImportPrivateKeyState>
    implements ImportPrivateKeyBloc {}

/// The private-key field receives a raw signing key. Like the seed-word grid,
/// it must keep that key away from the keyboard's suggestions and learning,
/// and out of the platform's autofill service.
void main() {
  late _MockBloc bloc;

  setUp(() {
    bloc = _MockBloc();
    whenListen(
      bloc,
      const Stream<ImportPrivateKeyState>.empty(),
      initialState: const ImportPrivateKeyState.initial(),
    );
    sl.registerFactory<ImportPrivateKeyBloc>(() => bloc);
  });

  tearDown(() => sl.unregister<ImportPrivateKeyBloc>());

  testWidgets('the key field keeps the key out of the keyboard and autofill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const ImportPrivateKeyScreen(accountId: 'acct-1'),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(field.autofillHints, isNull);
  });
}
