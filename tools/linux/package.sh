#!/bin/sh
# T9 fase B: paquete Linux de DevAgents (motor, CLI y MCP, sin cabina).
# Produce <salida>/devagents-<version>-linux-x86_64.tar.gz y su .sha256.
#
# Uso (desde la raiz del repo, dentro de devagents-t9:ubuntu24.04 o con Zig
# 0.16.0 en el PATH):
#   sh tools/linux/package.sh <carpeta-de-salida> [carpeta-de-cache]
#
# Contenido: bin/devagents (CLI), bin/devagents-core (la misma imagen con su
# nombre de motor), bin/devagents-engine, bin/devagents-mcp, bin/key-admin
# (claves en ~/.config/devagents con 0600) y LICENSE/NOTICE si existen.
set -eu

out="${1:?falta la carpeta de salida}"
cache="${2:-${TMPDIR:-/tmp}/devagents-package-cache}"
root="$(cd "$(dirname "$0")/../.." && pwd)"

version="$(sed -n 's/^pub const VERSION = "\([^"]*\)";.*/\1/p' "$root/core/src/root.zig")"
[ -n "$version" ] || { echo "package.sh: no se encontro VERSION en core/src/root.zig" >&2; exit 1; }
name="devagents-$version-linux-x86_64"

work="$(mktemp -d "${TMPDIR:-/tmp}/devagents-package-XXXXXX")"
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
stage="$work/$name"

cd "$root"
zig build headless -j1 -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe \
    --cache-dir "$cache" --prefix "$prefix" --summary none

mkdir -p "$stage/bin"
for exe in devagents devagents-core devagents-engine devagents-mcp key-admin; do
    [ -f "$prefix/bin/$exe" ] || { echo "package.sh: falta $prefix/bin/$exe" >&2; exit 1; }
    install -m 0755 "$prefix/bin/$exe" "$stage/bin/$exe"
done
for doc in LICENSE NOTICE; do
    if [ -f "$root/$doc" ]; then install -m 0644 "$root/$doc" "$stage/$doc"; fi
done

mkdir -p "$out"
tar -C "$work" --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" "$name"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
cat "$out/$name.tar.gz.sha256"
