#!/usr/bin/env bash
# Build the Rust bridge for iOS (device + Apple Silicon simulator), generate the Swift bindings
# and package everything as ios/build/LightCraftFFI.xcframework + ios/app/Generated/*.swift.
# Also regenerates the app's design layer from the desktop UI crate (ios/tools/gen-theme): it fails
# when upstream changed a value the iOS app mirrors, naming the line to update.
#
#   ios/build-xcframework.sh            # release
#   PROFILE=debug ios/build-xcframework.sh
#   FEATURES=heif ios/build-xcframework.sh   # decode HEIC in Rust (see lightcraft-ffi/Cargo.toml)
set -euo pipefail

cd "$(dirname "$0")"
IOS_DIR="$PWD"
PROFILE="${PROFILE:-release}"
FEATURES="${FEATURES:-}"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
LIB=liblightcraft_ffi.a
OUT="$IOS_DIR/build"
GEN="$IOS_DIR/app/Generated"

# rustup from Homebrew is keg-only
[ -d /opt/homebrew/opt/rustup/bin ] && export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
rustup target add "${TARGETS[@]}" >/dev/null

# Match the app's deployment target (project.yml) so the linker doesn't warn about newer objects.
export IPHONEOS_DEPLOYMENT_TARGET=17.0

echo "==> Design layer from the desktop UI (theme, icons, app icon; checks mirrored upstream values)"
mkdir -p "$GEN"
cargo run -q -p gen-theme -- "$IOS_DIR/.." "$GEN"

cargo_flags=(-p lightcraft-ffi --lib)
[ "$PROFILE" = release ] && cargo_flags+=(--release)
[ -n "$FEATURES" ] && cargo_flags+=(--features "$FEATURES")
for t in "${TARGETS[@]}"; do
  echo "==> cargo build $t ($PROFILE)"
  cargo build "${cargo_flags[@]}" --target "$t"
done

echo "==> Swift bindings"
rm -rf "$OUT/headers" "$GEN/lightcraft_ffi.swift"
mkdir -p "$OUT/headers"
cargo run -q -p lightcraft-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "target/aarch64-apple-ios/$PROFILE/$LIB" --language swift --out-dir "$OUT/gen"
mv "$OUT/gen/"*.swift "$GEN/"
mv "$OUT/gen/"*.h "$OUT/headers/"
# Xcode wants the module map named module.modulemap inside the headers folder
cat "$OUT/gen/"*.modulemap > "$OUT/headers/module.modulemap"
rm -rf "$OUT/gen"

echo "==> XCFramework"
rm -rf "$OUT/LightCraftFFI.xcframework"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/$PROFILE/$LIB" -headers "$OUT/headers" \
  -library "target/aarch64-apple-ios-sim/$PROFILE/$LIB" -headers "$OUT/headers" \
  -output "$OUT/LightCraftFFI.xcframework" >/dev/null

echo "Done: $OUT/LightCraftFFI.xcframework, bindings in $GEN"
