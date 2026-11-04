import 'package:package_info_plus/package_info_plus.dart';

import 'environment.dart';

/// The installed version as shown to people, e.g. `1.4.0 (137)`.
///
/// A preview build appends [Config.buildLabel]:
/// `1.4.0 (137) · preview dev@1a2b3c4d`.
String displayAppVersion(PackageInfo info) {
  final version = '${info.version} (${info.buildNumber})';
  final label = Config.buildLabel;
  return label.isEmpty ? version : '$version · $label';
}
