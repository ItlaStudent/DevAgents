#!/bin/sh
# T9 fase B (L9 y prueba del paquete): descomprime el .tar.gz en limpio y usa
# la CLI, el MCP por stdio y las claves 0600, sin red y con datos temporales.
# Uso, en un contenedor NUEVO y sin red (desde la raiz del repo):
#   docker run --rm --network none -v "$PWD:/src:ro" -v <carpeta-del-paquete>:/pkg:ro \
#     devagents-t9:ubuntu24.04 sh /src/tools/linux/smoke.sh /pkg
# La clave que se guarda es falsa ("sk-test-..."): no sale a ninguna parte (sin
# red) y se borra antes de lanzar la orden, para que la orden use el doble de
# prueba (MockWorker) y no un proveedor real.
set -u
pkgdir="${1:?falta la carpeta con el .tar.gz}"
work="$(mktemp -d /tmp/devagents-smoke-XXXXXX)"
step() { printf '\n== %s\n' "$*"; }

step "paquete"
cd "$pkgdir" && sha256sum -c ./*.tar.gz.sha256 || exit 1
tar -xzf "$pkgdir"/*.tar.gz -C "$work" || exit 1
root="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'devagents-*' | head -1)"
ls -la "$root" "$root/bin"
export PATH="$root/bin:$PATH"
export DEVAGENTS_DATA_DIR="$work/datos"
unset BEATS_DATA_DIR
export XDG_CONFIG_HOME="$work/config"
mkdir -p "$DEVAGENTS_DATA_DIR"
echo "DEVAGENTS_DATA_DIR=$DEVAGENTS_DATA_DIR XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
for t in claude codex gemini opencode gh; do command -v "$t" >/dev/null 2>&1 && echo "PRESENTE: $t" || echo "ausente: $t"; done

step "devagents --version"
devagents --version; echo "exit=$?"

step "devagents doctor"
devagents doctor; echo "exit=$?"

step "claves: key-admin con una clave falsa, permisos y borrado"
key-admin Groq "sk-test-t9b-linux-no-sale-a-red-0000" t9b; echo "exit=$?"
key-admin --status; echo "exit=$?"
if [ -d "$XDG_CONFIG_HOME/devagents" ]; then
    stat -c '%a %U %n' "$XDG_CONFIG_HOME/devagents"
    find "$XDG_CONFIG_HOME/devagents" -type f -exec stat -c '%a %U %s %n' {} \;
else
    echo "no existe $XDG_CONFIG_HOME/devagents"
fi
key-admin --clear-keys Groq; echo "exit=$?"
key-admin --status; echo "exit=$?"

step "orden real por la CLI (sin clave: doble de prueba)"
proyecto="$work/proyecto"
mkdir -p "$proyecto"
cd "$proyecto"
devagents order "Crea un archivo hola.txt con el texto: hola desde Linux" --answer target-language=Zig --yes; echo "exit=$?"
echo "-- archivos de la orden en disco (fuera de bin y de las bases):"
find "$work" -type f -not -path "$root/*" -not -path '*/.git/*' -not -name '*.db*' -not -name 'keys.json*' -not -name 'mcp.*' | sort | while read -r f; do
    echo "$f ($(wc -c < "$f") bytes)"
    case "$f" in *orden-*) head -c 400 "$f"; echo ;; esac
done

step "MCP por stdio: initialize, tools/list y una tool de lectura"
cd "$work"
printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t9b-smoke","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}' \
    | devagents-mcp > "$work/mcp.out" 2> "$work/mcp.err"
echo "exit=$?"
python3 - "$work/mcp.out" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    mid = msg.get("id")
    res = msg.get("result", {})
    if mid == 1:
        print("initialize:", res.get("serverInfo"), "protocol", res.get("protocolVersion"))
    elif mid == 2:
        tools = res.get("tools", [])
        print("tools/list:", len(tools), "tools; primeras:", [t["name"] for t in tools[:8]])
    elif mid == 3:
        text = res.get("content", [{}])[0].get("text", "")
        print("capabilities:", text[:600])
    else:
        print("otro:", line[:300])
PY
echo "-- stderr del MCP (primeras lineas):"
head -5 "$work/mcp.err"
