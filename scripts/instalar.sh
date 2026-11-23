#!/bin/bash
# Survivelia OS: instala (o actualiza) la última versión publicada en una Raspberry Pi o en un Linux con systemd,
# con un solo comando y sin compilar nada:
#
#   curl -fsSL https://raw.githubusercontent.com/crazyramirez/Survivelia-OS/main/scripts/instalar.sh | sudo bash
#
# Opciones (después de «sudo bash -s --»):
#   --no-kiosk      otro Linux: sin pantalla completa ni imagen de Survivelia OS al arrancar
#   --no-branding   Raspberry Pi: conservar la imagen de arranque de Raspberry Pi
#   --comprobar     solo descargar y verificar (firma y SHA-256), sin instalar ni pedir sudo
#
# Qué hace: descarga el manifiesto firmado de la última versión de GitHub, comprueba su firma Ed25519 con la clave
# de Survivelia OS (la misma que usan las actualizaciones automáticas), descarga el paquete, comprueba su SHA-256 y
# lo instala con el install-system.sh del propio paquete. Los datos y la configuración existentes se conservan.
set -euo pipefail

REPO=crazyramirez/Survivelia-OS
BASE="${SURVIVELIA_RELEASE_BASE:-https://github.com/$REPO/releases/latest/download}" # otra fuente: solo para pruebas
# Clave pública de las versiones (scripts/update-lib.mjs, TRUSTED_KEYS): Ed25519, «x» en base64url.
KEY_ID=survival-2026-11
KEY_X=XNjxY1scmfOYb6l6nwCFsQDjoTXPw7ffdsllKmSMsY0

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

CHECK_ONLY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --comprobar) CHECK_ONLY=1 ;;
    --no-kiosk|--kiosk|--no-branding|--branding) ARGS+=("$a") ;;
    *) die "opción desconocida: $a (válidas: --no-kiosk, --no-branding, --comprobar)" ;;
  esac
done

if [ "$CHECK_ONLY" = 0 ]; then
  [ "$(id -u)" = 0 ] || die "hace falta sudo:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/instalar.sh | sudo bash"
  [ -d /run/systemd/system ] || die "este sistema no usa systemd; usa la versión portable (README → Empezar con la versión portable)"
fi
case "$(uname -m)" in
  aarch64|arm64|x86_64) ;;
  *) die "procesador $(uname -m) no soportado: hace falta un sistema de 64 bits (arm64 o x64). En una Raspberry Pi, Raspberry Pi OS de 64 bits." ;;
esac
for c in curl tar sha256sum base64; do
  command -v "$c" >/dev/null || die "falta «$c» (sudo apt install $c)"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

say "Buscando la última versión de Survivelia OS"
curl -fsSL --retry 3 "$BASE/survival-os-update.json" -o manifest.json || die "sin conexión con GitHub"
curl -fsSL --retry 3 "$BASE/survival-os-update.json.sig" -o manifest.sig || die "sin conexión con GitHub"

# --- Firma Ed25519 del manifiesto (OpenSSL 3: Raspberry Pi OS Bookworm, Debian 12, Ubuntu 22.04 o posteriores)
b64url() { local s; s=$(printf '%s' "$1" | tr '_-' '/+'); while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; printf '%s' "$s" | base64 -d; }
sig_key=$(tr -d '\n ' < manifest.sig | sed -n 's/.*"keyId":"\([^"]*\)".*/\1/p')
sig_b64=$(tr -d '\n ' < manifest.sig | sed -n 's/.*"sig":"\([^"]*\)".*/\1/p')
[ "$sig_key" = "$KEY_ID" ] || die "el manifiesto está firmado con una clave desconocida (${sig_key:-ninguna})"
b64url "$sig_b64" > manifest.sig.bin
# Clave pública en DER: cabecera SubjectPublicKeyInfo de Ed25519 (302a300506032b6570032100) + los 32 bytes de la clave.
{ printf '%s' 'MCowBQYDK2VwAyEA' | base64 -d; b64url "$KEY_X"; } > key.der
[ "$(wc -c < key.der)" -eq 44 ] || die "clave pública mal formada"
if command -v openssl >/dev/null && openssl pkeyutl -verify -pubin -keyform DER -inkey key.der -rawin -in manifest.json -sigfile manifest.sig.bin >/dev/null 2>&1; then
  echo "    firma de Survivelia OS comprobada"
elif command -v openssl >/dev/null && openssl version | grep -q '^OpenSSL 3'; then
  die "la firma del manifiesto NO es válida: no se instala nada"
else
  # OpenSSL 1.1 (Debian 11) no verifica Ed25519 desde la línea de órdenes: se confía en HTTPS de GitHub y en el SHA-256.
  echo "    AVISO: este sistema no puede comprobar firmas Ed25519 (hace falta OpenSSL 3); se comprueba el SHA-256 sobre HTTPS"
fi

# --- Paquete del sistema (kind "system") y su SHA-256, del manifiesto ya verificado
flat=$(tr -d '\n\r\t ' < manifest.json)
version=$(printf '%s' "$flat" | sed -n 's/^{.*"version":"\([0-9][0-9.]*\)".*/\1/p' | head -1)
tarball="survival-os-$version.tar.gz"
sha=$(printf '%s' "$flat" | grep -o "\"name\":\"$tarball\"[^}]*" | sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p')
[ -n "$version" ] && [ -n "$sha" ] || die "manifiesto sin paquete del sistema"
say "Descargando Survivelia OS $version"
curl -fL --retry 3 --progress-bar "$BASE/$tarball" -o "$tarball" || die "no se pudo descargar $tarball"
echo "$sha  $tarball" | sha256sum -c --quiet - || die "el SHA-256 de $tarball no coincide: descarga borrada"
echo "    SHA-256 comprobado"

installer=$(tar -tzf "$tarball" | grep -m1 '/scripts/install-system.sh$\|^scripts/install-system.sh$' || true)
[ -n "$installer" ] || die "el paquete no trae scripts/install-system.sh"
tar -xzf "$tarball" "$installer"

if [ "$CHECK_ONLY" = 1 ]; then
  say "Comprobado: Survivelia OS $version listo para instalar (no se ha instalado nada)"
  exit 0
fi

say "Instalando Survivelia OS $version"
bash "$installer" "$TMP/$tarball" "${ARGS[@]}"

say "Survivelia OS $version instalado"
if printf '%s ' "${ARGS[@]}" | grep -q -- '--no-kiosk'; then
  echo "    Ábrelo en este equipo: http://127.0.0.1:3000"
else
  echo "    Reinicia para arrancar a pantalla completa:  sudo reboot"
fi
echo "    La primera vez verás la bienvenida: idioma, país y «Descargarlo todo»."
