# libkrun-builds

Pre-built `libkrun` and `libkrunfw` binaries for the platforms supported
upstream. Each GitHub Release ships a relocatable tarball per target triple,
with checksum, build provenance, and cosign sidecars, ready to extract and
link against.

`libkrun` is a dynamic library for spawning lightweight microVMs. It depends on
`libkrunfw`, a companion library that embeds a Linux kernel image. Building
both from source needs a Rust toolchain, `lld`, `libclang`, and a fully
configured kernel build environment, with a handful of non-obvious quirks on
macOS. This repo runs that build once per release in CI and publishes the
results.

## Supported targets

- `aarch64-apple-darwin` (macOS Apple Silicon)
- `x86_64-unknown-linux-gnu` (Linux amd64)
- `aarch64-unknown-linux-gnu` (Linux arm64)

## Using a release

Releases are tagged `libkrun-v<version>` and carry, per target triple:

- `libkrun-<version>-<triple>.tar.gz`                   the binaries
- `libkrun-<version>-<triple>.tar.gz.sha256`            SHA-256 sidecar
- `libkrun-<version>-<triple>.tar.gz.cosign-bundle.json` cosign signing bundle
- `libkrun-<version>-<triple>.tar.gz.sbom.cdx.json`     CycloneDX SBOM

Plus a SLSA build provenance attestation stored on GitHub's attestation API
(not downloaded as a file; verified via `gh attestation verify`).

### 1. Download and verify

Pick one of the three verification paths depending on your trust model.

#### SHA-256 (fastest, no extra tools)

```bash
TRIPLE=aarch64-apple-darwin               # or x86_64-unknown-linux-gnu, etc.
VERSION=1.18.1                            # match the release tag, no 'v' prefix
TARBALL=libkrun-${VERSION}-${TRIPLE}.tar.gz
BASE=https://github.com/igorjs-forks/libkrun-builds/releases/download/libkrun-v${VERSION}

curl --fail --location --remote-name "${BASE}/${TARBALL}"
curl --fail --location --remote-name "${BASE}/${TARBALL}.sha256"

# Linux
sha256sum -c "${TARBALL}.sha256"
# macOS
shasum -a 256 -c "${TARBALL}.sha256"
```

`checksums.txt` at the root of this repo carries the same sums for every
published release, useful when you want to pin a checksum out-of-band in
your own consumer repo.

#### Build provenance attestation (strongest end-to-end guarantee)

Every release artifact has a SLSA build provenance statement signed via
Sigstore using GitHub's OIDC. Verification proves the tarball was built by
*this specific workflow* on *this specific commit*, not just that the bytes
match a checksum someone published.

```bash
gh attestation verify "${TARBALL}" --repo igorjs-forks/libkrun-builds
```

Requires `gh` 2.49+ and is free for public repos.

#### Cosign keyless signature

For consumers that already verify via Sigstore but don't run `gh`:

```bash
curl --fail --location --remote-name "${BASE}/${TARBALL}.cosign-bundle.json"

cosign verify-blob \
  --bundle "${TARBALL}.cosign-bundle.json" \
  --new-bundle-format \
  --certificate-identity-regexp 'https://github.com/igorjs-forks/libkrun-builds/.+' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "${TARBALL}"
```

### 2. Extract and rewrite the pkg-config prefix

```bash
PREFIX=/opt/libkrun                       # wherever you want it
mkdir -p "${PREFIX}"
tar -xzf "${TARBALL}" -C "${PREFIX}"

# Rewrite the placeholder in libkrun.pc so pkg-config returns real paths.
sed -i.bak "s|__VENDOR_PREFIX__|${PREFIX}|" "${PREFIX}/lib/pkgconfig/libkrun.pc"
rm "${PREFIX}/lib/pkgconfig/libkrun.pc.bak"
```

After that, `PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig pkg-config --cflags --libs
libkrun` returns the right flags.

### 3. Runtime: make `libkrunfw` discoverable

`libkrun` loads `libkrunfw` at runtime by bare name (`libkrunfw.5.dylib` on
macOS, `libkrunfw.so.5` on Linux), not by absolute path. Both libraries ship
together in the tarball's `lib/` directory with their install names set to
`@rpath/libkrun{,fw}.dylib` (macOS) or RUNPATH `$ORIGIN` (Linux), so the
loader looks next to whichever binary loaded them.

