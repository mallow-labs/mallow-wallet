import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = readFileSync(new URL('../../../lib/features/browser/services/dapp_provider_script.dart', import.meta.url), 'utf8').split("r'''")[1].split("''';")[0];
const address = '11111111111111111111111111111111';
const signature = Buffer.alloc(64, 1).toString('base64');
function fixture({android = false, responder, mainFrame = true, protocol = 'https:'} = {}) {
  const requests = [];
  const window = new EventTarget();
  const stored = new Map();
  window.localStorage = {getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value)};
  window.top = mainFrame ? window : {};
  window.__mallowDocumentToken = 'native-document-token';
  window.__mallowSupportedChains = ['solana:mainnet', 'solana:devnet'];
  let wallet;
  window.addEventListener('wallet-standard:register-wallet', event => event.detail({register: value => {wallet = value;}}));
  const response = async envelope => {
    requests.push(envelope);
    const result = responder ? await responder(envelope) : envelope.method === 'connect' ? {publicKey: address, chains: ['solana:mainnet', 'solana:devnet'], canSign: true, canSignMessages: true} : envelope.method === 'signMessage' ? {signature, publicKey: address} : envelope.method === 'signAllTransactions' ? {transactions: envelope.params.transactions} : envelope.method === 'signTransaction' ? {transaction: envelope.params.transaction} : envelope.method === 'signAndSendTransaction' ? {signature: '1'.repeat(64)} : {};
    return {result};
  };
  if (android) {
    window.mallowNative = {postMessage: value => {
      const envelope = JSON.parse(value);
      response(envelope).then(
        value => window.mallowNative.onmessage({data: JSON.stringify({id: envelope.id, ...value})}),
        error => window.mallowNative.onmessage({data: JSON.stringify({id: envelope.id, error: {code: error.code, message: error.message}})}),
      );
    }};
  } else {
    window.flutter_inappwebview = {callHandler: (name, envelope) => {assert.equal(name, 'mallowWallet'); return response(envelope);}};
  }
  runInContext(source, createContext({window, location: {protocol}, Uint8Array, Date, Event, CustomEvent, setTimeout, clearTimeout, atob, btoa}));
  return {window, requests, get wallet() {return wallet;}};
}

test('registers mallow with empty accounts and never identifies as another wallet', () => {
  const {window, wallet, requests} = fixture();
  assert.equal(wallet.name, 'mallow');
  assert.equal(wallet.accounts.length, 0);
  assert.deepEqual([...wallet.chains], ['solana:mainnet', 'solana:devnet']);
  assert.equal(window.solana.publicKey, null);
  assert.equal(window.solana.isMallow, true);
  assert.equal(window.solana.isPhantom, undefined);
  assert.equal(requests.length, 0);
});

test('connect uses native token and account events, disconnect clears account', async () => {
  const {window, wallet, requests} = fixture();
  const changes = [];
  wallet.features['standard:events'].on('change', value => changes.push(value));
  const connected = await wallet.features['standard:connect'].connect();
  assert.equal(connected.accounts[0].address, address);
  assert.equal(connected.accounts[0].publicKey.length, 32);
  assert.equal(requests[0].documentToken, 'native-document-token');
  assert.equal(window.solana.publicKey.toBase58(), address);
  await window.solana.disconnect();
  assert.equal(wallet.accounts.length, 0);
  assert.equal(changes.at(-1).accounts.length, 0);
});

test('transaction-only account omits message signing without hiding transaction features', async () => {
  const {wallet} = fixture({responder: async () => ({
    publicKey: address,
    chains: ['solana:mainnet'],
    canSign: true,
    canSignMessages: false,
  })});
  await wallet.features['standard:connect'].connect();
  assert.deepEqual(
    [...wallet.accounts[0].features],
    ['solana:signTransaction', 'solana:signAndSendTransaction'],
  );
});

