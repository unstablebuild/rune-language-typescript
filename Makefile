# Release packaging for the Rune javascript, tsx and typescript packages. See
# README.md for the runbook.
#
# One host builds every platform: extension_typescript is pure Go
# (CGO_ENABLED=0), the grammars are compiled by Apple clang for macOS and by
# `zig cc` for Linux, and the TypeScript 7 native compiler is a prebuilt npm
# download. macOS packages need Apple clang and codesign, so they must be
# built on macOS.
#
# The macOS tree-sitter.so is signed with Rune's Developer ID. Rune.app runs
# with the hardened runtime, whose library validation refuses to load a
# tree-sitter.so signed by any other team; an ad-hoc signature has no team.
# Packages are not notarized: Rune installs them without the quarantine
# attribute, so Gatekeeper never assesses them.

# The native compiler the typescript package ships. Only TypeScript 7 and
# later serve LSP.
TS_VERSION=7.0.2

# Platform floors from docs.rune.build; scripts/test.sh enforces them.
MACOS_MIN=13.3
GLIBC_MIN=2.28

PLATFORMS=darwin-arm64 darwin-amd64 linux-arm64 linux-amd64
ENVS=prod staging
# The grammar-only packages come first: typescript requires them, so they
# must be uploaded before it.
PACKAGES=javascript tsx typescript

TEAM_ID=YYZRWD888J
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. ($(TEAM_ID))
# Signs and checks macOS packages; shared by every language repo.
MACOS_SIGNING=TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	TARGET_ARCH=$(TARGET_ARCH) ./scripts/macos-signing.sh

HOST_OS:=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH:=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS?=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)
PLATFORM=$(TARGET_OS)-$(TARGET_ARCH)

ifeq ($(filter $(PLATFORM),$(PLATFORMS)),)
$(error unsupported platform '$(PLATFORM)'; expected one of: $(PLATFORMS))
endif
ifeq ($(TARGET_OS)-$(HOST_OS),darwin-linux)
$(error $(PLATFORM) packages must be built on macOS)
endif

BUILD=build/$(PLATFORM)
PKG=$(BUILD)/pkg
TS_PKG=$(PKG)/typescript
# Download cache. It survives `make clean`; file names carry the version.
DL=downloads

# GNU tar is named "gtar" on macOS (Homebrew) but is the default "tar" on Linux.
ifeq ($(HOST_OS),darwin)
GTAR=gtar
else
GTAR=tar
endif

# npm names the compiler's platform packages after node's <os>-<arch> pair.
NPM_ARCH_amd64=x64
NPM_ARCH_arm64=arm64
TS_PLATFORM=$(TARGET_OS)-$(NPM_ARCH_$(TARGET_ARCH))
TS_TARBALL=$(DL)/typescript-$(TS_PLATFORM)-$(TS_VERSION).tgz

# `zig cc` cross-compiles the Linux grammars against a pinned glibc, so no
# target toolchain or sysroot is needed.
ZIG?=zig
ZIG_ARCH_amd64=x86_64
ZIG_ARCH_arm64=aarch64
CLANG_ARCH_amd64=x86_64
CLANG_ARCH_arm64=arm64
ifeq ($(TARGET_OS),darwin)
PARSER_CC=cc -arch $(CLANG_ARCH_$(TARGET_ARCH)) -mmacosx-version-min=$(MACOS_MIN) -bundle
else
PARSER_CC=$(ZIG) cc -target $(ZIG_ARCH_$(TARGET_ARCH))-linux-gnu.$(GLIBC_MIN) -shared -fPIC
endif

# Each package's grammar; tree-sitter-typescript holds both TS dialects.
GRAMMAR_javascript=tree-sitter-javascript
GRAMMAR_typescript=tree-sitter-typescript/typescript
GRAMMAR_tsx=tree-sitter-typescript/tsx
# The queries are written for Rune, and Rune's syntax suite tests them against
# these grammar revisions, so they ship from the rune submodule's fixtures.
QUERIES=rune/internal/ide/syntax/syntaxtest
QUERY_FILES=highlights.scm locals.scm folds.scm indents.scm
# The queries adapt nvim-treesitter's and tree-sitter-javascript's, and the
# TypeScript grammars extend the JavaScript one.
GRAMMAR_LICENSES=tree-sitter-javascript/LICENSE tree-sitter-typescript/LICENSE \
	licenses/nvim-treesitter.txt

# $(call fetch,<url>,<file>): download <url> to <file> unless it is cached.
fetch=mkdir -p $(DL) && { [ -f $2 ] || { wget -O $2.part $1 && mv $2.part $2; }; }

