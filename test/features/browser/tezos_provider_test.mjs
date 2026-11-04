import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = readFileSync(new URL('../../../lib/features/browser/services/dapp_provider_script.dart', import.meta.url), 'utf8').split("r'''")[1].split("''';")[0];
const address = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
const plain = value => JSON.parse(JSON.stringify(value));
function fixture({onBeacon} = {}) {
  const requests = [], posted = [];
  const stored = new Map();
  const timers = new Map();
  let nextTimer = 0;
  const window = new EventTarget();
  window.top = window;
  window.__mallowDocumentToken = 'document';
  window.postMessage = (data, origin) => posted.push({data, origin});
  window.localStorage = {
    getItem: key => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value),
  };
  let granted = false;
  window.flutter_inappwebview = {callHandler: async (_, envelope) => {
    requests.push(envelope);
    if (envelope.namespace !== 'tezos') return {result: {accounts: []}};
    if (envelope.method === 'connect') {
      if (envelope.params.silent && !granted) return {result: {accounts: []}};
      granted = true;
      return {result: {accounts: [address], address, publicKey: 'edpk-test', network: {type: 'mainnet'}}};
    }
    if (envelope.method === 'disconnect') { granted = false; return {result: {}}; }
    if (envelope.method === 'signPayload') return {result: {signature: 'edsig-test'}};
    if (envelope.method === 'sendOperations') return {result: {hash: 'op-test'}};
    if (envelope.method === 'beacon' && onBeacon) return onBeacon(envelope);
    if (envelope.method === 'beacon') return {result: {message: envelope.params.encryptedPayload
      ? {target: 'toPage', encryptedPayload: 'response'}
      : {target: 'toPage', payload: 'pairing-response'}}};
    return {error: {code: 4200, message: 'Unsupported'}};
  }};
  const context = createContext({window, location: {protocol: 'https:', origin: 'https://site.example'}, Uint8Array, Date, Event, CustomEvent,
    setTimeout: callback => {const id = ++nextTimer; timers.set(id, callback); return id;},
    clearTimeout: id => timers.delete(id), atob, btoa, Math});
  runInContext(source, context);
  const message = (data, {origin = 'https://site.example', frame = window} = {}) => {
    const event = new Event('message');
    Object.defineProperties(event, {data: {value: data}, origin: {value: origin}, source: {value: frame}});
    window.dispatchEvent(event);
  };
  const stringify = (value, replacer, space) => {
    context.stringifyArgs = [value, replacer, space];
    return runInContext('JSON.stringify(...stringifyArgs)', context);
  };
  const select = (key = 'art.mallow.wallet') => {
    const encoded = stringify({key, type: 'mobile', icon: 'data:image/svg+xml;base64,test'});
    window.localStorage.setItem('beacon:last-selected-wallet', encoded);
  };
  const flush = async () => {
    for (const [id, callback] of [...timers]) { timers.delete(id); callback(); }
    await new Promise(resolve => setImmediate(resolve));
  };
  return {window, tezos: window.tezos, requests, posted, message, stringify, select, flush, stored};
}
const pairing = {id: 'sdk-pairing', type: 'postmessage-pairing-request', name: 'Test dapp', version: '3', publicKey: '511c34a1a2cb521df16bb246b8de8e7997ce235c7e76b22a3d7503a24819dd8a'};

