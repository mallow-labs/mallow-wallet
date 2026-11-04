import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mallow_wallet/features/browser/services/browser_visibility.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';

void main() {
  test('resuming behind settings cannot restore web content or requests', () {
    final visibility = BrowserVisibility()..routeVisible = false;
    expect(visibility.updateLifecycle(AppLifecycleState.paused), isTrue);
    expect(visibility.updateLifecycle(AppLifecycleState.resumed), isFalse);
    expect(visibility.canReceiveRequests, isFalse);
    expect(visibility.retainWebView, isFalse);
    expect(visibility.coverWebView, isTrue);
    visibility.routeVisible = true;
    expect(visibility.canReceiveRequests, isTrue);
    expect(visibility.retainWebView, isTrue);
  });
  test(
    'transient biometric inactive covers but preserves approval document',
    () {
      final visibility = BrowserVisibility();
      expect(visibility.updateLifecycle(AppLifecycleState.inactive), isFalse);
      expect(visibility.canReceiveRequests, isFalse);
      expect(visibility.coverWebView, isTrue);
      expect(visibility.retainWebView, isTrue);
      expect(visibility.updateLifecycle(AppLifecycleState.resumed), isFalse);
      expect(visibility.canReceiveRequests, isTrue);
      expect(visibility.coverWebView, isFalse);
    },
  );
  test(
    'an external signer returning before resume keeps in-flight work alive',
    () {
      final visibility = BrowserVisibility();
      visibility.updateLifecycle(AppLifecycleState.inactive);
      expect(visibility.canReceiveRequests, isFalse);
      expect(visibility.canContinueRequests, isTrue);
      visibility.updateLifecycle(AppLifecycleState.paused);
      expect(visibility.canContinueRequests, isFalse);
      // Resuming passes back through inactive; the suspension holds until resumed.
      visibility.updateLifecycle(AppLifecycleState.inactive);
      expect(visibility.canContinueRequests, isFalse);
      visibility.updateLifecycle(AppLifecycleState.resumed);
      expect(visibility.canContinueRequests, isTrue);
    },
  );
  test('actual backgrounding cancels work but keeps the covered page', () {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      final visibility = BrowserVisibility();
      expect(visibility.updateLifecycle(state), isTrue);
      expect(visibility.retainWebView, isTrue);
      expect(visibility.coverWebView, isTrue);
      expect(visibility.canReceiveRequests, isFalse);
      expect(visibility.canContinueRequests, isFalse);
    }
  });
  test('returning from the background uncovers the same page', () {
    final visibility = BrowserVisibility();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
    ]) {
      visibility.updateLifecycle(state);
      expect(visibility.retainWebView, isTrue);
      expect(visibility.coverWebView, isTrue);
    }
    expect(visibility.updateLifecycle(AppLifecycleState.resumed), isFalse);
    expect(visibility.coverWebView, isFalse);
    expect(visibility.canReceiveRequests, isTrue);
  });
  test('an explorer hop from the review keeps the request and the page', () {
    final visibility = BrowserVisibility()..beginExternalHop();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      expect(visibility.updateLifecycle(state), isFalse);
      expect(visibility.retainWebView, isTrue);
      expect(visibility.canContinueRequests, isTrue);
      expect(visibility.canReceiveRequests, isFalse);
      expect(visibility.coverWebView, isTrue);
    }
    expect(visibility.updateLifecycle(AppLifecycleState.resumed), isFalse);
    expect(visibility.canReceiveRequests, isTrue);
    // The resume ended the hop: the next backgrounding is real again.
    expect(visibility.updateLifecycle(AppLifecycleState.paused), isTrue);
    expect(visibility.canContinueRequests, isFalse);
  });
  test('a failed launch or detach does not leave the hop exemption', () {
    final failed = BrowserVisibility()
      ..beginExternalHop()
      ..endExternalHop();
    expect(failed.updateLifecycle(AppLifecycleState.paused), isTrue);
    final detached = BrowserVisibility()..beginExternalHop();
    expect(detached.updateLifecycle(AppLifecycleState.detached), isTrue);
    expect(detached.canContinueRequests, isFalse);
  });
  test('native overlays remain blocking across lifecycle transitions', () {
    final visibility = BrowserVisibility()..nativeOverlays = 1;
    visibility.updateLifecycle(AppLifecycleState.inactive);
    visibility.updateLifecycle(AppLifecycleState.resumed);
    expect(visibility.canReceiveRequests, isFalse);
    visibility.nativeOverlays--;
    expect(visibility.canReceiveRequests, isTrue);
  });
  testWidgets(
    'page observer suspends full-screen routes but not approval dialogs',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final page = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [browserPageRouteObserver],
          home: Scaffold(key: page),
        ),
      );
      final events = _RouteEvents();
      browserPageRouteObserver.subscribe(
        events,
        ModalRoute.of(page.currentContext!)! as PageRoute<dynamic>,
      );
      unawaited(
        navigator.currentState!.push(
          DialogRoute<void>(
            context: page.currentContext!,
            builder: (_) => const AlertDialog(title: Text('Native approval')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(events.covered, 0);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Settings')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(events.covered, 1);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(events.revealed, 1);
      browserPageRouteObserver.unsubscribe(events);
    },
  );

  test('plugin event logging cannot expose page URLs or bridge payloads', () {
    PlatformInAppWebViewController.debugLoggingSettings.enabled = true;
    configureBrowserWebViewPrivacy();
    expect(
      PlatformInAppWebViewController.debugLoggingSettings.enabled,
      isFalse,
    );
  });
}

class _RouteEvents with RouteAware {
  int covered = 0;
  int revealed = 0;
  @override
  void didPushNext() => covered++;
  @override
  void didPopNext() => revealed++;
}
