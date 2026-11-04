import json
import unittest

import generate_public_instructions as generator


def tag(name, number, strategy="omitted"):
    return {
        "name": name,
        "type": {"kind": "numberTypeNode", "format": "u8", "endian": "le"},
        "defaultValue": {"kind": "numberValueNode", "number": number},
        "defaultValueStrategy": strategy,
    }


class PublicInstructionGeneratorTest(unittest.TestCase):
    def test_codama_keeps_variant_but_excludes_optional_payload_defaults(self):
        instruction = {
            "name": "delegateStakingV1",
            "arguments": [
                tag("discriminator", 44),
                tag("delegateStakingV1Discriminator", 5),
                tag("amount", 1, "optional"),
            ],
        }
        self.assertEqual(list(generator.codama([instruction])), [("2c05", "DelegateStakingV1")])

    def test_codama_missing_fixed_prefix_fails(self):
        with self.assertRaisesRegex(ValueError, "No fixed prefix"):
            list(generator.codama([{"name": "guess", "arguments": [tag("amount", 1)]}]))

    def test_anchor_legacy_route_hash_matches_public_wire_discriminator(self):
        document = {"instructions": [{"name": "route"}]}
        self.assertEqual(list(generator.idl(document, {"origin": "anchor"})), [("e517cb977ae3ad2a", "Route")])

    def test_orca_account_discriminators_cannot_name_instructions(self):
        source = {"format": "orca", "address": "Whirlpool", "instructionCount": 1}
        text = '''
        export const WHIRLPOOL_PROGRAM_ADDRESS = "Whirlpool";
        if (containsBytes(data, fixEncoderSize(getBytesEncoder(), 8).encode(
            new Uint8Array([147, 16, 144, 116, 47, 146, 149, 46]),
        ), 0,)) { return WhirlpoolAccount.Whirlpool; }
        if (containsBytes(data, fixEncoderSize(getBytesEncoder(), 8).encode(
            new Uint8Array([41, 36, 216, 245, 27, 85, 103, 67]),
        ), 0,)) { return WhirlpoolInstruction.CloseBundledPosition; }
        '''
        self.assertEqual(generator.extract(text.encode(), source), {"2924d8f51b556743": "CloseBundledPosition"})

    def test_source_program_address_must_match_manifest(self):
        document = {"address": "Other", "instructions": []}
        with self.assertRaisesRegex(ValueError, "Program address mismatch"):
            generator.extract(json.dumps(document).encode(), {"format": "idl", "address": "Expected", "name": "Program"})

    def test_conflicting_discriminators_fail_instead_of_silently_overwriting(self):
        document = {
            "address": "Program",
            "instructions": [
                {"name": "first", "discriminator": [1]},
                {"name": "second", "discriminator": [1]},
            ],
        }
        with self.assertRaisesRegex(ValueError, "Conflicting labels"):
            generator.extract(json.dumps(document).encode(), {"format": "idl", "address": "Program", "name": "Program"})


if __name__ == "__main__":
    unittest.main()
