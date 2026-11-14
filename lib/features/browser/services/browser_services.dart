import 'package:flutter/foundation.dart';

import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../models/browser_models.dart';
import 'browser_site_catalog_service.dart';
import 'dapp_permission_service.dart';

/// One instance makes revocation observable across browser screens.
final browserPermissions = DappPermissionService();

/// The well-known sites the address bar suggests. Started by the browser's
/// screens, so the list is fetched only once the browser is used.
final browserSites = BrowserSiteCatalog();

/// The browser's search engine, shared by every address field.
final browserSearchEngine = BrowserSearchEngineSetting();

/// The chosen [BrowserSearchEngine], kept in preferences: it is a display
/// choice, not browsing data, so clearing browsing data leaves it.
class BrowserSearchEngineSetting extends ValueNotifier<BrowserSearchEngine> {
  BrowserSearchEngineSetting() : super(_stored());

  static BrowserSearchEngine _stored() {
    if (!sl.isRegistered<PreferencesService>()) {
      return BrowserSearchEngine.duckDuckGo;
    }
    final name = sl<PreferencesService>().browserSearchEngine;
    return BrowserSearchEngine.values.firstWhere(
      (engine) => engine.name == name,
      orElse: () => BrowserSearchEngine.duckDuckGo,
    );
  }

  Future<void> choose(BrowserSearchEngine engine) async {
    value = engine;
    if (sl.isRegistered<PreferencesService>()) {
      await sl<PreferencesService>().setBrowserSearchEngine(engine.name);
    }
  }
}
