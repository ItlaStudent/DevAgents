#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Commit = 'HEAD',
    [Parameter(Position = 1)]
    [string]$Salida = (Join-Path $env:LOCALAPPDATA ('Temp/angel-publico-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
& python (Join-Path $PSScriptRoot 'exportar_arbol_publico.py') $root $Commit $Salida
exit $LASTEXITCODE