test('standard silent connect returns empty accounts only for the native ungranted sentinel', async () => {
  let granted = false;
  const {window, wallet} = fixture({responder: async request => {
    if (request.params.silent && !granted) return {accounts: []};
    if (request.params.onlyIfTrusted && !granted) {
      throw Object.assign(new Error('Connection approval required'), {code: 4100});
    }
    granted = true;
    return {publicKey: address, chains: ['solana:mainnet'], canSign: true, canSignMessages: true};
  }});

  assert.equal((await wallet.features['standard:connect'].connect({silent: true})).accounts.length, 0);
  assert.equal(wallet.accounts.length, 0);
  await assert.rejects(window.solana.connect({onlyIfTrusted: true}), error => error.code === 4100);
  await window.solana.connect();
  granted = false;
  assert.equal((await wallet.features['standard:connect'].connect({silent: true})).accounts.length, 0);
  assert.equal(wallet.accounts.length, 0);
});

test('standard silent connect propagates unrelated native errors including other 4100 failures', async () => {
  const {wallet} = fixture({responder: async () => {
    throw Object.assign(new Error('Stale document'), {code: 4100});
  }});
  await assert.rejects(
    wallet.features['standard:connect'].connect({silent: true}),
    error => error.code === 4100 && error.message === 'Stale document',
  );
});

test('legacy listeners receive the newly approved account after a native wallet switch', async () => {
  let current = address;
  const {window} = fixture({responder: async () => ({publicKey: current, chains: ['solana:mainnet'], canSign: true})});
  const accounts = [];
  window.solana.on('accountChanged', key => accounts.push(key?.toBase58() ?? null));
  await window.solana.connect();
  window.__mallowDisconnect();
  current = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
  await window.solana.connect({onlyIfTrusted: true});
  assert.deepEqual(accounts, [address, null, current]);
});

test('standard sign transaction batches preserve exact bytes and requested devnet', async () => {
  const {wallet, requests} = fixture();
  await wallet.features['standard:connect'].connect();
  const account = wallet.accounts[0];
  const result = await wallet.features['solana:signTransaction'].signTransaction({transaction: new Uint8Array([1,2,3]), account, chain: 'solana:devnet'}, {transaction: new Uint8Array([9,8,7]), account, chain: 'solana:devnet'});
  assert.deepEqual([...result[0].signedTransaction], [1,2,3]);
  assert.deepEqual([...result[1].signedTransaction], [9,8,7]);
  assert.equal(requests[1].method, 'signAllTransactions');
  assert.equal(requests[1].params.chain, 'solana:devnet');
  assert.equal(requests[1].params.account, address);
});

test('standard message result is immutable snapshot even when caller mutates input during approval', async () => {
  let release;
  const gate = new Promise(resolve => {release = resolve;});
  const {wallet} = fixture({responder: async request => {
    if (request.method === 'connect') return {publicKey: address, chains: ['solana:mainnet'], canSign: true};
    await gate;
    return {signature};
  }});
  await wallet.features['standard:connect'].connect();
  const message = new Uint8Array([1,2,3]);
  const result = wallet.features['solana:signMessage'].signMessage({message, account: wallet.accounts[0]});
  message[0] = 9;
  release();
  assert.deepEqual([...(await result)[0].signedMessage], [1,2,3]);
});

test('legacy transaction objects deserialize native signed bytes', async () => {
  class Transaction {
    serialize(options) {assert.equal(options.requireAllSignatures, false); return new Uint8Array([1,2,3]);}
    static from(bytes) {return {signed: [...bytes]};}
  }
  const {window} = fixture();
  await window.solana.connect();
  assert.deepEqual(await window.solana.signTransaction(new Transaction()), {signed: [1,2,3]});
  const message = await window.solana.signMessage(new Uint8Array([0,255]));
  assert.equal(message.signature.length, 64);
});

