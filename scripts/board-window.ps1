# board-window.ps1 - open the live pool board in its OWN terminal window (shared launcher).
#
# Two uses: (1) the pool LEAD's wrapper calls this at session start so the board pops up automatically;
#           (2) an agent or the user runs it on demand (also reachable as:  pool.ps1 board -Show ).
# Idempotent: if a live board window for THIS exact bus is already open, it does not open a second one.
# BusRoot defaults to $env:POOL_BUS_ROOT (the pool wrapper sets it). ASCII source; no Cyrillic.
param(
  [string]$BusRoot = $env:POOL_BUS_ROOT,
  [int]$IntervalSeconds = 8,
  [switch]$Notify
)
$ErrorActionPreference = 'Stop'
if (-not $BusRoot) { Write-Warning 'board-window: -BusRoot required (or set $env:POOL_BUS_ROOT). Not a pool session?'; return }
$BusRoot = [System.IO.Path]::GetFullPath($BusRoot)
$pool = Join-Path $PSScriptRoot 'pool.ps1'
$tag  = try { Split-Path (Split-Path $BusRoot -Parent) -Leaf } catch { 'pool' }

# Idempotency: skip if a 'board -Watch' window for this exact bus is already running.
try {
  $open = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*board*-Watch*' -and $_.CommandLine -like ('*' + $BusRoot + '*') } |
    Select-Object -First 1
} catch { $open = $null }
if ($open) { Write-Host ("[board-window] already open for '{0}' (PID {1})." -f $tag, $open.ProcessId); return }

$notifyFlag = if ($Notify -or (Test-Path (Join-Path $PSScriptRoot '.board-notify'))) { ' -Notify' } else { '' }
$inner  = "`$host.ui.RawUI.WindowTitle='POOL BOARD - $tag'; & '$pool' board -Watch -BusRoot '$BusRoot' -IntervalSeconds $IntervalSeconds$notifyFlag"
$psArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$inner`""
Start-Process powershell -ArgumentList $psArgs | Out-Null
Write-Host ("[board-window] opened live board for '{0}' (refresh {1}s)." -f $tag, $IntervalSeconds)
