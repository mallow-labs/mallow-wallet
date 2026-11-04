import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/ethereum_dapp_adapter.dart';

const _address = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
const _token = '0xabababababababababababababababababababab';
const _eth = ReviewAsset(id: evmNativeAssetId, symbol: 'ETH', decimals: 18);
const _erc20 = ReviewAsset(id: _token, symbol: 'TOKEN', decimals: 6);
final _wei = BigInt.from(10).pow(18);

SimulationReview _review({
  SimulationExecution execution = SimulationExecution.succeeded,
  SimulationCoverage coverage = SimulationCoverage.complete,
  String chain = ethereumMainnet,
  BigInt? maxNetworkFee,
  BigInt? networkFee,
  List<FundChange> funds = const [],
  List<AccountChange> accounts = const [],
  List<NftChange> nfts = const [],
}) => SimulationReview(
  payloadDigest: 'digest',
  origin: 'https://site.example',
  walletId: 'w',
  address: _address,
  chain: chain,
  simulatedAt: DateTime.utc(2026),
  execution: execution,
  coverage: coverage,
  maxNetworkFee: maxNetworkFee,
  networkFee: networkFee,
  funds: funds,
  accounts: accounts,
  nfts: nfts,
);

FundChange _fund(ReviewAsset asset, BigInt amount, {bool isNet = true}) =>
    FundChange(
      asset: asset,
      address: _address.toLowerCase(),
      rawAmount: amount,
      evidence: ReviewEvidence.simulatedState,
      isNet: isNet,
    );

double? _price(String id) => {evmNativeAssetId: 2000.0, _token: 2.0}[id];

void main() {
  group('estimateEthereumOutgoingUsd', () {
    test(
      'prices an ETH send plus the maximum fee rather than the estimate',
      () {
        final review = _review(
          networkFee: _wei ~/ BigInt.from(1000),
          maxNetworkFee: _wei * BigInt.from(3) ~/ BigInt.from(1000),
          funds: [_fund(_eth, -_wei)],
        );

        expect(
          estimateEthereumOutgoingUsd(review, _price),
          closeTo(2006, 1e-9),
        );
      },
    );

    test('uses the expected fee when no maximum fee is available', () {
      final review = _review(
        networkFee: _wei ~/ BigInt.from(1000),
        funds: [_fund(_eth, -_wei)],
      );

      expect(estimateEthereumOutgoingUsd(review, _price), closeTo(2002, 1e-9));
    });

    test(
      'prices ERC-20 outflows using their decimals and adds the ETH fee',
      () {
        final review = _review(
          maxNetworkFee: _wei ~/ BigInt.from(1000),
          funds: [
            _fund(_erc20, BigInt.from(-1500000)),
            _fund(_erc20, BigInt.from(-500000)),
          ],
        );

        expect(estimateEthereumOutgoingUsd(review, _price), closeTo(6, 1e-9));
      },
    );

    test(
      'receipts and duplicate gross entries do not change the net outflow',
      () {
        final review = _review(
          maxNetworkFee: BigInt.zero,
          funds: [
            _fund(_eth, -_wei),
            _fund(_eth, _wei * BigInt.two),
            _fund(_eth, -_wei, isNet: false),
            _fund(const ReviewAsset(id: 'unpriced', symbol: '?'), BigInt.one),
          ],
        );

        expect(estimateEthereumOutgoingUsd(review, _price), 2000);
      },
    );

    for (final execution in [
      SimulationExecution.failed,
      SimulationExecution.unavailable,
    ]) {
      test('keeps $execution simulation value unknown', () {
        final review = _review(
          execution: execution,
          maxNetworkFee: BigInt.zero,
        );

        expect(estimateEthereumOutgoingUsd(review, _price), isNull);
      });
    }

    test('keeps a review on another chain unknown', () {
      final review = _review(
        chain: 'solana:mainnet',
        maxNetworkFee: BigInt.zero,
      );

      expect(estimateEthereumOutgoingUsd(review, _price), isNull);
    });

    for (final coverage in [
      SimulationCoverage.partial,
      SimulationCoverage.unavailable,
    ]) {
      test('keeps $coverage coverage unknown even with priced outflows', () {
        final review = _review(
          coverage: coverage,
          maxNetworkFee: _wei ~/ BigInt.from(1000),
          funds: [_fund(_erc20, BigInt.from(-1000000))],
        );

        expect(estimateEthereumOutgoingUsd(review, _price), isNull);
      });
    }

    test('keeps a missing network fee unknown', () {
      expect(estimateEthereumOutgoingUsd(_review(), _price), isNull);
    });

    for (final asset in [_eth, _erc20]) {
      for (final price in <double?>[null, double.nan, double.infinity, -1]) {
        test('keeps ${asset.symbol} with price $price unknown', () {
          final review = _review(
            maxNetworkFee: BigInt.one,
            funds: [_fund(asset, -BigInt.one)],
          );

          expect(
            estimateEthereumOutgoingUsd(
              review,
              (id) => id == asset.id ? price : _price(id),
            ),
            isNull,
          );
        });
      }
    }

    test('keeps an outgoing token with missing decimals unknown', () {
      final review = _review(
        maxNetworkFee: BigInt.zero,
        funds: [
          _fund(const ReviewAsset(id: _token, symbol: 'TOKEN'), -BigInt.one),
        ],
      );

      expect(estimateEthereumOutgoingUsd(review, _price), isNull);
    });

    test('keeps an outgoing NFT unknown', () {
      final review = _review(
        maxNetworkFee: BigInt.zero,
        nfts: [
          NftChange(
            kind: NftChangeKind.transfer,
            assetId: '$_token:1',
            description: 'NFT leaves wallet',
            evidence: ReviewEvidence.simulatedState,
            from: _address.toLowerCase(),
            to: _token,
          ),
        ],
      );

      expect(estimateEthereumOutgoingUsd(review, _price), isNull);
    });

    test('keeps a spending approval unknown even with no funds leaving', () {
      final review = _review(
        maxNetworkFee: BigInt.zero,
        accounts: [
          const AccountChange(
            kind: AccountChangeKind.approve,
            address: _token,
            program: _token,
            description: 'Token spending permission',
            evidence: ReviewEvidence.simulatedState,
          ),
        ],
      );

      expect(estimateEthereumOutgoingUsd(review, _price), isNull);
    });

    test('keeps an amount too large for a finite double unknown', () {
      final review = _review(
        maxNetworkFee: BigInt.zero,
        funds: [_fund(_eth, -BigInt.from(10).pow(400))],
      );

      expect(estimateEthereumOutgoingUsd(review, _price), isNull);
    });

    test('keeps an overflowing USD product unknown', () {
      final review = _review(
        maxNetworkFee: BigInt.zero,
        funds: [_fund(_eth, -_wei * BigInt.from(10).pow(308))],
      );

      expect(estimateEthereumOutgoingUsd(review, _price), isNull);
    });

    test('keeps an overflowing sum of finite USD values unknown', () {
      final review = _review(
        maxNetworkFee: _wei,
        funds: [_fund(_erc20, BigInt.from(-1000000))],
      );

      expect(estimateEthereumOutgoingUsd(review, (_) => 1e308), isNull);
    });

    test('accepts a known zero price', () {
      final review = _review(maxNetworkFee: _wei, funds: [_fund(_eth, -_wei)]);

      expect(estimateEthereumOutgoingUsd(review, (_) => 0), 0);
    });
  });
}
