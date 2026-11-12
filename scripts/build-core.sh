#!/usr/bin/env bash
# يبني نواة Rust للجوال والمحاكي، يولّد ربط Swift بـ UniFFI، ويغلّفهم XCFramework داخل باكج QBCore.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST="$ROOT/rust"
PKG="$ROOT/QBCore"
OUT="$RUST/target/qbcore"
LIB=libqb_ffi.a
export IPHONEOS_DEPLOYMENT_TARGET=26.0

# QB_TARGETS يحدد الأهداف (الافتراضي الجوال والمحاكي)
read -r -a TARGETS <<< "${QB_TARGETS:-aarch64-apple-ios aarch64-apple-ios-sim}"

cd "$RUST"
for t in "${TARGETS[@]}"; do
  echo "▸ cargo build --release --target $t"
  cargo build --locked --release -p qb-ffi --target "$t"
done

rm -rf "$OUT" && mkdir -p "$OUT/headers" "$OUT/swift"

echo "▸ uniffi-bindgen (Swift)"
cargo run --locked --release -p uniffi-bindgen -- generate \
  --library "$RUST/target/aarch64-apple-ios/release/$LIB" \
  --language swift --out-dir "$OUT/swift"

# الهيدرات + modulemap واحد يجمع موديولات الـ FFI كلها
mv "$OUT"/swift/*.h "$OUT/headers/"
cat "$OUT"/swift/*.modulemap > "$OUT/headers/module.modulemap"
rm "$OUT"/swift/*.modulemap

echo "▸ xcodebuild -create-xcframework"
XCF_ARGS=()
for t in "${TARGETS[@]}"; do XCF_ARGS+=(-library "$RUST/target/$t/release/$LIB" -headers "$OUT/headers"); done
xcodebuild -create-xcframework "${XCF_ARGS[@]}" \
  -output "$PKG/QBCoreFFI.xcframework"

mkdir -p "$PKG/Sources/QBCore/Generated"
rm -f "$PKG"/Sources/QBCore/Generated/*.swift
cp "$OUT"/swift/*.swift "$PKG/Sources/QBCore/Generated/"

echo "✔ QBCore جاهز: $(du -sh "$PKG/QBCoreFFI.xcframework" | cut -f1)"
