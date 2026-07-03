# pool.ps1 - SHARED maildir message bus for agent-pool coordination (v1 prototype, 2026-06-21).
#
# ONE shared copy for the whole workspace (<workspace-root>\.launcher\pool-bus\pool.ps1).
# Pools supply only DATA (a per-pool .bus/ store) + thin binding (hook config, wrapper env).
# Editing this one file changes behavior for every pool at once - no per-pool rollout.
#
# ASCII-only source (PS 5.1 mangles Cyrillic in .ps1 without BOM). Message BODIES are
# written/read as UTF-8 without BOM at runtime, so Cyrillic DATA is safe.
#
# Maildir model: one immutable file = one message; recipient = folder; state = folder; transition = atomic rename.
#   <BusRoot>/<recipient>/{tmp,new,cur}/   new = unread, cur = claimed/in-progress
#   <BusRoot>/archive/                      acked / terminal
#   <BusRoot>/.ledger/seen-<owner>.txt      per-recipient watcher ledger (ids already woken on)
#   <BusRoot>/.watch/lock-<owner>.txt       watcher singleton heartbeat
#
# Owner/BusRoot default to env (AGENT_OWNER / POOL_BUS_ROOT) so the hook and watcher are env-driven.
#
# Commands:
#   pool.ps1 send    -To <o> -From <o> -Subject <s> [-Body <t> | -BodyFile <p>] [-Kind coord] -BusRoot <d>
#   pool.ps1 reply   -To <o> -From <o> -Subject <s> [-Body|-BodyFile] [-InReplyTo <id>] -BusRoot <d>
#   pool.ps1 note    -To <o> -From <o> -Subject <s> [-Body|-BodyFile] [-Wake] -BusRoot <d>   # message, NOT a task
#   pool.ps1 inbox   -Owner <o> -BusRoot <d>
#   pool.ps1 mine    -Owner <o> -BusRoot <d>          # personal plate: my cur/ (in-progress) + new/ (pending) + notes
#   pool.ps1 claim   -Owner <o> -Id <id> -BusRoot <d>
#   pool.ps1 ack     -Owner <o> -Id <id> -BusRoot <d>
#   pool.ps1 dismiss -Owner <o> -Id <id> -BusRoot <d> # clear a note (new/ -> archive, one step, no claim/ack)
#   pool.ps1 check   -Owner <o> -BusRoot <d>          # one watcher detection pass
#   pool.ps1 watch   -Owner <o> -BusRoot <d> [-IntervalSeconds 45]   # background sleeping watcher
#   pool.ps1 hook                                     # UserPromptSubmit hook (env-driven, silent if not a pool)
#   pool.ps1 activity                                 # hook: write .activity/<owner> state (busy/idle/subagents); reads payload from stdin, env-driven, silent
#   pool.ps1 board   -BusRoot <d> [-Watch | -Show] [-IntervalSeconds 8]   # table; -Watch=live here; -Show=open live board in a NEW window
#   pool.ps1 help
#
# note = a message, not a task: hidden from the board, shown in a separate [POOL NOTE] inbox section,
# cleared with `dismiss` (no claim/ack). Plain `note` is quiet (picked up by the hook on the next turn);
# `note -Wake` also wakes an idle watcher, exactly like a task.

param(
  [Parameter(Mandatory,Position=0)]
  [ValidateSet('send','reply','note','inbox','mine','claim','ack','dismiss','check','watch','hook','activity','board','help')]
  [string]$Cmd,
  [string]$To, [string]$From, [string]$Owner, [string]$Subject,
  [string]$Body, [string]$BodyFile, [string]$Id, [string]$InReplyTo,
  [string]$Kind = 'coord',
  [string]$BusRoot,
  [int]$IntervalSeconds = 45,
  [switch]$Watch,
  [switch]$Show,
  [switch]$Wake,
  [switch]$Notify
)

$ErrorActionPreference = 'Stop'
$script:U8 = New-Object System.Text.UTF8Encoding($false)

if (-not $BusRoot) { $BusRoot = $env:POOL_BUS_ROOT }
if (-not $Owner)   { $Owner   = $env:AGENT_OWNER }
if ($BusRoot)      { $BusRoot = [System.IO.Path]::GetFullPath($BusRoot) }

