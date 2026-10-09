#!/usr/bin/env bash
# Verifies the release tarballs of one platform. Run through `make test`,
# which builds them and passes the variables below.
#
# Guards:
#   1. No .go source files leak into any tarball. The repo vendors the `rune`
#      Go submodule and builds extension_typescript from it, so a stray copy of
#      Go sources into a package would ship source into the release.
#   2. Every package ships its grammar, the four queries Rune loads, the
#      grammar licenses and its config.yaml. The typescript package also
#      ships extension_typescript, the bin/tsgo shim, and the compiler with
#      its lib.d.ts and license.
#   3. typescript's config.yaml requires the javascript and tsx packages:
#      its server handles those dialects, but their grammars ship in them.
#   4. The real compiler is hidden (tsgo/.tsgo), and the only non-hidden
#      executables outside bin/ are the grammars. Rune releases before v1.3.0
#      flat-copy every non-hidden executable into the shared $RUNE_DATADIR/bin,
#      so a visible compiler would land there severed from its lib.*.d.ts, and
#      an executable lib.*.d.ts would land on PATH.
#   5. Binaries are built for $TARGET_OS/$TARGET_ARCH and meet the platform
#      floors on docs.rune.build: Mach-O minos <= $MACOS_MIN, ELF glibc symbol
#      versions <= $GLIBC_MIN. They link nothing beyond the OS: glibc's own
#      libraries on Linux, /usr/lib and /System on macOS. A binary for another
#      architecture would pass the other guards: Rosetta runs x86_64 code on
#      Apple silicon, and the other platforms' binaries are never run.
#   6. extension_typescript is built from the pinned rune commit ($RUNE_REV)
#      without cgo. Its Go build info must not record a modified tree:
#      check-release-tag.sh only sees tracked changes in the submodule, and an
#      untracked .go file in it would be compiled in.
#   7. macOS targets: Rune.app can load every package. Each tree-sitter.so is
#      signed with the $TEAM_ID Developer ID and loads into a process signed
#      like Rune.app, and every Mach-O file, the Microsoft-signed compiler
#      included, is intact and validly signed (scripts/macos-signing.sh check).
#   8. The bin/tsgo shim runs the compiler from both install locations: the
#      package's own bin/ and the shared $RUNE_DATADIR/bin (simulated with a
#      fake data dir + lib/typescript symlink). Through the shared one, the
#      compiler reports $TS_VERSION, type-checks a project against the
#      packaged lib.*.d.ts, and serves LSP over stdio as Rune runs it.
#
# Guard 8 executes the packaged binaries, so it only runs when RUN_BINARIES=1
# (the tarballs target the host platform).
set -euo pipefail

BUILD="${BUILD:?}"
PACKAGES="${PACKAGES:?}"
TARGET_OS="${TARGET_OS:?}"
TARGET_ARCH="${TARGET_ARCH:?}"
TS_VERSION="${TS_VERSION:?}"
MACOS_MIN="${MACOS_MIN:?}"
GLIBC_MIN="${GLIBC_MIN:?}"
RUNE_REV="${RUNE_REV:?}"
RUN_BINARIES="${RUN_BINARIES:-0}"
if [ "$TARGET_OS" = darwin ]; then
	TEAM_ID="${TEAM_ID:?}"
	CODESIGN_IDENTITY="${CODESIGN_IDENTITY:?}"
fi
scripts="$(cd "$(dirname "$0")" && pwd)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fail() {
	echo "error: $*" >&2
	exit 1
}

# sort_versions: sorts dotted versions numerically (BSD and GNU sort alike).
sort_versions() { sort -t. -k1,1n -k2,2n -k3,3n; }
# version_le A B: true if dotted version A <= B.
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort_versions | head -1)" = "$1" ]; }

# file(1)'s description of a binary built for the target. A universal Mach-O
# file is described as "Mach-O universal binary", so it does not match.
case "$TARGET_OS-$TARGET_ARCH" in
darwin-arm64) want_binary="Mach-O 64-bit * arm64" ;;
darwin-amd64) want_binary="Mach-O 64-bit * x86_64" ;;
linux-arm64) want_binary="ELF 64-bit LSB *, ARM aarch64, *" ;;
linux-amd64) want_binary="ELF 64-bit LSB *, x86-64, *" ;;
*) fail "unsupported target $TARGET_OS-$TARGET_ARCH" ;;
esac

