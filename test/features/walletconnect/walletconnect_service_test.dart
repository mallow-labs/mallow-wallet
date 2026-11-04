import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_client.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_service.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_uri.dart';
import 'package:reown_core/reown_core.dart'
    show
        JsonRpcError,
        PairingMetadata,
        Relay,
        TransportType,
        Validation,
        VerifyContext;
import 'package:reown_sign/reown_sign.dart'
    show
        ConnectionMetadata,
        Namespace,
        ProposalData,
        ReownSignError,
        RequiredNamespace,
        SessionData,
        SessionProposalEvent,
        SessionRequest,
        SessionRequestEvent;

const _ethereum = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
const _other = '0x00000000219ab540356cBB839Cbe05303d7705Fa';

WalletInfo _wallet(String id, String address, {String chain = 'ethereum'}) =>
    WalletInfo(
      id: id,
      address: address,
      name: id,
      walletType: WalletType.hd,
      chain: chain,
    );

class _FakeClient implements WalletConnectClient {
  final proposalEvents = StreamController<SessionProposalEvent>.broadcast(
    sync: true,
  );
  final requestEvents = StreamController<SessionRequestEvent>.broadcast(
    sync: true,
  );
  final ended = StreamController<String>.broadcast(sync: true);
  final active = <String, SessionData>{};
  final approved = <int, Map<String, Namespace>>{};
  final rejected = <int, ReownSignError>{};
  final responses = <int, (Object?, JsonRpcError?)>{};
  final disconnected = <String>[];

  @override
  Future<void> init() async {}
  @override
  Future<void> pair(Uri uri) async => paired++;
  int paired = 0;
  int reconnects = 0;

  @override
  bool relayConnected = true;

  @override
  String? relayProblem;
  final expiries = <int, int>{};

  @override
  Future<String> approve(int id, Map<String, Namespace> namespaces) async {
    approved[id] = namespaces;
    active['topic$id'] = _session('topic$id', namespaces);
    return 'topic$id';
  }

  @override
  int? requestExpiry(int id) => expiries[id];

  @override
  Future<void> reject(int id, ReownSignError reason) async =>
      rejected[id] = reason;
  @override
  Future<void> respond(
    String topic,
    int id, {
    Object? result,
    JsonRpcError? error,
  }) async => responses[id] = (result, error);
  @override
  Future<void> disconnect(String topic) async {
    disconnected.add(topic);
    active.remove(topic);
  }

  @override
  Future<void> reconnect() async => reconnects++;
  @override
  Future<void> close() async {}
  @override
  Map<String, SessionData> sessions() => Map.of(active);
  @override
  Map<String, SessionRequest> pendingRequests() => const {};
  @override
  Stream<SessionProposalEvent> get proposals => proposalEvents.stream;
  @override
  Stream<SessionRequestEvent> get requests => requestEvents.stream;
  @override
  Stream<String> get endedSessions => ended.stream;
}

const _site = PairingMetadata(
  name: 'Example',
  description: '',
  url: 'https://app.example.org/swap',
  icons: ['https://app.example.org/icon.png'],
);

SessionData _session(String topic, Map<String, Namespace> namespaces) =>
    SessionData(
      topic: topic,
      pairingTopic: 'pairing',
      relay: Relay('irn'),
      expiry: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      acknowledged: true,
      controller: 'self',
      namespaces: namespaces,
      self: const ConnectionMetadata(
        publicKey: 'self',
        metadata: WalletConnectService.metadata,
      ),
      peer: const ConnectionMetadata(publicKey: 'peer', metadata: _site),
    );

SessionProposalEvent _proposal(
  int id, {
  Validation? validation,
  String pairingTopic = 'pairing',
}) => SessionProposalEvent(
  id,
  ProposalData(
    id: id,
    expiry: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
    relays: [Relay('irn')],
    proposer: const ConnectionMetadata(publicKey: 'peer', metadata: _site),
    requiredNamespaces: const {
      'eip155': RequiredNamespace(
        chains: ['eip155:1'],
        methods: ['personal_sign'],
        events: [],
      ),
    },
    optionalNamespaces: const {},
    pairingTopic: pairingTopic,
  ),
  validation == null
      ? null
      : VerifyContext(
          origin: 'https://app.example.org',
          validation: validation,
          verifyUrl: 'https://verify.example',
        ),
);

