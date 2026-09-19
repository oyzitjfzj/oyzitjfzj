#!/usr/bin/env bash
set -euo pipefail
OUT="${1:-/tmp/las-verification-toolchain-cache.tar.gz}"
RUST_VERSION="1.98.1"
RUSTC_COMMIT="48a229ceaefd4985c50990b14116b6d856af0985"
CARGO_VERSION_LINE="cargo 1.98.1 (797e8a9bc 2026-08-05)"
TARGET="x86_64-unknown-linux-gnu"
TLA_VERSION="1.7.2"
TLA_SHA1="7f21faa2cdae3189e7d5fadb4488f0dfcc658407"
ALR_VERSION="2.1.1"
ALR_SHA256="09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7"
GNAT_VERSION="16.1.0"
GPRBUILD_VERSION="26.0.1"
GNATPROVE_VERSION="16.1.0"
fail(){ echo "ERROR: $*" >&2; exit 2; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }
[[ "$(uname -s)" == Linux ]] || fail "requires Linux"
[[ "$(uname -m)" == x86_64 ]] || fail "requires x86_64"
for b in bash curl tar gzip unzip sha1sum sha256sum awk grep find sort; do need "$b"; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/las-cache-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CACHE="$WORK/cache"; HOME_DIR="$CACHE/home"; DOWNLOADS="$CACHE/downloads"; ALR_DIST="$CACHE/alr-dist"
mkdir -p "$HOME_DIR" "$DOWNLOADS" "$ALR_DIST"
export HOME="$HOME_DIR" CARGO_HOME="$HOME_DIR/.cargo" RUSTUP_HOME="$HOME_DIR/.rustup"
mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
RUSTUP_INIT="$DOWNLOADS/rustup-init"; RUSTUP_SHA="$DOWNLOADS/rustup-init.sha256"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$RUSTUP_INIT" "https://static.rust-lang.org/rustup/dist/${TARGET}/rustup-init"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$RUSTUP_SHA" "https://static.rust-lang.org/rustup/dist/${TARGET}/rustup-init.sha256"
expected_rustup="$(awk 'NR==1 {print $1}' "$RUSTUP_SHA")"
[[ "$expected_rustup" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid rustup checksum"
echo "${expected_rustup}  ${RUSTUP_INIT}" | sha256sum --check --strict
chmod +x "$RUSTUP_INIT"; "$RUSTUP_INIT" -y --profile minimal --default-toolchain none
export PATH="$CARGO_HOME/bin:$PATH"
rustup toolchain install "$RUST_VERSION" --profile minimal
rustup component add --toolchain "$RUST_VERSION" rustfmt clippy
rustc_info="$(rustc +"$RUST_VERSION" --version --verbose)"; printf '%s\n' "$rustc_info"
grep -qx "commit-hash: ${RUSTC_COMMIT}" <<<"$rustc_info" || fail "unexpected rustc commit"
grep -qx "host: ${TARGET}" <<<"$rustc_info" || fail "unexpected Rust host"
grep -qx "release: ${RUST_VERSION}" <<<"$rustc_info" || fail "unexpected Rust release"
[[ "$(cargo +"$RUST_VERSION" --version)" == "$CARGO_VERSION_LINE" ]] || fail "unexpected Cargo build"
rustup component list --toolchain "$RUST_VERSION" --installed | grep -qx "rustfmt-${TARGET}" || fail "rustfmt missing"
rustup component list --toolchain "$RUST_VERSION" --installed | grep -qx "clippy-${TARGET}" || fail "clippy missing"
TLA_JAR="$DOWNLOADS/tla2tools.jar"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$TLA_JAR" "https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"
echo "${TLA_SHA1}  ${TLA_JAR}" | sha1sum --check --strict
ALR_ZIP="$DOWNLOADS/alr.zip"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$ALR_ZIP" "https://github.com/alire-project/alire/releases/download/v${ALR_VERSION}/alr-${ALR_VERSION}-bin-x86_64-linux.zip"
echo "${ALR_SHA256}  ${ALR_ZIP}" | sha256sum --check --strict
unzip -q "$ALR_ZIP" -d "$ALR_DIST"
[[ -x "$ALR_DIST/bin/alr" ]] || fail "Alire missing"
export PATH="$ALR_DIST/bin:$PATH"
alr -n toolchain --select "gnat_native=${GNAT_VERSION}" "gprbuild=${GPRBUILD_VERSION}"
ALR_WS="$CACHE/alire-workspace"; mkdir -p "$ALR_WS"
(
 cd "$ALR_WS"
 alr -n init --in-place --no-skel --lib las_verify_toolchain
 alr with "gnatprove=${GNATPROVE_VERSION}"
 alr exec -- gnatmake --version
 alr exec -- gprbuild --version
 alr exec -- gnatprove --version
 { echo "gnatmake=$(alr exec -- sh -lc 'command -v gnatmake')"; echo "gprbuild=$(alr exec -- sh -lc 'command -v gprbuild')"; echo "gnatprove=$(alr exec -- sh -lc 'command -v gnatprove')"; } > "$CACHE/ADA-TOOL-PATHS.txt"
)
[[ -f "$ALR_WS/alire.toml" ]] || fail "Alire workspace manifest missing"
cat > "$CACHE/CACHE-MANIFEST.txt" <<MANIFEST
schema=las-verification-cache-v2
rust=${RUST_VERSION}
rustc_commit=${RUSTC_COMMIT}
cargo_version_line=${CARGO_VERSION_LINE}
target=${TARGET}
tla_tools=${TLA_VERSION}
tla_tools_sha1=${TLA_SHA1}
alire=${ALR_VERSION}
alire_sha256=${ALR_SHA256}
gnat_native=${GNAT_VERSION}
gprbuild=${GPRBUILD_VERSION}
gnatprove=${GNATPROVE_VERSION}
rustup_init_sha256=${expected_rustup}
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
{
 echo "--- rustup ---"; rustup --version
 echo "--- rustc ---"; rustc +"$RUST_VERSION" --version --verbose
 echo "--- cargo ---"; cargo +"$RUST_VERSION" --version
 echo "--- rustfmt ---"; rustfmt +"$RUST_VERSION" --version
 echo "--- clippy ---"; cargo +"$RUST_VERSION" clippy --version
 echo "--- alire ---"; alr --version
 echo "--- ada/spark ---"
 (cd "$ALR_WS" && alr exec -- gnatmake --version)
 (cd "$ALR_WS" && alr exec -- gprbuild --version)
 (cd "$ALR_WS" && alr exec -- gnatprove --version)
} > "$CACHE/INSTALLED-VERSIONS.txt" 2>&1
mkdir -p "$(dirname "$OUT")"; OUT_DIR="$(cd "$(dirname "$OUT")" && pwd -P)"; OUT="$OUT_DIR/$(basename "$OUT")"
tar -C "$WORK" -czf "$OUT" cache
DIGEST="$(sha256sum "$OUT" | awk '{print $1}')"
printf '%s  %s\n' "$DIGEST" "$(basename "$OUT")" > "${OUT}.sha256"
echo "CACHE_ARCHIVE=$OUT"; echo "CACHE_SHA256=$DIGEST"; echo "CACHE_SHA256_FILE=${OUT}.sha256"
