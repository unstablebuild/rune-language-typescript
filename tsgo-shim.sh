#!/bin/sh
# Shim published as `tsgo` in place of the real TypeScript 7 compiler.
#
# The compiler reads its lib.*.d.ts files from the directory of its own
# executable, symlinks resolved, and panics when they are missing, so it must
# run from inside the package's tsgo/ dir. The Rune installer flat-copies every
# non-hidden executable in the package into $RUNE_DATADIR/bin, which would
# publish a copy severed from those files; the real binary is therefore hidden
# (tsgo/.tsgo, skipped by the installer) and only this shim gets copied.
#
# The shim runs from two locations: the package's own bin/ dir
# (<pkg>/bin/tsgo, which extension_typescript resolves) and the installer's
# shared copy ($RUNE_DATADIR/bin/tsgo, where lib/typescript symlinks the
# package root).
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
for tsgo in "$dir/../tsgo/.tsgo" "$dir/../lib/typescript/tsgo/.tsgo"; do
	if [ -x "$tsgo" ]; then
		exec "$tsgo" "$@"
	fi
done
echo "tsgo shim: packaged compiler not found near $dir" >&2
exit 127