class _Presenter implements WalletConnectPresenter {
  _Presenter(this.key);
  final GlobalKey key;
  Map<String, WalletInfo>? Function(WalletConnectProposal)? answer;
  final asked = <WalletConnectProposal>[];
  final messages = <String>[];

  @override
  BuildContext? get context => key.currentContext;
  @override
  Future<Map<String, WalletInfo>?> approveProposal(
    WalletConnectProposal proposal,
  ) async {
    asked.add(proposal);
    return answer?.call(proposal);
  }

  @override
  void showMessage(String message, {bool error = false}) =>
      messages.add(message);
}

void main() {
  late _FakeClient client;
  late _Presenter presenter;
  late WalletConnectService service;
  late List<WalletInfo> device;
  late List<WalletInfo> session;
  late bool unlocked;
  late bool continuing;
  String? bindings;
  late List<DappSigningRequest> signed;
  late Future<Map<String, Object?>> Function(DappSigningRequest) onSign;

  Future<void> setUpService(WidgetTester tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(SizedBox(key: key));
    client = _FakeClient();
    presenter = _Presenter(key);
    device = [_wallet('eth', _ethereum), _wallet('other', _other)];
    session = [_wallet('eth', _ethereum)];
    unlocked = true;
    continuing = true;
    bindings = null;
    signed = [];
    onSign = (request) async => {'signature': '0xsig'};
    service = WalletConnectService(
      projectId: 'project',
      createClient: () => client,
      presenter: presenter,
      deviceWallets: () async => device,
      sessionWallets: () => session,
      attended: () => unlocked,
      canContinue: () => continuing,
      enabled: () => true,
      sign: (context, request) {
        signed.add(request);
        return onSign(request);
      },
      tezosPublicKey: (wallet, active, cancelled) async => 'edpk',
      readUsed: () async => true,
      writeUsed: (_) async {},
      readBindings: () async => bindings,
      writeBindings: (value) async => bindings = value,
    );
    await service.start();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  Future<void> connect(WidgetTester tester) async {
    presenter.answer = (proposal) => {
      'eip155': proposal.candidates['eip155']!.first,
    };
    client.proposalEvents.add(_proposal(1));
    await settle(tester);
  }

  SessionRequestEvent request(
    int id,
    String method,
    Object? params, {
    String topic = 'topic1',
  }) => SessionRequestEvent(
    id,
    topic,
    method,
    'eip155:1',
    params,
    TransportType.relay,
  );

  testWidgets('An approved proposal connects the chosen wallet', (
    tester,
  ) async {
    await setUpService(tester);
    await connect(tester);
    expect(presenter.asked.single.origin, Uri.parse('https://app.example.org'));
    expect(presenter.asked.single.validation, Validation.UNKNOWN);
    expect(client.approved[1]!['eip155']!.accounts, ['eip155:1:$_ethereum']);
    expect(service.sessions.value.single.addresses, {'eip155': _ethereum});
    expect(service.sessions.value.single.name, 'Example');
  });

  testWidgets('The session wallets come first, then the device others', (
    tester,
  ) async {
    await setUpService(tester);
    session = [_wallet('view-only:profile', _other), _wallet('eth', _ethereum)];
    await connect(tester);
    expect(presenter.asked.single.candidates['eip155']!.map((w) => w.id), [
      'eth',
      'other',
    ]);
  });

  testWidgets('A network the session lacks is offered from the device', (
    tester,
  ) async {
    await setUpService(tester);
    session = [];
    await connect(tester);
    expect(presenter.asked.single.candidates['eip155']!.map((w) => w.id), [
      'eth',
      'other',
    ]);
    expect(client.approved[1]!['eip155']!.accounts, ['eip155:1:$_ethereum']);
  });

  group('After a scan', () {
    final topic = 'a' * 64;
    final link = WalletConnectUri.tryParse(
      'wc:$topic@2?symKey=${'b' * 64}&relay-protocol=irn',
    )!;
    const silence =
        'The website did not answer. Get a new code from the website and '
        'try again.';
    const refused =
        'mallow could not reach WalletConnect (3000: Unauthorized: origin '
        'not allowed). Check your connection and try again.';

    testWidgets('a website that never answers is reported', (tester) async {
      await setUpService(tester);
      await service.pair(link);
      expect(presenter.messages, ['Connecting to the website…']);
      await tester.pump(const Duration(seconds: 21));
      expect(presenter.messages.last, silence);
    });

    testWidgets('a closed relay is reopened before pairing', (tester) async {
      await setUpService(tester);
      await service.pair(link);
      expect(client.reconnects, greaterThan(0));
      expect(client.paired, 1);
      await tester.pump(const Duration(seconds: 21));
    });

    testWidgets('a relay that stays closed is reported with its reason', (
      tester,
    ) async {
      await setUpService(tester);
      client
        ..relayConnected = false
        ..relayProblem = '3000: Unauthorized: origin not allowed';
      await service.pair(link);
      expect(client.paired, 0);
      expect(presenter.messages, [refused]);
    });

    testWidgets('a relay lost while waiting is reported as such', (
      tester,
    ) async {
      await setUpService(tester);
      await service.pair(link);
      client
        ..relayConnected = false
        ..relayProblem = '3000: Unauthorized: origin not allowed';
      await tester.pump(const Duration(seconds: 21));
      expect(presenter.messages.last, refused);
    });

    testWidgets('a website that answers is not reported', (tester) async {
      await setUpService(tester);
      await service.pair(link);
      client.proposalEvents.add(_proposal(1, pairingTopic: topic));
      await settle(tester);
      await tester.pump(const Duration(seconds: 21));
      expect(presenter.messages, isNot(contains(silence)));
      expect(presenter.asked, hasLength(1));
    });

    testWidgets('an answer that cannot be shown says why it waits', (
      tester,
    ) async {
      await setUpService(tester);
      await service.pair(link);
      unlocked = false;
      client.proposalEvents.add(_proposal(1, pairingTopic: topic));
      await settle(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(
        presenter.messages.last,
        'mallow got the connection request but could not show it '
        '(not ready).',
      );
      expect(presenter.asked, isEmpty);
    });

    testWidgets('a sheet that fails to open is reported', (tester) async {
      await setUpService(tester);
      presenter.answer = (_) => throw StateError('no screen');
      await service.pair(link);
      client.proposalEvents.add(_proposal(1, pairingTopic: topic));
      await settle(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(
        presenter.messages.last,
        'mallow could not show the connection request (StateError). Get a '
        'new code from the website and try again.',
      );
    });
  });

  testWidgets('A website reported as malicious is refused unasked', (
    tester,
  ) async {
    await setUpService(tester);
    client.proposalEvents.add(_proposal(2, validation: Validation.SCAM));
    await settle(tester);
    expect(presenter.asked, isEmpty);
    expect(client.rejected, contains(2));
    expect(client.approved, isEmpty);
  });

  testWidgets('A proposal needing a wallet the device lacks is refused', (
    tester,
  ) async {
    await setUpService(tester);
    session = [];
    device = [
      _wallet(
        'sol',
        'GsbwXfJraMomNxBcjYLcG3mxkBUiyWXAB32fGbSMQRdW',
        chain: 'solana',
      ),
    ];
    client.proposalEvents.add(_proposal(3));
    await settle(tester);
    expect(presenter.asked, isEmpty);
    expect(client.rejected, contains(3));
  });

  testWidgets('Nothing is shown while locked; it waits for the unlock', (
    tester,
  ) async {
    await setUpService(tester);
    unlocked = false;
    presenter.answer = (proposal) => {
      'eip155': proposal.candidates['eip155']!.first,
    };
    client.proposalEvents.add(_proposal(1));
    await settle(tester);
    expect(presenter.asked, isEmpty);
    unlocked = true;
    service.attendedChanged();
    await settle(tester);
    expect(client.approved, contains(1));
  });

  testWidgets('A request signs with the session wallet, not the active one', (
    tester,
  ) async {
    await setUpService(tester);
    await connect(tester);
    session = [_wallet('other', _other)];
    client.requestEvents.add(
      request(10, 'personal_sign', ['0x68656c6c6f', _ethereum]),
    );
    await settle(tester);
    expect(signed.single.method, 'personal_sign');
    expect(signed.single.wallet.address, _ethereum);
    expect(signed.single.context.canonicalOrigin, 'https://app.example.org');
    expect(
      signed.single.context.iconUrl,
      Uri.parse('https://app.example.org/icon.png'),
    );
    expect(client.responses[10], ('0xsig', null));
  });

  testWidgets('A rejection reaches the website as the standard 5000', (
    tester,
  ) async {
    await setUpService(tester);
    await connect(tester);
    onSign = (_) async => throw const DappException(4001, 'Rejected');
    client.requestEvents.add(
      request(11, 'personal_sign', ['0x68656c6c6f', _ethereum]),
    );
    await settle(tester);
    expect(client.responses[11]!.$2!.code, 5000);
  });

  testWidgets('eth_sign is refused before any review', (tester) async {
    await setUpService(tester);
    await connect(tester);
    client.requestEvents.add(request(12, 'eth_sign', [_ethereum, '0x00']));
    await settle(tester);
    expect(signed, isEmpty);
    expect(client.responses[12]!.$2!.code, 5101);
  });

  testWidgets('A request for an ended session is refused', (tester) async {
    await setUpService(tester);
    await connect(tester);
    client.active.clear();
    client.ended.add('topic1');
    client.requestEvents.add(
      request(13, 'personal_sign', ['0x68656c6c6f', _ethereum]),
    );
    await settle(tester);
    expect(signed, isEmpty);
    expect(client.responses[13]!.$2!.code, 4100);
    expect(service.sessions.value, isEmpty);
  });

  testWidgets('Removing the wallet ends its sessions', (tester) async {
    await setUpService(tester);
    await connect(tester);
    device = [_wallet('other', _other)];
    await service.walletsChanged();
    await settle(tester);
    expect(client.disconnected, ['topic1']);
    expect(service.sessions.value, isEmpty);
  });

  testWidgets('An empty wallet list never ends sessions', (tester) async {
    await setUpService(tester);
    await connect(tester);
    device = [];
    await service.walletsChanged();
    await settle(tester);
    expect(client.disconnected, isEmpty);
    expect(service.sessions.value, hasLength(1));
  });

  testWidgets('A website that swaps its session wallet is disconnected', (
    tester,
  ) async {
    await setUpService(tester);
    await connect(tester);
    // `wc_sessionUpdate` from the website, which the SDK accepts unchecked.
    client.active['topic1'] = _session('topic1', const {
      'eip155': Namespace(
        chains: ['eip155:1'],
        accounts: ['eip155:1:$_other'],
        methods: ['personal_sign'],
        events: [],
      ),
    });
    client.requestEvents.add(
      request(15, 'personal_sign', ['0x68656c6c6f', _other]),
    );
    await settle(tester);
    expect(signed, isEmpty);
    expect(client.responses[15]!.$2!.code, 4100);
    expect(client.disconnected, ['topic1']);
  });

  testWidgets('Approved wallets survive a restart through the bindings', (
    tester,
  ) async {
    await setUpService(tester);
    await connect(tester);
    expect(bindings, contains(_ethereum));
  });

  testWidgets('An expired request is never reviewed', (tester) async {
    await setUpService(tester);
    await connect(tester);
    client.expiries[16] = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1;
    client.requestEvents.add(
      request(16, 'personal_sign', ['0x68656c6c6f', _ethereum]),
    );
    await settle(tester);
    expect(signed, isEmpty);
  });

  testWidgets('The lock cancels a request in review', (tester) async {
    await setUpService(tester);
    await connect(tester);
    final review = Completer<Map<String, Object?>>();
    onSign = (_) => review.future;
    client.requestEvents.add(
      request(17, 'personal_sign', ['0x68656c6c6f', _ethereum]),
    );
    await settle(tester);
    expect(signed, hasLength(1));
    continuing = false;
    service.cancelActive();
    await settle(tester);
    review.complete({'signature': '0xlate'});
    await settle(tester);
    expect(client.responses[17]!.$2!.code, 5000);
  });

  testWidgets('A duplicate delivery of one request is answered once', (
    tester,
  ) async {
    await setUpService(tester);
    await connect(tester);
    final event = request(14, 'personal_sign', ['0x68656c6c6f', _ethereum]);
    client.requestEvents
      ..add(event)
      ..add(event);
    await settle(tester);
    expect(signed, hasLength(1));
  });
}