# check_floor <pkg> <file>: guard 5 for one binary of an extracted package.
check_floor() {
	local f=$2 desc minos glibc foreign
	desc="$(file -b "$f")"
	# shellcheck disable=SC2254 # want_binary is a pattern.
	case "$desc" in
	$want_binary) ;;
	*) fail "$1: ${f#"$workdir"/} is not a $TARGET_OS-$TARGET_ARCH binary: $desc" ;;
	esac
	case "$TARGET_OS" in
	darwin)
		minos="$(otool -l "$f" | awk '$1 == "minos" {print $2}' | sort_versions | tail -1)"
		if [ -z "$minos" ] || ! version_le "$minos" "$MACOS_MIN"; then
			fail "$1: ${f#"$workdir"/} requires macOS ${minos:-<unknown>}, above the $MACOS_MIN floor"
		fi
		foreign="$(otool -L "$f" | tail -n +2 | awk '{print $1}' |
			{ grep -vE '^(/usr/lib/|/System/Library/)' || true; })"
		;;
	linux)
		# Static binaries have no dynamic symbols, so objdump may fail on them.
		glibc="$({ objdump -T "$f" 2>/dev/null || true; } |
			{ grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/^GLIBC_//' | sort_versions | tail -1)"
		if [ -n "$glibc" ] && ! version_le "$glibc" "$GLIBC_MIN"; then
			fail "$1: ${f#"$workdir"/} requires glibc $glibc, above the $GLIBC_MIN floor"
		fi
		foreign="$({ objdump -p "$f" 2>/dev/null || true; } | awk '$1 == "NEEDED" {print $2}' |
			{ grep -vE '^(libc|libm|libdl|libpthread|librt|libutil)\.so\.[0-9]+$|^ld-linux-(x86-64|aarch64)\.so\.[0-9]+$' || true; })"
		;;
	esac
	if [ -n "$foreign" ]; then
		fail "$1: ${f#"$workdir"/} links libraries outside the OS: $(echo "$foreign" | xargs)"
	fi
}

command -v file > /dev/null || fail "file is required to check binary architectures"
command -v go > /dev/null || fail "go is required to read extension_typescript's build info"
if [ "$TARGET_OS" = linux ]; then
	command -v objdump > /dev/null || fail "objdump is required to check glibc floors"
fi

for pkg in $PACKAGES; do
	tar="$BUILD/$pkg.tar.gz"
	[ -f "$tar" ] || fail "$tar not found; run 'make' first"
	dir="$workdir/$pkg"
	mkdir -p "$dir"

	# Entries are relative to the package root, e.g. ./lib/tree-sitter.so.
	# Kept in a file: `grep -q` exits on the first match, which would SIGPIPE
	# a feeding tar under pipefail.
	members="$workdir/$pkg.members"
	tar -tzf "$tar" > "$members"

	go_files="$(grep -E '\.go$' "$members" || true)"
	if [ -n "$go_files" ]; then
		printf '%s\n' "$go_files" >&2
		fail "$tar contains .go source files"
	fi

	want="./config.yaml ./lib/tree-sitter.so ./lib/highlights.scm ./lib/locals.scm
		./lib/folds.scm ./lib/indents.scm ./lib/LICENSE"
	if [ "$pkg" = typescript ]; then
		want="$want ./bin/extension_typescript ./bin/tsgo ./tsgo/.tsgo ./tsgo/lib.d.ts
			./tsgo/lib.es2024.d.ts ./tsgo/lib.dom.d.ts ./tsgo/LICENSE ./tsgo/NOTICE.txt"
	fi
	for f in $want; do
		grep -qxF "$f" "$members" || fail "$tar is missing $f"
	done

	tar -xzf "$tar" -C "$dir"

	executables="$(cd "$dir" && find . -type f -perm -u+x ! -path './bin/*' ! -name '.*' |
		{ grep -vxF ./lib/tree-sitter.so || true; })"
	if [ -n "$executables" ]; then
		printf '%s\n' "$executables" >&2
		fail "$tar has non-hidden executables outside bin/, which the installer would publish onto PATH"
	fi

	binaries="lib/tree-sitter.so"
	if [ "$pkg" = typescript ]; then
		binaries="$binaries tsgo/.tsgo bin/extension_typescript"
	fi
	for f in $binaries; do
		check_floor "$pkg" "$dir/$f"
	done

	echo "ok: $pkg payload present, no .go files, executables hidden, $TARGET_OS-$TARGET_ARCH binaries within floors"
