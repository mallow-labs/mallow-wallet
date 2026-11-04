// Run with: node --test test/features/browser/ui_channel_test.mjs
import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';

const read = path => readFileSync(new URL(`../../../lib/features/browser/services/${path}`, import.meta.url), 'utf8');
const provider = read('dapp_provider_script.dart').split("r'''")[1].split("''';")[0];
const channel = read('browser_ui_channel.dart');
const grant = channel.split("const _grantScript = r'''")[1].split("''';")[0];
const startTheme = channel.split("const _startThemeScript = r'''")[1].split("''';")[0];
const matcher = channel.split("const _firstPartyDocumentScript = r'''")[1].split("''';")[0];
// The built-in hosts, read from the Dart list itself so the two cannot drift.
const hosts = [...channel.split('const browserFirstPartyHosts = <String>[')[1].split('];')[0].matchAll(/^\s*'([^']+)',/gm)].map(([, host]) => host);
const origins = hosts.map(host => `https://${host}`);
const firstParty = 'https://mallow.art';
// What the native host passes the scripts: the exact origins, and whether
// local development hosts count.
const firstPartyCall = local => `${matcher}(${JSON.stringify(origins)}, ${local})`;
const locationOf = url => {
  const {protocol, origin, hostname} = new URL(url);
  return {protocol, origin, hostname};
};

function fixture({android = false, origin = firstParty, local = false, theme = 'dark', startTheme: started, token = 'native-document-token', mainFrame = true, opener = null, withGrant = true, uiReply = () => ({result: null})} = {}) {
  const requests = [];
  const window = new EventTarget();
  window.top = mainFrame ? window : {};
  window.opener = opener;
  if (token) window.__mallowDocumentToken = token;
  window.__mallowSupportedChains = ['solana:mainnet'];
  // Approvals never answer, so they stay pending for the limit checks.
  const respond = envelope => {
    requests.push(envelope);
    return envelope.namespace === 'ui' ? Promise.resolve(uiReply(envelope)) : new Promise(() => {});
  };
  if (android) {
    window.mallowNative = {postMessage: value => {
      const envelope = JSON.parse(value);
      respond(envelope).then(reply => window.mallowNative.onmessage({data: JSON.stringify({id: envelope.id, ...reply})}));
    }};
  } else {
    window.flutter_inappwebview = {callHandler: (name, envelope) => {assert.equal(name, 'mallowWallet'); return respond(envelope);}};
  }
  const context = createContext({window, location: locationOf(origin), Uint8Array, Date, Event, CustomEvent, setTimeout, clearTimeout, atob, btoa});
  if (withGrant) runInContext(`${grant}(${firstPartyCall(local)}, ${JSON.stringify(theme)});`, context);
  runInContext(provider, context);
  // Added after the provider when the wallet's theme moved since the grant.
  if (started) runInContext(`${startTheme}(${firstPartyCall(local)}, ${JSON.stringify(started)});`, context);
  return {window, requests};
}

const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test('a first-party document gets window.mallow.ui, frozen, and the grant is gone', () => {
  const {window} = fixture();
  const {ui} = window.mallow;
  assert.equal(ui.version, 1);
  assert.equal(ui.theme, 'dark');
  assert.equal(typeof ui.setOverlay, 'function');
  assert.ok(Object.isFrozen(ui));
  assert.ok(Object.isFrozen(window.mallow));
  assert.equal(window.__mallowUiGrant, undefined);
  assert.equal(Object.getOwnPropertyDescriptor(window, '__mallowUiGrant'), undefined);
  assert.equal(window.mallow.solana.isMallow, true);
});

for (const [name, options] of [
  ['another origin', {origin: 'https://evil.example'}],
  ['a look-alike origin', {origin: 'https://mallow.art.evil.example'}],
  ['a gateway subdomain', {origin: 'https://gateway.mallow.art'}],
  ['an origin on another port', {origin: 'https://mallow.art:8443'}],
  ['a local host outside development', {origin: 'https://localhost:5173'}],
  ['a third-party host in development', {origin: 'https://evil.example', local: true}],
  ['a popup', {opener: {}}],
  ['no grant script at all', {withGrant: false}],
]) {
  test(`${name} gets the providers only, exactly as before`, () => {
    const {window} = fixture(options);
    assert.deepEqual(Object.keys(window.mallow), ['solana', 'ethereum', 'tezos']);
    assert.equal(window.__mallowUiSetTheme, undefined);
    assert.equal(window.__mallowUiGrant, undefined);
  });
}

