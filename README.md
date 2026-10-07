# rune-language-typescript

Rune language packages for TypeScript and JavaScript, built from one repo and
released with one tag:

- `typescript`: the TypeScript 7 native compiler (`tsgo`), which also serves
  LSP; `extension_typescript`; and the TypeScript grammar. It requires the
  other two packages.
- `javascript`: the JavaScript grammar, JSX included.
- `tsx`: the TSX grammar.

To install TypeScript and JavaScript support in Rune, run this command in the
Rune console:

```text
pkg install typescript
```

The release instructions below are for Rune maintainers.

## Release runbook

1. **Prepare the build host.** A Mac builds all four platforms; a Linux host
   builds only the Linux ones, so `release-all` and `dist-<env>-all` fail on
   Linux. Install Go, Xcode command line tools (macOS), `zig`, `wget`,
   GNU tar (`gtar` on macOS), `objdump`, `perl` and `bluectl`.
   `extension_typescript` is pure Go, the compiler is a prebuilt npm download,
   and the Linux grammars are cross-compiled by `zig cc` against glibc 2.28, so
   no other toolchain is needed.
   The macOS `tree-sitter.so` files are signed with the `Developer ID
   Application: Unstable Build, LLC. (YYZRWD888J)` identity, so the Mac needs
   that identity in its keychain. Rune.app runs with the hardened runtime,
   which refuses to load a `tree-sitter.so` signed by any other team. The other
   binaries run as separate processes and keep their linker or vendor
   signatures; Microsoft signs the compiler. Packages are not notarized: Rune
   installs them without the quarantine attribute, so Gatekeeper never
   assesses them.
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out a clean, tagged release commit (`v0.0.10` or later: the grammar-only
   packages published from rune-language-template are at `v0.0.9-1-g58ab44c`).
   The `dist-*` targets reject untagged, dirty, or non-semver releases.
   Authenticate `bluectl` via gcloud Application Default Credentials and set
   `BLUE_PGP_KEY` and `BLUE_PGP_KEYRING` (see `bluectl release upload -h`).
3. **Publish** every platform to an environment:

   ```sh
   make dist-staging-all
   make dist-prod-all
   ```

   `dist-<env>-all` builds and tests all four platforms into
   `build/<os>-<arch>/{javascript,tsx,typescript}.tar.gz` and uploads only if
   every one passes. Each platform uploads `javascript` and `tsx` before
   `typescript`, which requires them. `dist-<env>-<os>-<arch>` (e.g.
   `dist-prod-linux-amd64`) releases a single platform, and `release-all` /
   `release-<os>-<arch>` build and test without uploading. `make test` checks
   for `.go` source leaks, the payload of each package, that `typescript`
   requires the other two, that the compiler and its `lib.*.d.ts` cannot be
   published onto `PATH`, the glibc 2.28 and macOS 13.3 floors, and OS-only
   library dependencies. For macOS it checks that Rune.app can load each
   package: every `tree-sitter.so` is Developer ID-signed and loads into a
   process signed like Rune.app, x86_64 under Rosetta, and every binary is
   intact and validly signed (`scripts/macos-signing.sh`, shared by every
   language repo). For the host platform it also runs the compiler through
   both shim locations: it type-checks a project against the packaged
   `lib.*.d.ts` and completes an LSP handshake (`scripts/lsp-smoke.pl`).
   Downloads are cached in `downloads/` (`make distclean` removes them). Each
   upload selects the pinned project and per-platform release bucket from
   `deploy/bluectl/`; do not run `dist.sh` directly.

To move to a new TypeScript release, bump `TS_VERSION` in the `Makefile`. To
move the grammars, update the `tree-sitter-javascript` and
`tree-sitter-typescript` submodules together with the `rune` submodule: the
queries ship from Rune's syntax test fixtures
(`rune/internal/ide/syntax/syntaxtest/<lang>/`), and Rune's syntax suite tests
them against parsers built from the same grammar revisions.

## Payload layout

```
javascript/ and tsx/
  config.yaml                # editor comments, icons and indents
  lib/{tree-sitter.so, highlights.scm, locals.scm, folds.scm, indents.scm, LICENSE}

typescript/
  config.yaml                # requirements, extension, editor settings
  bin/{tsgo, extension_typescript}   # tsgo is the tsgo-shim.sh wrapper
  tsgo/{.tsgo, lib.*.d.ts, LICENSE, NOTICE.txt}   # compiler (hidden) + its libs
  lib/{tree-sitter.so, highlights.scm, locals.scm, folds.scm, indents.scm, LICENSE}
```

Three non-obvious invariants, all consequences of how the installer publishes
a package: it symlinks the version dir at `$RUNE_DATADIR/lib/<pkg-id>` and
**byte-copies every non-hidden executable** it finds, by base name, into the
shared `$RUNE_DATADIR/bin`.

1. **The real compiler is hidden (`tsgo/.tsgo`); PATH gets a shim.** The
   compiler reads its `lib.*.d.ts` from the directory of its own executable
   and panics when they are missing, so it must run from inside the package
   next to them. A non-hidden compiler would be flat-copied into
   `$RUNE_DATADIR/bin` severed from them. Hidden files are skipped, so only the
   `tsgo-shim.sh` wrapper (staged as `bin/tsgo`) is published. It execs the
   hidden binary from either of its two install locations. The `lib.*.d.ts`
   are stripped of exec bits for the same reason.
2. **The shim is named `tsgo`, not `tsc`.** A `tsc` in `$RUNE_DATADIR/bin`
   would shadow the `tsc` a project installs, which is usually an older,
   Node-based TypeScript that its build depends on. `extension_typescript`
   finds the compiler by the package-local path `bin/tsgo` and runs it
   directly, so the package sets no `gui.env` and adds nothing to `PATH`.
3. **`typescript` requires `javascript` and `tsx`.** One tsgo server serves
   every dialect, but each grammar ships under the package id of its language,
   which is how Rune finds it. Installing `typescript` installs the other two
   first.

`scripts/test.sh` pins all three against the built tarballs, including a type
check and an LSP handshake through the shared-location shim from a simulated
`$RUNE_DATADIR`.