# jupiter_aggregator

A typed Dart client for [Jupiter](https://dev.jup.ag)'s Solana swap and price
APIs.

It is a path dependency of the mallow wallet app, but it does not depend on the
app and is written to stand alone.

## What it covers

| Client | Covers |
|---|---|
| `JupiterAggregatorClient` | **Ultra** (`/ultra/v1`) — the managed flow: `getOrder` returns a quote plus an unsigned transaction when `taker` is set, `executeOrder` submits the signed transaction for Jupiter to broadcast and confirm |
| `JupiterPriceClient` | **Price** (`/price/v3`) — spot prices for a set of mints, keyed by mint |
| `JupiterSwapInstructionsClient` | **Classic swap** — `getQuote` and `getSwapInstructions`, for building the transaction yourself when you want control over the route |

Requests and responses are modelled rather than untyped maps, so a wire change
surfaces as a parse error at the boundary instead of a null deep inside a
screen.

## Usage

```dart
final jupiter = JupiterAggregatorClient();

final order = await jupiter.getOrder(
  UltraOrderRequestDto(
    inputMint: inputMint,
    outputMint: outputMint,
    amount: rawAmount,
    taker: walletAddress,
  ),
);

// ...sign order.transaction, then:
final result = await jupiter.executeOrder(
  UltraExecuteRequestDto(
    requestId: order.requestId,
    signedTransaction: signedBase64,
  ),
);
```

## Configuration

Every client takes an optional `baseUrl` and `apiKey`. The defaults are
Jupiter's public endpoints under `https://api.jup.ag`; an `apiKey` is sent as
`x-api-key`.

Two of the clients also read a compile-time fallback, used **only** when the
caller passes no `baseUrl`: `--dart-define=QUOTE_API_BASE` for Ultra and
`--dart-define=CLASSIC_SWAP_API_BASE` for classic swap. That is the standalone
path. An application that constructs the clients with an explicit `baseUrl` —
as the wallet does, so all three move together — never reaches either define,
and should configure its own base URL instead.

The public API is rate-limited. For production traffic prefer a proxy that adds
the key server-side over compiling one in — a value compiled into a mobile
binary is recoverable from it. Paths beneath the base URL match Jupiter's own,
so a proxy only has to forward.

## Referral fees

Ultra supports an integrator fee through Jupiter's referral programme. The
referral token accounts must be of the correct programme version, or **the fee
is silently dropped** rather than rejected. Verify against the fee actually
reported on an order rather than assuming it applied.

## Status

A path dependency, not published to pub.dev. If you would find it useful as a
published package, open an issue on the wallet repository.