done

# Guard 3: a top-level `requirements:` list naming both grammar packages.
requirements="$(awk '
	/^requirements:/ { in_req = 1; next }
	/^[^[:space:]-]/ { in_req = 0 }
	in_req && $1 == "-" { print $2 }' "$workdir/typescript/config.yaml" | sort | xargs)"
if [ "$requirements" != "javascript tsx" ]; then
	fail "typescript's config.yaml requires '$requirements', expected 'javascript tsx'"
fi
echo "ok: typescript requires the javascript and tsx packages"

# Guard 6: `go version -m` prints one "build" line per setting, e.g.
# "<tab>build<tab>vcs.modified=false". Kept in a file for grep -q (see above).
buildinfo="$workdir/extension_typescript.buildinfo"
go version -m "$workdir/typescript/bin/extension_typescript" |
	awk '$1 == "build" { print $2 }' > "$buildinfo"
for want in "GOOS=$TARGET_OS" "GOARCH=$TARGET_ARCH" CGO_ENABLED=0 \
	"vcs.revision=$RUNE_REV" vcs.modified=false; do
	grep -qxF "$want" "$buildinfo" ||
		fail "extension_typescript's build info lacks $want: $(xargs < "$buildinfo")"
done
echo "ok: extension_typescript is built from rune ${RUNE_REV:0:12} with a clean tree and no cgo"

if [ "$TARGET_OS" = darwin ]; then
	for pkg in $PACKAGES; do
		echo "checking $pkg for Rune.app"
		TEAM_ID="$TEAM_ID" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" TARGET_ARCH="$TARGET_ARCH" \
			"$scripts/macos-signing.sh" check "$workdir/$pkg" "tree_sitter_$pkg"
	done
fi

if [ "$RUN_BINARIES" != 1 ]; then
	echo "skip: $BUILD targets another platform; not running its binaries"
	exit 0
fi

ts="$workdir/typescript"
want_version="Version $TS_VERSION"

version="$("$ts/bin/tsgo" --version)" || fail "package-local shim failed to run the packaged compiler"
[ "$version" = "$want_version" ] || fail "package-local shim reports '$version', expected '$want_version'"

# Reproduce the installed layout: the shim is flat-copied into a shared bin
# dir, and lib/typescript symlinks the package root (the installer's
# lib/<pkg-id> convention). The shim must find the hidden compiler through
# that symlink.
fdd="$workdir/fakedatadir"
mkdir -p "$fdd/bin" "$fdd/lib"
cp "$ts/bin/tsgo" "$fdd/bin/tsgo"
ln -s "$ts" "$fdd/lib/typescript"
tsgo="$fdd/bin/tsgo"

version="$("$tsgo" --version)" || fail "shared-bin shim failed to run the packaged compiler"
[ "$version" = "$want_version" ] || fail "shared-bin shim reports '$version', expected '$want_version'"
echo "ok: the shim runs TypeScript $TS_VERSION from the package and the shared bin"

# The compiler must resolve the packaged lib.*.d.ts: Array.prototype.includes
# comes from lib.es2016, and the one expected error proves it type-checks.
proj="$workdir/proj"
mkdir -p "$proj"
printf '%s\n' '{"compilerOptions": {"strict": true, "target": "es2022", "lib": ["es2022"]}}' \
	> "$proj/tsconfig.json"
printf '%s\n' 'const n: number = [1, 2].includes(1) ? 1 : 0;' 'export const s: string = n;' \
	> "$proj/main.ts"
out="$(cd "$proj" && "$tsgo" --noEmit --pretty false -p . 2>&1 || true)"
want_error="main.ts(2,14): error TS2322: Type 'number' is not assignable to type 'string'."
if [ "$out" != "$want_error" ]; then
	printf 'want: %s\ngot:\n%s\n' "$want_error" "$out" >&2
	fail "the packaged compiler did not type-check against its lib.*.d.ts"
fi
echo "ok: the compiler type-checks against the packaged lib.*.d.ts"

if ! "$scripts/lsp-smoke.pl" "$tsgo" --lsp --stdio > "$workdir/lsp-smoke.log" 2>&1; then
	cat "$workdir/lsp-smoke.log" >&2
	fail "the packaged compiler failed the LSP handshake"
fi
echo "ok: tsgo --lsp --stdio $(tail -1 "$workdir/lsp-smoke.log")"