#!/usr/bin/env python3
"""Regenerate offline instruction labels from pinned, hash-checked public sources."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).with_name("public_instruction_sources.json")
OUTPUT = ROOT / "lib/core/services/known_solana_instructions.dart"


def fetch(source, cache):
    digest = source["sha256"]
    path = cache / digest if cache else None
    if path and path.exists():
        raw = path.read_bytes()
    else:
        with urllib.request.urlopen(source["url"], timeout=30) as response:
            raw = response.read()
    if hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError(f"Source hash mismatch: {source['url']}")
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
    return raw


def pascal(name):
    return "".join(part[:1].upper() + part[1:] for part in name.split("_"))


def snake(name):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def literal(argument):
    value = argument["defaultValue"]
    shape = argument["type"]
    if value["kind"] == "numberValueNode":
        if shape["kind"] != "numberTypeNode" or shape["format"] not in ("u8", "u16", "u32", "u64"):
            raise ValueError(f"Unsupported discriminator type: {shape}")
        width = int(shape["format"][1:]) // 8
        endian = {"le": "little", "be": "big"}[shape.get("endian", "le")]
        return value["number"].to_bytes(width, endian)
    if value["kind"] == "bytesValueNode" and value["encoding"] == "base16":
        data = bytes.fromhex(value["data"])
        if shape["kind"] != "fixedSizeTypeNode" or shape["size"] != len(data):
            raise ValueError("Discriminator byte size mismatch")
        return data
    raise ValueError(f"Unsupported discriminator literal: {value}")


def codama(instructions):
    for instruction in instructions:
        prefix = b""
        for argument in instruction["arguments"]:
            if argument.get("defaultValueStrategy") != "omitted":
                break
            # Only leading fixed discriminator fields are labels. Never use
            # a caller-supplied payload field or an optional default as a tag.
            if "discriminator" not in argument["name"].lower():
                break
            prefix += literal(argument)
        if not prefix:
            raise ValueError(f"No fixed prefix: {instruction['name']}")
        yield prefix.hex(), pascal(instruction["name"])
        yield from codama(instruction.get("subInstructions", []))


def idl(document, source):
    origin = document.get("metadata", {}).get("origin", source.get("origin"))
    for instruction in document["instructions"]:
        if "discriminator" in instruction:
            prefix = bytes(instruction["discriminator"])
        elif "discriminant" in instruction:
            tag = instruction["discriminant"]
            if tag["type"] != "u8":
                raise ValueError(f"Unsupported IDL discriminant: {tag}")
            prefix = bytes([tag["value"]])
        elif origin == "anchor":
            # Legacy Anchor IDLs omit the hash; the wire discriminator is
            # SHA256("global:<Rust instruction name>")[:8]. New IDLs carry it.
            rust_name = snake(instruction["name"])
            prefix = hashlib.sha256(f"global:{rust_name}".encode()).digest()[:8]
        else:
            raise ValueError(f"No discriminator: {instruction['name']}")
        yield prefix.hex(), pascal(instruction["name"])


def extract(raw, source):
    if source["format"] == "orca":
        text = raw.decode()
        address = re.search(r'WHIRLPOOL_PROGRAM_ADDRESS\s*=\s*"([^"]+)"', text)[1]
        # Require one complete containsBytes condition. A loose match across
        # the file can accidentally use an account discriminator as an
        # instruction discriminator from a later function.
        pattern = (
            r"new Uint8Array\(\[([\d,\s]+)\]\),\s*\),\s*0,\s*\)\s*\)"
            r"\s*\{\s*return WhirlpoolInstruction\.(\w+);"
        )
        entries = [
            (bytes(int(b.strip()) for b in values.split(",") if b.strip()).hex(), name)
            for values, name in re.findall(pattern, text)
        ]
        if len(entries) != source["instructionCount"]:
            raise ValueError("Orca instruction count mismatch")
    else:
        document = json.loads(raw)
        if source["format"] == "codama":
            program = document["program"]
            address = program["publicKey"]
            entries = list(codama(program["instructions"]))
        else:
            address = document.get("address") or document.get("metadata", {}).get("address")
            entries = list(idl(document, source))
            if address is None and "addressSource" in source:
                address = source["address"]  # Verified against declare_id below.
    if address != source["address"]:
        raise ValueError(f"Program address mismatch for {source['name']}")
    table = {}
    for prefix, name in entries:
        if not re.fullmatch(r"(?:[0-9a-f]{2}){1,16}", prefix):
            raise ValueError(f"Invalid prefix: {prefix}")
        if not re.fullmatch(r"[A-Za-z0-9]{1,64}", name):
            raise ValueError(f"Invalid label: {name}")
        if prefix in table and table[prefix] != name:
            raise ValueError(f"Conflicting labels for {prefix}")
        table[prefix] = name
    if not table:
        raise ValueError(f"Empty table for {source['name']}")
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the checked-in catalog")
    parser.add_argument("--cache-dir", type=Path, help="Cache sources by SHA256 for offline regeneration")
    args = parser.parse_args()
    sources = json.loads(MANIFEST.read_text())["sources"]
    lines = [
        "// Generated by tool/program_labels/generate_public_instructions.py.",
        "// Regenerate instead of editing. Sources are pinned and hash-checked.",
        "// Checked in so transaction reviews can name calls offline at startup.",
        "// Names identify wire prefixes, not validated payloads or effects.",
        "const knownSolanaInstructions = <String, Map<String, String>>{",
    ]
    seen = set()
    count = 0
    for source in sources:
        if source["address"] in seen:
            raise ValueError("Duplicate program in source manifest")
        seen.add(source["address"])
        if "addressSource" in source:
            proof = fetch(source["addressSource"], args.cache_dir).decode()
            declared = re.search(r'declare_id!\("([^"]+)"\)', proof)[1]
            if declared != source["address"]:
                raise ValueError("Program declare_id mismatch")
        table = extract(fetch(source, args.cache_dir), source)
        count += len(table)
        lines.extend([f"  // {source['name']}", f"  // {source['url']}", f"  '{source['address']}': {{"])
        for prefix, name in sorted(table.items()):
            lines.append(f"    '{prefix}': '{name}',")
        lines.append("  },")
    lines.extend(["};", ""])
    with tempfile.TemporaryDirectory() as temp:
        output = Path(temp) / OUTPUT.name
        output.write_text("\n".join(lines))
        subprocess.run(["dart", "format", str(output)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        generated = output.read_text()
    if args.check:
        if OUTPUT.read_text() != generated:
            raise SystemExit("Instruction catalog differs; regenerate it")
    else:
        OUTPUT.write_text(generated)
    print(f"{'Verified' if args.check else 'Generated'} {count} instruction labels across {len(sources)} programs")


if __name__ == "__main__":
    main()
