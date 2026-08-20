import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'di.config.dart';

/// Global service locator instance.
final sl = GetIt.instance;

/// Initialize dependency injection.
///
/// This should be called once at app startup before runApp().
@InjectableInit()
Future<void> configureDependencies() async => sl.init();
