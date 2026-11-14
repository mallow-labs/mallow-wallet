"""Independent reference generator for social vault v1 test vectors.

Written against Python's `cryptography` and `hashlib` only, so the vectors do
not come from either implementation they test (Dart, TypeScript).
"""

import base64
import hashlib
import hmac
import json
import sys
import unicodedata

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PREFIX = "mallow-social-vault/v1"


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def hkdf(ikm: bytes, salt: bytes, info: str) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info.encode()).derive(ikm)


def seq(start: int, n: int) -> bytes:
    return bytes((start + i) & 0xFF for i in range(n))


def pubkey(seed: bytes) -> bytes:
    return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


# --- base58 / SLIP-10 for derivation vectors -------------------------------
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58(b: bytes) -> str:
    n = int.from_bytes(b, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    pad = len(b) - len(b.lstrip(b"\0"))
    return "1" * pad + out


def b58check(b: bytes) -> str:
    return b58(b + hashlib.sha256(hashlib.sha256(b).digest()).digest()[:4])


def tz1(pub: bytes) -> str:
    return b58check(bytes([6, 161, 159]) + hashlib.blake2b(pub, digest_size=20).digest())


def bip39_seed(mnemonic: str) -> bytes:
    m = unicodedata.normalize("NFKD", mnemonic)
    return hashlib.pbkdf2_hmac("sha512", m.encode(), b"mnemonic", 2048)


def slip10_ed25519(seed: bytes, path: list) -> bytes:
    i = hmac.new(b"ed25519 seed", seed, hashlib.sha512).digest()
    k, c = i[:32], i[32:]
    for idx in path:
        data = b"\0" + k + (idx | 0x80000000).to_bytes(4, "big")
        i = hmac.new(c, data, hashlib.sha512).digest()
        k, c = i[:32], i[32:]
    return k


def main() -> None:
    vault_id = seq(0x10, 16)
    vault_id_s = b64u(vault_id)
    data_key = seq(0x40, 32)

    # Payloads ---------------------------------------------------------------
    # A payload is always a BIP39 phrase: `bip39` is the only kind in v1.
    mnemonic = "abandon " * 11 + "about"
    payloads = [
        ("bip39", json.dumps({"v": 1, "kind": "bip39", "mnemonic": mnemonic}, separators=(",", ":"))),
    ]
    payload_vectors = []
    for i, (name, pjson) in enumerate(payloads):
        nonce = seq(0xA0 + i, 12)
        aad = f"{PREFIX}/payload/{vault_id_s}"
        ct = AESGCM(data_key).encrypt(nonce, pjson.encode(), aad.encode())
        payload_vectors.append(
            {
                "name": name,
                "vaultId": vault_id_s,
                "dataKeyHex": data_key.hex(),
                "nonce": b64u(nonce),
                "aad": aad,
                "payloadJson": pjson,
                "ciphertext": b64u(ct),
            }
        )

    # Slots ------------------------------------------------------------------
    slot_vectors = []
    for i, kind in enumerate(["passkey-prf", "platform"]):
        slot_id = seq(0x60 + 16 * i, 16)
        slot_id_s = b64u(slot_id)
        secret = seq(0x80 + 32 * i, 32)
        info = f"{PREFIX}/kek/{kind}"
        kek = hkdf(secret, vault_id, info)
        nonce = seq(0xC0 + i, 12)
        aad = f"{PREFIX}/slot/{vault_id_s}/{slot_id_s}"
        wrapped = AESGCM(kek).encrypt(nonce, data_key, aad.encode())
        slot_vectors.append(
            {
                "kind": kind,
                "vaultId": vault_id_s,
                "slotId": slot_id_s,
                "slotSecretHex": secret.hex(),
                "kekInfo": info,
                "kekHex": kek.hex(),
                "dataKeyHex": data_key.hex(),
                "nonce": b64u(nonce),
                "aad": aad,
                "wrappedKey": b64u(wrapped),
            }
        )

    # vault key + request signature -----------------------------------------
    auth_seed = hkdf(data_key, vault_id, f"{PREFIX}/auth")
    auth_pub = pubkey(auth_seed)
    body = json.dumps({"slotId": slot_vectors[0]["slotId"]}, separators=(",", ":"))
    message = "\n".join(
        [
            f"{PREFIX}/request",
            "POST",
            "/v2/social-vault/slots/remove",
            vault_id_s,
            "7",
            hashlib.sha256(body.encode()).hexdigest(),
            "1762646400",
        ]
    )
    sig = Ed25519PrivateKey.from_private_bytes(auth_seed).sign(message.encode())
    vault_key = {
        "vaultId": vault_id_s,
        "dataKeyHex": data_key.hex(),
        "info": f"{PREFIX}/auth",
        "seedHex": auth_seed.hex(),
        "publicKey": b64u(auth_pub),
        "request": {
            "method": "POST",
            "path": "/v2/social-vault/slots/remove",
            "revision": 7,
            "body": body,
            "timestamp": 1762646400,
        },
        "message": message,
        "signature": b64u(sig),
    }

    # Derivation -------------------------------------------------------------
    seed = bip39_seed(mnemonic)
    sol = pubkey(slip10_ed25519(seed, [44, 501, 0, 0]))
    tez = pubkey(slip10_ed25519(seed, [44, 1729, 0, 0]))
    derivation = {
        "bip39": {
            "mnemonic": mnemonic,
            "solana": b58(sol),
            "solanaPath": "m/44'/501'/0'/0'",
            # Keccak is not in hashlib; this is the published BIP44 vector for
            # this mnemonic, checked against MultiChainDerivation in Dart.
            "ethereum": "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
            "ethereumPath": "m/44'/60'/0'/0/0",
            "tezos": tz1(tez),
            "tezosPath": "m/44'/1729'/0'/0'",
        },
    }

    # A payload whose phrase is not in its one spelling ----------------------
    # Another client may seal a phrase with stray white space or capitals.
    # Every reader must bring it to the same spelling before deriving keys,
    # or the same vault opens to a wallet on one client and fails on another.
    raw = "  Abandon  abandon\tabandon\nabandon abandon abandon abandon abandon abandon abandon abandon   ABOUT \n"
    assert " ".join(raw.strip().lower().split()) == mnemonic
    nc_json = json.dumps({"v": 1, "kind": "bip39", "mnemonic": raw}, separators=(",", ":"))
    nc_nonce = seq(0xB0, 12)
    nc_aad = f"{PREFIX}/payload/{vault_id_s}"
    non_canonical = [
        {
            "name": "bip39 with stray white space and capitals",
            "vaultId": vault_id_s,
            "dataKeyHex": data_key.hex(),
            "nonce": b64u(nc_nonce),
            "aad": nc_aad,
            "payloadJson": nc_json,
            "ciphertext": b64u(AESGCM(data_key).encrypt(nc_nonce, nc_json.encode(), nc_aad.encode())),
            "normalizedMnemonic": mnemonic,
            "solana": derivation["bip39"]["solana"],
            "ethereum": derivation["bip39"]["ethereum"],
            "tezos": derivation["bip39"]["tezos"],
        }
    ]

    # Negative cases: each must fail to open --------------------------------
    p0 = payload_vectors[0]
    s0 = slot_vectors[0]
    other_vault = b64u(seq(0x11, 16))
    negative = [
        {"case": "payload under another vault id", "target": "payload", "vaultId": other_vault, "from": "bip39"},
        {"case": "slot under another slot id", "target": "slot", "slotId": b64u(seq(0x61, 16)), "from": "passkey-prf"},
        {"case": "slot unwrapped as the other kind", "target": "slot", "kind": "platform", "from": "passkey-prf"},
    ]

    out = {
        "format": "mallow-social-vault/v1",
        "note": "Generated by an independent Python reference. Binary fields on the wire are base64url without padding; *Hex fields are test inputs.",
        "payload": payload_vectors,
        "slots": slot_vectors,
        "vaultKey": vault_key,
        "derivation": derivation,
        "negative": negative,
        "nonCanonicalPayload": non_canonical,
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