for (const origin of origins) {
  test(`${origin}, a built-in origin, gets window.mallow.ui`, () => {
    const {window} = fixture({origin});
    assert.equal(window.mallow.ui.version, 1);
  });
}

test('a development build grants a local web app', () => {
  const {window} = fixture({origin: 'https://192.168.1.20:5173', local: true});
  assert.equal(window.mallow.ui.version, 1);
});

// The document check on its own, against the browser's own parse of the URL.
const matches = (url, local) => runInContext(firstPartyCall(local), createContext({location: locationOf(url)}));

test('the built-in hosts are the apex and www, and the list is read', () => {
  assert.ok(origins.includes('https://mallow.art'));
  assert.ok(origins.includes('https://www.mallow.art'));
  for (const origin of origins) {
    for (const local of [false, true]) {
      assert.equal(matches(`${origin}/artwork/1?x=2#y`, local), true, origin);
      assert.equal(matches(`${origin}:443/`, local), true, origin);
      assert.equal(matches(`${origin}:8443/`, local), false, origin);
      assert.equal(matches(origin.replace('https:', 'http:'), local), false, origin);
      assert.equal(matches(origin.replace('https://', 'https://cdn.'), local), false, origin);
      assert.equal(matches(`${origin}.evil.example`, local), false, origin);
    }
  }
});

// Tailscale's MagicDNS domain, composed into the hosts below.
const magicDns = 'ts.net';

const localHosts = [
  'https://localhost/',
  'https://localhost:3000/',
  'https://LOCALHOST:8443/x',
  'https://app.localhost:5173/',
  'https://a.b.localhost/',
  'https://127.0.0.1/',
  'https://127.255.255.254:8443/',
  'https://10.0.0.1:5173/',
  'https://10.255.255.255/',
  'https://172.16.0.1/',
  'https://172.31.255.255:3000/',
  'https://192.168.1.20:5173/',
  'https://169.254.10.1/',
  'https://100.64.0.1/',
  'https://100.101.102.103:8443/',
  'https://100.127.255.255/',
  'https://[::1]/',
  'https://[::1]:5173/',
  'https://[0:0:0:0:0:0:0:1]/',
  'https://[fd7a:115c:a1e0::1]:8443/',
  'https://[fc00::1]/',
  'https://[fdff:ffff::1]/',
  'https://[fe80::1]/',
  'https://[febf:ffff::1]:3000/',
  'https://[fe80:0:0:0:1:2:3:4]/',
  `https://dev-box.tail1234.${magicDns}/`,
  `https://dev-box.tail1234.${magicDns}:8443/`,
  'https://macbook.local:5173/',
];

for (const url of localHosts) {
  test(`${url} is first-party in development builds only`, () => {
    assert.equal(matches(url, true), true);
    assert.equal(matches(url, false), false);
  });
}

for (const url of [
  // Next to a private range, but public.
  'https://100.63.255.255/',
  'https://100.128.0.1/',
  'https://172.15.255.255/',
  'https://172.32.0.1/',
  'https://11.0.0.1/',
  'https://9.255.255.255/',
  'https://192.169.0.1/',
  'https://169.253.0.1/',
  'https://128.0.0.1/',
  'https://8.8.8.8/',
  'https://10.0.0.1.evil.example/',
  // Look-alike names.
  'https://localhost.evil.com/',
  'https://localhost.evil.com:3000/',
  'https://evillocalhost/',
  'https://ts.net.evil.com/',
  'https://evilts.net/',
  'https://ts.net/',
  'https://local/',
  'https://evil.localx/',
  'https://box.local.evil.com/',
  // Public, unspecified or IPv4-mapped IPv6.
  'https://[2001:db8::1]/',
  'https://[::]/',
  'https://[::2]/',
  'https://[fec0::1]/',
  'https://[ff02::1]/',
  'https://[::ffff:127.0.0.1]/',
  'https://[::ffff:192.168.1.1]/',
  // Right host, wrong scheme.
  'http://localhost:3000/',
  'http://192.168.1.20/',
  'http://[::1]/',
  'ws://localhost/',
]) {
  test(`${url} is third-party even in development builds`, () => {
    assert.equal(matches(url, true), false);
  });
}

