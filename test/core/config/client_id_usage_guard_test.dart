import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scanning guard on where the client-id credential may be attached.
///
/// The header stands in for an API key on the open `/v2` routes, so it must
/// only ever travel to a host the deployment declares first-party
/// (`Config.firstPartyHosts`). Two mechanisms enforce that, and nothing else
/// is allowed to: `ClientIdInterceptor` for everything on the shared `Dio`,
/// and `Config.clientIdHeadersFor(url)` for the clients that ride no
/// interceptor chain — raw `RpcClient`s, per-service `Dio`s, `package:http`.
///
/// Both are easy to bypass by accident: `...Config.clientIdHeaders` reads like
/// an ordinary header spread and produces an *ungated* credential that follows
/// whatever endpoint the build was configured with, including a public
/// third-party RPC. Nothing at runtime distinguishes the two, and no analyzer
/// rule catches it, so the check is textual and lives here.
void main() {
  final libDir = Directory('lib');

  /// Files allowed to name `clientIdHeaders` without the `For` suffix: the
  /// definition itself and the interceptor that applies its own host guard.
  const sanctioned = {
    'lib/core/config/environment.dart',
    'lib/core/network/client_id_interceptor.dart',
  };

  /// Matches `clientIdHeaders` but not `clientIdHeadersFor`. The lookahead is
  /// load-bearing — every migrated call site contains `clientIdHeaders` as a
  /// substring, so a plain `contains` would flag all of them.
  final ungated = RegExp(r'clientIdHeaders(?!For)');

  /// The deleted pre-gate accessor. Tombstoned so it cannot be reintroduced
  /// under its old name, which carried no host guard at all.
  final tombstone = RegExp(r'rpcProxyHeaders');

  /// `lib/**/*.dart` as repo-relative POSIX paths, sorted for stable output.
  List<({String path, String source})> dartSources() {
    expect(
      libDir.existsSync(),
      isTrue,
      reason:
          'Run this from the package root: the guard scans lib/ on disk, so '
          'the working directory has to be the one holding pubspec.yaml.',
    );
    final files =
        libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final f in files)
        (path: f.path.replaceAll(r'\', '/'), source: f.readAsStringSync()),
    ];
  }

  test('the client-id credential is never attached without a host gate', () {
    final offenders = [
      for (final file in dartSources())
        if (!sanctioned.contains(file.path) && ungated.hasMatch(file.source))
          file.path,
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          'These files name Config.clientIdHeaders directly:\n'
          '  ${offenders.join('\n  ')}\n\n'
          'Use Config.clientIdHeadersFor(url) instead, passing the URL the '
          'request actually targets. clientIdHeaders is the raw credential '
          'with no host check: spread into a client that talks to a '
          'configurable endpoint, it hands our identity to whichever host the '
          'deployment pointed that endpoint at — a public RPC, a third-party '
          'pinning service — where it lands in someone else\'s access logs. '
          'clientIdHeadersFor returns an empty map unless the host is in '
          'Config.firstPartyHosts.\n\n'
          'If you are adding a genuinely new place the credential belongs, '
          'say so here — do not widen the sanctioned set to silence this.',
    );
  });

  test('the ungated rpcProxyHeaders accessor stays deleted', () {
    final offenders = [
      for (final file in dartSources())
        if (tombstone.hasMatch(file.source)) file.path,
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          'These files name rpcProxyHeaders:\n'
          '  ${offenders.join('\n  ')}\n\n'
          'That accessor was removed because it returned the client-id '
          'credential unconditionally, and every one of its call sites talked '
          'to an endpoint the build configures. Use '
          'Config.clientIdHeadersFor(url).',
    );
  });
}