function Require-Bus { if (-not $BusRoot) { throw 'BusRoot required: pass -BusRoot or set $env:POOL_BUS_ROOT' } }

function Ensure-Dir([string]$d) { [System.IO.Directory]::CreateDirectory($d) | Out-Null; $d }
function Owner-Dir([string]$o)  { Ensure-Dir (Join-Path $BusRoot $o) }
function Sub-Dir([string]$o,[string]$s) { Ensure-Dir (Join-Path (Owner-Dir $o) $s) }
function Ledger-Dir   { Ensure-Dir (Join-Path $BusRoot '.ledger') }
function Watch-Dir    { Ensure-Dir (Join-Path $BusRoot '.watch') }
function Archive-Dir  { Ensure-Dir (Join-Path $BusRoot 'archive') }

function Write-Utf8([string]$path,[string]$text) { [System.IO.File]::WriteAllText($path, $text, $script:U8) }
function Read-Utf8([string]$path) { [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }

# id = unix-ms (lexicographically sortable until ~2286) + '-' + 10 random hex. Never reused
# (time advances; random suffix avoids same-ms collision). Coordination-free: no shared counter, no lock.
function New-MsgId {
  $ms   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $rand = -join (1..10 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
  "{0}-{1}" -f $ms, $rand
}

# <id>.from-<from>.<kind>[.<pid>.<claimedms>].md -> id/from/kind
function Parse-MsgName([string]$name) {
  if ($name -match '^(?<id>[^.]+)\.from-(?<from>[^.]+)\.(?<kind>[^.]+?)(\.\d+\.\d+)?\.md$') {
    [pscustomobject]@{ id = $Matches.id; from = $Matches.from; kind = $Matches.kind; name = $name }
  } else { $null }
}

function Get-BodyText {
  if ($BodyFile) { return (Read-Utf8 $BodyFile) }
  if ($PSBoundParameters.ContainsKey('Body')) { return $Body }
  ''
}

function First-Subject([string]$path) { try { ((Read-Utf8 $path) -split "`n")[0] -replace '^#\s*', '' } catch { $null } }  # file may be consumed (claimed/archived) between the board's dir snapshot and this read -> tolerate, don't crash the render

# Migration/system notices (from=migration) are bus FYI, not real work - hidden from the monitor board.
function Is-Migration([string]$name) { $p = Parse-MsgName $name; [bool]($p -and $p.from -eq 'migration') }

# Notes (kind note / note-wake) are messages, NOT tasks: hidden from the board, shown in a separate inbox
# section, cleared with `dismiss` (no claim/ack). Quiet `note` never wakes the watcher; `note-wake` does.
function Is-Note([string]$name) { $p = Parse-MsgName $name; [bool]($p -and $p.kind -match '^note') }

# Watcher wakes on tasks and note-wake; never on a quiet note or migration FYI. Unknown name -> wake (conservative).
function Is-Wakeable([string]$name) {
  $p = Parse-MsgName $name
  if (-not $p) { return $true }
  if ($p.from -eq 'migration') { return $false }
  if ($p.kind -eq 'note')      { return $false }
  $true
}

function Invoke-Send([string]$toOwner,[string]$fromOwner,[string]$subj,[string]$kind,[string]$inReplyTo) {
  Require-Bus
  if (-not $toOwner -or -not $fromOwner -or -not $subj) { throw 'send/reply require -To -From -Subject' }
  $id     = New-MsgId
  $iso    = (Get-Date).ToString('o')
  $thread = if ($inReplyTo) { $inReplyTo } else { $id }
  $content = "# " + $subj + "`n`n" +
             "| Field | Value |`n|---|---|`n" +
             "| From | "   + $fromOwner + " |`n" +
             "| To | "     + $toOwner   + " |`n" +
             "| Date | "   + $iso       + " |`n" +
             "| Thread | " + $thread    + " |`n`n" +
             (Get-BodyText) + "`n"
  $tmp   = Join-Path (Sub-Dir $toOwner 'tmp') ($id + '.tmp')
  $final = Join-Path (Sub-Dir $toOwner 'new') (("{0}.from-{1}.{2}.md") -f $id, $fromOwner, $kind)
  Write-Utf8 $tmp $content
  [System.IO.File]::Move($tmp, $final)   # atomic on same NTFS volume; target unique, so no overwrite path
  $id
}

function Invoke-Inbox([string]$o) {
  Require-Bus
  $files = @(Get-ChildItem -Path (Sub-Dir $o 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  $notes = @($files | Where-Object { Is-Note $_.Name })
  $tasks = @($files | Where-Object { -not (Is-Note $_.Name) })
  if ($tasks.Count -eq 0) {
    Write-Output ("[POOL INBOX] {0}: clean (0 pending)" -f $o)
  } else {
    Write-Output ("[POOL INBOX] {0}: {1} pending" -f $o, $tasks.Count)
    foreach ($f in $tasks) {
      $p = Parse-MsgName $f.Name
      if ($p) { Write-Output (" - {0} (from {1}): {2}" -f $p.id, $p.from, (First-Subject $f.FullName)) }
    }
    Write-Output ("Take: pool.ps1 claim -Owner {0} -Id <id>" -f $o)
  }
  if ($notes.Count -gt 0) {
    Write-Output ("[POOL NOTE] {0}: {1} message(s) - FYI, not a task" -f $o, $notes.Count)
    foreach ($f in $notes) {
      $p = Parse-MsgName $f.Name
      if ($p) { Write-Output (" - {0} (from {1}): {2}" -f $p.id, $p.from, (First-Subject $f.FullName)) }
    }
    Write-Output ("Read & clear: pool.ps1 dismiss -Owner {0} -Id <id>" -f $o)
  }
}

function Invoke-Claim([string]$o,[string]$mid) {
  Require-Bus
  if (-not $mid) { throw 'claim requires -Id' }
  $m = Get-ChildItem -Path (Sub-Dir $o 'new') -Filter ($mid + '.from-*.md') -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $m) { Write-Output ("CLAIM-MISS: {0} not in new/{1} (already taken/gone)" -f $mid, $o); return }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($m.Name)
  $dest = Join-Path (Sub-Dir $o 'cur') ("{0}.{1}.{2}.md" -f $base, $PID, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  [System.IO.File]::Move($m.FullName, $dest)   # atomic rename = the claim; loser gets FileNotFound
  Write-Output ("CLAIMED: {0}" -f $mid)
}

function Invoke-Ack([string]$o,[string]$mid) {
  Require-Bus
  if (-not $mid) { throw 'ack requires -Id' }
  $m = Get-ChildItem -Path (Sub-Dir $o 'cur') -Filter ($mid + '.from-*') -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $m) { Write-Output ("ACK-MISS: {0} not in cur/{1}" -f $mid, $o); return }
  [System.IO.File]::Move($m.FullName, (Join-Path (Archive-Dir) $m.Name))
  Write-Output ("ACKED: {0}" -f $mid)
}

# Dismiss a note: new/ -> archive in one step (no claim/ack). For messages, not tasks - though it will
# move any new/ file, so a recipient can also use it to drop a task they intentionally won't action.
function Invoke-Dismiss([string]$o,[string]$mid) {
  Require-Bus
  if (-not $mid) { throw 'dismiss requires -Id' }
  $m = Get-ChildItem -Path (Sub-Dir $o 'new') -Filter ($mid + '.from-*') -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $m) { Write-Output ("DISMISS-MISS: {0} not in new/{1}" -f $mid, $o); return }
  [System.IO.File]::Move($m.FullName, (Join-Path (Archive-Dir) $m.Name))
  Write-Output ("DISMISSED: {0}" -f $mid)
}

# Watcher detection: wake iff new/<owner>/ holds a file whose id is not in the ledger.
# Signal = presence + id-ledger (NOT mtime, NOT bare-id-in-shared-store). On fire, ledger := all current new ids.
function Invoke-Check([string]$o) {
  Require-Bus
  $ledger = Join-Path (Ledger-Dir) ("seen-{0}.txt" -f $o)
  $seen = @{}
  if (Test-Path $ledger) { foreach ($l in [System.IO.File]::ReadAllLines($ledger)) { $t = "$l".Trim(); if ($t) { $seen[$t] = $true } } }
  $ids = @()       # every id currently in new/ (ledger snapshot on fire)
  $wake = @()      # unseen AND wakeable (tasks + note-wake; quiet notes/migration never wake)
  foreach ($f in (Get-ChildItem -Path (Sub-Dir $o 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    $p = Parse-MsgName $f.Name; if (-not $p) { continue }
    $ids += $p.id
    if (-not $seen.ContainsKey($p.id) -and (Is-Wakeable $f.Name)) { $wake += $p.id }
  }
  if ($wake.Count -gt 0) {
    [System.IO.File]::WriteAllLines($ledger, [string[]]$ids, $script:U8)
    Write-Output ("[WAKE] {0}: {1} new" -f $o, $wake.Count)
    foreach ($n in $wake) { Write-Output ("   new: {0}" -f $n) }
  } else {
    Write-Output ("[no-wake] {0}: nothing new" -f $o)
  }
}

# Background "sleeping watcher": polls check; on first fire prints re-arm + exits (harness wakes the agent).
# Singleton heartbeat-lock prevents two watchers per owner. Re-arm is the agent's job (a watcher cannot
# wake an idle session itself). File staying in new/ is the floor: even a lost wake is caught by the hook (pull).
function Invoke-Watch([string]$o,[int]$interval) {
  Require-Bus
  $lock  = Join-Path (Watch-Dir) ("lock-{0}.txt" -f $o)
  $stale = [Math]::Max(120, $interval * 3)
  if (Test-Path $lock) {
    $age = ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalSeconds
    if ($age -lt $stale) { Write-Output ("[WATCH] {0}: another watcher active (lock age {1:N0}s) - exiting (no re-arm)" -f $o, $age); return }
  }
  $reArm = '  Bash(run_in_background:true): powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" watch -Owner {1} -BusRoot "{2}"' -f $PSCommandPath, $o, $BusRoot
  while ($true) {
    Set-Content -Path $lock -Value ((Get-Date).ToString('o')) -Encoding ASCII   # heartbeat
    $det = Invoke-Check $o
    if (($det -join "`n") -match '\[WAKE\]') {
      if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
      Write-Output ("[WATCH] {0}: new task(s). STEP 1 (do FIRST): re-arm watcher:" -f $o)
      Write-Output $reArm
      Write-Output "STEP 2 (after re-arm): handle:"
      $det | Where-Object { $_ -match 'new:' } | ForEach-Object { Write-Output $_ }
      return
    }
    Start-Sleep -Seconds $interval
  }
}

# UserPromptSubmit hook: env-driven, silent for non-pool sessions. Emits the [POOL INBOX] banner.
function Invoke-Hook {
  if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($BusRoot)) { return }  # not a pool session
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  # Quiet when inbox is clean (POOL_INBOX_QUIET=1): inject NOTHING that turn -> no per-turn banner accumulation.
  $pending = @(Get-ChildItem -Path (Sub-Dir $Owner 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue)
  if ($pending.Count -eq 0 -and $env:POOL_INBOX_QUIET -eq '1') { return }
  Invoke-Inbox $Owner
}

# Activity tracker (hook side): env-driven, SILENT (writes files only - never stdout, so it cannot pollute the
# UserPromptSubmit context injection; wrapped so it never throws -> cannot block a turn). Wired in settings.local.json
# to UserPromptSubmit (busy + sweep orphan sub-markers >2h) / Stop (idle ONLY - never clears sub-markers, since background
# subagents outlive the parent turn; only SubagentStop drops a marker) / SubagentStart (add sub-marker) / SubagentStop (drop).
# Per-subagent marker files = no shared counter to race; parallel subagents touch distinct files. Reads the hook
# payload from stdin (or -Body for tests) and self-dispatches on hook_event_name.
function Write-ActivityState([string]$adir, [string]$state) {
  [void](Ensure-Dir $adir)
  $json = '{"state":"' + $state + '","ts":"' + (Get-Date).ToString('o') + '"}'
  [System.IO.File]::WriteAllText((Join-Path $adir 'state.json'), $json, $script:U8)
}
# Backstop for orphaned sub-* markers: a missed SubagentStop (crashed subagent / killed session) would otherwise pin the
# board on a phantom sub<N> forever. Swept on UserPromptSubmit; TTL is generous (2h) so it never drops a live subagent.
function Clear-StaleSubMarkers([string]$adir) {
  if (-not (Test-Path $adir)) { return }
  $cut = (Get-Date).AddHours(-2)
  Get-ChildItem $adir -Filter 'sub-*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Invoke-Activity {
  try {
    if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($BusRoot)) { return }   # not a pool session
    $payload = if ($Body) { $Body } elseif ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { return }
    if ([string]::IsNullOrWhiteSpace($payload)) { return }
    $o = $null; try { $o = $payload | ConvertFrom-Json } catch { return }
    if (-not $o) { return }
    $adir = Join-Path (Join-Path $BusRoot '.activity') $Owner
    switch ("$($o.hook_event_name)") {
      'UserPromptSubmit' { Write-ActivityState $adir 'busy'; Clear-StaleSubMarkers $adir }
      'Stop'             { Write-ActivityState $adir 'idle' }
      'SubagentStart'    { if ($o.agent_id) { [void](Ensure-Dir $adir); [System.IO.File]::WriteAllText((Join-Path $adir ("sub-{0}" -f $o.agent_id)), '', $script:U8) } }
      'SubagentStop'     { if ($o.agent_id) { Remove-Item (Join-Path $adir ("sub-{0}" -f $o.agent_id)) -Force -ErrorAction SilentlyContinue } }
      default { }
    }
  } catch { }
}

# Tiny ANSI painter: wraps text in an SGR color for a live terminal; plain when output is redirected
# (capture/pipe/selftest stay clean, and everything stays on the success stream via Write-Output).
function Paint([string]$text, [string]$sgr) {
  if (-not $script:useColor -or -not $sgr) { return $text }
  $e = [char]27
  $e + '[' + $sgr + 'm' + $text + $e + '[0m'
}

# Watcher liveness from its heartbeat lock (.watch/lock-<owner>.txt): `pool watch` rewrites it every cycle
# and deletes it on fire/exit. Fresh lock = armed & sleeping; stale = died/froze; absent = not armed (or the
# brief fire->re-arm gap, or a watcher the user killed on purpose). Read-only: never creates .watch/.
# Threshold is generous vs the watcher's own self-stale (default interval 45s -> 135s) to avoid boundary flap.
function Get-WatchState([string]$o) {
  $lock = Join-Path (Join-Path $BusRoot '.watch') ("lock-{0}.txt" -f $o)
  if (-not (Test-Path $lock)) { return [pscustomobject]@{ state = 'off'; age = $null } }
  $age = ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalSeconds
  if ($age -le 150) { [pscustomobject]@{ state = 'on'; age = $age } } else { [pscustomobject]@{ state = 'stale'; age = $age } }
}

# Compact age: 90s / 6m / 2h (ASCII source -> letters only).
function Format-Age([double]$sec) {
  if ($sec -lt 120)  { return ("{0:N0}s" -f $sec) }
  if ($sec -lt 7200) { return ("{0:N0}m" -f ($sec / 60)) }
  ("{0:N0}h" -f ($sec / 3600))
}

# Activity state for the board, from .activity/<owner>/ (written by the `activity` hook). subagents = count of
# sub-* marker files; state.json = {state,ts} for busy/idle. busy with a very old ts (>15m, no Stop seen) -> 'busy?'
# (likely crashed mid-turn). No state at all -> 'na' (hook not wired / never ran). Read-only: never creates dirs.
function Get-ActivityState([string]$o) {
  $adir = Join-Path (Join-Path $BusRoot '.activity') $o
  if (-not (Test-Path $adir)) { return [pscustomobject]@{ act = 'na'; subs = 0 } }
  $subs = @(Get-ChildItem $adir -Filter 'sub-*' -File -ErrorAction SilentlyContinue).Count
  if ($subs -gt 0) { return [pscustomobject]@{ act = 'sub'; subs = $subs } }
  $sf = Join-Path $adir 'state.json'
  if (-not (Test-Path $sf)) { return [pscustomobject]@{ act = 'na'; subs = 0 } }
  $st = $null; try { $st = (Read-Utf8 $sf) | ConvertFrom-Json } catch { }
  if (-not $st) { return [pscustomobject]@{ act = 'na'; subs = 0 } }
  if ("$($st.state)" -eq 'busy') {
    $age = try { ((Get-Date) - [datetime]::Parse("$($st.ts)")).TotalSeconds } catch { 999999 }
    if ($age -le 900) { return [pscustomobject]@{ act = 'busy'; subs = 0 } }
    return [pscustomobject]@{ act = 'busy?'; subs = 0 }
  }
  return [pscustomobject]@{ act = 'idle'; subs = 0 }
}

# Monitor board: color-coded table (green=in progress, yellow=pending, gray=idle) + a totals line.
# Each row also shows watcher liveness (w on/off/stale <age> from .watch/lock-<owner>) and activity
# (act busy/idle/sub<N>/busy? from .activity/<owner>); header sums armed watchers + active agents.
# Colors only when interactive; subjects truncated to window width; markers/rules drawn from char codes (ASCII source).
function Invoke-Board {
  Require-Bus
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $script:useColor = -not [Console]::IsOutputRedirected
  $W = try { [Console]::WindowWidth } catch { 100 }; if ($W -lt 50) { $W = 100 }
  if (-not (Test-Path $BusRoot)) { Write-Output (Paint '(empty bus)' '90'); return }

  $dot = [char]0x25CF; $ring = [char]0x25CB; $br = [char]0x2514
  $hr  = [string]([char]0x2500) * [Math]::Min($W - 1, 72)
  $tag = try { Split-Path (Split-Path $BusRoot -Parent) -Leaf } catch { '' }

  $rows = @(Get-ChildItem -Path $BusRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(\.|archive$)' } | Sort-Object Name | ForEach-Object {
      [pscustomobject]@{
        name = $_.Name
        new  = @(Get-ChildItem (Join-Path $_.FullName 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { -not (Is-Migration $_.Name) -and -not (Is-Note $_.Name) })
        cur  = @(Get-ChildItem (Join-Path $_.FullName 'cur') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { -not (Is-Migration $_.Name) -and -not (Is-Note $_.Name) })
        w    = (Get-WatchState $_.Name)
        a    = (Get-ActivityState $_.Name)
      }
    })
  $arch  = @(Get-ChildItem (Join-Path $BusRoot 'archive') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
  $tPend  = [int](($rows | ForEach-Object { $_.new.Count } | Measure-Object -Sum).Sum)
  $tProg  = [int](($rows | ForEach-Object { $_.cur.Count } | Measure-Object -Sum).Sum)
  $tArmed  = [int](@($rows | Where-Object { $_.w.state -eq 'on' }).Count)
  $tActive = [int](@($rows | Where-Object { $_.a.act -eq 'busy' -or $_.a.act -eq 'busy?' -or $_.a.act -eq 'sub' }).Count)
  # "working" = fresh busy / running subagents / stale-busy? whose watcher is STILL alive (process up, just a long
  # quiet turn -> would otherwise falsely read as "stopped"). busy? with a dead/absent watcher = likely crashed ->
  # NOT counted, so the idle-notification can still fire. Drives the idle-notification trigger.
  $script:LastWorking = [int](@($rows | Where-Object { $_.a.act -eq 'busy' -or $_.a.act -eq 'sub' -or ($_.a.act -eq 'busy?' -and $_.w.state -eq 'on') }).Count)
  $script:LastTag = $tag

  Write-Output ((Paint ("POOL BOARD  " + $tag) '1;36') + (Paint ('   ' + (Get-Date).ToString('HH:mm:ss')) '90'))
  Write-Output (Paint $hr '36')
  Write-Output (
    (Paint ("{0} agents" -f $rows.Count) '97') + (Paint '  |  ' '90') +
    (Paint ("{0} pending" -f $tPend) $(if ($tPend) { '93' } else { '90' })) + (Paint '   ' '90') +
    (Paint ("{0} in progress" -f $tProg) $(if ($tProg) { '92' } else { '90' })) + (Paint '   ' '90') +
    (Paint ("{0} done" -f $arch) '90') + (Paint '  |  ' '90') +
    (Paint ("{0}/{1} watchers" -f $tArmed, $rows.Count) $(if ($rows.Count -and $tArmed -eq $rows.Count) { '92' } elseif ($tArmed -eq 0) { '90' } else { '93' })) + (Paint '  |  ' '90') +
    (Paint ("{0} active" -f $tActive) $(if ($tActive) { '93' } else { '90' }))
  )
  Write-Output (Paint $hr '90')

  foreach ($r in $rows) {
    $nc = $r.new.Count; $cc = $r.cur.Count
    $mk    = if ($cc -or $nc) { $dot } else { $ring }
    $mkSgr = if ($cc) { '92' } elseif ($nc) { '93' } else { '90' }
    $nmSgr = if ($cc -or $nc) { '97' } else { '90' }
    # build PLAIN text + color separately, then PadRight the plain text (padding the colored string would
    # count ANSI escape bytes and misalign). Fixed-width watcher token keeps the following act column straight.
    $wText = switch ($r.w.state) { 'on' { 'w on' } 'stale' { 'w stale ' + (Format-Age $r.w.age) } default { 'w off' } }
    $wSgr  = switch ($r.w.state) { 'on' { '92' }   'stale' { '91' }                                default { '90' } }
    $aText = switch ($r.a.act) { 'sub' { 'act sub' + $r.a.subs } 'busy' { 'act busy' } 'busy?' { 'act busy?' } 'idle' { 'act idle' } default { 'act -' } }
    $aSgr  = switch ($r.a.act) { 'sub' { '96' }                 'busy' { '93' }        'busy?' { '91' }        'idle' { '90' }        default { '90' } }
    Write-Output (
      (Paint $mk $mkSgr) + ' ' + (Paint ($r.name.PadRight(20)) $nmSgr) +
      '  ' + (Paint ("new {0,-3}" -f $nc) $(if ($nc) { '93' } else { '90' })) +
      ' ' + (Paint ("cur {0,-2}" -f $cc) $(if ($cc) { '92' } else { '90' })) +
      '  ' + (Paint ($wText.PadRight(12)) $wSgr) +
      ' ' + (Paint $aText $aSgr)
    )
    foreach ($f in ($r.new | Sort-Object Name | Select-Object -First 3)) {
      $p = Parse-MsgName $f.Name; if (-not $p) { continue }
      $subj = First-Subject $f.FullName; if ($null -eq $subj) { continue }   # consumed mid-render -> skip this preview line; the next redraw corrects the count
      $txt = '     ' + $br + ' ' + $subj + '  <' + $p.from + '>'
      $max = [Math]::Max(20, $W - 2)
      if ($txt.Length -gt $max) { $txt = $txt.Substring(0, $max - 1) + [char]0x2026 }
      Write-Output (Paint $txt '90')
    }
    if ($nc -gt 3) { Write-Output (Paint ("       (+{0} more pending)" -f ($nc - 3)) '90') }
  }
}

# Live board: redraw on an interval in its own terminal window (Ctrl+C to exit). Clear guarded for non-console hosts.
function Invoke-BoardLoop([int]$interval, [bool]$notify) {
  $prevWorking = -1
  while ($true) {
    try { Clear-Host } catch { }
    Invoke-Board
    Write-Output ''
    $hint = if ($notify) { '  (idle-notify on)' } else { '' }
    Write-Output (Paint ("  live  -  refresh {0}s  -  Ctrl+C to exit{1}" -f $interval, $hint) '90')
    if ($notify) {
      # fire ONCE on the working->0 edge (pool fully stopped); re-arms only when work resumes
      $cur = [int]$script:LastWorking
      if ($prevWorking -gt 0 -and $cur -eq 0) {
        $n = Join-Path $PSScriptRoot 'notify-pool-idle.ps1'
        if (Test-Path $n) {
          try { Start-Process powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Pool "{1}"' -f $n, $script:LastTag) | Out-Null } catch { }
        }
      }
      $prevWorking = $cur
    }
    Start-Sleep -Seconds $interval
  }
}

# Personal plate (read-only): this owner's own work across states - cur/ (in-progress) + new/ (pending).
# Fills the gap inbox/board leave: an agent cannot otherwise see its OWN claimed (cur/) work after a
# restart, because it does not remember the claim and inbox shows only new/. This is the manual
# "self-recovery from cur/" of lease-v1: run `mine`, Read the printed cur/ file, resume; ack when done.
function Invoke-Mine([string]$o) {
  Require-Bus
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)   # render Cyrillic subjects correctly across hosts
  if (-not $o) { throw 'mine requires -Owner (or set $env:AGENT_OWNER)' }
  $curF = @(Get-ChildItem -Path (Sub-Dir $o 'cur') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  $newF = @(Get-ChildItem -Path (Sub-Dir $o 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  $newN = @($newF | Where-Object { Is-Note $_.Name })
  $newT = @($newF | Where-Object { -not (Is-Note $_.Name) })
  Write-Output ("[POOL MINE] {0}: {1} in progress (cur), {2} pending (new), {3} note(s)" -f $o, $curF.Count, $newT.Count, $newN.Count)
  Write-Output "  -- in progress (cur): Read the file to resume, then ack when done --"
  if ($curF.Count -eq 0) { Write-Output "     (none)" }
  foreach ($f in $curF) {
    $p = Parse-MsgName $f.Name
    if ($p) { Write-Output ("   * {0} (from {1}): {2}" -f $p.id, $p.from, (First-Subject $f.FullName)) }
    Write-Output ("       file: {0}" -f $f.FullName)
  }
  Write-Output "  -- pending (new): claim to take --"
  if ($newT.Count -eq 0) { Write-Output "     (none)" }
  foreach ($f in $newT) {
    $p = Parse-MsgName $f.Name
    if ($p) { Write-Output ("   - {0} (from {1}): {2}" -f $p.id, $p.from, (First-Subject $f.FullName)) }
  }
  Write-Output "  -- notes (new): FYI, not tasks - Read, then dismiss --"
  if ($newN.Count -eq 0) { Write-Output "     (none)" }
  foreach ($f in $newN) {
    $p = Parse-MsgName $f.Name
    if ($p) { Write-Output ("   ~ {0} (from {1}): {2}" -f $p.id, $p.from, (First-Subject $f.FullName)) }
    Write-Output ("       file: {0}" -f $f.FullName)
  }
  Write-Output ("Done: pool.ps1 ack -Owner {0} -Id <id>   |   Take: pool.ps1 claim -Owner {0} -Id <id>   |   Clear note: pool.ps1 dismiss -Owner {0} -Id <id>" -f $o)
}

switch ($Cmd) {
  'send'  { Invoke-Send  $To $From $Subject $Kind $InReplyTo }
  'reply' {
    $replyKind = if ($PSBoundParameters.ContainsKey('Kind')) { $Kind } else { 'reply' }
    Invoke-Send $To $From $Subject $replyKind $InReplyTo
  }
  'note'  {
    $noteKind = if ($Wake) { 'note-wake' } else { 'note' }
    Invoke-Send $To $From $Subject $noteKind $InReplyTo
  }
  'inbox' { Invoke-Inbox $Owner }
  'mine'  { Invoke-Mine  $Owner }
  'claim' { Invoke-Claim $Owner $Id }
  'ack'   { Invoke-Ack   $Owner $Id }
  'dismiss' { Invoke-Dismiss $Owner $Id }
  'check' { Invoke-Check $Owner }
  'watch' { Invoke-Watch $Owner $IntervalSeconds }
  'hook'  { Invoke-Hook }
  'activity' { Invoke-Activity }
  'board' {
    # idle-notify: explicit -Notify, or globally via a sentinel file .board-notify in this dir
    $doNotify = [bool]$Notify -or (Test-Path (Join-Path $PSScriptRoot '.board-notify'))
    if ($Show) {
      $bw = Join-Path $PSScriptRoot 'board-window.ps1'
      $bwArgs = @('-BusRoot', $BusRoot)
      if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $bwArgs += @('-IntervalSeconds', $IntervalSeconds) }
      if ($Notify) { $bwArgs += '-Notify' }
      & $bw @bwArgs
    } elseif ($Watch) {
      $iv = if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $IntervalSeconds } else { 8 }
      Invoke-BoardLoop $iv $doNotify
    } else { Invoke-Board }
  }
  'help'  { Get-Content $PSCommandPath -TotalCount 36 }
}
