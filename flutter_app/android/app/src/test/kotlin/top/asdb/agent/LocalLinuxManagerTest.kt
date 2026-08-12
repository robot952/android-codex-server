package top.asdb.agent

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalLinuxManagerTest {
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
