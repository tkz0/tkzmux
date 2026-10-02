# Linux development environment

How to set up a Linux host to build and test the tkzmux Linux port. The reference machine is Omarchy (Arch Linux, x86_64, glibc 2.44, GTK 4.22, Hyprland). Written in WOR-300 S1, which commits the toolchain pin that [ADR-0002](adr-0002-platform-defaults.md) D2 recommends. `scripts/linux/dev-env.sh` checks everything on this page.

## Pins

`scripts/linux/dev-env.sh` reads the `pin` lines below, so this block is the only place these versions are written. Change them only together with ADR-0002 D2 (Swift), D1 (zig target) or D3 (GTK floor).

```text
pin swift  6.3.3    swift-6.3.3-RELEASE, swift.org ubuntu24.04 x86_64 tarball
pin image  swift:6.3.3-noble@sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c
pin zig    0.16     libghostty-vt archive (WOR-302)
pin glslc  2026.3   shaderc 2026.3; SPIR-V output differs between glslc versions (WOR-313 drift check)
pin gtk4   4.16     floor from ADR-0002 D3; the reference machine has 4.22.4
```

- **Container tags.** Both exist on Docker Hub (checked 2026-10-02). The digests are of the multi-arch OCI image index:
  - `swift:6.3.3-noble@sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c` (the pin);
  - `swift:6.2.4-noble@sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784` (the D2 fallback).
- **Docker Hub re-pushes official tags** when the base image is rebuilt; both tags above were last pushed on 2026-10-02. A tag can therefore point at a new digest without a new Swift. CI names the tag with its digest, and whoever bumps the digest records the new one here.
- **Never an unpinned 6.4.** It ships with Xcode 27, defaults to Swift Build, and is preinstalled on GitHub's `ubuntu-24.04` runners. Always name the exact tag (ADR-0002 D2).
- To re-read a digest without pulling the image:

  ```sh
  tok=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/swift:pull" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  curl -fsSI -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    https://registry-1.docker.io/v2/library/swift/manifests/6.3.3-noble | grep -i docker-content-digest
  ```

## Compiler skew: shared code compiles under Swift 6.2

- macOS CI and releases stay on Xcode 26.1, which is Swift 6.2 (`.github/workflows/ci.yml`). Linux builds with 6.3.3.
- Shared code must compile under both. Mac CI is the 6.2 gate and Linux CI is the 6.3 gate.
- No language or library feature newer than 6.2 goes into a shared target, and `// swift-tools-version: 6.2` stays.
- Moving the Mac off Xcode 26.1 is a separate decision. Under decision 2 ([decisions.md](decisions.md)) nothing here changes it.

## Toolchain: the swift.org tarball, per user

The reference machine uses the official swift.org **Ubuntu 24.04** build of 6.3.3, unpacked under `$HOME/.local/share/swift/6.3.3`, plus a few compatibility libraries. Nothing is installed system-wide and no root is needed for the toolchain itself.

### Why not mise, and why not a container

