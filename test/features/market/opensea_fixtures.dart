import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';

const buyer = '0x1111111111111111111111111111111111111111';
const contract = '0x2222222222222222222222222222222222222222';
const protocol = '0x0000000000000068f116a894984e2db1123eb395';
const mint = '$contract-42';
const artwork = ArtworkDetails(
  mintAccount: mint,
  title: 'Artwork',
  imageUrl: '',
  description: null,
  artistName: 'Artist',
  artistAddress: contract,
  chain: 'ethereum',
  tokenStandard: 'erc721',
);

Map<String, dynamic> quoteJson({String standard = 'erc721'}) => {
  'quoteId': 'quote',
  'chainId': 1,
  'buyerAddress': buyer,
  'contractAddress': contract,
  'tokenId': '42',
  'orderHash': '0x${'ab' * 32}',
  'protocolAddress': protocol,
  'tokenStandard': standard,
  'quantity': '1',
  'listedCopies': '1',
  'marketplace': 'opensea',
  'sellerProceedsWei': '900',
  'marketplaceFees': [
    {'recipient': protocol, 'amountWei': '50'},
  ],
  'creatorFees': [
    {'recipient': contract, 'amountWei': '50', 'required': true},
  ],
  'buyerPaidExtraWei': '0',
  'totalWei': '1000',
  'estimatedGas': '100',
  'estimatedGasWei': '100',
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
  'referral': {'enabled': false, 'buyerCostWei': '0'},
};
OpenSeaPurchaseQuote purchaseQuote() =>
    OpenSeaPurchaseQuote.fromJson(quoteJson());
OpenSeaPurchasePrepareResponse$Result prepared(OpenSeaPurchaseQuote q) =>
    OpenSeaPurchasePrepareResponse$Result(
      quoteId: q.quoteId,
      orderHash: q.orderHash,
      chainId: 1,
      from: buyer,
      to: protocol,
      data: '0x12345678',
      value: q.totalWei,
    );
EvmSimulationResult simulation({String standard = 'ERC721'}) =>
    EvmSimulationResult(
      changes: [
        const EvmAssetChange(
          assetType: 'NATIVE',
          changeType: 'TRANSFER',
          from: buyer,
          to: protocol,
          rawAmount: '1000',
        ),
        EvmAssetChange(
          assetType: standard,
          changeType: 'TRANSFER',
          from: contract,
          to: buyer,
          contractAddress: contract,
          tokenId: '42',
          rawAmount: standard == 'ERC1155' ? '1' : null,
        ),
      ],
    );
