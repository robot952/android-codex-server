package top.asdb.agent

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalLinuxManagerTest {
    @Test
    fun aptSourcesPreferAliyunAndKeepOfficialFallback() {
        val aliyun = debianAptSources(DebianAptMirror.ALIYUN)
        val official = debianAptSources(DebianAptMirror.OFFICIAL)

        assertTrue(aliyun.contains("mirrors.aliyun.com/debian trixie"))
        assertTrue(aliyun.contains("mirrors.aliyun.com/debian-security trixie-security"))
        assertFalse(aliyun.contains("deb.debian.org"))
        assertTrue(official.contains("deb.debian.org/debian trixie"))
        assertTrue(official.contains("security.debian.org/debian-security trixie-security"))
    }

    @Test
    fun aptCommandsUseBoundedIpv4NetworkingAndStrictUpdates() {
        val update = debianAptCommand("update")
        val install = debianAptCommand("install -y git")

        assertTrue(update.contains("Acquire::Retries=1"))
        assertTrue(update.contains("Acquire::ForceIPv4=true"))
        assertTrue(update.contains("Acquire::http::Timeout=15"))
        assertTrue(update.contains("APT::Update::Error-Mode=any"))
        assertFalse(install.contains("APT::Update::Error-Mode"))
        assertTrue(install.endsWith("install -y git"))
    }

    @Test
    fun prootPathContainingEqualsIsTheExecutableInsteadOfAnEnvArgument() {
        val directory = Files.createTempDirectory("base==").toFile()
        try {
            val nativeDirectory = File(directory, "lib/arm64").apply { mkdirs() }
            val proot = File(nativeDirectory, "libproot.so").apply {
                writeText("")
                assertTrue(setExecutable(true))
            }
            val loader = File(nativeDirectory, "libproot-loader.so").apply { writeText("") }
            val rootfs = File(directory, "rootfs")
            val temp = File(directory, "tmp")

            val spec = buildProotProcessSpec(
                nativeDirectory,
                rootfs,
                temp,
                listOf("/bin/true"),
            )

            assertEquals(proot.absolutePath, spec.command.first())
            assertEquals("--link2symlink", spec.command[1])
            assertFalse(spec.command.contains("/system/bin/env"))
            assertEquals(loader.absolutePath, spec.environment["PROOT_LOADER"])
            assertEquals(temp.absolutePath, spec.environment["PROOT_TMP_DIR"])
            assertEquals(nativeDirectory.absolutePath, spec.environment["LD_LIBRARY_PATH"])
        } finally {
            directory.deleteRecursively()
        }
    }
}
