# DevAgents User Guide

> **Historical snapshot (2026-09-21), retained for context:** the earlier edition reported 185 tests, “UI not implemented”, an Engram mock, suite 1222/1224 (E3, 21-09), 76 authenticated MCP tools, and live acceptance of 20 scenarios on 2026-09-16. Those figures and statuses are not current. At the 12-Oct-2026 cutoff, the latest global suite recorded is 1753/1753 tests in 82/82 steps (9-Oct; not rerun on `main` `2e377be`); the native C++/WebView2 cabin is implemented but its E5 walkthrough remains open; the source now has 108 unique MCP tools. Sources: `la documentación interna:3,59,212-215`, `tools/mcp_server.zig:1420-1529,3205`, and `la documentación interna:1094-1095`.
>
> This guide keeps its original procedures and historical entries. For current product state use the [README](../README.md), `la documentación interna`, and append-only audit register. The installer is currently self-signed and triggers SmartScreen; this guide contains no download/install procedure for it (detalle en la evidencia interna).
>
> The earlier migration notice also linked `la documentación interna`; that file remains an archived planning snapshot, while current states are in the checklist and audit register.
>
> The earlier notice said that sections below were reliable only where the README confirmed them; retain that caution for the original migration-era procedures. Current state and open items are in the checklist and audit register above.

## Overview

DevAgents is an AI-powered development agent orchestrator. It takes high-level orders, breaks them into plans, dispatches parallel workers, audits results, and produces consolidated reports — all with a deterministic, testable pipeline.

## Prerequisites

- **Windows** (required — uses DPAPI for key encryption, named pipes for IPC, kernel32 for threading)
- **Zig 0.16.0 (current)** at `C:\devagents\toolchain\zig\zig.exe`; Download Zig 0.16.0 for your platform and point `ZIG_PATH` at the executable.
- **PowerShell 7+** (pwsh) for verification scripts

### Build from source

```powershell
& "path\to\zig.exe" build
```

This produces `zig-out/bin/` with all executables.

For current builds, use a fresh cache per session at `%LOCALAPPDATA%\Temp\beats-cache-<session>`, export `ZIG_PATH` and `DEVAGENTS_HOOK_CACHE`, and keep at least 15 GiB free. Caches and generated outputs may be deleted without damaging the project. Source: `las reglas del repositorio:69,79-80` (owner order, 2026-10-10).

```powershell
$session = Get-Date -Format 'yyyyMMdd-HHmmss'
$cache = Join-Path $env:LOCALAPPDATA "Temp\beats-cache-$session"
$env:ZIG_PATH = "C:\devagents\toolchain\zig\zig.exe"
$env:DEVAGENTS_HOOK_CACHE = $cache
& $env:ZIG_PATH build -j1 --cache-dir $cache
```

## Key Management

DevAgents encrypts API keys with Windows DPAPI. Keys never appear in plaintext in logs, output, or the database.

### Adding a key

```powershell
.\zig-out\bin\key-admin.exe <provider> <key> [label]
```

Example:
```powershell
.\zig-out\bin\key-admin.exe OpenCode sk-your-key-here default
```

Historical provider list from the first edition (2026-07-30): `OpenCode`, `NVIDIA`, `Groq`, `Anthropic`, `Gemini`, `Cohere`, `el agente`. The current checklist records 29 models across 5 providers and flags the old “seven providers” count for reconciliation; use the current catalog for accepted provider IDs (detalle en la evidencia interna).

Keys are stored encrypted in `catalog.db`. The `key-admin` tool never prints the key value.

### Verifying providers

```powershell
# Set environment variables for live verification:
$env:DEVAGENTS_NVIDIA_KEY = "nvapi-your-key"
$env:DEVAGENTS_OPENCODE_KEY = "sk-your-key"

# Run the gate to verify
zig build gate-g2a
```

Historical note from the initial migration: G2a was blocked without valid API keys. Current live-provider checks and their key requirements are tracked in and the latest status in `la documentación interna:61`.

## Mounting Folders

Mount external directories to import agents, skills, and MCPs from other projects:

```powershell
devagents mount add <path>
devagents mount list
devagents mount remove <path>
```

Mounted directories are scanned for `.claude/agents/`, `skills/*/SKILL.md`, and MCP configs.

## CLI Commands