You've got two ways to satisfy that lookup:

- **Embed an rpath in your consuming binary.** Set `@loader_path` (macOS) or
  `$ORIGIN` (Linux) so the loader looks beside your executable, then ship
  `libkrun.{dylib,so}` and `libkrunfw.{dylib,so}` next to it. Portable, no
  environment variables required.
- **Set a loader env var at runtime.** `DYLD_LIBRARY_PATH=${PREFIX}/lib` on
  macOS, `LD_LIBRARY_PATH=${PREFIX}/lib` on Linux. Simpler for development,
  fragile in production (some macOS binaries strip `DYLD_*`).

Whichever you pick, keep `libkrun` and `libkrunfw` in the same directory.

## Tarball contents

```
lib/libkrun.{dylib,so}            relocatable, install name @rpath / $ORIGIN
lib/libkrunfw.{dylib,so}          same
lib/pkgconfig/libkrun.pc          synthesised, prefix is __VENDOR_PREFIX__
include/libkrun.h                 the public header
```

`libkrunfw.h` isn't shipped. Consumers link only against `libkrun`; `libkrunfw`
is dlopened at runtime.

## Versioning

`libkrun` and `libkrunfw` use independent upstream version schemes. The
authoritative pairing comes from upstream's Homebrew formulas, and this repo
pins both:

- `version.txt` carries the `libkrun` release tag (e.g. `1.18.1`).
- `libkrunfw-version.txt` carries the `libkrunfw` release tag (e.g. `5.4.0`).
- `upstream-checksums.txt` pins the SHA-256 of every upstream tarball the
  build downloads. The watcher refreshes it whenever it bumps a version.

### Release tags

Releases are tagged `libkrun-v<libkrun-version>` only. The `libkrunfw` version
is embedded in the binaries but not in the tag.

### The same-tag overwrite gotcha

When upstream `libkrunfw` releases a new version but `libkrun` doesn't, the
watcher bumps `libkrunfw-version.txt` and re-publishes under the existing
`libkrun-v<n>` tag. The tag stays the same; the bytes change. Consumers
pinning by tag silently get new binaries on the next download.

If you need byte-stable pinning, pin by SHA-256 against `checksums.txt` or by
attestation against a specific commit SHA.

### Release cadence

A daily cron (midnight AEST) checks `containers/libkrun` and
`containers/libkrunfw` for new stable releases. When either is newer than the
pinned version, the watcher:

1. Refetches every upstream tarball and refreshes `upstream-checksums.txt`
   with the new SHA-256 pins (so `build.sh` refuses a tarball that changed
   between watch-time and build-time).
2. Opens a PR bumping the version pin(s) and enables auto-merge; the PR
   merges itself once the required status checks pass.
3. Dispatches the release workflow against the PR branch, so the build
   runs in parallel with the PR checks.

Manual dispatches via the Actions tab work the same way and accept a
`version_override`.

## Repo layout

```
.
├── README.md
├── LICENSE
├── version.txt                       pinned libkrun release tag
├── libkrunfw-version.txt             pinned libkrunfw release tag
├── upstream-checksums.txt            pinned SHAs of upstream downloads
├── build.sh                          builds for the host platform
├── checksums.txt                     SHAs of the published vendor tarballs
└── .github/
    ├── dependabot.yml                weekly bumps for SHA-pinned actions
    └── workflows/
        ├── release.yml               build matrix + publish + checksums sync
        ├── watch-upstream.yml        daily upstream watcher
        ├── osv-scan.yml              OSV scan of libkrun's Cargo.lock, on every PR
        ├── lint.yml                  actionlint, on every PR
        ├── codeql.yml                CodeQL `actions` analyser, on every PR
        └── dependabot-auto-merge.yml auto-merge for Dependabot patch/minor bumps
```

## Building locally

You normally don't need to: the publishing workflow runs the build in CI and
attaches the result to a Release. Local builds are mostly useful for
debugging build-script changes before committing.

### Required tools (host-dependent)

