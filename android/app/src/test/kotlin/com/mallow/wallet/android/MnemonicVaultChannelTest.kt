package com.mallow.wallet.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class MnemonicVaultChannelTest {
    @Test
    fun `eraseVaultEntry deletes the keystore alias before committing preferences`() {
        val calls = mutableListOf<String>()

        eraseVaultEntry(
            eraseKeystoreAlias = { calls.add("keystore") },
            eraseCiphertext = {
                calls.add("preferences")
                true
            },
        )

        assertEquals(listOf("keystore", "preferences"), calls)
    }

    @Test
    fun `eraseVaultEntry surfaces a keystore deletion failure without touching preferences`() {
        var preferencesTouched = false

        assertThrows(IllegalStateException::class.java) {
            eraseVaultEntry(
                eraseKeystoreAlias = { error("keystore refused deletion") },
                eraseCiphertext = {
                    preferencesTouched = true
                    true
                },
            )
        }

        assertFalse(preferencesTouched)
    }

    @Test
    fun `eraseVaultEntry surfaces a failed preferences commit`() {
        assertThrows(IllegalStateException::class.java) {
            eraseVaultEntry(
                eraseKeystoreAlias = {},
                eraseCiphertext = { false },
            )
        }
    }
}
