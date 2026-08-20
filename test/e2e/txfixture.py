#!/usr/bin/env python3
"""Deserializable Solana transaction fixtures for E2E tests.

The client never inspects a server-built transaction's contents. The only
structural constraints are:

  * it must decode through `SignedTx.fromBytes`
    (`lib/core/services/transaction_signing.dart`), and
  * the wallet's pubkey must sit in a signer slot, or `place()`
    (`lib/core/crypto/wallet_manager.dart`) throws a `StateError`.

So a fixture only has to be *well-formed*, not semantically real. That is what
makes mint / list / bid / buy / raffle / swap / burn testable against a mock.

Two signature variants exist because `_refreshBlockhashIfSafe`
(`lib/core/services/transaction_signing.dart`) branches on them:

  * `presigned=False` - every signature slot is 64 zero bytes, so the client
    rewrites `recentBlockhash` before signing (blockhash-rewrite branch).
  * `presigned=True`  - a dummy non-zero signature is pre-attached in a
    *non-wallet* slot, so the client signs the bytes as-is (the branch the
    market / raffle staleness checks depend on).

Stdlib only, no pip dependency: base58 and the Solana wire format are
hand-rolled below.
"""

import base64
import hashlib

# --- base58 ---------------------------------------------------------------

B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(data: bytes) -> str:
    """Bitcoin-alphabet base58, leading zero bytes preserved as '1'."""
    pad = 0
    for byte in data:
        if byte != 0:
            break
        pad += 1
    number = int.from_bytes(data, "big")
    out = ""
    while number > 0:
        number, rem = divmod(number, 58)
        out = B58_ALPHABET[rem] + out
    return "1" * pad + out


def b58decode(text: str) -> bytes:
    """Inverse of [b58encode]. Raises ValueError on a non-alphabet char."""
    number = 0
    for char in text:
        number = number * 58 + B58_ALPHABET.index(char)
    pad = 0
    for char in text:
        if char != "1":
            break
        pad += 1
    body = number.to_bytes((number.bit_length() + 7) // 8, "big") if number else b""
    return b"\x00" * pad + body


def compact_u16(value: int) -> bytes:
    """Solana shortvec length prefix."""
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte if value == 0 else byte | 0x80)
        if value == 0:
            return bytes(out)


# --- fixture constants ----------------------------------------------------

# 32 bytes -> a valid base58 blockhash. Built from bytes so it can never drift
# into the wrong length (`copyWith(recentBlockhash:)` re-encodes it verbatim).
DEFAULT_BLOCKHASH = b58encode(bytes(range(1, 33)))

# All-zero pubkey. Deliberately obvious: if a test forgets to set the real
# fee payer, `place()` throws a loud StateError instead of quietly passing.
PLACEHOLDER_FEE_PAYER = b58encode(bytes(32))

# A stand-in co-signer for the presigned variant. Never the wallet.
SERVER_SIGNER = b58encode(bytes([7]) * 32)

# Memo program: a readonly, unsigned account key that makes the single
# instruction well-formed without needing any real accounts.
MEMO_PROGRAM_ID = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"

_INSTRUCTION_DATA = b"mallow-e2e"
_DUMMY_SIGNATURE = bytes([0xAB]) * 64
_ZERO_SIGNATURE = bytes(64)


def build_unsigned_tx(
    fee_payer: str,
    version: str = "legacy",
    presigned: bool = False,
    blockhash: str = DEFAULT_BLOCKHASH,
) -> str:
    """Base64 transaction with [fee_payer] in signer slot 0.

    [version] is "legacy" or "v0" (v0 carries an empty address-table-lookup
    list, so it decodes without fetching any ALT). [presigned] attaches the
    dummy server signature in slot 1 - see the module docstring.
    """
    if version not in ("legacy", "v0"):
        raise ValueError("version must be 'legacy' or 'v0', got %r" % (version,))
    payer = b58decode(fee_payer)
    if len(payer) != 32:
        raise ValueError("fee_payer must be a 32-byte base58 pubkey: %r" % (fee_payer,))

    if presigned:
        # [writable signer payer, readonly signer server, readonly program]
        keys = [payer, b58decode(SERVER_SIGNER), b58decode(MEMO_PROGRAM_ID)]
        header = bytes([2, 1, 1])
        signatures = [_ZERO_SIGNATURE, _DUMMY_SIGNATURE]
    else:
        # [writable signer payer, readonly program]
        keys = [payer, b58decode(MEMO_PROGRAM_ID)]
        header = bytes([1, 0, 1])
        signatures = [_ZERO_SIGNATURE]

    program_index = len(keys) - 1
    instruction = (
        bytes([program_index])
        + compact_u16(0)  # no account indexes
        + compact_u16(len(_INSTRUCTION_DATA))
        + _INSTRUCTION_DATA
    )

    message = bytearray()
    if version == "v0":
        message.append(1 << 7)
    message += header
    message += compact_u16(len(keys))
    for key in keys:
        message += key
    message += b58decode(blockhash)
    message += compact_u16(1) + instruction
    if version == "v0":
        message += compact_u16(0)  # no address table lookups

    tx = bytearray(compact_u16(len(signatures)))
    for signature in signatures:
        tx += signature
    tx += message
    return base64.b64encode(bytes(tx)).decode()


def build_tx_variants(fee_payer: str, blockhash: str = DEFAULT_BLOCKHASH) -> dict:
    """All four fixtures at once, keyed `<version>_<signed|unsigned>`."""
    return {
        "legacy_unsigned": build_unsigned_tx(fee_payer, "legacy", False, blockhash),
        "legacy_presigned": build_unsigned_tx(fee_payer, "legacy", True, blockhash),
        "v0_unsigned": build_unsigned_tx(fee_payer, "v0", False, blockhash),
        "v0_presigned": build_unsigned_tx(fee_payer, "v0", True, blockhash),
    }


def signature_for(tx_base64: str) -> str:
    """A deterministic, plausible 64-byte base58 signature for [tx_base64].

    Deterministic so a rebroadcast of the same bytes yields the same id, the
    way a real cluster behaves.
    """
    first = hashlib.sha256(tx_base64.encode()).digest()
    second = hashlib.sha256(first).digest()
    return b58encode(first + second)
