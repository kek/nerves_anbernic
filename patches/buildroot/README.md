# Buildroot patches

These patch Buildroot itself, not a package it builds, so they do not go
through `BR2_GLOBAL_PATCH_DIR`. Apply them by hand to the Buildroot tree that
`nerves_system_br` downloads:

```bash
cd deps/nerves_system_br/buildroot-2026.05.1
patch -p1 < ../../../patches/buildroot/0001-mesa3d-panfrost-without-target-llvm.patch
```

`mix deps.get` replaces that tree, so reapply after any dependency refresh.
There is no hook for this yet; if these become permanent, the right home is a
step in `tools/`.

## 0001-mesa3d-panfrost-without-target-llvm

Lets the Gallium panfrost driver build without LLVM **on the target**, which
is the difference between roughly 28.5 GB of build tree and 9 GB.

Buildroot 2026.05.1 has panfrost `depends on BR2_PACKAGE_MESA3D_LLVM` and
force-selecting `NEEDS_PRECOMP_COMPILER`, which selects `MESA3D_OPENCL`, which
in turn depends on `MESA3D_LLVM` and selects target `CLANG` and `LIBCLC`. So
asking for panfrost asks for LLVM and clang cross-compiled for the device.

Mesa does not need any of that at runtime. It needs a *compiler* to precompile
shaders at build time, and `mesa3d.mk` already builds one for the host:

    HOST_MESA3D_CONF_OPTS = ... -Dmesa-clc=enabled -Dprecomp-compiler=enabled
    MESA3D_CONF_OPTS += -Dmesa-clc=system -Dprecomp-compiler=system

`system` means the target build consumes the host's `mesa-clc` and
precompiler. The target LLVM is redundant.

Verified: with this patch, `libEGL.so`, `libGLESv2.so` and the panfrost DRI
driver build and install into staging. Host-side LLVM and clang are still
built -- they are what the precompiler needs -- but those are ~6 GB rather
than an additional ~20 GB on the target.

Three things had to change together, and the third is the one that is easy to
miss:

1. Drop `depends on BR2_PACKAGE_MESA3D_LLVM` from the panfrost driver.
2. Drop `select BR2_PACKAGE_MESA3D_OPENCL` and
   `select BR2_PACKAGE_SPIRV_LLVM_TRANSLATOR` from
   `BR2_PACKAGE_MESA3D_NEEDS_PRECOMP_COMPILER`.
3. Drop `spirv-llvm-translator` from `MESA3D_DEPENDENCIES`. This one is a
   *make* dependency, not a Kconfig select, so removing the select is not
   enough -- Buildroot still queues the target package, which drags target
   LLVM back in. Symptom: the build starts configuring `build/llvm-22.1.7`
   even though `BR2_PACKAGE_LLVM` is absent from `.config`.

Also needed: `-Dcpp_rtti=false` for host-mesa3d. `MESA3D_OPENCL` used to
`select BR2_PACKAGE_LLVM_RTTI`, which built host LLVM with RTTI on. Without
it, host-mesa3d's configure fails with

    LLVM was built without RTTI, so Mesa must also disable RTTI.
    Use an LLVM built with LLVM_ENABLE_RTTI or add cpp_rtti=false.

`BR2_PACKAGE_LLVM_RTTI` lives inside `if BR2_PACKAGE_LLVM`, so it cannot be
set from the defconfig without pulling target LLVM back in -- hence disabling
RTTI on the Mesa side instead.

### Disk, and a trap that looks like a disk problem

This fits in a 63 GB Docker Desktop VM, but only after one piece of cleanup
that is easy to mistake for needing a bigger disk.

The artifact step copies the sysroot and tars it, so a bloated sysroot is paid
for twice. An *aborted* target-LLVM build leaves its staging install behind:
1.86 GB of `libLLVM.so.22.1` plus several hundred `libLLVM*.a`, which took the
sysroot from ~1.2 GB to 10 GB. Nothing depends on those files once the patch
is applied, and Buildroot never removes them, so every subsequent packaging
attempt failed with "No space left on device" while the real fault was
orphaned files. Removing them from
`host/aarch64-buildroot-linux-gnu/sysroot/usr/lib` fixed it.

If you hit disk errors during the artifact step, measure the sysroot before
concluding the VM is too small.