test('Android native web message transport correlates IDs and returns standard byte signatures', async () => {
  const {wallet, requests} = fixture({android: true});
  await wallet.features['standard:connect'].connect();
  const results = await wallet.features['solana:signAndSendTransaction'].signAndSendTransaction({transaction: new Uint8Array([1]), account: wallet.accounts[0], chain: 'solana:mainnet'});
  assert.equal(results[0].signature.length, 64);
  assert.notEqual(requests[0].id, requests[1].id);
});

test('Android serialization failures do not reserve pending request slots', async () => {
  const {window} = fixture({android: true});
  const cyclic = {};
  cyclic.self = cyclic;
  for (let index = 0; index < 8; index++) {
    await assert.rejects(window.solana.connect(cyclic), error => error.name === 'TypeError');
  }
  assert.equal((await window.solana.connect()).publicKey.toBase58(), address);
});

test('Android synchronous postMessage failures release pending request slots', async () => {
  const {window} = fixture({android: true});
  const postMessage = window.mallowNative.postMessage;
  window.mallowNative.postMessage = () => { throw new Error('transport unavailable'); };
  for (let index = 0; index < 8; index++) {
    await assert.rejects(window.solana.connect(), /transport unavailable/);
  }
  window.mallowNative.postMessage = postMessage;
  assert.equal((await window.solana.connect()).publicKey.toBase58(), address);
});

test('Android disconnect succeeds when native revocation clears provider accounts before its reply', async () => {
  let env;
  env = fixture({android: true, responder: async request => {
    if (request.method === 'connect') return {publicKey: address, chains: ['solana:mainnet'], canSign: true};
    env.window.__mallowDisconnect();
    return {};
  }});
  await env.window.solana.connect();
  await env.window.solana.disconnect();
  assert.equal(env.wallet.accounts.length, 0);
});

test('provider never installs in HTTP or child frames', () => {
  assert.equal(fixture({mainFrame: false}).window.solana, undefined);
  assert.equal(fixture({protocol: 'http:'}).window.solana, undefined);
});

test('native lifecycle invalidation clears visible account without revoking remembered grant', async () => {
  const {window, wallet, requests} = fixture();
  await window.solana.connect();
  window.__mallowDisconnect();
  assert.equal(window.solana.publicKey, null);
  assert.equal(wallet.accounts.length, 0);
  assert.equal(requests.filter(request => request.method === 'disconnect').length, 0);
});