test('Beacon picker selection replays its generated pairing through the native transport', async () => {
  const f = fixture();
  const encoded = f.stringify(pairing);
  await f.flush();
  assert.equal(f.requests.length, 0);
  f.select();
  await f.flush();
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].method, 'beacon');
  assert.equal(f.requests[0].namespace, 'tezos');
  assert.equal(f.requests[0].documentToken, 'document');
  assert.deepEqual(plain(f.requests[0].params), {pairingJson: encoded});
  assert.equal(f.posted[0].data.message.payload, 'pairing-response');
  assert.equal(f.posted[0].data.sender.id, 'art.mallow.wallet');
});
test('Beacon picker can select Mallow before its async pairing metadata is ready', async () => {
  const f = fixture();
  f.select();
  await f.flush();
  assert.equal(f.requests.length, 0);
  f.stringify(pairing);
  await f.flush();
  assert.equal(f.requests.length, 1);
});
test('Beacon compatibility ignores stale selections, other wallets and unpersisted metadata', async () => {
  const f = fixture();
  f.stringify(pairing);
  f.stringify({key: 'art.mallow.wallet', type: 'mobile'});
  await f.flush();
  assert.equal(f.requests.length, 0);
  f.select();
  f.select('another-wallet');
  await f.flush();
  assert.equal(f.requests.length, 0);
  f.select();
  f.stringify({...pairing, id: 'next-sdk-pairing'});
  await f.flush();
  assert.equal(f.requests.length, 0);
});
test('Beacon compatibility leaves regular pairing messages to the SDK', async () => {
  const f = fixture();
  f.stringify(pairing);
  f.select();
  f.message({target: 'toExtension', payload: 'sdk-serialized-pairing', targetId: 'art.mallow.wallet'});
  await f.flush();
  assert.equal(f.requests.length, 1);
  assert.deepEqual(plain(f.requests[0].params), {payload: 'sdk-serialized-pairing'});
});
test('Beacon compatibility drops pending selection on native cancellation and page departure', async () => {
  for (const cancel of [f => f.window.__mallowDisconnect(), f => f.window.dispatchEvent(new Event('pagehide'))]) {
    const f = fixture();
    f.stringify(pairing);
    f.select();
    cancel(f);
    await f.flush();
    assert.equal(f.requests.length, 0);
  }
});
test('Beacon compatibility suppresses a late pairing response after selecting another wallet', async () => {
  let reply;
  const f = fixture({onBeacon: () => new Promise(resolve => {reply = resolve;})});
  f.stringify(pairing);
  f.select();
  await f.flush();
  assert.equal(f.requests.length, 1);
  f.select('another-wallet');
  reply({result: {message: {target: 'toPage', payload: 'late-pairing'}}});
  await f.flush();
  assert.equal(f.posted.length, 0);
  assert.equal(JSON.parse(f.stored.get('beacon:last-selected-wallet')).key, 'another-wallet');
});
test('Beacon compatibility suppresses a late pairing response after page departure', async () => {
  let reply;
  const f = fixture({onBeacon: () => new Promise(resolve => {reply = resolve;})});
  f.stringify(pairing);
  f.select();
  await f.flush();
  f.window.dispatchEvent(new Event('pagehide'));
  reply({result: {message: {target: 'toPage', payload: 'late-pairing'}}});
  await f.flush();
  assert.equal(f.posted.length, 0);
  assert.equal(JSON.parse(f.stored.get('beacon:last-selected-wallet')).type, 'mobile');
});
test('Beacon compatibility allows an explicit retry after a failed native pairing', async () => {
  let attempts = 0;
  const f = fixture({onBeacon: async () => ++attempts === 1
    ? {error: {code: 4001, message: 'Request cancelled'}}
    : {result: {message: {target: 'toPage', payload: 'pairing-response'}}}});
  f.stringify(pairing);
  f.select();
  await f.flush();
  assert.equal(f.posted.length, 0);
  f.select();
  await f.flush();
  assert.equal(f.requests.length, 2);
  assert.equal(f.posted.length, 1);
  assert.equal(JSON.parse(f.stored.get('beacon:last-selected-wallet')).type, 'extension');
});
test('Beacon observer preserves JSON outputs, replacers, toJSON calls and exceptions', async () => {
  const f = fixture();
  let calls = 0;
  const value = {toJSON: () => {calls++; return pairing;}};
  assert.equal(f.stringify(value), JSON.stringify(pairing));
  assert.equal(calls, 1);
  assert.equal(f.stringify({a: 1, b: 2}, ['a'], 2), '{\n  "a": 1\n}');
  const cyclic = {}; cyclic.self = cyclic;
  assert.throws(() => f.stringify(cyclic), /circular/i);
  assert.equal(f.stringify(undefined), undefined);
  await f.flush();
  assert.equal(f.requests.length, 0);
});
test('injects a discoverable Tezos provider and answers Beacon ping without signing', () => {
  const f = fixture();
  assert.equal(f.window.mallow.tezos, f.tezos);
  assert.equal(f.tezos.isMallow, true);
  f.window.tezos = {};
  assert.equal(f.window.tezos, f.tezos);
  f.message({target: 'toExtension', payload: 'ping'});
  assert.equal(f.posted[0].data.payload, 'pong');
  assert.equal(f.posted[0].data.sender.id, 'art.mallow.wallet');
  assert.match(f.posted[0].data.sender.iconUrl, /^data:image\/svg\+xml;base64,/);
  assert.match(Buffer.from(f.posted[0].data.sender.iconUrl.split(',')[1], 'base64').toString(), /<svg/);
  assert.equal(f.requests.length, 0);
});
test('Beacon accepts only the current origin main window and its target id', () => {
  const f = fixture();
  f.message({target: 'toExtension', payload: 'ping'}, {origin: 'https://other.example'});
  f.message({target: 'toExtension', payload: 'ping'}, {frame: {}});
  f.message({target: 'toExtension', payload: 'ping', targetId: 'another-wallet'});
  assert.equal(f.posted.length, 0);
});
test('Beacon encrypted requests use the native document-bound transport', async () => {
  const f = fixture();
  f.message({target: 'toExtension', encryptedPayload: 'cipher', targetId: 'art.mallow.wallet'});
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(plain(f.requests[0]), {id: f.requests[0].id, method: 'beacon', namespace: 'tezos', params: {encryptedPayload: 'cipher'}, documentToken: 'document'});
  assert.equal(f.posted[0].data.message.encryptedPayload, 'response');
  assert.equal(f.posted[0].data.sender.id, 'art.mallow.wallet');
});
test('Tezos signatures and operations require connection and pin its address', async () => {
  const {tezos, requests} = fixture();
  await assert.rejects(tezos.requestSignPayload({payload: '050100000000'}), e => e.code === 4100);
  await tezos.requestPermissions({network: {type: 'mainnet'}});
  assert.equal(tezos.address, address);
  assert.deepEqual(plain(await tezos.requestSignPayload({payload: '050100000000', signingType: 'micheline'})), {signature: 'edsig-test'});
  assert.equal(requests.at(-1).params.sourceAddress, address);
  assert.deepEqual(plain(await tezos.requestOperation({operationDetails: [{kind: 'transaction'}]})), {transactionHash: 'op-test'});
  assert.equal(requests.at(-1).params.sourceAddress, address);
  await tezos.disconnect();
  assert.equal(tezos.address, null);
});
test('temporary native UI preserves Tezos while revocation clears only its namespace', async () => {
  const {window, tezos} = fixture();
  await tezos.connect();
  window.__mallowDisconnect({preserveConnection: true});
  assert.equal(tezos.address, address);
  window.__mallowDisconnect({preserveNamespaces: ['tezos']});
  assert.equal(tezos.address, address);
  window.__mallowDisconnect({preserveNamespaces: ['solana', 'eip155']});
  assert.equal(tezos.address, null);
});