test('hosts are judged in the browser\'s canonical form', () => {
  // The page's own location is already parsed: 127.1 is loopback, and a
  // leading zero is octal, so 010.0.0.1 is the public 8.0.0.1.
  assert.equal(new URL('https://127.1/').hostname, '127.0.0.1');
  assert.equal(matches('https://127.1/', true), true);
  assert.equal(matches('https://0x7f.0.0.1/', true), true);
  assert.equal(new URL('https://010.0.0.1/').hostname, '8.0.0.1');
  assert.equal(matches('https://010.0.0.1/', true), false);
  // A non-canonical string can still never pass the shape checks.
  for (const hostname of ['[::ffff:127.0.0.1]', '[1::2::3]', '[fe80::1%en0]', '[:::1]', '[1:2:3:4:5:6:7:8:9]', '256.0.0.1', '1.2.3.4.5']) {
    const location = {protocol: 'https:', origin: `https://${hostname}`, hostname};
    assert.equal(runInContext(firstPartyCall(true), createContext({location})), false, hostname);
  }
});

test('the grant script rejects anything but a light or dark theme', () => {
  const {window} = fixture({theme: 'sepia'});
  assert.equal(window.mallow.ui, undefined);
});

for (const android of [false, true]) {
  test(`setOverlay sends a fire-and-forget ui envelope (${android ? 'Android' : 'iOS'})`, async () => {
    const {window, requests} = fixture({android});
    assert.equal(window.mallow.ui.setOverlay(true), undefined);
    window.mallow.ui.setOverlay(false);
    await settle();
    assert.equal(requests.length, 2);
    const [open, close] = requests;
    assert.equal(open.namespace, 'ui');
    assert.equal(open.method, 'setOverlay');
    assert.deepEqual({...open.params}, {active: true});
    assert.equal(open.documentToken, 'native-document-token');
    assert.equal(typeof open.id, 'string');
    assert.deepEqual({...close.params}, {active: false});
  });
}

test('setOverlay is outside the approval limit and survives a native cancel', async () => {
  const {window, requests} = fixture({android: true});
  // Eight approvals already fill the page's allowance.
  const approvals = Array.from({length: 8}, () => window.solana.connect().catch(() => {}));
  await settle();
  await assert.rejects(window.solana.connect(), {code: -32005});
  window.mallow.ui.setOverlay(true);
  window.__mallowDisconnect({preserveConnection: true});
  window.mallow.ui.setOverlay(false);
  await Promise.all(approvals);
  const ui = requests.filter(request => request.namespace === 'ui');
  assert.deepEqual(ui.map(request => request.params.active), [true, false]);
});

test('before the document token arrives only the latest state is sent', async () => {
  const {window, requests} = fixture({token: null});
  window.mallow.ui.setOverlay(true);
  window.mallow.ui.setOverlay(false);
  window.mallow.ui.setOverlay(true);
  await settle();
  assert.equal(requests.length, 0);
  window.__mallowDocumentToken = 'late-token';
  window.dispatchEvent(new Event('mallow:document-ready'));
  await settle();
  const ui = requests.filter(request => request.namespace === 'ui');
  assert.equal(ui.length, 1);
  assert.deepEqual({...ui[0].params}, {active: true});
  assert.equal(ui[0].documentToken, 'late-token');
});