for (const android of [false, true]) {
  test(`${android ? 'Android' : 'iOS'} Solana disconnect preserves Ethereum and its in-flight restore`, async () => {
    const ethAddress = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
    let env;
    let solanaGranted = true;
    let releaseRestore;
    const restoreGate = new Promise(resolve => {releaseRestore = resolve;});
    env = fixture({android, responder: async request => {
      if (request.namespace === 'eip155') {
        if (request.params.silent) await restoreGate;
        return {accounts: [ethAddress]};
      }
      if (request.method === 'connect') {
        if (!solanaGranted) throw Object.assign(new Error('Connection approval required'), {code: 4100});
        return {publicKey: address, chains: ['solana:mainnet'], canSign: true};
      }
      solanaGranted = false;
      env.window.__mallowDisconnect({preserveNamespaces: ['eip155']});
      env.window.__mallowRestore();
      return {};
    }});
    await env.window.solana.connect();
    await env.window.ethereum.request({method: 'eth_requestAccounts'});
    const ethEvents = [];
    env.window.ethereum.on('accountsChanged', value => ethEvents.push(value));
    const solanaEvents = [];
    env.wallet.features['standard:events'].on('change', value => solanaEvents.push(value.accounts.length));
    await env.window.solana.disconnect();
    assert.equal(env.window.ethereum.selectedAddress, ethAddress);
    releaseRestore();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(env.wallet.accounts.length, 0);
    assert.equal(env.window.ethereum.selectedAddress, ethAddress);
    assert.deepEqual(solanaEvents, [0]);
    assert.deepEqual(ethEvents, []);
  });

  test(`${android ? 'Android' : 'iOS'} Solana disconnect reply does not cancel an Ethereum connection`, async () => {
    const ethAddress = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
    let release;
    const gate = new Promise(resolve => {release = resolve;});
    const {window} = fixture({android, responder: async request => {
      if (request.namespace === 'eip155') {
        await gate;
        return {accounts: [ethAddress]};
      }
      if (request.method === 'connect') return {publicKey: address, chains: ['solana:mainnet'], canSign: true};
      return {};
    }});
    await window.solana.connect();
    const connecting = window.ethereum.request({method: 'eth_accounts'});
    const result = connecting.then(value => value, error => error);
    await window.solana.disconnect();
    release();
    assert.deepEqual([...(await result)], [ethAddress]);
  });

  for (const preserveNamespaces of [[], ['solana'], ['eip155']]) {
    test(`${android ? 'Android' : 'iOS'} scoped revocation ${JSON.stringify(preserveNamespaces)} cancels both chains' pending work`, async () => {
      const ethAddress = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
      let release;
      const gate = new Promise(resolve => {release = resolve;});
      const {window, wallet} = fixture({android, responder: async request => {
        if (request.method === 'connect') return request.namespace === 'eip155'
          ? {accounts: [ethAddress]}
          : {publicKey: address, chains: ['solana:mainnet'], canSign: true};
        await gate;
        return {signature};
      }});
      await window.solana.connect();
      await window.ethereum.request({method: 'eth_requestAccounts'});
      const solana = window.solana.signMessage(new Uint8Array([1]));
      const ethereum = window.ethereum.request({method: 'personal_sign', params: ['0x01', ethAddress]});
      const cancelled = Promise.all([solana, ethereum].map(work => assert.rejects(work, error => error.code === 4001)));
      window.__mallowDisconnect({preserveNamespaces});
      release();
      await cancelled;
      assert.equal(wallet.accounts.length, preserveNamespaces.includes('solana') ? 1 : 0);
      assert.equal(window.ethereum.selectedAddress, preserveNamespaces.includes('eip155') ? ethAddress : null);
    });
  }

  test(`${android ? 'Android' : 'iOS'} temporary suspension cancels requests without disconnecting the site`, async () => {
    let release;
    const gate = new Promise(resolve => {release = resolve;});
    const {window, wallet, requests} = fixture({android, responder: async request => {
      if (request.method === 'connect') return request.namespace === 'eip155'
        ? {accounts: ['0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826']}
        : {publicKey: address, chains: ['solana:mainnet'], canSign: true};
      await gate;
      return {signature};
    }});
    await window.solana.connect();
    await window.ethereum.request({method: 'eth_requestAccounts'});
    const account = wallet.accounts[0];
    const changes = [];
    wallet.features['standard:events'].on('change', value => changes.push(value));
    window.ethereum.on('accountsChanged', value => changes.push(value));
    const signing = window.solana.signMessage(new Uint8Array([1]));
    const ethSigning = window.ethereum.request({method: 'personal_sign', params: ['0x01', window.ethereum.selectedAddress]});
    const cancelled = Promise.all([signing, ethSigning].map(work => assert.rejects(work, error => error.code === 4001)));
    window.__mallowDisconnect({preserveConnection: true});
    release();
    await cancelled;
    assert.equal(wallet.accounts[0], account);
    assert.equal(window.solana.isConnected, true);
    assert.equal(window.ethereum.selectedAddress, '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826');
    assert.equal(changes.length, 0);
    assert.equal(requests.filter(request => request.method === 'disconnect').length, 0);
  });

  test(`${android ? 'Android' : 'iOS'} cancelled connection cannot restore an account from a late response`, async () => {
    let release;
    const gate = new Promise(resolve => {release = resolve;});
    const {window, wallet} = fixture({android, responder: async () => {
      await gate;
      return {publicKey: address, chains: ['solana:mainnet'], canSign: true};
    }});
    const connection = window.solana.connect();
    const cancelled = assert.rejects(connection, error => error.code === 4001);
    window.__mallowDisconnect({preserveConnection: true});
    release();
    await cancelled;
    assert.equal(wallet.accounts.length, 0);
  });
}

