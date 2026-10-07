#!/usr/bin/env bash
# Uploads build/<os>-<arch>/{javascript,tsx,typescript}.tar.gz as releases of
# the packages of the same names, all with the same tag.
#
# Usage: dist.sh <prod|staging> <os> <arch>
#
# Do not run this directly: the make dist-* targets build and test the
# tarballs first. <env> selects the pinned bluectl project and the
# per-platform release bucket under deploy/bluectl/. Packages that already
# have this version are skipped, so an interrupted dist-<env>-all can be rerun.
set -eu
cd "$(dirname "$0")"

# typescript requires the other two, so they are uploaded before it.
PACKAGES="javascript tsx typescript"

if [ $# -ne 3 ]; then
	echo "usage: $0 <prod|staging> <os> <arch>" >&2
	exit 2
fi
ENV=$1 OS=$2 ARCH=$3
BLUECTL_CONFIG_DIR="deploy/bluectl/$ENV/$OS-$ARCH"
if [ ! -f "$BLUECTL_CONFIG_DIR/config" ]; then
	echo "error: no bluectl config at $BLUECTL_CONFIG_DIR" >&2
	exit 1
fi
for pkg in $PACKAGES; do
	if [ ! -f "build/$OS-$ARCH/$pkg.tar.gz" ]; then
		echo "error: build/$OS-$ARCH/$pkg.tar.gz not found; use the make dist-* targets" >&2
		exit 1
	fi
done
: "${BLUE_PGP_KEY:?is not set. See bluectl release upload -h for help.}"
: "${BLUE_PGP_KEYRING:?is not set. See bluectl release upload -h for help.}"
SIGN_ARGS=(-k "$BLUE_PGP_KEY" -r "$BLUE_PGP_KEYRING")
# Optional: without it bluectl prompts for the key's passphrase on every
# upload, twelve times for dist-<env>-all.
if [ -n "${BLUE_PGP_PASSPHRASE:-}" ]; then
	SIGN_ARGS+=(-p "$BLUE_PGP_PASSPHRASE")
fi

# The remote URL is published as release metadata; drop any userinfo
# (https://user:token@host/...) a local checkout may carry.
GIT_REMOTE_URL=$(git remote get-url origin | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#')
GIT_AUTHOR_EMAIL=$(git log -1 --pretty=format:'%ae')
GIT_TAG=$(git describe --tags --dirty)
GIT_HEAD=$(git rev-parse HEAD)

# If HEAD is tagged, log the range between the latest two tags; otherwise
# between the latest tag and HEAD.
if git describe --contains >/dev/null 2>&1; then
	GIT_LOG_RANGE=$(git tag -l --sort=-version:refname | head -2 | xargs | sed 's/ /.../g')
else
	GIT_LOG_RANGE="$(git tag -l --sort=-version:refname | head -1)...HEAD"
fi
GIT_LOG=$(git log --pretty=format:"%h: %s" "$GIT_LOG_RANGE")

for pkg in $PACKAGES; do
	if bluectl -c "$BLUECTL_CONFIG_DIR" release describe "$pkg" "$GIT_TAG" >/dev/null 2>&1; then
		echo "$pkg $GIT_TAG is already released for $OS/$ARCH in $ENV; skipping"
		continue
	fi
	echo "uploading $pkg $GIT_TAG for $OS/$ARCH to $ENV ($GIT_LOG_RANGE)"
	printf '%s\n' "$GIT_LOG"
	bluectl -c "$BLUECTL_CONFIG_DIR" release upload \
		-d target-os="$OS" \
		-d target-arch="$ARCH" \
		-d git-remote-url="$GIT_REMOTE_URL" \
		-d git-author-email="$GIT_AUTHOR_EMAIL" \
		-d git-tag="$GIT_TAG" -d git-head="$GIT_HEAD" \
		-d git-log="$GIT_LOG" \
		-y \
		"${SIGN_ARGS[@]}" "$pkg" "$GIT_TAG" "build/$OS-$ARCH/$pkg.tar.gz"
done