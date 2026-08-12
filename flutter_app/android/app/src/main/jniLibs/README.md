# Local Linux native runtime

The `arm64-v8a` files in this directory are reproducibly extracted from pinned
Termux packages by `scripts/prepare-local-linux-runtime.sh`. Do not replace them
manually. The script verifies every downloaded Debian package with SHA-256 and
patches only PRoot's library lookup metadata so it can resolve libraries from
the APK native library directory.

Sources and licenses:

- PRoot 5.1.107.89: GPL-2.0
- libandroid-shmem 0.7: Apache-2.0
- talloc 2.4.3: LGPL-3.0-or-later

Package sources are fetched from the official Termux package repository. The
local Linux feature downloads a separately hashed Debian root filesystem as
data on first use; the root filesystem is not part of the APK.

Run `scripts/test-local-linux-runtime.sh [apk-path]` to verify the pinned
hashes, ARM64 ELF metadata, patched dependencies, and optional APK contents.