test('trusted reconnect with unchanged account does not emit another connection change', async () => {
  const {window, wallet} = fixture();
  await window.solana.connect();
  const account = wallet.accounts[0];
  const changes = [];
  wallet.features['standard:events'].on('change', value => changes.push(value));
  window.solana.on('connect', value => changes.push(value));
  await window.solana.connect({onlyIfTrusted: true});
  assert.equal(wallet.accounts[0], account);
  assert.equal(changes.length, 0);
});

test('document readiness restores a previously approved Android connection', async () => {
  const {window, wallet, requests} = fixture({android: true});
  delete window.__mallowDocumentToken;
  const changed = new Promise(resolve => wallet.features['standard:events'].on('change', resolve));
  window.__mallowDocumentToken = 'reopened-document-token';
  window.dispatchEvent(new Event('mallow:document-ready'));
  await changed;
  assert.equal(wallet.accounts[0].address, address);
  // The Ethereum provider makes its own silent check in its own namespace.
  const solana = requests.filter(request => request.namespace === undefined);
  assert.equal(solana.length, 1);
  assert.equal(solana[0].params.onlyIfTrusted, true);
  assert.equal(solana[0].documentToken, 'reopened-document-token');
  assert.deepEqual(requests.filter(request => request.namespace === 'eip155').map(request => request.params), [{silent: true}]);
});

test('a document that leaves gives up its token, and a restored one waits for its new token', async () => {
  const {window, requests} = fixture({android: true});
  window.dispatchEvent(new Event('pagehide'));
  assert.equal(window.__mallowDocumentToken, undefined);
  // Restored from the back-forward cache: nothing goes out on the old token.
  const connected = window.solana.connect();
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(requests.filter(request => request.method === 'connect' && !request.params.onlyIfTrusted).length, 0);
  window.__mallowDocumentToken = 'restored-document-token';
  window.dispatchEvent(new Event('mallow:document-ready'));
  await connected;
  const connect = requests.find(request => request.method === 'connect' && request.namespace === undefined && !request.params.onlyIfTrusted);
  assert.equal(connect.documentToken, 'restored-document-token');
});

test('a request cancelled before document readiness never enters the native bridge', async () => {
  const {window, wallet, requests} = fixture({android: true});
  await window.solana.connect();
  delete window.__mallowDocumentToken;
  const signing = window.solana.signMessage(new Uint8Array([1]));
  const cancelled = assert.rejects(signing, error => error.code === 4001);
  window.__mallowDisconnect({preserveConnection: true});
  window.__mallowDocumentToken = 'ready-document-token';
  window.dispatchEvent(new Event('mallow:document-ready'));
  await cancelled;
  assert.equal(requests.filter(request => request.method === 'signMessage').length, 0);
  assert.equal(wallet.accounts[0].address, address);
});

test('trusted reconnect still reports changes to signing capabilities', async () => {
  let canSignMessages = true;
  const {window, wallet} = fixture({responder: async () => ({
    publicKey: address, chains: ['solana:mainnet'], canSign: true, canSignMessages,
  })});
  await window.solana.connect();
  const changes = [];
  wallet.features['standard:events'].on('change', value => changes.push(value));
  canSignMessages = false;
  await window.solana.connect({onlyIfTrusted: true});
  assert.equal(changes.length, 1);
  assert.equal(wallet.accounts[0].features.includes('solana:signMessage'), false);
});

