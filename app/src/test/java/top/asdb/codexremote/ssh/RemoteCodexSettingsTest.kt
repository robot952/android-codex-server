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
    fun `model list script has valid POSIX shell syntax`() {
        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use {
            it.write(
                RemoteCodexSettings.modelListScript(
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
    fun `parses compatible API model limits`() {
        val response = """
            {"data":[
              {"id":"gpt-large","display_name":"GPT Large","context_length":128000,"max_output_tokens":16000},
              {"id":"gpt-small","context_window":"32000","top_provider":{"max_completion_tokens":4096}}
            ]}
        """.trimIndent()
        val encoded = java.util.Base64.getEncoder().encodeToString(response.toByteArray())

        val models = RemoteCodexSettings.parseApiModels(
            listOf(
                "__CODEX_API_MODEL_LIST_STATUS=SUCCESS",
                "__CODEX_API_MODEL_LIST_HTTP_STATUS=200",
                "__CODEX_API_MODEL_LIST_DATA=$encoded",
            ),
        )

        assertEquals(listOf("gpt-large", "gpt-small"), models.map { it.modelId })
        assertEquals(128_000, models[0].contextWindowTokens)
        assertEquals(16_000, models[0].maxOutputTokens)
        assertEquals(32_000, models[1].contextWindowTokens)
        assertEquals(4_096, models[1].maxOutputTokens)
    }

    @Test
    fun `includes curl exit code in model list network errors`() {
        val error = runCatching {
            RemoteCodexSettings.parseApiModels(
                listOf(
                    "__CODEX_API_MODEL_LIST_STATUS=NETWORK_ERROR",
                    "__CODEX_API_MODEL_LIST_CURL_EXIT=6",
                ),
            )
        }.exceptionOrNull()

        assertTrue(error?.message?.contains("curl exit 6") == true)
    }

    @Test
    fun `model list script emits a short final base64 chunk`() {
        val home = Files.createTempDirectory("codex-remote-model-list").toFile()
        try {
            val bin = home.resolve("bin").apply { mkdirs() }
            val curl = bin.resolve("curl")
            curl.writeText(
                """
                #!/bin/sh
                body_file=
                while [ "${'$'}#" -gt 0 ]; do
                  case "${'$'}1" in
                    --output)
                      body_file="${'$'}2"
                      shift 2
                      ;;
                    *) shift ;;
                  esac
                done
                [ -n "${'$'}body_file" ] || exit 91
                printf '%s' '{"data":[{"id":"gpt-short"}]}' > "${'$'}body_file"
                printf '200'
                """.trimIndent() + "\n",
            )
            assertTrue(curl.setExecutable(true))

            val process = ProcessBuilder("sh", "-s")
                .apply {
                    environment()["HOME"] = home.absolutePath
                    environment()["PATH"] = listOf(bin.absolutePath, System.getenv("PATH").orEmpty())
                        .joinToString(":")
                }
                .start()
            process.outputStream.bufferedWriter().use {
                it.write(
                    RemoteCodexSettings.modelListScript(
                        "https://gateway.example.com/v1",
                        "sk-short-response",
                        "",
                    ),
                )
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            val models = RemoteCodexSettings.parseApiModels(process.inputStream.bufferedReader().readLines())
            assertEquals(listOf("gpt-short"), models.map { it.modelId })
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `model list script retries one transient network failure`() {
        val home = Files.createTempDirectory("codex-remote-model-list-retry").toFile()
        try {
            val bin = home.resolve("bin").apply { mkdirs() }
            val curl = bin.resolve("curl")
            curl.writeText(
                """
                #!/bin/sh
                attempts_file="${'$'}HOME/curl-attempts"
                attempts=0
                if [ -r "${'$'}attempts_file" ]; then attempts="${'$'}(cat "${'$'}attempts_file")"; fi
                attempts=${'$'}((attempts + 1))
                printf '%s' "${'$'}attempts" > "${'$'}attempts_file"
                if [ "${'$'}attempts" -eq 1 ]; then exit 28; fi
                body_file=
                while [ "${'$'}#" -gt 0 ]; do
                  case "${'$'}1" in
                    --output)
                      body_file="${'$'}2"
                      shift 2
                      ;;
                    *) shift ;;
                  esac
                done
                [ -n "${'$'}body_file" ] || exit 91
                printf '%s' '{"data":[{"id":"gpt-retried"}]}' > "${'$'}body_file"
                printf '200'
                """.trimIndent() + "\n",
            )
            assertTrue(curl.setExecutable(true))

            val process = ProcessBuilder("sh", "-s")
                .apply {
                    environment()["HOME"] = home.absolutePath
                    environment()["PATH"] = listOf(bin.absolutePath, System.getenv("PATH").orEmpty())
                        .joinToString(":")
                }
                .start()
            process.outputStream.bufferedWriter().use {
                it.write(
                    RemoteCodexSettings.modelListScript(
                        "https://gateway.example.com/v1",
                        "sk-retry-response",
                        "",
                    ),
                )
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            val models = RemoteCodexSettings.parseApiModels(process.inputStream.bufferedReader().readLines())
            assertEquals(listOf("gpt-retried"), models.map { it.modelId })
            assertEquals("2", home.resolve("curl-attempts").readText())
        } finally {
            home.deleteRecursively()
        }
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
                model_reasoning_effort = "high"
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
            assertEquals("high", settings.reasoningEffort)
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
                grep -Fqx '{"model":"gpt-test","input":"ping"}' "${'$'}body_file" || exit 97
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
            assertTrue(stdout.contains("__CODEX_CONNECTION_TEST_API=responses"))
            assertFalse(stdout.contains("sk-test-connection"))
            assertFalse(stderr.contains("sk-test-connection"))
            val result = RemoteCodexSettings.parseConnectionTest(stdout.lineSequence().toList())
            assertTrue(result.successful)
            assertTrue(result.message.contains("gpt-test"))
            assertTrue(result.message.contains("Responses"))
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `connection test requires a model and targets compatible APIs`() {
        val script = RemoteCodexSettings.testConnectionScript(
            "https://gateway.example.com/v1",
            "sk-test",
            "",
            "",
        )

        assertTrue(script.contains("/responses"))
        assertTrue(script.contains("/chat/completions"))
        assertFalse(script.contains("max_output_tokens"))
        assertFalse(script.contains("max_tokens"))
        assertFalse(
            RemoteCodexSettings.parseConnectionTest(
                listOf("__CODEX_CONNECTION_TEST_STATUS=MISSING_TEST_MODEL"),
            ).successful,
        )
    }

    @Test
    fun `connection test falls back to Chat Completions when Responses is unavailable`() {
        val home = Files.createTempDirectory("codex-remote-test-chat-fallback").toFile()
        try {
            val bin = home.resolve("bin").apply { mkdirs() }
            val curl = bin.resolve("curl")
            curl.writeText(
                """
                #!/bin/sh
                endpoint=
                header_file=
                body_file=
                for argument in "${'$'}@"; do
                  case "${'$'}argument" in
                    https://*) endpoint="${'$'}argument" ;;
                    @*)
                      candidate="${'$'}{argument#@}"
                      if grep -Fqx 'Authorization: Bearer sk-chat-fallback' "${'$'}candidate"; then
                        header_file="${'$'}candidate"
                      else
                        body_file="${'$'}candidate"
                      fi
                      ;;
                  esac
                done
                [ -n "${'$'}header_file" ] || exit 91
                [ -n "${'$'}body_file" ] || exit 92
                case "${'$'}endpoint" in
                  */responses)
                    grep -Fqx '{"model":"gpt-chat","input":"ping"}' "${'$'}body_file" || exit 93
                    printf '404'
                    ;;
                  */chat/completions)
                    grep -Fqx '{"model":"gpt-chat","messages":[{"role":"user","content":"ping"}]}' "${'$'}body_file" || exit 94
                    printf '200'
                    ;;
                  *) exit 95 ;;
                esac
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
                        "sk-chat-fallback",
                        "",
                        "gpt-chat",
                    ),
                )
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            val stdout = process.inputStream.bufferedReader().readText()
            val stderr = process.errorStream.bufferedReader().readText()
            assertEquals(stderr, 0, process.exitValue())
            assertTrue(stdout.contains("__CODEX_CONNECTION_TEST_STATUS=SUCCESS"))
            assertTrue(stdout.contains("__CODEX_CONNECTION_TEST_API=chat/completions"))
            val result = RemoteCodexSettings.parseConnectionTest(stdout.lineSequence().toList())
            assertTrue(result.successful)
            assertTrue(result.message.contains("Chat Completions"))
        } finally {
            home.deleteRecursively()
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun `test model rejects whitespace and shell-like input`() {
        RemoteCodexSettings.normalizeTestModel("gpt-test; rm")
    }

    @Test
    fun `default reasoning effort accepts supported Codex values`() {
        assertEquals("", RemoteCodexSettings.normalizeDefaultReasoningEffort("  "))
        assertEquals("minimal", RemoteCodexSettings.normalizeDefaultReasoningEffort("minimal"))
        assertEquals("xhigh", RemoteCodexSettings.normalizeDefaultReasoningEffort(" XHIGH "))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `default reasoning effort rejects unsupported values`() {
        RemoteCodexSettings.normalizeDefaultReasoningEffort("maximum")
    }

    @Test
    fun `script updates defaults while preserving an unchanged custom provider`() {
        val home = Files.createTempDirectory("codex-remote-preserve-provider").toFile()
        try {
            val codexDir = home.resolve(".codex").apply { mkdirs() }
            val config = codexDir.resolve("config.toml")
            config.writeText(
                """
                model = "gpt-5.4"
                model_reasoning_effort = "low"
                model_provider = "relay"

                [model_providers.relay]
                base_url = "https://relay.example.com/v1"

                [features]
                web_search = true
                """.trimIndent() + "\n",
            )

            val process = ProcessBuilder("sh", "-s")
                .apply { environment()["HOME"] = home.absolutePath }
                .start()
            process.outputStream.bufferedWriter().use {
                it.write(
                    RemoteCodexSettings.writeScript(
                        baseUrl = "https://relay.example.com/v1",
                        apiKey = "",
                        proxyUrl = "",
                        defaultModel = "gpt-5.6-sol",
                        defaultReasoningEffort = "xhigh",
                        preserveCurrentProvider = true,
                    ),
                )
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            val updatedConfig = config.readText()
            assertTrue(updatedConfig.contains("model = \"gpt-5.6-sol\""))
            assertTrue(updatedConfig.contains("model_reasoning_effort = \"xhigh\""))
            assertTrue(updatedConfig.contains("model_provider = \"relay\""))
            assertFalse(updatedConfig.contains("model_provider = \"openai\""))
            assertTrue(updatedConfig.contains("[model_providers.relay]"))
            assertTrue(updatedConfig.contains("[features]\nweb_search = true"))

            val clearProcess = ProcessBuilder("sh", "-s")
                .apply { environment()["HOME"] = home.absolutePath }
                .start()
            clearProcess.outputStream.bufferedWriter().use {
                it.write(
                    RemoteCodexSettings.writeScript(
                        baseUrl = "https://relay.example.com/v1",
                        apiKey = "",
                        proxyUrl = "",
                        defaultModel = "",
                        defaultReasoningEffort = "",
                        preserveCurrentProvider = true,
                    ),
                )
            }

            assertTrue(clearProcess.waitFor(5, TimeUnit.SECONDS))
            assertEquals(clearProcess.errorStream.bufferedReader().readText(), 0, clearProcess.exitValue())
            val clearedConfig = config.readText().lineSequence().map(String::trim).toList()
            assertFalse(clearedConfig.any { it.startsWith("model =") })
            assertFalse(clearedConfig.any { it.startsWith("model_reasoning_effort =") })
            assertTrue(clearedConfig.contains("model_provider = \"relay\""))
        } finally {
            home.deleteRecursively()
        }
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