- **mise** (`mise install swift`) fails on Arch. Its toolchain binaries want `libncurses.so.6`, `libxml2.so.2` and `libpython3.9`. Arch ships `libncursesw.so.6`, `libxml2.so.16` and Python 3.14 instead.
- **Docker** (`swift:<pin>-noble`): the user is not in the `docker` group (the socket is `root:docker 0660`), so it needs a one-time group change or sudo. Noble's `libgtk-4-dev` is GTK 4.14, which is below the 4.16 floor (see [GTK header skew](#gtk-header-skew-414-in-the-image-422-on-the-host)), so the container cannot build the GTK targets anyway.
- **Podman** is not installed yet (it is in the package list below). The container route stays documented under [Container route](#container-route-reference-not-used-for-daily-work) for reproducing the pinned CI image.

### Install

```sh
mkdir -p "$HOME/.local/share/swift" && cd "$HOME/.local/share/swift"
base=https://download.swift.org/swift-6.3.3-release/ubuntu2404/swift-6.3.3-RELEASE
curl -fLO "$base/swift-6.3.3-RELEASE-ubuntu24.04.tar.gz"
curl -fLO "$base/swift-6.3.3-RELEASE-ubuntu24.04.tar.gz.sig"
curl -fsSL https://www.swift.org/keys/all-keys.asc | gpg --import -
gpg --verify swift-6.3.3-RELEASE-ubuntu24.04.tar.gz.sig swift-6.3.3-RELEASE-ubuntu24.04.tar.gz
mkdir 6.3.3 && tar -xzf swift-6.3.3-RELEASE-ubuntu24.04.tar.gz -C 6.3.3 --strip-components=1
```

The tarball is about 1.07 GB, and the unpacked toolchain is 3.3 GB. It includes the static runtime (`usr/lib/swift_static`), `swift-build` (Swift Build), `ld.lld` and `lldb`.

### Compat libraries

Some toolchain binaries are linked against Ubuntu sonames that Arch does not ship:

| Soname | Needed by | Arch has | Fix |
|---|---|---|---|
| `libncurses.so.6`, `libform.so.6`, `libpanel.so.6` | `swift-driver` (so `swiftc`), `swift-package`, `swift-build-tool`, `sourcekit-lsp`, `lldb` | the wide-char builds `libncursesw.so.6` etc. (same ABI) | symlink to the `w` builds |
| `libxml2.so.2` | `swift-package`, `swift-build`, `sourcekit-lsp`, `docc`, `lld`, `lldb` (through `FoundationXML`) | `libxml2.so.16` | the `libxml2-legacy` package (2.13.9, against Arch's ICU 78) |
| `libedit.so.2`, `libpython3.12.so.1.0` | `lldb`, `lldb-dap`, `lldb-server` only | `libedit.so.0`, Python 3.14 | none; see [Debugging](#debugging) |

The built binaries do not need any of these. A `--static-swift-stdlib` executable needs only `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, `libc.so.6` and `ld-linux-x86-64.so.2`.

**Recommended route: put the links in the toolchain's RUNPATH directory.** `swift-driver`, `swift-package` and `swift-build` carry `RUNPATH $ORIGIN/../lib/swift/linux`, so links placed there are found without any environment variable:

```sh
sudo pacman -S --needed libxml2-legacy
lib="$HOME/.local/share/swift/6.3.3/usr/lib/swift/linux"
for l in ncurses form panel; do ln -sf "/usr/lib/lib${l}w.so.6" "$lib/lib$l.so.6"; done
```

```sh
# $HOME/.local/share/swift/env.sh, recommended route
export PATH="$HOME/.local/share/swift/6.3.3/usr/bin:$PATH"
```

Verified on 2026-10-02 against a copy of the toolchain with the three links and the `libxml2-legacy` 2.13.9 shared object in that directory, with `LD_LIBRARY_PATH` unset: `swift build` with both `--build-system native` and `--build-system swiftbuild`, each with and without `--static-swift-stdlib`, built and ran a hello world. Nothing in these steps is specific to this host, so the `archlinux` CI container (ADR-0002 D5) can use them as written; WOR-303 confirms that.

**Route as first installed on the reference machine: a compat directory on `LD_LIBRARY_PATH`.** It works for `--build-system native` but not for `--build-system swiftbuild`, so it is superseded by the route above.

```sh
# $HOME/.local/share/swift/env.sh, as first installed
# Compat libs in $HOME/.local/lib/swift-compat:
#   libncurses/form/panel.so.6 -> Arch's *w.so.6 (symlinks)
#   libxml2.so.2 + libicu{uc,data,i18n}.so.74 from Ubuntu noble .debs (SwiftPM's swift-build needs them)
export PATH="$HOME/.local/share/swift/6.3.3/usr/bin:$PATH"   # plus zig 0.16.0 and shellcheck when installed through mise
export LD_LIBRARY_PATH="$HOME/.local/lib/swift-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

- The noble `libxml2.so.2` (2.9.14) needs `libicuuc.so.74`, which is why the ICU 74 libraries came along from the noble `.deb`s. `libxml2-legacy` links Arch's ICU 78 and makes them unnecessary.
- **The swiftbuild backend drops `LD_LIBRARY_PATH`** for the compiler and linker it spawns. Under this route, `swift build --build-system swiftbuild` compiles and then fails at the link step: `swiftc: error while loading shared libraries: libncurses.so.6: cannot open shared object file`. `--build-system native` keeps the environment and works. `dev-env.sh` reports this as a gap because WOR-300 S4 and WOR-303 S1 run both backends.
- The noble `.deb`s cannot simply move into the RUNPATH directory either: RUNPATH applies only to an object's direct dependencies, and the noble `libxml2.so.2` has no RUNPATH of its own to find ICU 74.

### Debugging

The toolchain's `lldb` cannot start on Arch: it needs `libedit.so.2` and `libpython3.12.so.1.0`. Arch has `libedit.so.0` and Python 3.14, and a symlink across those sonames would be an ABI guess. Swift-aware debugging is therefore unavailable with this route. Arch's own `lldb` (in the package list) debugs the C shims, the Zig archive and crashes at the machine level. `dev-env.sh` reports the toolchain `lldb` as a warning, not a gap. If Swift-aware debugging becomes necessary, the container route has a working `lldb`.

### Verify

```sh
swift --version
# Swift version 6.3.3 (swift-6.3.3-RELEASE)
# Target: x86_64-unknown-linux-gnu
scripts/linux/dev-env.sh --smoke
```

Measured on the reference machine (2026-10-02, glibc 2.44): a `swift package init --type executable` hello world, built with `swift build -c release --static-swift-stdlib` (native backend), ran and printed `Hello, world!`. It also ran with `LD_LIBRARY_PATH` unset. `readelf -d` NEEDED: `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, `libc.so.6`, `ld-linux-x86-64.so.2`. WOR-300 S4 records the full NEEDED, PT_INTERP and GLIBC-version measurements in `spikes.md`.

## GTK header skew: 4.14 in the image, 4.22 on the host

- The host has GTK 4.22.4 (headers and library). Noble, which the `swift:<pin>-noble` image is built on, has GTK 4.14.
- 4.14 is below the 4.16 floor (ADR-0002 D3: `gtk_graphics_offload_set_black_background` and `gdk_dmabuf_texture_builder_set_color_state` are 4.16 APIs). Ubuntu images therefore build and test only the non-GTK targets, through an explicit `--target` list (ADR-0002 D5).
- The 4.22 headers do not raise the runtime requirement on their own: `GTK_CHECK_VERSION` is compile-time only. Anything newer than 4.16 goes through the runtime gate in ADR-0002 D4.
- The required full Linux build runs in an `archlinux` container pinned by digest, which matches the host's GTK (ADR-0002 D5, WOR-303).

## Packages

Already present on the reference machine: gtk4 4.22.4, pango, freetype2, harfbuzz, fontconfig, libxkbcommon 1.13.2 (headers included), shaderc 2026.3, dbus, binutils 2.47 (`ld.gold`, `readelf`, `objcopy`), pkgconf, vulkan-icd-loader.

Install the rest on Arch/Omarchy:

```sh
sudo pacman -S --needed zig vulkan-headers vulkan-tools vulkan-validation-layers vulkan-swrast \
  zsh fish lld lldb valgrind podman libxml2-legacy wayland-utils sway
```

| Package (pacman / apt) | Needed by | `dev-env.sh` probe |
|---|---|---|
| swift (pin) / swift.org tarball, or the `swift:<pin>-noble` image | all | `swift --version` equals the pin; toolchain libraries resolve with and without `LD_LIBRARY_PATH`; static runtime present |
| `libxml2-legacy` / `libxml2` | toolchain (`swift-package`, `swift-build`) | part of the toolchain probe |
| `zig` 0.16.x / ziglang.org tarball (no noble package) | WOR-302 | `zig version` |
| `pkgconf` / `pkg-config` | all | `pkg-config` |
| `binutils` / `binutils` | WOR-299, WOR-302 (`readelf`, `objcopy`, `objdump`, `nm`, `strings`); `ld.gold` is the toolchain's default linker | each command |
| `lld` / `lld` | WOR-300 S4 (`-Xswiftc -use-ld=lld`; the form `-Xlinker -fuse-ld` is wrong). `-use-ld=lld` actually runs the toolchain's own `ld.lld`, which needs `libxml2.so.2` from `libxml2-legacy` ([spikes.md](spikes.md#link-matrix)) | system `ld.lld`; the toolchain's own copy does not count |
| `shaderc` (glslc) / `glslc` | WOR-313 S2 | `glslc --version` equals the glslc pin |
| `gtk4` / `libgtk-4-dev` | WOR-314 | `pkg-config gtk4` ≥ the gtk4 pin |
| `pango` / `libpango1.0-dev` | WOR-317 (`pangoft2`, decision S6-1) | `pkg-config pangoft2` |
| `freetype2`, `harfbuzz`, `fontconfig` / `libfreetype-dev`, `libharfbuzz-dev`, `libfontconfig-dev` | WOR-312 | `pkg-config` |
| `libxkbcommon` / `libxkbcommon-dev` | WOR-315 S1, tests only (decision S6-3) | `pkg-config xkbcommon` |
| `vulkan-icd-loader` / `libvulkan-dev` | WOR-301, WOR-313 | `pkg-config vulkan` |
| `vulkan-headers` / `libvulkan-dev` | WOR-301, WOR-313 | `/usr/include/vulkan/vulkan.h` |
| `vulkan-validation-layers` / `vulkan-validationlayers` | WOR-301, WOR-313 | `VkLayer_khronos_validation.json` manifest |
| `vulkan-swrast` / `mesa-vulkan-drivers` (lavapipe) | WOR-301, WOR-313 | `lvp_icd*.json` manifest |
| `vulkan-tools` / `vulkan-tools` | WOR-301 | `vulkaninfo` |
| `wayland-utils` / `wayland-utils` | WOR-301 | `wayland-info` |
| `sway` / `sway` (`WLR_BACKENDS=headless`) | WOR-314 S2/S5, WOR-300 S3 | `sway` |
| `dbus` / `dbus-daemon` | WOR-320 S1 | `dbus-daemon` |
| `zsh`, `fish` / `zsh`, `fish` | WOR-305, WOR-306 | each command |
| `valgrind` / `valgrind` | WOR-314 (`asan-valgrind` job) | `valgrind` |
| `lldb` / `lldb` | C/Zig-level debugging (see [Debugging](#debugging)) | system `lldb` |
| `podman` / `podman` | WOR-303 (pinned CI images, rootless, no group change) | `podman` |

### glslc pin

`glslc --version` on the reference machine (shaderc 2026.3-1) prints:

```text
2026.3
1:1.4.357.0
1:1.4.357.0

Target: SPIR-V 1.0
```

Arch's build prints bare version numbers; upstream builds print `shaderc v2026.3 …`. `dev-env.sh` takes the first `YYYY.N` on the first line. Noble's `glslc` is an older shaderc, so SPIR-V that WOR-313's drift check compares is generated on Arch (host or `archlinux` container), never on noble.

## `scripts/linux/dev-env.sh`

```sh
scripts/linux/dev-env.sh              # read-only checks; exit 0 = no gaps, 1 = gaps, 2 = usage or pin error
scripts/linux/dev-env.sh --smoke      # also build and run a --static-swift-stdlib hello world with both build systems
scripts/linux/dev-env.sh --container  # also check podman, or docker with docker-group access
```

- Every gap is printed with the package that fixes it (pacman on Arch, apt on Debian/Ubuntu) or the section of this page, and the run ends with one `pacman -S --needed …` line for all missing packages.
- The toolchain's `lldb` is a warning, never a gap.
- `--smoke` writes only to a `mktemp -d` directory and removes it.
- `DEV_ENV_SYSROOT` prefixes the file probes, so the script can be tested against a fake tree.
- On 2026-10-02 the reference machine reports 15 gaps with `--smoke --container`: the packages in the install line above, the toolchain's `LD_LIBRARY_PATH` dependency, the failing `swiftbuild` smoke cell, and docker-group access. With the recommended compat route and stub packages it exits 0, and with one package removed it exits 1, naming that package.

## Container route (reference, not used for daily work)

```sh
podman run --rm -v "$PWD:/src" -w /src \
  docker.io/library/swift:6.3.3-noble@sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c \
  swift build --build-system native --static-swift-stdlib --target <non-GTK target>
```

- With docker instead, add `--user "$(id -u):$(id -g)"` so build products are not root-owned, and either join the `docker` group (`sudo usermod -aG docker "$USER"`, then log in again) or use sudo.
- `--static-swift-stdlib` binaries built in the container run on the host: noble has glibc 2.39 and the host has 2.44.
- The image has no GTK 4.16, so only non-GTK targets build there (see [GTK header skew](#gtk-header-skew-414-in-the-image-422-on-the-host)).
