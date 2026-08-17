# Hacking on the system

You only need any of this if you are changing the BSP rather than using it.

```bash
git clone https://github.com/kek/nerves_system_rg40xxv
cd nerves_system_rg40xxv
mix deps.get
mix compile          # builds via Docker on macOS, natively on Linux
```

A full build is between one and three and a half hours depending on how much
`ccache` survives, and needs roughly 25 GB free.

`mix precommit` is the check to run before committing: `mix format --check` and
`tools/check-consistency.sh`. It deliberately does *not* compile, because
`:nerves_package` is in `compilers` and `mix compile` starts a Buildroot run
whenever no cached artifact matches the checksum.

## Almost every edit invalidates the artifact

`package_files()` in `mix.exs` determines the artifact checksum, and it
includes `README.md`. Editing the README therefore triggers a full rebuild.
`docs/` is *not* in `package_files()`, which is one reason the long-form notes
live there.

## Regenerating the kernel configuration

After editing `linux/nerves.fragment`:

```bash
tools/gen-kernel-defconfig.sh 6.18.44
```

This runs in Docker, asserts that every symbol you asked for actually took
effect, checks the boot-critical driver list, and writes
`linux/linux-6.18.defconfig`. It exits non-zero if anything is missing, so
it is safe to run in CI.

Asserting that symbols *took effect* is not pedantry. Kconfig silently
downgrades a `=y` symbol whose subsystem is `=m` rather than reporting a
conflict, which is exactly how `CONFIG_DRM_PANEL_MIPI=y` turned into a module
that nothing loads. Some symbols are also enabled by the arm64 defconfig and
omitted by `savedefconfig` because they default on — those are checked against
the full `.config` instead.

## Editing the board DTS does not rebuild the DTB

> [!WARNING]
> **`mix compile` after a DTS edit ships the *previous* DTB.** This has
> already put a wrong device tree on hardware once.

`BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` makes Buildroot depend on the *path* of
`linux/sun50i-h700-anbernic-rg40xx-v.dts`, not its contents — the same shape of
trap as `uboot/uboot.env`. Editing the DTS does not make the kernel package
out of date, so `make` copies nothing and `images/*.dtb` keeps its old content.

It is worse than it sounds, because the artifact checksum *does* change (the
DTS is under `linux/`, which is in `package_files()`). So the build looks like
it did the right thing: a new checksum, a new artifact, a new firmware UUID —
carrying a stale DTB.

There is a second half. Once the DTB is rebuilt in the Docker volume, the
*installed* artifact is still stale, and `mix compile` will not refresh it,
because the source checksum has not changed since the bad build. Both halves
have to be broken:

```bash
# 1. Force the kernel package to re-copy the DTS and rebuild
docker run --rm --mount type=volume,src=nerves_system_rg40xxv-<id>,target=/home/nerves/project \
  ... ghcr.io/nerves-project/nerves_system_br:1.34.1 \
  bash -c 'make linux-rebuild && make'

# 2. Force the artifact to be reinstalled from the volume
rm -rf ~/.nerves/artifacts/nerves_system_rg40xxv-portable-0.1.0
mix compile
```

Then check what actually shipped, rather than trusting the build:

```bash
dtc -I dtb -O dts ~/.nerves/artifacts/nerves_system_rg40xxv-portable-0.1.0/images/*.dtb \
  | grep -o 'anbernic,rg40xx[a-z0-9-]*panel'
```

`make linux-dirclean` and a full rebuild is the heavier, always-correct
version.

## Patches

`patches/linux/` carries seven patches and `patches/buildroot/` carries two;
each has a header explaining its upstream status, and
[`patches/buildroot/README.md`](../patches/buildroot/README.md) explains the
Buildroot ones in full. None are upstream as of 6.18, so all need re-checking
on a kernel bump.

## Notes on the boot chain

```
BROM → SPL → ATF BL31 (sun50i_h616) → U-Boot → sysboot → Linux
```

Two things here are easy to get wrong:

- **The kernel device tree is named explicitly** in
  `rootfs_overlay/boot/extlinux/extlinux-{a,b}.conf`. U-Boot's own built-in
  DTB is `sun50i-h700-anbernic-rg35xx-2024`, which leaves `mmc1` disabled.
  Booting on it produces a board with no WiFi and the wrong model string,
  and nothing obviously fails — so do not remove the `fdt` line.
- **Firmware updates do not rewrite the bootloader.** SPL and U-Boot are
  written only by the `complete` task, because they are not A/B redundant
  and an interrupted in-place rewrite would brick the device. If a system
  update changes U-Boot or the environment layout, re-flash the card rather
  than running `mix upload` / `mix firmware.burn --task upgrade`.
