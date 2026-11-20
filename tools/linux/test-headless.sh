#!/bin/sh
# T9 fase B (L8): suite del motor en Linux dentro de devagents-t9:ubuntu24.04.
# Uso (desde la raiz del repo):
#   docker run --rm -v "$PWD:/src:ro" -v devagents-t9-cache:/cache -v devagents-t9-prefix:/prefix
#     devagents-t9:ubuntu24.04 sh /src/tools/linux/test-headless.sh <etiqueta>
# Datos en una carpeta temporal (DEVAGENTS_DATA_DIR); cache y prefijo en volumenes.
set -u
export ZIG_GLOBAL_CACHE_DIR=/cache/global
export DEVAGENTS_DATA_DIR="$(mktemp -d /tmp/devagents-data-XXXXXX)"
unset BEATS_DATA_DIR
echo "== entorno"; cat /etc/os-release | head -2; uname -srm; zig version; git --version; python3 --version; id
echo "DEVAGENTS_DATA_DIR=$DEVAGENTS_DATA_DIR"
for t in claude codex gemini opencode gh node; do command -v $t >/dev/null 2>&1 && echo "PRESENTE: $t" || echo "ausente: $t"; done
cd /src
start=$(date +%s)
zig build test-headless -j1 --test-timeout 10m --cache-dir /cache/local-$1 --prefix /prefix/out-$1 --summary all 2>&1
rc=$?
echo "exit=$rc secs=$(( $(date +%s) - start ))"
