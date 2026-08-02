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
    fun `read script has valid POSIX shell syntax`() {
        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use { it.write(RemoteCodexSettings.readScript) }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }

    @Test
    fun `read script reports the active custom provider configuration`() {
        val home = Files.createTempDirectory("codex-remote-read-settings").toFile()
        try {
            val codexDir = home.resolve(".codex").apply { mkdirs() }
            codexDir.resolve("config.toml").writeText(
                """
                model = "gpt-5.4"
                model_provider = "relay"

                [model_providers.relay]
                base_url = "https://relay.example.com/v1"
                env_key = "OPENAI_API_KEY"
                """.trimIndent() + "\n",
            )
            codexDir.resolve("codex-remote.env").writeText(
                "# codex-remote-proxy: http://127.0.0.1:7890\n",
            )
            codexDir.resolve("auth.json").writeText("{\"tokens\":{}}\n")

            val process = ProcessBuilder("sh", "-s")
                .apply { environment()["HOME"] = home.absolutePath }
                .start()
            process.outputStream.bufferedWriter().use { it.write(RemoteCodexSettings.readScript) }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            val settings = RemoteCodexSettings.parse(process.inputStream.bufferedReader().readLines())
            assertEquals("relay", settings.modelProvider)
            assertEquals("gpt-5.4", settings.model)
            assertEquals("https://relay.example.com/v1", settings.baseUrl)
            assertEquals("http://127.0.0.1:7890", settings.proxyUrl)
            assertTrue(settings.hasStoredAuthentication)
            assertEquals("", settings.apiKey)
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `read script returns API key authentication for the settings page`() {
        val home = Files.createTempDirectory("codex-remote-read-api-key").toFile()
        try {
            val codexDir = home.resolve(".codex").apply { mkdirs() }
            codexDir.resolve("auth.json").writeText("{\"OPENAI_API_KEY\":\"sk-visible-test-key\"}\n")

            val process = ProcessBuilder("sh", "-s")
                .apply { environment()["HOME"] = home.absolutePath }
                .start()
            process.outputStream.bufferedWriter().use { it.write(RemoteCodexSettings.readScript) }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            val settings = RemoteCodexSettings.parse(process.inputStream.bufferedReader().readLines())
            assertTrue(settings.hasStoredAuthentication)
            assertEquals("sk-visible-test-key", settings.apiKey)
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `connection test keeps API key out of command arguments and reports success`() {
        val home = Files.createTempDirectory("codex-remote-test-connection").toFile()
        try {
            val bin = home.resolve("bin").apply { mkdirs() }
            val curl = bin.resolve("curl")
            curl.writeText(
                """
                #!/bin/sh
                header_file=
                body_file=
                for argument in "${'$'}@"; do
                  case "${'$'}argument" in
                    @*)
                      candidate="${'$'}{argument#@}"
                      if grep -Fqx 'Authorization: Bearer sk-test-connection' "${'$'}candidate"; then
                        header_file="${'$'}candidate"
                      else
                        body_file="${'$'}candidate"
                      fi
                      ;;
                    *sk-test-connection*) exit 91 ;;
                  esac
                done
                [ -n "${'$'}header_file" ] || exit 92
                [ -n "${'$'}body_file" ] || exit 95
                [ "${'$'}(stat -c '%a' "${'$'}header_file")" = 600 ] || exit 93
                [ "${'$'}(stat -c '%a' "${'$'}body_file")" = 600 ] || exit 96
                grep -Fqx 'Authorization: Bearer sk-test-connection' "${'$'}header_file" || exit 94
                grep -Fqx '{"model":"gpt-test","input":"ping","max_output_tokens":1}' "${'$'}body_file" || exit 97
                printf '204'
                """.trimIndent() + "\n",
            )
            assertTrue(curl.setExecutable(true))

            val process = ProcessBuilder("sh", "-s")
                .apply {
                    environment()["HOME"] = home.absolutePath
                    environment()["PATH"] = listOf(bin.absolutePath, System.getenv("PATH").orEmpty()).joinToString(":")
                }
                .start()
            process.outputStream.bufferedWriter().use {
                it.write(
                    RemoteCodexSettings.testConnectionScript(
                        "https://gateway.example.com/v1",
                        "sk-test-connection",
                        "",
                        "gpt-test",
                    ),
                )
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            val stdout = process.inputStream.bufferedReader().readText()
            val stderr = process.errorStream.bufferedReader().readText()
            assertEquals(stderr, 0, process.exitValue())
            assertTrue(stdout.contains("__CODEX_CONNECTION_TEST_STATUS=SUCCESS"))
            assertFalse(stdout.contains("sk-test-connection"))
            assertFalse(stderr.contains("sk-test-connection"))
            val result = RemoteCodexSettings.parseConnectionTest(stdout.lineSequence().toList())
            assertTrue(result.successful)
            assertTrue(result.message.contains("gpt-test"))
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `connection test requires a model and targets Responses API`() {
        val script = RemoteCodexSettings.testConnectionScript(
            "https://gateway.example.com/v1",
            "sk-test",
            "",
            "",
        )

        assertTrue(script.contains("/responses"))
        assertTrue(script.contains("max_output_tokens"))
        assertFalse(
            RemoteCodexSettings.parseConnectionTest(
                listOf("__CODEX_CONNECTION_TEST_STATUS=MISSING_TEST_MODEL"),
            ).successful,
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `test model rejects whitespace and shell-like input`() {
        RemoteCodexSettings.normalizeTestModel("gpt-test; rm")
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
