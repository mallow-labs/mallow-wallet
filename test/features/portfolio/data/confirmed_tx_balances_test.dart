import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/data/confirmed_tx_balances.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';

/// A `getTransaction` (jsonParsed) result for a SOL -> USDC swap by [owner],
/// shaped like the fields the parser reads.
Map<String, dynamic> _swapTx({
  required String owner,
  Object? err,
  List<Map<String, dynamic>>? preTokenBalances,
  List<Map<String, dynamic>>? postTokenBalances,
}) => {
  'meta': {
    'err': err,
    'fee': 5000,
    // Owner is index 0 (fee payer); index 1 is an unrelated program account.
    'preBalances': [2000000000, 1],
    'postBalances': [1494995000, 1],
    'preTokenBalances': preTokenBalances ?? const [],
    'postTokenBalances': postTokenBalances ?? const [],
  },
  'transaction': {
    'message': {
      'accountKeys': [
        {'pubkey': owner, 'signer': true, 'writable': true},
        {'pubkey': 'Program1111', 'signer': false, 'writable': false},
      ],
    },
  },
};

Map<String, dynamic> _tokenBalance({
  required String owner,
  required String mint,
  required String amount,
  int accountIndex = 3,
}) => {
  'accountIndex': accountIndex,
  'mint': mint,
  'owner': owner,
  'uiTokenAmount': {'amount': amount, 'decimals': 6},
};

void main() {
  const owner = 'Wa11et11111111111111111111111111111111111111';
  const stranger = 'Other111111111111111111111111111111111111111';
  const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  const bonk = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

  test('native SOL is taken from the post balance, not the swapped amount — '
      'it must include the fee the wallet actually paid', () {
    final balances = parseOwnerPostBalances(_swapTx(owner: owner), owner);

    final sol = balances.singleWhere((b) => b.isNative);
    expect(sol.mint, TokenBalance.solMint);
    // 2 SOL - 0.5 swapped - 5000 lamport fee, i.e. the chain's own number.
    expect(sol.rawBalance, 1494995000);
    // The pre value is what lets a later stale read be spotted as one.
    expect(sol.previousRawBalance, 2000000000);
  });

  test('SPL rows report the amount actually filled for this owner and ignore '
      'every other party in the route', () {
    final balances = parseOwnerPostBalances(
      _swapTx(
        owner: owner,
        postTokenBalances: [
          _tokenBalance(owner: owner, mint: usdc, amount: '112500000'),
          // Jupiter's market maker sits in the same tx — crediting its
          // balance to the user would be a silent corruption.
          _tokenBalance(owner: stranger, mint: usdc, amount: '999999999'),
        ],
      ),
      owner,
    );

    final usdcBalance = balances.singleWhere((b) => b.mint == usdc);
    expect(usdcBalance.rawBalance, 112500000);
    expect(usdcBalance.isNative, isFalse);
  });

  test('a mint sold out of entirely reports zero — its token account is gone '
      'from the post balances, so it would otherwise stay stale forever', () {
    final balances = parseOwnerPostBalances(
      _swapTx(
        owner: owner,
        preTokenBalances: [
          _tokenBalance(owner: owner, mint: bonk, amount: '5000000'),
        ],
        postTokenBalances: [
          _tokenBalance(owner: owner, mint: usdc, amount: '112500000'),
        ],
      ),
      owner,
    );

    final bonkBalance = balances.singleWhere((b) => b.mint == bonk);
    expect(bonkBalance.rawBalance, 0);
    expect(bonkBalance.previousRawBalance, 5000000);
  });

  test('multiple token accounts for one mint are summed', () {
    final balances = parseOwnerPostBalances(
      _swapTx(
        owner: owner,
        postTokenBalances: [
          _tokenBalance(owner: owner, mint: usdc, amount: '100'),
          _tokenBalance(
            owner: owner,
            mint: usdc,
            amount: '25',
            accountIndex: 4,
          ),
        ],
      ),
      owner,
    );

    expect(balances.singleWhere((b) => b.mint == usdc).rawBalance, 125);
  });

  test('a failed transaction yields nothing — its post balances describe a '
      'swap that never happened', () {
    final balances = parseOwnerPostBalances(
      _swapTx(
        owner: owner,
        err: {'InstructionError': <dynamic>[]},
        postTokenBalances: [
          _tokenBalance(owner: owner, mint: usdc, amount: '112500000'),
        ],
      ),
      owner,
    );

    expect(balances, isEmpty);
  });

  test('an owner absent from the account keys contributes no SOL row', () {
    final balances = parseOwnerPostBalances(_swapTx(owner: stranger), owner);

    expect(balances.where((b) => b.isNative), isEmpty);
  });

  test('malformed input degrades to nothing rather than throwing', () {
    expect(parseOwnerPostBalances(const {}, owner), isEmpty);
    expect(
      parseOwnerPostBalances(const {'meta': 'unexpected'}, owner),
      isEmpty,
    );
  });
}
