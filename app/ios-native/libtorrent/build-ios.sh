#!/usr/bin/env bash
# 把 libtorrent (及其依赖 OpenSSL, Boost 头文件) 与上游 anitorrent 的 C++ 封装交叉编译到 iOS,
# 产出 LibTorrent.xcframework (真机 arm64 与模拟器 arm64 的静态库与头文件).
#
# 版本与上游 anitorrent 一致: libtorrent 与 Boost 取自 anitorrent 的构建配置 (见 versions.env).
# 需要 macOS, Xcode, CMake. 用法: ./build-ios.sh [输出目录, 默认 ./build]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$here/versions.env"
out="$(mkdir -p "${1:-$here/build}" && cd "${1:-$here/build}" && pwd)"
src="$out/src"
mkdir -p "$src"
jobs="$(sysctl -n hw.ncpu)"

fetch() { # url dest
  [ -f "$2" ] || curl -fL --retry 4 --retry-all-errors --retry-delay 5 -o "$2" "$1"
}

# ---------- 源码 ----------
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$src/openssl.tar.gz"
echo "$OPENSSL_SHA256  $src/openssl.tar.gz" | shasum -a 256 -c -

if [ ! -d "$src/libtorrent" ]; then
  git clone -q --depth 1 --branch "$LIBTORRENT_TAG" --recurse-submodules --shallow-submodules \
    https://github.com/arvidn/libtorrent.git "$src/libtorrent"
fi
if [ ! -d "$src/anitorrent" ]; then
  git clone -q https://github.com/open-ani/anitorrent.git "$src/anitorrent"
  git -C "$src/anitorrent" checkout -q "$ANITORRENT_COMMIT"
fi
anitorrent_native="$src/anitorrent/anitorrent-native"
boost_include="$anitorrent_native/cpp/libs/boost"

# ---------- 每个平台 ----------
# 平台名 sysroot OpenSSL 目标
platforms=(
  "ios iphoneos ios64-xcrun"
  "ios-simulator iphonesimulator iossimulator-arm64-xcrun"
)

for entry in "${platforms[@]}"; do
  read -r name sdk openssl_target <<<"$entry"
  prefix="$out/$name"
  mkdir -p "$prefix"
  min_flag="-m$( [ "$sdk" = iphoneos ] && echo iphoneos || echo ios-simulator )-version-min=$IOS_DEPLOYMENT_TARGET"

  # OpenSSL (静态)
  if [ ! -f "$prefix/lib/libssl.a" ]; then
    rm -rf "$out/openssl-$name" && mkdir -p "$out/openssl-$name"
    tar -xzf "$src/openssl.tar.gz" -C "$out/openssl-$name" --strip-components 1
    (
      cd "$out/openssl-$name"
      ./Configure "$openssl_target" no-shared no-tests no-apps no-docs no-engine no-async \
        --prefix="$prefix" --libdir=lib "$min_flag"
      make -j"$jobs" build_libs >/dev/null
      make install_dev >/dev/null
    )
  fi

  # libtorrent (静态) + anitorrent 的 C++ 封装
  cmake -S "$here" -B "$out/cmake-$name" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DLIBTORRENT_SOURCE_DIR="$src/libtorrent" \
    -DANITORRENT_NATIVE_DIR="$anitorrent_native" \
    -DBoost_INCLUDE_DIR="$boost_include" \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DOPENSSL_INCLUDE_DIR="$prefix/include" \
    -DOPENSSL_SSL_LIBRARY="$prefix/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.a" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE
  cmake --build "$out/cmake-$name" -j"$jobs"
  cmake --install "$out/cmake-$name" >/dev/null

  # 合并为一个静态库, 便于 xcframework 与 cinterop 使用
  libtool -static -o "$prefix/libtorrent-ios.a" \
    "$prefix/lib/libanitorrent-core.a" "$prefix/lib/libtorrent-rasterbar.a" \
    "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a"
done

# ---------- xcframework ----------
rm -rf "$out/LibTorrent.xcframework"
xcodebuild -create-xcframework \
  -library "$out/ios/libtorrent-ios.a" -headers "$out/ios/include" \
  -library "$out/ios-simulator/libtorrent-ios.a" -headers "$out/ios-simulator/include" \
  -output "$out/LibTorrent.xcframework"
echo "Built $out/LibTorrent.xcframework"
