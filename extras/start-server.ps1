# Backs up the world save, then starts the dedicated server.
# Extra arguments are passed to PalServer.exe, e.g.:  .\start-server.ps1 -ServerDir D:\PalServer -port=8211
param(
    [string]$ServerDir = "C:\Program Files (x86)\Steam\steamapps\common\PalServer",
    [int]$KeepBackups = 10
)

$save = Join-Path $ServerDir "Pal\Saved\SaveGames"
if (-not (Test-Path $save)) {
    Write-Error "No save folder at $save. Set -ServerDir to your PalServer folder."
    exit 1
}

$backupRoot = Join-Path $ServerDir "OfflineProgressBackups"
$target = Join-Path $backupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item -Recurse $save $target
Write-Host "Backed up save to $target"

Get-ChildItem $backupRoot -Directory |
    Sort-Object Name -Descending |
    Select-Object -Skip $KeepBackups |
    Remove-Item -Recurse -Force

& (Join-Path $ServerDir "PalServer.exe") @args