test('the native theme hook updates the getter and dispatches mallow:theme on change only', () => {
  const {window} = fixture({theme: 'light'});
  const seen = [];
  window.addEventListener('mallow:theme', event => seen.push([event.detail.theme, window.mallow.ui.theme]));
  window.__mallowUiSetTheme('light');
  window.__mallowUiSetTheme('dark');
  window.__mallowUiSetTheme('dark');
  window.__mallowUiSetTheme('sepia');
  assert.deepEqual(seen, [['dark', 'dark']]);
  assert.equal(window.mallow.ui.theme, 'dark');
  // The page cannot replace the hook or the API (this module is strict).
  assert.throws(() => { window.__mallowUiSetTheme = () => {}; }, {name: 'TypeError'});
  assert.throws(() => { window.mallow.ui.version = 2; }, {name: 'TypeError'});
  assert.throws(() => Object.defineProperty(window.mallow, 'ui', {value: {}}), {name: 'TypeError'});
});

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const refused = {error: {code: 4100, message: 'Wallet request is not from the active HTTPS document'}};

for (const android of [false, true]) {
  test(`a refused release is sent once more, and nothing else is (${android ? 'Android' : 'iOS'})`, async () => {
    const {window, requests} = fixture({android, uiReply: () => refused});
    window.mallow.ui.setOverlay(true);
    window.mallow.ui.setOverlay(false);
    await wait(400);
    assert.deepEqual(requests.map(request => request.params.active), [true, false, false]);
    // The retry is not retried, and an accepted release never is.
    await wait(400);
    assert.equal(requests.length, 3);
  });
}

test('an accepted release is not sent again', async () => {
  const {window, requests} = fixture({android: true});
  window.mallow.ui.setOverlay(false);
  await wait(400);
  assert.equal(requests.length, 1);
});

test('a refused release is not retried once the page claims the chrome again', async () => {
  let refuse = true;
  const {window, requests} = fixture({uiReply: () => (refuse ? refused : {result: null})});
  window.mallow.ui.setOverlay(false);
  await settle();
  refuse = false;
  window.mallow.ui.setOverlay(true);
  await wait(400);
  assert.deepEqual(requests.map(request => request.params.active), [false, true]);
});

test('a bridge that throws counts as a refused release', async () => {
  const {window, requests} = fixture();
  let calls = 0;
  window.flutter_inappwebview.callHandler = (_, envelope) => {
    calls++;
    requests.push(envelope);
    throw new Error('bridge gone');
  };
  window.mallow.ui.setOverlay(false);
  await wait(400);
  assert.equal(calls, 2);
});

for (const android of [false, true]) {
  test(`pagehide releases a held overlay with the current token, then drops the token (${android ? 'Android' : 'iOS'})`, async () => {
    const {window, requests} = fixture({android});
    window.mallow.ui.setOverlay(true);
    window.dispatchEvent(new Event('pagehide'));
    await settle();
    assert.equal(window.__mallowDocumentToken, undefined);
    assert.deepEqual(requests.map(request => [request.params.active, request.documentToken]), [[true, 'native-document-token'], [false, 'native-document-token']]);
  });
}

test('a page restored from the back-forward cache queues until its new token', async () => {
  const {window, requests} = fixture();
  window.dispatchEvent(new Event('pagehide'));
  // Restored: the page reopens its sheet before native has issued a token.
  window.mallow.ui.setOverlay(true);
  await settle();
  assert.equal(requests.length, 0);
  window.__mallowDocumentToken = 'restored-token';
  window.dispatchEvent(new Event('mallow:document-ready'));
  await settle();
  const ui = requests.filter(request => request.namespace === 'ui');
  assert.deepEqual(ui.map(request => [request.params.active, request.documentToken]), [[true, 'restored-token']]);
});

test('a later document boots in the theme the wallet moved to', () => {
  const {window} = fixture({theme: 'light', startTheme: 'dark'});
  assert.equal(window.mallow.ui.theme, 'dark');
});

test('the start theme script touches nothing on another origin', () => {
  const {window} = fixture({origin: 'https://evil.example', startTheme: 'dark', local: true});
  assert.equal(window.mallow.ui, undefined);
  assert.equal(window.__mallowUiSetTheme, undefined);
});
