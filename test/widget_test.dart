import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/app.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAppLockBloc extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

void main() {
  // Placeholder smoke test. The app has many DI-resolved collaborators that
  // need to exist for `MallowApp.initState` and the first build pass to run
  // without crashing — we stub only the pieces touched synchronously before
  // the router future resolves, then assert the splash logo is on screen.

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    final getIt = GetIt.I;

    final mockAppLockBloc = _MockAppLockBloc();
    when(
      () => mockAppLockBloc.state,
    ).thenReturn(const AppLockState.uninitialized());

    final mockCastBloc = _MockCastBloc();
    when(() => mockCastBloc.state).thenReturn(const CastState.idle());

    if (getIt.isRegistered<AppLockBloc>()) {
      await getIt.unregister<AppLockBloc>();
    }
    getIt.registerFactory<AppLockBloc>(() => mockAppLockBloc);

    if (getIt.isRegistered<CastBloc>()) {
      await getIt.unregister<CastBloc>();
    }
    getIt.registerFactory<CastBloc>(() => mockCastBloc);

    if (getIt.isRegistered<PreferencesService>()) {
      await getIt.unregister<PreferencesService>();
    }
    getIt.registerSingleton<PreferencesService>(
      await PreferencesService.create(),
    );
  });

  tearDown(() async {
    final getIt = GetIt.I;
    if (getIt.isRegistered<AppLockBloc>()) {
      await getIt.unregister<AppLockBloc>();
    }
    if (getIt.isRegistered<CastBloc>()) {
      await getIt.unregister<CastBloc>();
    }
    if (getIt.isRegistered<PreferencesService>()) {
      await getIt.unregister<PreferencesService>();
    }
  });

  testWidgets('App can pump splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MallowApp());

    // Should show splash screen initially (before router is ready).
    // The splash mirrors the welcome screen's logo placement and renders the
    // M logo via SvgPicture — no other widget is on screen at this point.
    expect(find.byType(SvgPicture), findsOneWidget);
  });
}
