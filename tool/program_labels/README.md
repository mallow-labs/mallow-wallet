# Public instruction labels

The offline catalog names Solana instruction data using public program definitions.
`public_instruction_sources.json` pins each source URL and SHA256, plus the program
address it must declare. Sources are official IDLs, Codama trees, or the generated
Orca instruction identifier. Names describe wire prefixes; they do not validate
instruction payloads or establish transaction effects.

Regenerate the catalog after reviewing a source change:

```sh
python3 tool/program_labels/generate_public_instructions.py
```

Use `--check` to verify the checked-in catalog without changing it. Both commands
fetch the pinned sources; `--cache-dir <directory>` caches them by content hash
and allows subsequent offline regeneration. The Dart SDK formats the output.
No network fetch or generation is needed when the app builds or starts.

Codama labels include leading fixed variant fields, so pNFT and Token-2022
instructions can have two-byte discriminators. Modern Anchor IDLs provide the
discriminator directly; legacy Anchor IDLs use the first eight bytes of
SHA256(`global:<snake_case_instruction_name>`). Program addresses come from the
same source, with Jupiter checked against its Rust `declare_id!`.

Unknown tags remain unnamed. The catalog has no catch-all entries. In particular,
the Bubblegum V2 table belongs only to its declared program address; it is not
copied to the older Bubblegum deployment. Program upgrades can introduce further
tags, which can also be supplied by the fetched program-label list.
