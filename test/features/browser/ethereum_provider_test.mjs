import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';

// Run with: node --test test/features/browser/ethereum_provider_test.mjs
const source = readFileSync(new URL('../../../lib/features/browser/services/dapp_provider_script.dart', import.meta.url), 'utf8').split("r'''")[1].split("''';")[0];
const account = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
// Values built inside the vm context have that realm's prototypes.
const plain = value => value === undefined ? value : JSON.parse(JSON.stringify(value));

function fixture({responder, solanaResponder, granted = false} = {}) {
  const requests = [];
  const announced = [];
  const window = new EventTarget();
  const stored = new Map();
  window.localStorage = {getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value)};
  window.top = window;
  window.__mallowDocumentToken = 'native-document-token';
  window.__mallowSupportedChains = ['solana:mainnet'];
  window.addEventListener('eip6963:announceProvider', event => announced.push(event.detail));
  let isGranted = granted;
  window.flutter_inappwebview = {callHandler: async (_, envelope) => {
    requests.push(envelope);
    if (envelope.namespace !== 'eip155') return {result: solanaResponder ? await solanaResponder(envelope) : {}};
    if (responder) {
      try { return {result: await responder(envelope)}; } catch (error) { return {error: {code: error.code, message: error.message, data: error.data}}; }
    }
    if (envelope.method === 'connect') {
      if (envelope.params.silent && !isGranted) return {result: {accounts: []}};
      isGranted = true;
      return {result: {accounts: [account], chainId: '0x1'}};
    }
    if (envelope.method === 'disconnect') { isGranted = false; return {result: {}}; }
    if (envelope.method === 'personal_sign' || envelope.method === 'eth_signTypedData_v4') return {result: {signature: '0x' + '11'.repeat(65)}};
    if (envelope.method === 'eth_sendTransaction') return {result: {hash: '0x' + '22'.repeat(32)}};
    if (envelope.method === 'read') return {result: '0x10'};
    return {error: {code: -32601, message: 'Unsupported method'}};
  }};
  runInContext(source, createContext({window, location: {protocol: 'https:'}, Uint8Array, Date, Event, CustomEvent, setTimeout, clearTimeout, atob, btoa, Math}));
  return {window, requests, announced, eth: window.ethereum};
}

