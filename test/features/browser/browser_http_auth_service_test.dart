import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/browser_http_credentials.dart';
import 'package:mallow_wallet/features/browser/services/browser_http_auth_service.dart';

void main() {
  const credentials = (username: 'reader', password: 'test-password');
  const replacement = (username: 'editor', password: 'updated-test-password');
  late String? stored;
  late BrowserHttpAuthService service;

  BrowserHttpAuthService newService() => BrowserHttpAuthService(
    read: () async => stored,
    write: (value) async => stored = value,
  );

  URLProtectionSpace space({
    String host = 'example.com',
    int? port = 443,
    String? realm = 'members',
    String? protocol = 'https',
  }) => URLProtectionSpace(
    host: host,
    port: port,
    realm: realm,
    protocol: protocol,
  );

  Future<BrowserHttpCredentials?> resolve(
    URLProtectionSpace protectionSpace, {
    bool failed = false,
    BrowserHttpAuthPrompt? prompt,
  }) => service.resolve(
    protectionSpace: protectionSpace,
    failed: failed,
    isActive: () => true,
    prompt:
        prompt ??
        ({required failed, username}) async {
          fail('Saved credentials should be reused without a prompt');
        },
  );

  Future<void> save(
    URLProtectionSpace protectionSpace, [
    BrowserHttpCredentials entered = credentials,
  ]) async {
    expect(
      await resolve(
        protectionSpace,
        prompt: ({required failed, username}) async => entered,
      ),
      entered,
    );
  }

  setUp(() {
    stored = null;
    service = newService();
  });

  test('saved credentials survive a new service and repeated visits', () async {
    await save(space());
    service = newService();

    expect(await resolve(space()), credentials);
    expect(await resolve(space()), credentials);
    expect(await resolve(space(host: 'EXAMPLE.COM', port: -1)), credentials);
    expect(await resolve(space(port: null)), credentials);
  });

  test('host, port and realm keep credentials separate', () async {
    await save(space());
    for (final other in [
      space(host: 'other.example.com'),
      space(port: 8443),
      space(realm: 'other'),
      space(realm: null),
    ]) {
      var prompted = false;
      expect(
        await resolve(
          other,
          prompt: ({required failed, username}) async {
            prompted = true;
            expect(username, isNull);
            return null;
          },
        ),
        isNull,
      );
      expect(prompted, isTrue);
    }
    // Delimiters in server-controlled realms cannot collide with a host.
    expect(
      BrowserHttpAuthService.protectionSpaceKey(space(realm: 'x|443|y')),
      isNot(
        BrowserHttpAuthService.protectionSpaceKey(
          space(host: 'example.com|443|x', realm: 'y'),
        ),
      ),
    );
  });

  test('rejects cleartext challenges without prompting or saving', () async {
    expect(await resolve(space(protocol: 'http')), isNull);
    expect(await resolve(space(host: '')), isNull);
    expect(stored, isNull);
  });

  test('rejected saved credentials prompt and save the replacement', () async {
    await save(space());
    expect(
      await resolve(
        space(),
        failed: true,
        prompt: ({required failed, username}) async {
          expect(failed, isTrue);
          expect(username, credentials.username);
          return replacement;
        },
      ),
      replacement,
    );
    service = newService();
    expect(await resolve(space()), replacement);
  });

  test('cancelling a rejected sign-in does not delete saved details', () async {
    await save(space());
    expect(
      await resolve(
        space(),
        failed: true,
        prompt: ({required failed, username}) async => null,
      ),
      isNull,
    );
    service = newService();
    expect(await resolve(space()), credentials);
  });

  test('saving another site preserves existing credentials', () async {
    await save(space());
    await save(space(host: 'second.example.com'), replacement);
    service = newService();

    expect(await resolve(space()), credentials);
    expect(await resolve(space(host: 'second.example.com')), replacement);
  });

  test('clear deletes all saved details across service instances', () async {
    await save(space());
    await service.clear();

    expect(stored, isNull);
    service = newService();
    var prompted = false;
    expect(
      await resolve(
        space(),
        prompt: ({required failed, username}) async {
          prompted = true;
          expect(username, isNull);
          return null;
        },
      ),
      isNull,
    );
    expect(prompted, isTrue);
  });

  test('clear invalidates an outstanding credential read', () async {
    await save(space());
    final read = Completer<String?>();
    service = BrowserHttpAuthService(
      read: () => read.future,
      write: (value) async => stored = value,
    );
    final pending = resolve(space());
    final clearing = service.clear();
    read.complete(stored);

    expect(await pending, isNull);
    await clearing;
    expect(stored, isNull);
  });

  test('clear prevents an outstanding prompt from saving details', () async {
    final entered = Completer<BrowserHttpCredentials?>();
    final prompted = Completer<void>();
    final pending = resolve(
      space(),
      prompt: ({required failed, username}) {
        prompted.complete();
        return entered.future;
      },
    );
    await prompted.future;
    await service.clear();
    entered.complete(credentials);

    expect(await pending, isNull);
    expect(stored, isNull);
  });

  test('clear follows an outstanding write and leaves nothing saved', () async {
    final writing = Completer<void>();
    final finishWrite = Completer<void>();
    service = BrowserHttpAuthService(
      read: () async => stored,
      write: (value) async {
        if (value != null) {
          writing.complete();
          await finishWrite.future;
        }
        stored = value;
      },
    );
    final pending = resolve(
      space(),
      prompt: ({required failed, username}) async => credentials,
    );
    await writing.future;
    final clearing = service.clear();
    finishWrite.complete();

    expect(await pending, isNull);
    await clearing;
    expect(stored, isNull);
  });

  test('storage failures still allow manual sign-in', () async {
    service = BrowserHttpAuthService(
      read: () async => throw StateError('unavailable'),
      write: (_) async => throw StateError('unavailable'),
    );
    await save(space());
    expect(stored, isNull);
  });

  test(
    'failed writes preserve old details and do not poison deletion',
    () async {
      await save(space());
      service = BrowserHttpAuthService(
        read: () async => stored,
        write: (value) async {
          if (value != null) throw StateError('unavailable');
          stored = null;
        },
      );
      expect(
        await resolve(
          space(),
          failed: true,
          prompt: ({required failed, username}) async => replacement,
        ),
        replacement,
      );
      expect(await resolve(space()), credentials);
      await service.clear();
      expect(stored, isNull);
    },
  );

  test('unreadable saved data is preserved during manual sign-in', () async {
    stored = '{invalid';
    await save(space());
    expect(stored, '{invalid');
  });

  test('a closed tab cannot save the result of a pending prompt', () async {
    var active = true;
    final result = await service.resolve(
      protectionSpace: space(),
      failed: false,
      isActive: () => active,
      prompt: ({required failed, username}) async {
        active = false;
        return credentials;
      },
    );

    expect(result, isNull);
    expect(stored, isNull);
  });

  test('without autofill, saved details wait for the user', () async {
    await save(space());
    String? offered;
    final entered = await service.resolve(
      protectionSpace: space(),
      failed: false,
      autofill: false,
      isActive: () => true,
      prompt: ({required failed, username}) async {
        offered = username;
        return replacement;
      },
    );
    // Only the username is offered; the password is never sent unasked.
    expect(offered, credentials.username);
    expect(entered, replacement);
    expect(await resolve(space()), replacement);
  });
}
