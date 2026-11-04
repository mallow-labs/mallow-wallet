/// Inject at document start into HTTPS main frames only. Native frame metadata
/// remains authoritative even if a website replaces any of these JavaScript APIs.
///
/// Installs chain providers over one native transport: Solana (`window.solana`
/// and the Wallet Standard) and Ethereum (`window.ethereum`, EIP-1193, also
/// announced through EIP-6963), and Tezos (Beacon v2 and `window.tezos`).
///
/// Adds `window.mallow.ui` only when the origin-gated grant script from
/// `browser_ui_channel.dart` ran first in the same document.
const mallowDappProviderScript = r'''
(() => {
  'use strict';
  // The first-party UI grant, left only by the origin-gated script the native
  // host injects just before this one. Taken and removed before any page
  // script runs, so a page can neither see it nor plant one.
  const uiGrant = Object.getOwnPropertyDescriptor(window, '__mallowUiGrant')?.value;
  try { delete window.__mallowUiGrant; } catch (_) {}
  if (window !== window.top || location.protocol !== 'https:' || window.solana?.isMallow) return;
  const pending = new Map();
  // Reply handlers for the few fire-and-forget `ui` messages that care how
  // they were answered (a released overlay); kept out of `pending`.
  const uiReplies = new Map();
  const listeners = new Map();
  const standardListeners = new Set();
  let sequence = 0;
  let requestEpoch = 0;
  let account = null;
  let chains = Object.freeze(window.__mallowSupportedChains || ['solana:mainnet']);
  let tezosAccount = null;
  let ethAccount = null;
  const ethListeners = new Map();
  const ethEmit = (event, ...args) => {
    for (const listener of [...(ethListeners.get(event) || [])]) {
      try { listener(...args); } catch (_) {}
    }
  };
  const ethSet = accounts => {
    const next = Array.isArray(accounts) && typeof accounts[0] === 'string' ? accounts[0] : null;
    if (next === ethAccount) return;
    ethAccount = next;
    ethEmit('accountsChanged', next ? [next] : []);
  };
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  const bytes = value => {
    if (!(value instanceof Uint8Array)) throw new TypeError('Expected Uint8Array');
    return value;
  };
  const encode = value => {
    value = bytes(value);
    if (value.length > 65536) throw new RangeError('Payload is too large');
    let text = '';
    for (const byte of value) text += String.fromCharCode(byte);
    return btoa(text);
  };
  const decode = value => Uint8Array.from(atob(value), ch => ch.charCodeAt(0));
  const fromBase58 = value => {
    let number = 0n;
    for (const ch of value) {
      const digit = alphabet.indexOf(ch);
      if (digit < 0) throw new Error('Invalid public key');
      number = number * 58n + BigInt(digit);
    }
    const out = [];
    while (number > 0n) { out.push(Number(number & 255n)); number >>= 8n; }
    for (const ch of value) { if (ch !== '1') break; out.push(0); }
    return Uint8Array.from(out.reverse());
  };
  // web3.js PublicKey accepts PublicKeyData and compares its BN words directly.
  // This read-only numeric view supplies just the public-address representation;
  // all signing and authoritative account selection remain native.
  const publicKey = address => {
    const value = fromBase58(address);
    let number = 0n;
    for (const byte of value) number = (number << 8n) | BigInt(byte);
    const words = [];
    let remaining = number;
    do { words.push(Number(remaining & 0x3ffffffn)); remaining >>= 26n; } while (remaining);
    const toArray = (endian = 'be', length = 32) => {
      if (length < 32) throw new RangeError('Public key requires 32 bytes');
      const out = new Uint8Array(length);
      out.set(value, length - value.length);
      return Array.from(endian === 'le' ? out.reverse() : out);
    };
    const bn = Object.freeze({
      words: Object.freeze(words), length: words.length, negative: 0, red: null,
      constructor: Object.freeze({wordSize: 26}),
      byteLength: () => 32,
      toArray,
      toArrayLike: (Type, endian, length) => Type.from(toArray(endian, length)),
      eq: other => other?.negative === 0 && other.length === words.length && words.every((word, index) => word === other.words[index]),
    });
    return Object.freeze({
      _bn: bn,
      toBase58: () => address,
      toString: () => address,
      toJSON: () => address,
      toBytes: () => new Uint8Array(value),
      toBuffer: () => new Uint8Array(value),
      equals: other => other?.toString() === address,
    });
  };
  const emit = (event, value) => {
    for (const listener of listeners.get(event) || []) {
      try { listener(value); } catch (_) {}
    }
  };
  const update = result => {
    const previousAddress = account?.address;
    // A view-only account still offers the transaction features: sites build
    // their signer from them, and without one the request never reaches the
    // native review, which shows the simulation and then refuses to sign.
    const features = [
      'solana:signTransaction',
      'solana:signAndSendTransaction',
      ...(result.canSignMessages === true ? ['solana:signMessage'] : []),
    ];
    const same = (left, right) => left.length === right.length && left.every((value, index) => value === right[index]);
    if (previousAddress === result.publicKey && same(chains, result.chains) && same(account.features, features)) {
      return {publicKey: publicKey(account.address)};
    }
    chains = Object.freeze([...result.chains]);
    account = Object.freeze({
      address: result.publicKey,
      publicKey: fromBase58(result.publicKey),
      chains,
      features: Object.freeze(features),
      label: 'mallow',
    });
    for (const listener of standardListeners) { try { listener({accounts: [account], chains}); } catch (_) {} }
    emit('connect', publicKey(account.address));
    if (previousAddress !== account.address) emit('accountChanged', publicKey(account.address));
    return {publicKey: publicKey(account.address)};
  };
  const clearSolana = () => {
    if (!account) return;
    account = null;
    for (const listener of standardListeners) { try { listener({accounts: []}); } catch (_) {} }
    emit('accountChanged', null);
    emit('disconnect');
  };
  const clear = ({preserveConnection = false, preserveNamespaces = []} = {}) => {
    requestEpoch++;
    // Temporary native UI and document teardown cancel work, but must not
    // tell adapters to forget the user's persisted wallet selection.
    if (!preserveConnection) {
      if (!preserveNamespaces.includes('solana')) clearSolana();
      if (!preserveNamespaces.includes('eip155')) ethSet([]);
      if (!preserveNamespaces.includes('tezos')) tezosAccount = null;
    }
    for (const [id, {reject, timer, method}] of pending) {
      if (method === 'disconnect') continue;
      clearTimeout(timer);
      pending.delete(id);
      reject(Object.assign(new Error('Request cancelled'), {code: 4001}));
    }
  };
  Object.defineProperty(window, '__mallowDisconnect', {value: clear});
  const unwrap = response => {
    if (response?.error) throw Object.assign(new Error(response.error.message), {code: response.error.code}, typeof response.error.data === 'string' ? {data: response.error.data} : {});
    if (!response || !('result' in response)) throw new Error('Invalid wallet response');
    return response.result;
  };
  if (window.mallowNative) {
    window.mallowNative.onmessage = event => {
      let response;
      try { response = JSON.parse(event.data); } catch (_) { return; }
      const uiReply = uiReplies.get(response?.id);
      if (uiReply) {
        uiReplies.delete(response.id);
        uiReply(response);
        return;
      }
      const request = pending.get(response.id);
      if (!request) return;
      pending.delete(response.id);
      clearTimeout(request.timer);
      try { request.resolve(unwrap(response)); } catch (error) { request.reject(error); }
    };
  }
  const request = async (method, params = {}, namespace) => {
    const id = `${Date.now()}-${++sequence}`;
    const epoch = requestEpoch;
    const ensureCurrent = () => {
      if (method !== 'disconnect' && epoch !== requestEpoch) throw Object.assign(new Error('Request cancelled'), {code: 4001});
    };
    // Issued by the native host to this document after its main-frame load.
    // This supplements native sourceOrigin/isMainFrame; it never replaces them.
    if (!window.__mallowDocumentToken) {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { window.removeEventListener('mallow:document-ready', ready); reject(new Error('Wallet bridge unavailable')); }, 15000);
        const ready = () => { clearTimeout(timer); resolve(); };
        window.addEventListener('mallow:document-ready', ready, {once: true});
      });
    }
    ensureCurrent();
    const envelope = {id, method, params, documentToken: window.__mallowDocumentToken, ...(namespace ? {namespace} : {})};
    let result;
    if (window.mallowNative) {
      const serialized = JSON.stringify(envelope);
      // Reads have their own allowance, so a busy page cannot starve approvals.
      const reads = [...pending.values()].filter(entry => entry.method === 'read').length;
      if (method === 'read' ? reads >= 16 : pending.size - reads >= 8) throw Object.assign(new Error('Too many requests'), {code: -32005});
      result = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(Object.assign(new Error('Request timed out'), {code: 4001})); }, 185000);
        pending.set(id, {resolve, reject, timer, method});
        try {
          window.mallowNative.postMessage(serialized);
        } catch (error) {
          clearTimeout(timer);
          pending.delete(id);
          reject(error);
        }
      });
    } else {
      if (!window.flutter_inappwebview?.callHandler) throw new Error('Wallet bridge unavailable');
      result = unwrap(await window.flutter_inappwebview.callHandler('mallowWallet', envelope));
    }
    ensureCurrent();
    return result;
  };
  const serialize = transaction => encode(transaction instanceof Uint8Array ? transaction : transaction.serialize({requireAllSignatures: false, verifySignatures: false}));
  const restore = (original, encoded) => {
    const signed = decode(encoded);
    if (original instanceof Uint8Array) return signed;
    if (typeof original.constructor.deserialize === 'function') return original.constructor.deserialize(signed);
    if (typeof original.constructor.from === 'function') return original.constructor.from(signed);
    throw new TypeError('Unsupported transaction object');
  };
  const requireAccount = supplied => {
    if (!account || (supplied && supplied.address !== account.address)) throw Object.assign(new Error('Account is not connected'), {code: 4100});
    return account.address;
  };
  // A transaction-signing batch is one request, reviewed as a whole, up to
  // 100; the other batches are sent one request per input, up to 10.
  const batch = (inputs, max = 10) => { if (!inputs.length || inputs.length > max) throw new RangeError(`A batch must contain 1 to ${max} requests`); };
  // Pages extend the providers they find: Uniswap sets MetaMask's legacy
  // `autoRefreshOnNetworkChange` on `window.ethereum`, and a frozen provider
  // makes that strict-mode write throw and blank the page. So a provider
  // stays extensible, while its own members ignore reassignment, as
  // `window.ethereum` itself does, instead of being replaced or throwing.
  const lockedProvider = members => {
    const target = {};
    for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(members))) {
      const get = descriptor.get || (() => descriptor.value);
      Object.defineProperty(target, key, {get, set: () => {}, enumerable: true, configurable: false});
    }
    return target;
  };
  const provider = lockedProvider({
    isMallow: true,
    get isConnected() { return account !== null; },
    get publicKey() { return account ? publicKey(account.address) : null; },
    connect: async options => update(await request('connect', options || {})),
    disconnect: async () => { await request('disconnect'); clearSolana(); },
    on: (event, listener) => { if (!listeners.has(event)) listeners.set(event, new Set()); listeners.get(event).add(listener); return provider; },
    off: (event, listener) => { listeners.get(event)?.delete(listener); return provider; },
    removeListener: (event, listener) => { listeners.get(event)?.delete(listener); return provider; },
    signTransaction: async (transaction, options = {}) => restore(transaction, (await request('signTransaction', {transaction: serialize(transaction), account: requireAccount(), chain: options.chain, options})).transaction),
    signAllTransactions: async (transactions, options = {}) => {
      batch(transactions, 100);
      const result = await request('signAllTransactions', {transactions: transactions.map(serialize), account: requireAccount(), chain: options.chain, options});
      return result.transactions.map((value, index) => restore(transactions[index], value));
    },
    signAndSendTransaction: async (transaction, options = {}) => {
      const result = await request('signAndSendTransaction', {transaction: serialize(transaction), account: requireAccount(), chain: options.chain, options});
      return {signature: result.signature, publicKey: provider.publicKey};
    },
    signMessage: async message => {
      const result = await request('signMessage', {message: encode(message), account: requireAccount()});
      return {signature: decode(result.signature), publicKey: provider.publicKey};
    },
  });
  // Embedded from assets/icon/app_icon.svg so wallet pickers need no image fetch.
  const icon = 'data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIHZpZXdCb3g9IjAgMCAxMDI0IDEwMjQiPgogIDxyZWN0IHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIGZpbGw9IiMwMDAwMDAiLz4KICA8ZyB0cmFuc2Zvcm09InRyYW5zbGF0ZSgxOTQuNTYsMjU5Ljg5KSBzY2FsZSgyLjc2NSkgdHJhbnNsYXRlKC02My45NzQsLTYzLjk3NCkiIGZpbGw9IiNGRjlGOEYiPgogICAgPHBhdGggZD0iTTI4My40NjgsMTM0Ljc4NGwuMDMtNTguODU2Yy4wMDQtNy4zOTgtNi42NTQtMTIuOTc4LTEzLjk1MS0xMS43NjUtMzAuMTQ5LDUuMDEyLTU3LjQyOSwxOC42MjMtNzkuMjI4LDM4LjIxNywxNi4zNDEsMTkuMjcxLDI4LjczOCw0MS45ODQsMzUuOTIzLDY2Ljg4OCwxMy4zMzEtMTguMzM4LDMzLjc2Mi0zMS4xOTYsNTcuMjI2LTM0LjQ4NFoiLz4KICAgIDxwYXRoIGQ9Ik02My45NzQsMTU4Ljk2OHY3My4wMDJjMCw2LjU4Nyw1LjMzOSwxMS45MjYsMTEuOTI2LDExLjkyNmgzNy43ODd2LTI0LjQ5N2MwLTI5Ljg5OC0yMS40MTctNTQuODc5LTQ5LjcxMy02MC40MzFaIi8+CiAgICA8cGF0aCBkPSJNMTczLjc0MywxMTkuNzIxYy0yLjU2OS0zLjEyOS01LjI1Ny02LjE1NS04LjA1Ni05LjA3Ny0yLjczOC0yLjg1OC01LjU3Ny01LjYxNy04LjUyMS04LjI2NC04LjEzLTcuMzA3LTE3LjAyLTEzLjc4NS0yNi41NC0xOS4yOTItMTYuMDU1LTkuMjg5LTMzLjg5NC0xNS44MjQtNTIuODY1LTE4Ljk1NC03LjIyNy0xLjE5My0xMy43NzcsNC40NjgtMTMuNzc0LDExLjc5M2wuMDI5LDU4Ljg1OGMyMy40NjQsMy4yODgsNDMuODk1LDE2LjE0Niw1Ny4yMjYsMzQuNDg0LDMuMzMxLDQuNTgyLDYuMjA2LDkuNTEyLDguNTg2LDE0LjcxNiw0LjkzOCwxMC43OTcsNy43MSwyMi43ODUsNy43MSwzNS40MTR2MjQuNDk3aDcxLjkyMXYtMjQuNDVjMC0zNy44MTYtMTMuNDExLTcyLjU1NS0zNS43MTgtOTkuNzI2WiIvPgogICAgPGNpcmNsZSBjeD0iMjYxLjYyOSIgY3k9IjIxNC4zNDYiIHI9IjMxLjk4NyIvPgogIDwvZz4KPC9zdmc+Cg==';
  const wallet = Object.freeze({
    version: '1.0.0', name: 'mallow',
    icon,
    get chains() { return chains; },
    get accounts() { return account ? [account] : []; },
    features: Object.freeze({
      'standard:connect': {version: '1.0.0', connect: async options => {
        const silent = options?.silent === true;
        const result = await request('connect', {silent});
        if (silent && Array.isArray(result.accounts) && result.accounts.length === 0) {
          clearSolana();
          return {accounts: []};
        }
        update(result);
        return {accounts: [account]};
      }},
      'standard:disconnect': {version: '1.0.0', disconnect: provider.disconnect},
      'standard:events': {version: '1.0.0', on: (event, listener) => { if (event !== 'change') throw new Error('Unsupported event'); standardListeners.add(listener); return () => standardListeners.delete(listener); }},
      'solana:signTransaction': {version: '1.0.0', supportedTransactionVersions: ['legacy', 0], signTransaction: async (...inputs) => {
        batch(inputs, 100);
        const chain = inputs[0].chain || 'solana:mainnet';
        for (const input of inputs) { requireAccount(input.account); if ((input.chain || 'solana:mainnet') !== chain) throw new Error('Batch networks must match'); }
        const result = await request('signAllTransactions', {transactions: inputs.map(input => encode(input.transaction)), account: requireAccount(), chain, options: inputs[0].options || {}});
        return result.transactions.map(transaction => ({signedTransaction: decode(transaction)}));
      }},
      'solana:signAndSendTransaction': {version: '1.0.0', supportedTransactionVersions: ['legacy', 0], signAndSendTransaction: async (...inputs) => {
        batch(inputs);
        const results = [];
        try {
          for (const input of inputs) { const result = await request('signAndSendTransaction', {transaction: encode(input.transaction), account: requireAccount(input.account), chain: input.chain, options: input.options || {}}); results.push({signature: fromBase58(result.signature)}); }
        } catch (error) { error.completed = results; throw error; }
        return results;
      }},
      'solana:signMessage': {version: '1.0.0', signMessage: async (...inputs) => {
        batch(inputs);
        const results = [];
        for (const input of inputs) { const signedMessage = new Uint8Array(bytes(input.message)); const result = await request('signMessage', {message: encode(signedMessage), account: requireAccount(input.account)}); results.push({signedMessage, signature: decode(result.signature)}); }
        return results;
      }},
    }),
  });
  Object.defineProperty(window, 'solana', {value: provider, configurable: false});
  const rpcError = (code, message) => Object.assign(new Error(message), {code});
  const requireEth = address => {
    if (!ethAccount || (address != null && (typeof address !== 'string' || address.toLowerCase() !== ethAccount.toLowerCase()))) throw rpcError(4100, 'Account is not connected');
  };
  const ethPermission = () => ({parentCapability: 'eth_accounts', caveats: [{type: 'restrictReturnedAccounts', value: [ethAccount]}]});
  const ethReads = new Set(['eth_blockNumber', 'eth_call', 'eth_estimateGas', 'eth_feeHistory', 'eth_gasPrice', 'eth_getBalance', 'eth_getBlockByHash', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getLogs', 'eth_getStorageAt', 'eth_getTransactionByHash', 'eth_getTransactionCount', 'eth_getTransactionReceipt', 'eth_maxPriorityFeePerGas']);
  const ethRequest = async args => {
    if (!args || typeof args !== 'object' || typeof args.method !== 'string') throw rpcError(-32602, 'Invalid request arguments');
    const method = args.method;
    const params = args.params === undefined ? [] : args.params;
    if (params === null || typeof params !== 'object') throw rpcError(-32602, 'Invalid params');
    const list = Array.isArray(params) ? params : [params];
    const chainOf = value => typeof value?.chainId === 'string' ? value.chainId.toLowerCase() : null;
    switch (method) {
      case 'eth_chainId': return '0x1';
      case 'net_version': return '1';
      case 'eth_accounts': {
        // Pages poll this. Native keeps the cached account current: a
        // revocation, wallet switch or lock clears it through __mallowDisconnect.
        if (ethAccount) return [ethAccount];
        ethSet((await request('connect', {silent: true}, 'eip155')).accounts);
        return ethAccount ? [ethAccount] : [];
      }
      case 'eth_requestAccounts': {
        ethSet((await request('connect', {}, 'eip155')).accounts);
        return ethAccount ? [ethAccount] : [];
      }
      case 'wallet_requestPermissions': {
        if (!list[0] || typeof list[0] !== 'object' || !('eth_accounts' in list[0]) || Object.keys(list[0]).length !== 1) throw rpcError(-32602, 'Only eth_accounts can be requested');
        await ethRequest({method: 'eth_requestAccounts'});
        return [ethPermission()];
      }
      case 'wallet_getPermissions':
        return (await ethRequest({method: 'eth_accounts'})).length ? [ethPermission()] : [];
      case 'wallet_revokePermissions':
        await request('disconnect', {}, 'eip155');
        ethSet([]);
        return null;
      case 'wallet_switchEthereumChain':
        if (chainOf(list[0]) === '0x1') return null;
        throw rpcError(4902, 'mallow supports Ethereum mainnet only');
      case 'wallet_addEthereumChain':
        if (chainOf(list[0]) === '0x1') return null;
        throw rpcError(4200, 'mallow supports Ethereum mainnet only');
      case 'personal_sign': {
        let [message, address] = list;
        // Some sites send [address, message]. The account itself decides which is which.
        if (typeof message === 'string' && typeof address === 'string' && ethAccount && message.toLowerCase() === ethAccount.toLowerCase() && address.toLowerCase() !== ethAccount.toLowerCase()) [message, address] = [address, message];
        requireEth(address);
        if (typeof message !== 'string') throw rpcError(-32602, 'Message must be a string');
        return (await request('personal_sign', {message, address: ethAccount}, 'eip155')).signature;
      }
      case 'eth_signTypedData_v4': {
        const [address, typedData] = list;
        requireEth(address);
        if (typedData == null) throw rpcError(-32602, 'Typed data is required');
        return (await request('eth_signTypedData_v4', {address: ethAccount, typedData}, 'eip155')).signature;
      }
      case 'eth_sendTransaction': {
        const transaction = list[0];
        if (!transaction || typeof transaction !== 'object') throw rpcError(-32602, 'Invalid transaction');
        requireEth(transaction.from);
        return (await request('eth_sendTransaction', {transaction}, 'eip155')).hash;
      }
      default:
        if (ethReads.has(method)) return request('read', {method, params: list}, 'eip155');
        // eth_sign signs an arbitrary hash and is how wallets get drained; the
        // other legacy signing methods are not offered either.
        throw rpcError(4200, 'Unsupported method');
    }
  };
  const ethOn = (event, listener) => {
    if (typeof listener !== 'function') return ethereum;
    if (!ethListeners.has(event)) ethListeners.set(event, new Set());
    ethListeners.get(event).add(listener);
    return ethereum;
  };
  const ethOff = (event, listener) => { ethListeners.get(event)?.delete(listener); return ethereum; };
  const legacy = (payload, callback) => {
    const respond = promise => promise.then(
      result => callback(null, {id: payload?.id, jsonrpc: '2.0', result}),
      error => callback(error, {id: payload?.id, jsonrpc: '2.0', error: {code: error.code, message: error.message, ...(error.data ? {data: error.data} : {})}}),
    );
    if (Array.isArray(payload)) {
      Promise.all(payload.map(item => ethRequest(item).then(result => ({id: item?.id, jsonrpc: '2.0', result}), error => ({id: item?.id, jsonrpc: '2.0', error: {code: error.code, message: error.message}})))).then(results => callback(null, results));
      return;
    }
    respond(ethRequest(payload));
  };
  const ethereum = lockedProvider({
    isMallow: true,
    request: ethRequest,
    get chainId() { return '0x1'; },
    get networkVersion() { return '1'; },
    get selectedAddress() { return ethAccount; },
    isConnected: () => true,
    enable: () => ethRequest({method: 'eth_requestAccounts'}),
    on: ethOn,
    addListener: ethOn,
    once: (event, listener) => {
      const once = (...args) => { ethOff(event, once); listener(...args); };
      return ethOn(event, once);
    },
    off: ethOff,
    removeListener: ethOff,
    removeAllListeners: event => { if (event === undefined) ethListeners.clear(); else ethListeners.delete(event); return ethereum; },
    sendAsync: legacy,
    send: (methodOrPayload, paramsOrCallback) => {
      if (typeof methodOrPayload === 'string') return ethRequest({method: methodOrPayload, params: paramsOrCallback});
      if (typeof paramsOrCallback === 'function') return legacy(methodOrPayload, paramsOrCallback);
      // The synchronous legacy form can only answer from local state.
      const method = methodOrPayload?.method;
      const result = method === 'eth_accounts' || method === 'eth_coinbase' ? (ethAccount ? (method === 'eth_coinbase' ? ethAccount : [ethAccount]) : (method === 'eth_coinbase' ? null : [])) : method === 'eth_chainId' ? '0x1' : method === 'net_version' ? '1' : undefined;
      if (result === undefined) throw rpcError(4200, 'Synchronous requests are unsupported');
      return {id: methodOrPayload.id, jsonrpc: '2.0', result};
    },
  });
  // A page assigning its own provider is ignored rather than thrown at:
  // a strict-mode assignment to a read-only property would break the page.
  Object.defineProperty(window, 'ethereum', {get: () => ethereum, set: () => {}, enumerable: true, configurable: false});
  const hex = () => Math.floor(Math.random() * 16).toString(16);
  const ethInfo = Object.freeze({
    uuid: 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => c === 'x' ? hex() : ((Math.random() * 4 | 0) + 8).toString(16)),
    name: 'mallow',
    icon,
    rdns: 'art.mallow.wallet',
  });
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {detail: Object.freeze({info: ethInfo, provider: ethereum})}));
  window.addEventListener('eip6963:requestProvider', announce);
  announce();
  // window.mallow.ui, for the deployment's own web app only. Its messages
  // are fire-and-forget and kept out of `pending`: they never count against
  // the request limits, and a cancellation never rejects them.
  let ui;
  let uiWanted;
  if (uiGrant && (uiGrant.theme === 'light' || uiGrant.theme === 'dark')) {
    let theme = uiGrant.theme;
    let queued = false;
    // onReply sees the native answer, or an error-shaped stand-in when the
    // bridge itself failed.
    const sendUi = (method, params, onReply) => {
      const id = `${Date.now()}-${++sequence}`;
      const envelope = {id, namespace: 'ui', method, params, documentToken: window.__mallowDocumentToken};
      const failed = {error: {code: 4100, message: 'Wallet bridge unavailable'}};
      try {
        if (window.mallowNative) {
          if (onReply) {
            uiReplies.set(id, onReply);
            setTimeout(() => uiReplies.delete(id), 10000);
          }
          window.mallowNative.postMessage(JSON.stringify(envelope));
        } else {
          const reply = window.flutter_inappwebview?.callHandler?.('mallowWallet', envelope);
          if (!reply) throw new Error('Wallet bridge unavailable');
          reply.then?.(response => onReply?.(response), () => onReply?.(failed));
        }
      } catch (_) {
        uiReplies.delete(id);
        onReply?.(failed);
      }
    };
    // Sends the latest state asked for. Before the native host has issued
    // this document its token there is nothing to send it with, so only the
    // latest state goes out once it has. A release the wallet refused is
    // tried once more: a lost one would leave the chrome dimmed under a page
    // with no sheet left to close.
    const sendOverlay = retry => {
      if (!window.__mallowDocumentToken) {
        if (!queued) {
          queued = true;
          window.addEventListener('mallow:document-ready', () => {
            queued = false;
            sendOverlay(true);
          }, {once: true});
        }
        return;
      }
      const active = uiWanted;
      sendUi('setOverlay', {active}, !active && retry ? response => {
        if (!response?.error) return;
        setTimeout(() => { if (uiWanted === false) sendOverlay(false); }, 250);
      } : undefined);
    };
    ui = Object.freeze({
      version: 1,
      get theme() { return theme; },
      setOverlay: active => {
        uiWanted = Boolean(active);
        sendOverlay(true);
      },
    });
    Object.defineProperty(window, '__mallowUiSetTheme', {value: next => {
      if ((next !== 'light' && next !== 'dark') || next === theme) return;
      theme = next;
      window.dispatchEvent(new CustomEvent('mallow:theme', {detail: Object.freeze({theme})}));
    }});
  }
  // Beacon v2 discovers wallets with ping/pong, then pairs and exchanges
  // encrypted messages. Crypto and permission decisions stay native.
  const beaconSender = Object.freeze({id: 'art.mallow.wallet', name: 'mallow', iconUrl: icon, iconURL: icon});
  let beaconPairing = null;
  let beaconSelection = null;
  let beaconPairingTimer;
  const sendBeacon = async (params, isCurrent = () => true) => {
    const result = await request('beacon', params, 'tezos');
    if (result.message && isCurrent()) window.postMessage({message: result.message, sender: beaconSender}, location.origin);
  };
  // Beacon's picker records extension-only selections as "mobile" but never
  // sends their handshake. Observe its serialized public pairing metadata and
  // replay only a newly persisted Mallow selection. JSON output is untouched;
  // native frame checks and permission approval still govern every request.
  const replayBeaconSelection = () => {
    clearTimeout(beaconPairingTimer);
    if (!beaconPairing || !beaconSelection) return;
    const pairing = beaconPairing;
    const selection = beaconSelection;
    beaconPairingTimer = setTimeout(() => {
      if (beaconPairing !== pairing || beaconSelection !== selection || selection.epoch !== requestEpoch) return;
      beaconSelection = null;
      const isCurrent = () => beaconPairing === pairing && selection.epoch === requestEpoch && window.localStorage.getItem('beacon:last-selected-wallet') === selection.json;
      try {
        if (pairing.forwarded || !isCurrent()) return;
        pairing.forwarded = true;
        sendBeacon({pairingJson: pairing.json}, isCurrent).then(() => {
          if (isCurrent()) window.localStorage.setItem('beacon:last-selected-wallet', JSON.stringify({...JSON.parse(selection.json), name: beaconSender.name, type: 'extension'}));
        }).catch(() => { pairing.forwarded = false; });
      } catch (_) {}
    }, 50); // Give SDKs that send their own handshake time to do so first.
  };
  try {
    if (window.localStorage) {
      const stringify = JSON.stringify;
      const parse = JSON.parse;
      JSON.stringify = function (value, replacer, space) {
        const serialized = stringify.apply(this, arguments);
        try {
          if (typeof serialized === 'string' && serialized.length <= 4096 &&
              (serialized.includes('postmessage-pairing-request') || serialized.includes(beaconSender.id))) {
            const message = parse(serialized);
            if (message?.type === 'postmessage-pairing-request' &&
                (message.version === '2' || message.version === '3') &&
                typeof message.id === 'string' && message.id.length <= 128 &&
                typeof message.publicKey === 'string' && /^[0-9a-fA-F]{64}$/.test(message.publicKey)) {
              if (beaconPairing?.json !== serialized) {
                if (beaconPairing) beaconSelection = null;
                beaconPairing = {json: serialized, forwarded: false};
              }
              replayBeaconSelection();
            } else if (message?.key === beaconSender.id && message.type === 'mobile') {
              beaconSelection = {json: serialized, epoch: requestEpoch};
              replayBeaconSelection();
            }
          }
        } catch (_) {}
        return serialized;
      };
    }
  } catch (_) {} // Storage can be disabled; other chain providers still work.
  window.addEventListener('pagehide', () => {
    clearTimeout(beaconPairingTimer);
    beaconPairing = beaconSelection = null;
  });
  window.addEventListener('message', event => {
    if (event.source !== window || event.origin !== location.origin) return;
    const data = event.data;
    if (!data || data.target !== 'toExtension' || (data.targetId && data.targetId !== beaconSender.id)) return;
    if (data.payload === 'ping') {
      window.postMessage({target: 'toPage', payload: 'pong', sender: beaconSender}, location.origin);
      return;
    }
    const params = typeof data.encryptedPayload === 'string'
      ? {encryptedPayload: data.encryptedPayload}
      : typeof data.payload === 'string' ? {payload: data.payload} : null;
    if (!params) return;
    if (params.payload && beaconPairing) beaconPairing.forwarded = true;
    sendBeacon(params).catch(() => {});
  });
  const tezosConnect = async (params = {}) => {
    const result = await request('connect', params, 'tezos');
    tezosAccount = result.accounts?.length ? Object.freeze({...result}) : null;
    return tezosAccount;
  };
  const tezos = lockedProvider({
    isMallow: true,
    get address() { return tezosAccount?.address || null; },
    get publicKey() { return tezosAccount?.publicKey || null; },
    connect: tezosConnect,
    disconnect: async () => { await request('disconnect', {}, 'tezos'); tezosAccount = null; },
    requestPermissions: params => tezosConnect(params),
    requestSignPayload: async params => {
      if (!tezosAccount) throw rpcError(4100, 'Connect first');
      return request('signPayload', {...params, sourceAddress: params?.sourceAddress || tezosAccount.address}, 'tezos');
    },
    requestOperation: async params => {
      if (!tezosAccount) throw rpcError(4100, 'Connect first');
      const result = await request('sendOperations', {...params, sourceAddress: params?.sourceAddress || tezosAccount.address}, 'tezos');
      return {transactionHash: result.hash};
    },
  });
  Object.defineProperty(window, 'tezos', {get: () => tezos, set: () => {}, enumerable: true, configurable: false});
  Object.defineProperty(window, 'mallow', {value: Object.freeze(ui ? {solana: provider, ethereum, tezos, ui} : {solana: provider, ethereum, tezos}), configurable: false});
  // A document that is leaving, or going into the back-forward cache, gives
  // up its token. Restored from that cache it then waits for the token the
  // native host issues it on return, and its requests queue until then
  // instead of going out with one that is no longer valid. A held overlay is
  // released first, while the token still is.
  window.addEventListener('pagehide', () => {
    if (ui && uiWanted === true) ui.setOverlay(false);
    try { delete window.__mallowDocumentToken; } catch (_) {}
  });
  // Native calls this after its own overlays close: only previously approved
  // origins get their accounts back, and nothing prompts.
  const restoreConnections = () => {
    request('connect', {onlyIfTrusted: true}).then(update).catch(() => {});
    tezosConnect({silent: true}).catch(() => {});
    request('connect', {silent: true}, 'eip155').then(result => {
      if (result.accounts?.length) ethSet(result.accounts);
    }).catch(() => {});
  };
  Object.defineProperty(window, '__mallowRestore', {value: restoreConnections});
  window.dispatchEvent(new CustomEvent('wallet-standard:register-wallet', {detail: api => api.register(wallet)}));
  window.addEventListener('wallet-standard:app-ready', event => event.detail.register(wallet));
  // Only a previously approved origin can obtain an account without a prompt.
  window.addEventListener('mallow:document-ready', () => {
    ethEmit('connect', {chainId: '0x1'});
    restoreConnections();
  }, {once: true});
})();
''';
