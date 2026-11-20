# ===============================================================================
# CREATE DESKTOP SHORTCUT FOR DEVAGENTS
$root = Split-Path -Parent $PSScriptRoot
# ===============================================================================

$desktop = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$shortcutPath = Join-Path $desktop "DevAgents.lnk"
$targetExe = (Join-Path $root 'zig-out\\bin\\devagents-host.exe')
$workDir = $root

$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath = $targetExe
$sc.WorkingDirectory = $workDir
$sc.Description = "DevAgents Native Desktop Application"
$sc.Save()

Write-Host "Acceso directo creado en: $shortcutPath"
