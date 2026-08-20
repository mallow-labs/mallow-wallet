# shellcheck shell=sh
# dart_defines.sh — the ONE definition of the E2E --dart-define set.
#
# Sourced by every entry point that runs the suite:
#   - test/e2e/lib.sh                (e2e::run_flutter_test -> run_e2e.sh, run_one.sh)
#   - any CI e2e job you add
#
# It used to be hand-mirrored in those two places. A define that exists locally
# but not in CI is a test that passes here and fails there, so it lives here
# instead and neither copy can drift.
#
# POSIX sh on purpose, so a plain /bin/sh (dash) can source it. No arrays,
# no [[ ]].
#
# Usage — source it, then expand UNQUOTED; it is a flag list, not one argument:
#
#   . ./test/e2e/dart_defines.sh
#   flutter test integration_test/ -d emulator-5554 $E2E_DART_DEFINES
#
# MOCK_PORT must be set before sourcing (both callers set it), so the port is
# still resolved at use time rather than baked in here.

: "${MOCK_PORT:?dart_defines.sh: MOCK_PORT must be set before sourcing}"

# 10.0.2.2 is the emulator's alias for the host loopback, where the mock runs.
E2E_MOCK_URL="http://10.0.2.2:$MOCK_PORT"

# E2E_DISABLE_GL routes the welcome screen's three_js ring to its non-GL
# fallback (flutter_angle hard-crashes on the emulator's software GL).
#
# ETH_RPC_URL / TEZOS_RPC_URL are pointed at the mock for containment, not for
# service: Config.ethereumRpcUrl and Config.tezosRpcUrl otherwise fall back to
# LIVE mainnet nodes (https://ethereum-rpc.publicnode.com, https://rpc.tzkt.io/
# mainnet), so every post-onboarding case fired real JSON-RPC over the internet
# — slow and nondeterministic. The mock speaks no JSON-RPC on these paths; a
# fast local 404 the app's error handling already swallows is the point.
#
# EVM_SIMULATION_URL / EVM_GAS_API_URL are pointed at the same mock for the same
# reason. They have no Dart default, so leaving them out is not neutral: the
# request never leaves the app and the failure reads as a missing build var
# rather than as the unreachable endpoint these cases are meant to exercise.
#
# IMAGE_CDN_BASE_URL / AVATAR_SERVICE_URL are containment too: unset, image and
# avatar loads go straight to the asset's own origin and to DiceBear's public
# API, which is real network traffic from a suite that promises to be offline.
#
# The last five are the rest of that promise. Each getter below defaults to a
# LIVE third-party host, so every one of them was real traffic leaving a
# contributor's machine:
#
#   JUPITER_BASE_URL        api.jup.ag      — the one that actually fired.
#                           TokenRepository does `nativePricePerSol ??
#                           _fetchSolPrice()` on the balances path, so any
#                           scenario with a native balance and no price in its
#                           searchAssets body asks Jupiter for the SOL price.
#                           The same host also serves token search, the
#                           verified-token list, token info, and all three
#                           swap clients — di_module passes this one base URL
#                           to every Jupiter client for exactly this reason.
#   COINGECKO_BASE_URL      api.coingecko.com — token-detail price charts.
#   SOLANA_MAINNET_RPC_URL  api.mainnet-beta.solana.com — pinned to mainnet
#                           independently of ENV: `.sol` name resolution
#                           (SnsResolver) and SolanaRpcService.mainnet. Points
#                           at the mock ROOT because it speaks JSON-RPC, which
#                           the mock dispatches on the body's `method`.
#   IPFS_GATEWAY_URL        ipfs.io    — asset fallback ladder.
#   ARWEAVE_GATEWAY_URL     arweave.net — same ladder, Arweave half.
#
# The two gateways answer 404 from the default fixture: they are byte fetches
# for media, and a fast local miss is what the app's fallback already handles.
# The Jupiter and CoinGecko paths answer correctly-SHAPED empty bodies (see
# fixtures/default/routes.json) — an empty price map is "unpriced", which is a
# state the app renders, while a wrong-shaped body is an error view a careless
# test reads as "empty".
#
# ENV=development is deliberate and still correct after ENV's default flipped
# to `production`: it keeps `isDevnet` true, so the suite never builds an app
# that believes it is production. What it switches is inert here — the mock
# ignores the `?network=devnet` the RPC URL picks up (JSON-RPC dispatches on
# the body), WEB3AUTH_CLIENT_ID is unset so `sapphire_devnet` is never used,
# and ASSET_CDN_BASE_URL is unset so the store CDN is empty either way.
# shellcheck disable=SC2034  # consumed by the sourcing script, not by this one
E2E_DART_DEFINES="\
--dart-define=ENV=development \
--dart-define=E2E_DISABLE_GL=true \
--dart-define=API_BASE_URL=$E2E_MOCK_URL \
--dart-define=API_V2_BASE_URL=$E2E_MOCK_URL/v2 \
--dart-define=RPC_PROXY_BASE_URL=$E2E_MOCK_URL \
--dart-define=ETH_RPC_URL=$E2E_MOCK_URL \
--dart-define=TEZOS_RPC_URL=$E2E_MOCK_URL \
--dart-define=EVM_SIMULATION_URL=$E2E_MOCK_URL/alchemy \
--dart-define=EVM_GAS_API_URL=$E2E_MOCK_URL/infura/gas \
--dart-define=IMAGE_CDN_BASE_URL=$E2E_MOCK_URL/img \
--dart-define=AVATAR_SERVICE_URL=$E2E_MOCK_URL/avatar \
--dart-define=JUPITER_BASE_URL=$E2E_MOCK_URL/jupiter \
--dart-define=COINGECKO_BASE_URL=$E2E_MOCK_URL/coingecko \
--dart-define=SOLANA_MAINNET_RPC_URL=$E2E_MOCK_URL \
--dart-define=IPFS_GATEWAY_URL=$E2E_MOCK_URL/ipfs-gateway \
--dart-define=ARWEAVE_GATEWAY_URL=$E2E_MOCK_URL/arweave-gateway"