# $(call grammar,<pkg>): stage the parser, queries, licenses and config of
# <pkg>. The trailing blank line keeps each expansion a separate recipe line.
define grammar
	mkdir -p $(PKG)/$1/lib
	$(PARSER_CC) -Os -I $(GRAMMAR_$1)/src $(GRAMMAR_$1)/src/*.c -o $(PKG)/$1/lib/tree-sitter.so
	cp $(addprefix $(QUERIES)/$1/,$(QUERY_FILES)) $(PKG)/$1/lib
	for f in $(GRAMMAR_LICENSES); do printf '# %s\n\n' "$$f"; cat "$$f"; printf '\n'; done > $(PKG)/$1/lib/LICENSE
	cp config/$1.yaml $(PKG)/$1/config.yaml

endef

RELEASE_TARGETS=$(addprefix release-,$(PLATFORMS))
DARWIN_RELEASE_TARGETS=$(filter release-darwin-%,$(RELEASE_TARGETS))
DIST_TARGETS=$(foreach e,$(ENVS),$(foreach p,$(PLATFORMS),dist-$e-$p))
DIST_ALL_TARGETS=$(addprefix dist-,$(addsuffix -all,$(ENVS)))

.PHONY: default package sign tarballs test clean distclean \
	check-dist check-macos release-all $(RELEASE_TARGETS) $(DIST_TARGETS) \
	$(DIST_ALL_TARGETS)

default: tarballs

$(TS_TARBALL):
	$(call fetch,https://registry.npmjs.org/@typescript/typescript-$(TS_PLATFORM)/-/typescript-$(TS_PLATFORM)-$(TS_VERSION).tgz,$@)

# Stage every package. Everything is rebuilt on every run: the grammars and
# extension_typescript are quick, and a stale binary must never ship.
package: $(TS_TARBALL)
	rm -rf $(PKG) $(BUILD)/npm
	$(foreach p,$(PACKAGES),$(call grammar,$p))
	# The compiler reads lib.*.d.ts from its own directory, so it ships
	# hidden next to them (tsgo/.tsgo, which the installer does not copy
	# into $$RUNE_DATADIR/bin) and bin/tsgo is the tsgo-shim.sh wrapper. The
	# shim is not named tsc so that it never shadows a project's own tsc.
	mkdir -p $(BUILD)/npm $(TS_PKG)/bin $(TS_PKG)/tsgo
	$(GTAR) -xzf $(TS_TARBALL) -C $(BUILD)/npm --strip-components=1
	cp $(BUILD)/npm/lib/*.d.ts $(BUILD)/npm/LICENSE $(BUILD)/npm/NOTICE.txt $(TS_PKG)/tsgo
	chmod a-x $(TS_PKG)/tsgo/*
	install -m 0755 $(BUILD)/npm/lib/tsc $(TS_PKG)/tsgo/.tsgo
	install -m 0755 tsgo-shim.sh $(TS_PKG)/bin/tsgo
	cd rune && CGO_ENABLED=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) \
		go build -o $(CURDIR)/$(TS_PKG)/bin/extension_typescript ./cmd/extension_typescript

# Developer ID-sign each tree-sitter.so in a macOS package, the one file Rune
# loads into its own process. The other binaries keep the signatures their
# linker or vendor gave them: Microsoft signs the compiler, and re-signing
# vendor binaries has corrupted them before (see scripts/macos-signing.sh).
# Linux packages are not signed.
sign: package
ifeq ($(TARGET_OS),darwin)
	for p in $(PACKAGES); do $(MACOS_SIGNING) sign $(PKG)/$$p || exit 1; done
endif

tarballs: sign
	for p in $(PACKAGES); do \
		(cd $(PKG)/$$p && $(GTAR) --no-xattrs --no-acls -czf $(CURDIR)/$(BUILD)/$$p.tar.gz .) || exit 1; \
	done

# Verify the tarballs (see scripts/test.sh). Binaries only run when the target
# is the host platform; every other check applies to all platforms.
test: tarballs
	BUILD=$(BUILD) PACKAGES="$(PACKAGES)" TARGET_OS=$(TARGET_OS) TARGET_ARCH=$(TARGET_ARCH) \
		TS_VERSION=$(TS_VERSION) MACOS_MIN=$(MACOS_MIN) GLIBC_MIN=$(GLIBC_MIN) \
		TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
		RUN_BINARIES=$(if $(filter $(HOST_OS)-$(HOST_ARCH),$(PLATFORM)),1,0) \
		./scripts/test.sh

# release-<os>-<arch>: build one platform from scratch and test it. This is
# dist-* without the upload.
$(RELEASE_TARGETS): release-%:
	rm -rf build/$*
	$(MAKE) test TARGET_OS=$(word 1,$(subst -, ,$*)) TARGET_ARCH=$(word 2,$(subst -, ,$*))

$(DARWIN_RELEASE_TARGETS): check-macos

# Linux hosts cannot build the macOS packages, so they cannot release all.
release-all: check-macos
	for p in $(PLATFORMS); do $(MAKE) release-$$p || exit 1; done

# dist-<env>-<os>-<arch>: release one platform and upload it to <env>.
$(DIST_TARGETS): dist-%: check-dist
	$(MAKE) release-$(word 2,$(subst -, ,$*))-$(word 3,$(subst -, ,$*))
	./dist.sh $(subst -, ,$*)

# dist-<env>-all: release all four platforms, then upload them. Nothing is
# uploaded unless every platform builds and passes its tests. It fails on
# Linux, which cannot build the macOS packages.
$(DIST_ALL_TARGETS): dist-%-all: check-macos check-dist
	$(MAKE) release-all
	for p in $(PLATFORMS); do ./dist.sh $* $${p%-*} $${p#*-} || exit 1; done

# Fail before any build work if the release cannot be uploaded.
check-dist:
	./check-release-tag.sh
	@command -v bluectl >/dev/null || { echo "error: bluectl is not on PATH" >&2; exit 1; }
	@: "$${BLUE_PGP_KEY:?is not set; see bluectl release upload -h}"
	@: "$${BLUE_PGP_KEYRING:?is not set; see bluectl release upload -h}"

# Fail before any build work if this host cannot sign the macOS packages:
# macOS and the Developer ID identity.
check-macos:
	@$(MACOS_SIGNING) preflight

clean:
	rm -rf build

distclean: clean
	rm -rf $(DL)