test('view-only account keeps transaction features so requests reach the native review', async () => {
  const {wallet} = fixture({responder: async () => ({
    publicKey: address,
    chains: ['solana:mainnet'],
    canSign: false,
    canSignMessages: false,
  })});
  await wallet.features['standard:connect'].connect();
  assert.deepEqual(
    [...wallet.accounts[0].features],
    ['solana:signTransaction', 'solana:signAndSendTransaction'],
  );
});

// Optional interoperability regression using the actual site's adapter SDK.
if (process.env.MALLOW_STANDARD_ADAPTER_MODULE) {
  test('native suspension retains adapter selection for auto-connect on a later visit', async () => {
    const {StandardWalletAdapter} = await import(process.env.MALLOW_STANDARD_ADAPTER_MODULE);
    const {window, wallet} = fixture({android: true});
    const previousWindow = globalThis.window;
    const previousDocument = globalThis.document;
    globalThis.window = window;
    globalThis.document = {};
    const adapter = new StandardWalletAdapter({wallet});
    let selected = 'mallow';
    adapter.on('error', () => {});
    // WalletProvider clears its persisted wallet name on this event.
    adapter.on('disconnect', () => {selected = null;});
    try {
      await adapter.connect();
      window.__mallowDisconnect({preserveConnection: true});
      await window.solana.connect({onlyIfTrusted: true});
      assert.equal(adapter.connected, true);
      assert.equal(selected, 'mallow');
      const later = fixture({android: true});
      const restored = new StandardWalletAdapter({wallet: later.wallet});
      try {
        if (selected === restored.name) await restored.autoConnect();
        assert.equal(restored.connected, true);
      } finally {
        restored.destroy();
      }
      await adapter.disconnect();
      assert.equal(selected, null);
      assert.equal(wallet.accounts.length, 0);
    } finally {
      adapter.destroy();
      globalThis.window = previousWindow;
      globalThis.document = previousDocument;
    }
  });
}

// Optional real-SDK interoperability check, without adding an npm dependency to
// the Flutter app: MALLOW_WEB3_MODULE=/path/to/@solana/web3.js/lib/index.cjs.js.
if (process.env.MALLOW_WEB3_MODULE) {
  test('real web3.js PublicKey, legacy Transaction and VersionedTransaction interoperate', async () => {
    const {PublicKey, SystemProgram, Transaction, TransactionMessage, VersionedTransaction} = await import(process.env.MALLOW_WEB3_MODULE);
    const {window} = fixture();
    await window.solana.connect();
    const key = window.solana.publicKey;
    const sdkKey = new PublicKey(address);
    assert.equal(sdkKey.equals(key), true);
    assert.equal(new PublicKey(key).equals(sdkKey), true);
    assert.deepEqual([...new PublicKey(key).toBytes()], [...key.toBytes()]);
    const destination = new PublicKey('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
    assert.equal(destination.equals(key), false);
    const nonzero = fixture({responder: async () => ({publicKey: destination.toBase58(), chains: ['solana:mainnet'], canSign: true})});
    await nonzero.window.solana.connect();
    assert.equal(destination.equals(nonzero.window.solana.publicKey), true);
    assert.deepEqual([...new PublicKey(nonzero.window.solana.publicKey).toBytes()], [...destination.toBytes()]);
    const instruction = SystemProgram.transfer({fromPubkey: key, toPubkey: destination, lamports: 1});
    const legacy = new Transaction({feePayer: key, recentBlockhash: address}).add(instruction);
    const signedLegacy = await window.solana.signTransaction(legacy);
    assert.ok(signedLegacy instanceof Transaction);
    assert.deepEqual(signedLegacy.serializeMessage(), legacy.serializeMessage());
    const versioned = new VersionedTransaction(new TransactionMessage({payerKey: key, recentBlockhash: address, instructions: [instruction]}).compileToV0Message());
    const signedVersioned = await window.solana.signTransaction(versioned);
    assert.ok(signedVersioned instanceof VersionedTransaction);
    assert.deepEqual(signedVersioned.message.serialize(), versioned.message.serialize());
  });
}
