#!/usr/bin/env bash
#
# mayhem/build.sh — build a harness over kyverno's engine context deferred loaders
# (pkg/engine/context/deferred.go) as a sanitized libFuzzer binary (OSS-Fuzz Go path:
# go-118-fuzz-build -libfuzzer archive + clang++ ASan link), plus a dynamically-linked
# KAT oracle probe for mayhem/test.sh to run.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (go get of the /testing shim).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network
#     LAST, so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod
#     + GOSUMDB=off keep go.sum verification local (no sum.golang.org round trip).
#
# HARNESS STAGING: the harness imports the real pkg/engine/context, so it is built INSIDE
# the kyverno module (staged under _mayhem_harness/). go-118-fuzz-build needs its /testing
# shim in go.mod; to leave upstream's go.mod/go.sum untouched the build uses a private copy
# of both (-modfile=mayhem-build/go.mod).
set -euo pipefail

: "${SRC:=/mayhem}"
cd "$SRC"

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 AND prepend a DWARF3 anchor.o at the
# final clang++ link so the FIRST .debug_info CU is DWARF < 4.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

go version

TARGET="fuzz_deferred"
STAGE="$SRC/_mayhem_harness"
BUILD="$SRC/mayhem-build"

# Pseudo-version of the go-118-fuzz-build /testing shim that the Dockerfile's
# `go install ...@a70c2aa677fa...` already resolved + cached (resolves offline).
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"

rm -rf "$STAGE" "$BUILD"
mkdir -p "$STAGE/deferred" "$STAGE/kat" "$BUILD"
cp "$SRC/mayhem/harness_deferred.go.src" "$STAGE/deferred/harness.go"
cp "$SRC/mayhem/kat_main.go.src"         "$STAGE/kat/main.go"

# Private go.mod/go.sum: upstream's tree stays clean.
cp "$SRC/go.mod" "$BUILD/go.mod"
cp "$SRC/go.sum" "$BUILD/go.sum"
export GOFLAGS="-mod=mod -modfile=$BUILD/go.mod"
go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"

echo "=== go-118-fuzz-build $TARGET (func FuzzDeferredLoaders) ==="
go-118-fuzz-build -func FuzzDeferredLoaders -o "$BUILD/$TARGET.a" ./_mayhem_harness/deferred

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$BUILD/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$BUILD/anchor.c" -o "$BUILD/anchor.o"
# go_runtime_ready.o (init-ordering shim, #1644) links first.
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem/go_runtime_ready.c" -o "$BUILD/go_runtime_ready.o"
$CXX $GO_SAN $LIB_FUZZING_ENGINE "$BUILD/anchor.o" "$BUILD/go_runtime_ready.o" "$BUILD/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
go build -o /mayhem/kyverno_deferred_kat ./_mayhem_harness/kat
file /mayhem/kyverno_deferred_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/kyverno_deferred_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/kyverno_deferred_kat (dynamically linked)"

echo "build.sh complete"