The spellings below are from the original guide. Current executable and argument forms were checked against `devagents-core.exe --help` on 12-Oct-2026; see [`docs/COMANDOS-COBERTURA.md`](COMANDOS-COBERTURA.md#L1-L25). The old `devagents` wrapper is not asserted to exist.

| Historical command | Current CLI form | Description |
|---------|-------------|-------------|
| `devagents order "<description>"` | `zig-out\bin\devagents-core.exe order "<text>" [--yes] [--sudo]` | Submit a work order |
| `devagents chat` | `zig-out\bin\devagents-core.exe chat --model <id> [--provider <name>] [--prompt <text>\|--stdin]` | Interactive chat session |
| `devagents mount add/remove/list` | `zig-out\bin\devagents-core.exe mount add\|remove\|list <path>` | Manage mounted folders |
| `devagents webhook add/remove/list` | `zig-out\bin\devagents-core.exe webhook add --url <url> [--event <ev>]; remove <id>; list` | Manage webhooks |

## Running Verification

The verification block below records the original 185-test migration snapshot and its gates; those commands and counts are historical (2026-07-30), not a current test inventory. The latest global result recorded as of 12-Oct is 1753/1753 tests in 82/82 steps on 9-Oct; it was not rerun on `main` `2e377be` (`la documentación interna:1094-1095`; `la documentación interna:212`). Current suite command, per `las reglas del repositorio:69,80`:

```powershell
$session = Get-Date -Format 'yyyyMMdd-HHmmss'
$cache = Join-Path $env:LOCALAPPDATA "Temp\beats-cache-$session"
$env:ZIG_PATH = "C:\devagents\toolchain\zig\zig.exe"
$env:DEVAGENTS_HOOK_CACHE = $cache
& $env:ZIG_PATH build test -j1 --cache-dir $env:DEVAGENTS_HOOK_CACHE --summary all
```

```powershell
# Run all tests (185 tests)
zig build test

# Run specific gates
zig build gate-f4    # Superagent loop
zig build gate-g3    # MVP pipeline
zig build gate-f6    # Shared memory recall
zig build gate-f8    # Extensibility

# Run full E2E suite
zig build e2e

# Run parser fuzzer (100k iterations)
zig build fuzz

# Run secrets check
zig build secrets-check

# Profile scheduler
zig build bench-scheduler
```

## Blocked / Deuda Declarada

The table preserves the initial migration snapshot (2026-07-30). Read “Today” for the current status; source of truth is `la documentación interna` and the cited CK IDs.

| Feature | Historical status | Today (12-Oct-2026) |
|---------|--------|--------|
| Live LLM calls (G2a) | Blocked; requires valid API keys | Provider inventory and live checks remain tracked by; see `la documentación interna:61`. |
| UI (Qt/C++) | Deferred; “IDE shell compiles but UI not implemented” | The current cabin is native C++/Win32 + WebView2; E5 cabin walkthrough remains open (detalle en la evidencia interna; host target and WebView origin: `build.zig:212-215`, `shell/host/webview_host.cpp:809,943`). |
| Real Engram memory (Gemini) | Deferred; “Mock implementation in place” | An Engram MCP backend exists (`core/src/engram_memory.zig:54-90`), but two-session persistent-memory behavior remains HECHO-SIN-VERIFICAR under (`la documentación interna:99`). |
| HTTP server for webhooks (incoming) | Deferred; outgoing webhooks via mock `sendFn` work | The current MCP server exposes outgoing webhook tools; this does not claim incoming HTTP support or verified delivery (`tools/mcp_server.zig:1320-1328`; current status: `la documentación interna`). |
| Linux/macOS support | Deferred; Windows-only (DPAPI, kernel32, named pipes) | The product README remains Windows 10/11; B10 is still an unintegrated branch (`README.md:47-50`; `la documentación interna:59`). |

## Troubleshooting

**Tests show fewer than 185**: Historical migration diagnostic (2026-07-30); the original advice was to clear `.zig-cache/` and rebuild. Current recorded suite count is 1753/1753; if investigating a cache issue, use a fresh per-session cache and the 15-GiB rule from `las reglas del repositorio:79-80` (`la documentación interna:1094-1095`; `la documentación interna:212`).

**`zig build` fails with 1 errors**: Historical wording from the original guide; its advice was to check the old Zig 0.16 fork path and run `zig fmt --check.`. Today use Zig 0.16.0 at the path in `las reglas del repositorio:80`; verify the actual compiler output and use the current session cache.

**Keys not encrypting**: Ensure Windows DPAPI is available. The original “Pro/Enterprise editions” requirement is historical and is not enforced by this implementation; encryption calls `CryptProtectData` / `CryptUnprotectData` without an edition check (`core/src/dpapi.zig:14-32,42-65`).

**Pre-commit hooks fail**: Run `.\tools\install-hooks.ps1` to install hooks.
