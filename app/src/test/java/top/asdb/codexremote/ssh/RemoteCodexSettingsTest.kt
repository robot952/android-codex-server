package top.asdb.codexremote.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import java.util.concurrent.TimeUnit

class RemoteCodexSettingsTest {
    @Test
    fun `base URL accepts HTTP addresses and removes a trailing slash`() {
        assertEquals(
            "https://gateway.example.com/v1",
            RemoteCodexSettings.validateBaseUrl(" https://gateway.example.com/v1/ "),
        )
        assertEquals("", RemoteCodexSettings.validateBaseUrl("  "))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `base URL rejects unsupported schemes`() {
        RemoteCodexSettings.validateBaseUrl("file:///tmp/codex")
    }

    @Test
    fun `generated script has valid POSIX shell syntax`() {
        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use {
            it.write(
                RemoteCodexSettings.writeScript(
                    "https://gateway.example.com/v1",
                    "sk-test",
                    "http://127.0.0.1:7890",
                ),
            )
        }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }

    @Test
    fun `script preserves unrelated config and keeps proxy and key private`() {
        val home = Files.createTempDirectory("codex-remote-settings").toFile()
        try {
            val codexDir = home.resolve(".codex").apply { mkdirs() }
            val config = codexDir.resolve("config.toml")
            config.writeText(
                """
                model = "gpt-test"
                openai_base_url = "https://old.example.com/v1"

                [features]
                web_search = true
                """.trimIndent() + "\n",
            )
            val wrapper = home.resolve(".local/bin/codex-remote")
            requireNotNull(wrapper.parentFile).mkdirs()
            wrapper.writeText(
                """
                #!/bin/sh
                if [ "${'$'}1" = login ] && [ "${'$'}2" = --with-api-key ]; then
                  IFS= read -r key || true
                  printf '%s' "${'$'}key" > "${'$'}HOME/login-key"
                  exit 0
                fi
                exit 64
                """.trimIndent() + "\n",
            )
            assertTrue(wrapper.setExecutable(true))

            val process = ProcessBuilder("sh", "-s")
                .apply { environment()["HOME"] = home.absolutePath }
                .start()
            process.outputStream.bufferedWriter().use {
                it.write(
                    RemoteCodexSettings.writeScript(
                        "https://gateway.example.com/v1/",
                        "sk-private-key",
                        "https://proxy.example.com:8443",
                    ),
                )
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            val stderr = process.errorStream.bufferedReader().readText()
            val stdout = process.inputStream.bufferedReader().readText()
            assertEquals(stderr, 0, process.exitValue())
            assertTrue(stdout.contains("__CODEX_GLOBAL_UPDATED=1"))
            assertFalse(stdout.contains("sk-private-key"))
            assertFalse(stderr.contains("sk-private-key"))

            val updatedConfig = config.readText()
            assertTrue(updatedConfig.contains("model = \"gpt-test\""))
            assertTrue(updatedConfig.contains("model_provider = \"openai\""))
            assertTrue(updatedConfig.contains("openai_base_url = \"https://gateway.example.com/v1\""))
            assertFalse(updatedConfig.contains("https://old.example.com/v1"))
            assertTrue(updatedConfig.contains("[features]\nweb_search = true"))
            assertTrue(updatedConfig.indexOf("model_provider") < updatedConfig.indexOf("[features]"))

            val environment = codexDir.resolve("codex-remote.env")
            val environmentText = environment.readText()
            assertTrue(environmentText.contains("# codex-remote-proxy: https://proxy.example.com:8443"))
            assertTrue(environmentText.contains("export HTTP_PROXY=https://proxy.example.com:8443"))
            assertTrue(environmentText.contains("export https_proxy=https://proxy.example.com:8443"))
            assertEquals(
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                Files.getPosixFilePermissions(environment.toPath()),
            )
            assertEquals("sk-private-key", home.resolve("login-key").readText())
        } finally {
            home.deleteRecursively()
        }
    }
}