| Host                                | Need                                                                                                                       |
|-------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| macOS (Apple Silicon)               | Xcode CLT (`install_name_tool`), Homebrew, `lld` (`brew install lld`), pkg-config, `LIBCLANG_PATH` pointing at Homebrew llvm |
| Linux (amd64 or arm64)              | `build-essential clang lld llvm-dev libclang-dev patchelf pkg-config libelf-dev bc bison flex`                              |
| All                                 | Rust stable (CI uses `dtolnay/rust-toolchain@stable`; libkrun's deps need at least 1.87 today), `curl`, `tar`, `pkg-config`, `sha256sum` or `shasum` |

### Run the build

```bash
./build.sh                         # builds for the host's native triple
TARGET=x86_64-unknown-linux-gnu ./build.sh   # cross-target (limited; see below)
```

Output: `dist/libkrun-<version>-<triple>.tar.gz`. The script also prints the
SHA-256 to stdout.

Cross-targeting is constrained: the script doesn't set up a cross-compiler
toolchain, it just toggles the script's output naming. Use it only for hosts
that can natively produce the requested triple (e.g. a Linux x86_64 host can
target `x86_64-unknown-linux-gnu` but not `aarch64-apple-darwin`).

## Automated releases (operator notes)

### Daily watcher

`.github/workflows/watch-upstream.yml` runs at `0 14 * * *` UTC (midnight
AEST), with `concurrency: { group: watch-upstream }` to serialise overlapping
runs. When upstream has a new release, it:

1. Mints a short-lived installation token via `actions/create-github-app-token`
   using the `BOT_APP_CLIENT_ID` + `BOT_APP_PRIVATE_KEY` secrets.
2. Opens a PR via `peter-evans/create-pull-request` using the App's token
   (commits are API-created, so they're auto-signed by GitHub).
3. Enables auto-merge on the PR.
4. Dispatches the release workflow against the PR branch so the build
   proceeds in parallel with the PR's review / status checks.

The bump PR auto-merges once the required status checks pass; the ruleset
requires no approving reviews, so no bypass is involved. Every required
check runs on every PR on purpose: a required check that never reports
leaves the PR stuck in "Expected" and auto-merge waits forever.

### Manual dispatch

Use the **release** workflow's `Run workflow` button from the Actions tab.
The optional `version_override` input lets you publish from a non-default
version pin; the workflow validates the format before using it.

## Troubleshooting

### `error: missing required tool 'patchelf'` on Linux

Install via apt: `sudo apt-get install -y patchelf`.

### `error: missing required tool 'install_name_tool'` on macOS

You're missing Xcode Command Line Tools. Install with `xcode-select --install`.

### `cargo: command not found`

Install Rust via rustup: `curl --proto '=https' --tlsv1.2 -sSf
https://sh.rustup.rs | sh`. Then `rustup default stable` to match CI.

### `bindgen` complains about libclang on macOS

Homebrew keeps `llvm` keg-only, so `libclang.dylib` isn't on dyld's default
search path. Export it before running `build.sh`:

```bash
LLVM_PREFIX="$(brew --prefix llvm)"
export LIBCLANG_PATH="${LLVM_PREFIX}/lib"
export LLVM_CONFIG_PATH="${LLVM_PREFIX}/bin/llvm-config"
```

The CI workflow does this automatically.

### `error: upstream SHA mismatch for '...'`

`build.sh` refused to use a tarball whose SHA doesn't match
`upstream-checksums.txt`. Either upstream re-uploaded the asset (rare but
documented for the libkrun source tarball, which GitHub can regenerate), or
something is tampering with the download. Inspect the diff between the
expected and actual SHA, then either:

- If you trust upstream changed the bytes legitimately: refresh the line in
  `upstream-checksums.txt` manually (see the file's header comment).
- Otherwise: don't bypass it. Investigate.

### libkrun loads but can't find libkrunfw at runtime

Three usual causes:

1. You didn't keep `libkrun` and `libkrunfw` in the same directory.
2. Your binary's rpath doesn't include `@loader_path` / `$ORIGIN`, and you
   haven't set `DYLD_LIBRARY_PATH` / `LD_LIBRARY_PATH`.
3. On macOS, your binary is hardened (SIP, library validation) and is
   stripping `DYLD_*` env vars. Embed an rpath instead.

## Licence

The build scripts in this repo are Apache-2.0, matching upstream `libkrun`
(since they're trivial glue around its build system). The produced binaries
inherit `libkrun`'s licence: Apache-2.0.

The `libkrun-v<version>` releases are tagged but not separately licensed
beyond the licences of their constituent parts.
