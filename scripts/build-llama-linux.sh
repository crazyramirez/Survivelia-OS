#!/bin/bash
# Compila llama-server (llama.cpp) para la versión portable de Linux con glibc 2.31 (Debian 11+, Ubuntu 20.04+,
# Raspberry Pi OS Bullseye/Bookworm), sin OpenSSL ni OpenMP y con libc++ dentro del binario: solo depende de glibc.
# Los paquetes oficiales de llama.cpp para Linux piden glibc 2.34 (x64) o 2.38 (arm64) y OpenSSL 3, así que no
# arrancaban en Debian 12 / Raspberry Pi OS Bookworm (arm64) ni en distribuciones anteriores a 2022.
#
# Dos variantes por arquitectura; la app elige la rápida si la CPU la tiene (portable/lib.mjs, optionalServices):
#   arm64: llama-server (ARMv8, cualquier placa) y llama-server-dotprod (ARMv8.2 + dotprod: Pi 5 y placas actuales)
#   x64:   llama-server (x86-64-v2) y llama-server-avx2 (x86-64-v3: procesadores de 2013 en adelante)
#
# Uso (Linux o WSL, sin root): bash scripts/build-llama-linux.sh <tag, p. ej. b12428> <arm64|x64> <carpeta de trabajo>
# Deja en la carpeta de trabajo llama-<tag>-survivelia-linux-<arch>.tar.gz (súbelo a la release «components» y pon su
# URL y SHA-256 en content/catalog.json).
set -euo pipefail
TAG="$1"
ARCH="$2"
W="$3"
mkdir -p "$W" && cd "$W"
[ -d zig ] || { curl -sL https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz | tar xJ && mv zig-x86_64-linux-0.14.1 zig; }
[ -d cmake ] || { curl -sL https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz | tar xz && mv cmake-3.31.6-linux-x86_64 cmake; }
[ -x ninja ] || { curl -sL https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip -o ninja.zip && python3 -c "import zipfile;zipfile.ZipFile('ninja.zip').extractall('.')" && chmod +x ninja; }
[ -d "src-$TAG" ] || { curl -sL "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$TAG.tar.gz" | tar xz && mv "llama.cpp-$TAG" "src-$TAG"; }
Z="$PWD/zig/zig"
case "$ARCH" in
  arm64) TRIPLE=aarch64-linux-gnu.2.31; PROC=aarch64; VARIANTS="llama-server:generic llama-server-dotprod:generic+dotprod+fullfp16" ;;
  x64) TRIPLE=x86_64-linux-gnu.2.31; PROC=x86_64; VARIANTS="llama-server:x86_64_v2 llama-server-avx2:x86_64_v3" ;;
  *) echo "arquitectura: arm64 o x64" >&2; exit 2 ;;
esac
PKG="llama-$TAG-survivelia-linux-$ARCH"
rm -rf "$PKG" && mkdir "$PKG"
for v in $VARIANTS; do
  name="${v%%:*}"
  cpu="${v#*:}"
  out="build-$ARCH-$name"
  wrap="$PWD/wrap-$ARCH-$name"
  mkdir -p "$wrap"
  printf '#!/bin/sh\nexec "%s" cc -target %s -mcpu=%s "$@"\n' "$Z" "$TRIPLE" "$cpu" > "$wrap/cc"
  printf '#!/bin/sh\nexec "%s" c++ -target %s -mcpu=%s "$@"\n' "$Z" "$TRIPLE" "$cpu" > "$wrap/c++"
  chmod +x "$wrap/cc" "$wrap/c++"
  rm -rf "$out"
  ./cmake/bin/cmake -S "src-$TAG" -B "$out" -G Ninja -DCMAKE_MAKE_PROGRAM="$PWD/ninja" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$PROC" \
    -DCMAKE_C_COMPILER="$wrap/cc" -DCMAKE_CXX_COMPILER="$wrap/c++" \
    -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH= -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON \
    -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_NUMBER="${TAG#b}" -DLLAMA_BUILD_COMMIT="$TAG" > "$out.log" 2>&1
  ./cmake/bin/cmake --build "$out" --target llama-server -j "$(nproc)" >> "$out.log" 2>&1
  "$Z" objcopy --strip-all "$out/bin/llama-server" "$PKG/$name"
  chmod 755 "$PKG/$name"
  echo "$name: $(stat -c %s "$PKG/$name") bytes · $(readelf -dW "$PKG/$name" | grep -c NEEDED) librerías (glibc máx $(readelf -VW "$PKG/$name" | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1))"
done
cp "src-$TAG/LICENSE" "$PKG/LICENSE-llama.cpp.txt"
printf 'llama.cpp %s compilado por Survivelia OS (scripts/build-llama-linux.sh): glibc 2.31, sin OpenSSL ni OpenMP.\n' "$TAG" > "$PKG/LEEME.txt"
tar czf "$PKG.tar.gz" "$PKG"
echo "$PKG.tar.gz $(stat -c %s "$PKG.tar.gz") $(sha256sum "$PKG.tar.gz" | cut -d' ' -f1)"