test('injects an EIP-1193 provider and announces it through EIP-6963', () => {
  const {eth, announced, window} = fixture();
  assert.equal(eth.isMallow, true);
  assert.equal(eth.isMetaMask, undefined);
  assert.equal(eth.chainId, '0x1');
  assert.equal(eth.selectedAddress, null);
  assert.equal(announced.length, 1);
  assert.equal(announced[0].info.name, 'mallow');
  assert.equal(announced[0].info.rdns, 'art.mallow.wallet');
  assert.match(announced[0].info.uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(announced[0].provider, eth);
  window.dispatchEvent(new Event('eip6963:requestProvider'));
  assert.equal(announced.length, 2);
  assert.equal(window.mallow.ethereum, eth);
});

test('a page cannot replace the provider, and the assignment does not throw', () => {
  const {window, eth} = fixture();
  window.ethereum = {isMetaMask: true};
  assert.equal(window.ethereum, eth);
});

test('a page can extend a provider but not replace its members, and neither write throws', () => {
  // Strict-mode writes, as Uniswap's bundle makes to `window.ethereum`.
  const {window, eth} = fixture();
  for (const [target, member] of [[eth, 'request'], [window.solana, 'connect'], [window.tezos, 'connect']]) {
    const original = target[member];
    assert.equal(typeof original, 'function');
    target.autoRefreshOnNetworkChange = false;
    assert.equal(target.autoRefreshOnNetworkChange, false);
    target[member] = () => 'replaced';
    target.isMallow = false;
    assert.equal(target[member], original);
    assert.equal(target.isMallow, true);
  }
  eth.selectedAddress = account;
  assert.equal(eth.selectedAddress, null);
});

test('chain id and network are answered without the native bridge', async () => {
  const {eth, requests} = fixture();
  assert.equal(await eth.request({method: 'eth_chainId'}), '0x1');
  assert.equal(await eth.request({method: 'net_version'}), '1');
  assert.equal(requests.length, 0);
});

test('eth_accounts is silent and empty until the site is approved', async () => {
  const {eth, requests} = fixture();
  assert.deepEqual(plain(await eth.request({method: 'eth_accounts'})), []);
  assert.deepEqual(plain(requests[0]), {id: requests[0].id, method: 'connect', params: {silent: true}, documentToken: 'native-document-token', namespace: 'eip155'});
});

test('eth_requestAccounts connects and emits accountsChanged once', async () => {
  const {eth, requests} = fixture();
  const changes = [];
  eth.on('accountsChanged', value => changes.push(value));
  assert.deepEqual(plain(await eth.request({method: 'eth_requestAccounts'})), [account]);
  const before = requests.length;
  assert.deepEqual(plain(await eth.request({method: 'eth_accounts'})), [account]);
  assert.equal(requests.length, before, 'a connected eth_accounts is answered locally');
  assert.equal(eth.selectedAddress, account);
  assert.deepEqual(plain(changes), [[account]]);
});

test('wallet permissions follow the eth_accounts grant', async () => {
  const {eth, requests} = fixture();
  assert.deepEqual(plain(await eth.request({method: 'wallet_getPermissions'})), []);
  const granted = await eth.request({method: 'wallet_requestPermissions', params: [{eth_accounts: {}}]});
  assert.equal(granted[0].parentCapability, 'eth_accounts');
  await assert.rejects(eth.request({method: 'wallet_requestPermissions', params: [{eth_accounts: {}, snap_dialog: {}}]}), error => error.code === -32602);
  const changes = [];
  eth.on('accountsChanged', value => changes.push(value));
  assert.equal(await eth.request({method: 'wallet_revokePermissions', params: [{eth_accounts: {}}]}), null);
  assert.equal(requests.at(-1).method, 'disconnect');
  assert.deepEqual(plain(changes), [[]]);
});

test('Ethereum revocation preserves the Solana account and emits no Solana disconnect', async () => {
  const solanaAddress = '11111111111111111111111111111111';
  let env;
  env = fixture({
    solanaResponder: async () => ({publicKey: solanaAddress, chains: ['solana:mainnet'], canSignMessages: true}),
    responder: async envelope => {
      if (envelope.method === 'connect') return {accounts: envelope.params.silent ? [] : [account]};
      env.window.__mallowDisconnect({preserveNamespaces: ['solana']});
      env.window.__mallowRestore();
      return {};
    },
  });
  await env.window.solana.connect();
  await env.eth.request({method: 'eth_requestAccounts'});
  const publicKey = env.window.solana.publicKey.toBase58();
  const solanaEvents = [];
  env.window.solana.on('disconnect', () => solanaEvents.push('disconnect'));
  env.window.solana.on('accountChanged', key => solanaEvents.push(key?.toBase58()));
  env.window.solana.on('connect', () => solanaEvents.push('connect'));
  let wallet;
  env.window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', {detail: {register: value => {wallet = value;}}}));
  const standardAccount = wallet.accounts[0];
  wallet.features['standard:events'].on('change', value => solanaEvents.push(value));
  const ethEvents = [];
  env.eth.on('accountsChanged', value => ethEvents.push(value));
  await env.eth.request({method: 'wallet_revokePermissions', params: [{eth_accounts: {}}]});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(env.eth.selectedAddress, null);
  assert.equal(env.window.solana.publicKey.toBase58(), publicKey);
  assert.equal(wallet.accounts[0], standardAccount);
  assert.deepEqual(solanaEvents, []);
  assert.deepEqual(plain(ethEvents), [[]]);
});

test('an ungranted Solana silent connect leaves Ethereum connected', async () => {
  const {window, eth} = fixture({solanaResponder: async envelope => envelope.params.silent
    ? {accounts: []}
    : {publicKey: '11111111111111111111111111111111', chains: ['solana:mainnet'], canSignMessages: true},
  });
  await window.solana.connect();
  await eth.request({method: 'eth_requestAccounts'});
  const changes = [];
  eth.on('accountsChanged', value => changes.push(value));
  let wallet;
  window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', {detail: {register: value => {wallet = value;}}}));
  assert.equal((await wallet.features['standard:connect'].connect({silent: true})).accounts.length, 0);
  assert.equal(wallet.accounts.length, 0);
  assert.equal(eth.selectedAddress, account);
  assert.deepEqual(changes, []);
});

test('only mainnet can be switched to', async () => {
  const {eth} = fixture();
  assert.equal(await eth.request({method: 'wallet_switchEthereumChain', params: [{chainId: '0x1'}]}), null);
  await assert.rejects(eth.request({method: 'wallet_switchEthereumChain', params: [{chainId: '0x89'}]}), error => error.code === 4902);
  await assert.rejects(eth.request({method: 'wallet_addEthereumChain', params: [{chainId: '0x89'}]}), error => error.code === 4200);
});

test('signing needs a connected account and the account named must be it', async () => {
  const {eth} = fixture();
  await assert.rejects(eth.request({method: 'personal_sign', params: ['0x68656c6c6f', account]}), error => error.code === 4100);
  await eth.request({method: 'eth_requestAccounts'});
  await assert.rejects(eth.request({method: 'personal_sign', params: ['0x68656c6c6f', '0x' + '00'.repeat(20)]}), error => error.code === 4100);
  await assert.rejects(eth.request({method: 'eth_sendTransaction', params: [{from: '0x' + '00'.repeat(20), to: account}]}), error => error.code === 4100);
});

test('personal_sign accepts both parameter orders and sends the message natively', async () => {
  const {eth, requests} = fixture();
  await eth.request({method: 'eth_requestAccounts'});
  assert.equal(await eth.request({method: 'personal_sign', params: ['0x68656c6c6f', account]}), '0x' + '11'.repeat(65));
  assert.deepEqual(plain(requests.at(-1).params), {message: '0x68656c6c6f', address: account});
  await eth.request({method: 'personal_sign', params: [account.toLowerCase(), '0x68656c6c6f']});
  assert.deepEqual(plain(requests.at(-1).params), {message: '0x68656c6c6f', address: account});
});

test('typed data and transactions reach the bridge in the eip155 namespace', async () => {
  const {eth, requests} = fixture();
  await eth.request({method: 'eth_requestAccounts'});
  const typed = JSON.stringify({types: {}, primaryType: 'EIP712Domain', domain: {}, message: {}});
  await eth.request({method: 'eth_signTypedData_v4', params: [account, typed]});
  assert.deepEqual(plain(requests.at(-1).params), {address: account, typedData: typed});
  const tx = {from: account, to: account, value: '0x1'};
  assert.equal(await eth.request({method: 'eth_sendTransaction', params: [tx]}), '0x' + '22'.repeat(32));
  assert.equal(requests.at(-1).namespace, 'eip155');
  assert.deepEqual(plain(requests.at(-1).params), {transaction: tx});
});

test('eth_sign and legacy typed-data versions are refused without reaching the bridge', async () => {
  const {eth, requests} = fixture();
  await eth.request({method: 'eth_requestAccounts'});
  const before = requests.length;
  for (const method of ['eth_sign', 'eth_signTypedData', 'eth_signTypedData_v3', 'eth_signTransaction', 'wallet_sendCalls']) {
    await assert.rejects(eth.request({method, params: [account, '0x00']}), error => error.code === 4200);
  }
  assert.equal(requests.length, before);
});

test('allowlisted reads go through the bridge and keep revert data', async () => {
  const revert = '0x08c379a0';
  const {eth, requests} = fixture({responder: async envelope => {
    if (envelope.method === 'read' && envelope.params.method === 'eth_call') throw Object.assign(new Error('execution reverted'), {code: 3, data: revert});
    if (envelope.method === 'read') return '0x10';
    return {accounts: []};
  }});
  assert.equal(await eth.request({method: 'eth_blockNumber'}), '0x10');
  assert.deepEqual(plain(requests.at(-1).params), {method: 'eth_blockNumber', params: []});
  await assert.rejects(eth.request({method: 'eth_call', params: [{to: account, data: '0x'}, 'latest']}), error => error.code === 3 && error.data === revert);
});

test('legacy sendAsync, send and enable map onto request', async () => {
  const {eth} = fixture();
  assert.deepEqual(plain(await eth.enable()), [account]);
  const viaSend = await eth.send('eth_chainId');
  assert.equal(viaSend, '0x1');
  assert.deepEqual(plain(eth.send({id: 7, method: 'eth_accounts'})), {id: 7, jsonrpc: '2.0', result: [account]});
  assert.throws(() => eth.send({id: 8, method: 'eth_blockNumber'}), error => error.code === 4200);
  const response = await new Promise(resolve => eth.sendAsync({id: 9, method: 'eth_chainId'}, (error, value) => resolve({error, value})));
  assert.equal(response.error, null);
  assert.deepEqual(plain(response.value), {id: 9, jsonrpc: '2.0', result: '0x1'});
});

test('disconnect from native clears the Ethereum account; a temporary cancel keeps it', async () => {
  const {window, eth} = fixture();
  await eth.request({method: 'eth_requestAccounts'});
  const changes = [];
  eth.on('accountsChanged', value => changes.push(value));
  window.__mallowDisconnect({preserveConnection: true});
  assert.equal(eth.selectedAddress, account);
  window.__mallowDisconnect({preserveConnection: false});
  assert.equal(eth.selectedAddress, null);
  assert.deepEqual(plain(changes), [[]]);
});

test('document readiness emits connect and silently restores an approved site', async () => {
  const {window, eth} = fixture({granted: true});
  const events = [];
  eth.on('connect', value => events.push(['connect', value]));
  eth.on('accountsChanged', value => events.push(['accountsChanged', value]));
  const restored = new Promise(resolve => eth.once('accountsChanged', resolve));
  window.dispatchEvent(new Event('mallow:document-ready'));
  await restored;
  assert.deepEqual(plain(events), [['connect', {chainId: '0x1'}], ['accountsChanged', [account]]]);
});

test('an empty silent restore preserves an explicitly approved Ethereum account', async () => {
  const {window, eth, requests} = fixture({responder: async envelope => ({
    accounts: envelope.params.silent ? [] : [account],
  })});
  await eth.request({method: 'eth_requestAccounts'});
  const changes = [];
  eth.on('accountsChanged', value => changes.push(value));
  window.__mallowDisconnect({preserveConnection: true});
  window.__mallowRestore();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(plain(requests.at(-1).params), {silent: true});
  assert.equal(requests.at(-1).namespace, 'eip155');
  assert.equal(eth.selectedAddress, account);
  assert.deepEqual(plain(await eth.request({method: 'eth_accounts'})), [account]);
  assert.deepEqual(plain(changes), []);
});

test('listeners can be removed', async () => {
  const {eth} = fixture();
  const changes = [];
  const listener = value => changes.push(value);
  eth.on('accountsChanged', listener);
  eth.removeListener('accountsChanged', listener);
  await eth.request({method: 'eth_requestAccounts'});
  assert.deepEqual(plain(changes), []);
});
