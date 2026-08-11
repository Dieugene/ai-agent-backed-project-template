# pool.ps1 - SHARED maildir message bus for agent-pool coordination (v1 prototype, 2026-06-21).
#
# ONE shared copy for the whole workspace (<workspace-root>\.launcher\pool-bus\pool.ps1).
# Pools supply only DATA (a per-pool .bus/ store) + thin binding (hook config, wrapper env).
# Editing this one file changes behavior for every pool at once - no per-pool rollout.
#
# Source is UTF-8 WITH BOM -> Cyrillic in comments/strings is safe here (was ASCII-only until 2026-07-27).
# Do NOT strip the BOM: PS 5.1 would then read this file as cp1251 and mangle every Cyrillic byte.
# NB: selftest.ps1 has NO BOM - that file really is ASCII-only, keep Cyrillic out of it.
# Message BODIES are written/read as UTF-8 without BOM at runtime, so Cyrillic DATA is safe either way.
#
# Maildir model: one immutable file = one message; recipient = folder; state = folder; transition = atomic rename.
#   <BusRoot>/<recipient>/{tmp,new,cur}/   new = unread, cur = claimed/in-progress
#   <BusRoot>/archive/                      acked / terminal
#   <BusRoot>/.ledger/seen-<owner>.txt      per-recipient watcher ledger (note-wake ping ids already woken on; tasks are NOT recorded - claim is their suppressor)
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
#   pool.ps1 ready   -Owner <o> -BusRoot <d>          # confirm readiness for shutdown (ONLY way to set the flag)
#   pool.ps1 check   -Owner <o> -BusRoot <d>          # one watcher detection pass
#   pool.ps1 watch   -Owner <o> -BusRoot <d> [-IntervalSeconds 45]   # background sleeping watcher (one-shot: fires, exits, must be re-armed)
#   pool.ps1 monitor -Owner <o> -BusRoot <d> [-IntervalSeconds 20]   # CONTINUOUS sibling of watch: arm with the Monitor tool (persistent), never exits
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
  [ValidateSet('send','reply','note','inbox','mine','claim','ack','dismiss','ready','check','watch','monitor','hook','activity','armgate','board','help')]
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

# --- Platform: how to call ourselves back ---------------------------------------------------------
# The SAME file has to run under Windows PowerShell 5.1 and under pwsh 7 on Linux (pools are moving to
# a server). Exactly two things differ: the interpreter's NAME and its FLAGS (-ExecutionPolicy exists
# only on Windows). Everything that SPAWNS a process or PRINTS a ready-made command to the agent must
# go through these three, because a hardcoded `powershell ...` on Linux fails twice over: the spawn
# does not start, and - far worse - the agent READS the hint as an instruction, cannot arm its watcher,
# and concludes the watcher is broken.
# $IsWindows only exists in PS 6+; under 5.1 there is no such variable at all. Asked via Get-Variable rather
# than by naming it directly, because a host with Set-StrictMode on THROWS on an undefined variable - and this
# file does get dot-sourced (tests, ad-hoc checks) into shells whose rules we do not control. Absent = 5.1 = Windows.
$script:OnWindows = $true
try { $__isWin = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($__isWin) { $script:OnWindows = [bool]$__isWin.Value } } catch { }
function Get-PSHostExe {
  if ($script:OnWindows) { return 'powershell' }
  # pwsh may be outside PATH (on the server it is unpacked into ~/.local/pwsh), so ask the process we
  # are running in rather than guessing a name.
  try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; if ($exe) { return $exe } } catch { }
  return 'pwsh'
}
function Get-PSHostFlags { if ($script:OnWindows) { return '-NoProfile -ExecutionPolicy Bypass' } else { return '-NoProfile' } }
# One ready command line that calls THIS pool.ps1 back. On Windows the result is byte-for-byte what the
# hardcoded strings used to produce - the Windows path must not shift by a single character.
function Get-SelfCommand([string]$verb, [string]$o, [string]$bus) {
  $exe = Get-PSHostExe
  # Quoted OUTSIDE Windows only: there the value is a full path that may contain a space, and an unquoted one
  # would print the role a command it cannot run - the exact failure this whole change exists to remove. On
  # Windows it stays the bare word `powershell`, because the produced string must not shift by one character.
  if (-not $script:OnWindows) { $exe = '"' + $exe + '"' }
  '{0} {1} -File "{2}" {3} -Owner {4} -BusRoot "{5}"' -f $exe, (Get-PSHostFlags), $PSCommandPath, $verb, $o, $bus
}

# Hook payload (stdin) reader for `activity` / `armgate`. A real hook gets its JSON and then the harness CLOSES the
# pipe, so a read returns at EOF. But the same command run BY HAND (agent tool call) gets a stdin that is redirected
# and NEVER closed -> a plain [Console]::In.ReadToEnd() blocks FOREVER. That is what left armgate processes hanging
# for hours and sent agents diagnosing phantom orphans. So: read asynchronously and give up fast - no payload means
# "run as if stdin were empty" (armgate assumes Stop; activity self-cancels). Raw .NET async read on purpose: a
# scriptblock handed to a thread-pool thread has no runspace and would throw.
function Read-HookPayload([string]$inline, [int]$timeoutMs = 2000) {
  if ($inline) { return $inline }
  if (-not [Console]::IsInputRedirected) { return '' }
  try {
    $s = [Console]::OpenStandardInput(); $mem = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 8192; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
      $left = $timeoutMs - $sw.ElapsedMilliseconds
      if ($left -le 0) { break }                                        # nothing coming -> hand-run, stop waiting
      $ar = $s.BeginRead($buf, 0, $buf.Length, $null, $null)
      if (-not $ar.AsyncWaitHandle.WaitOne([int]$left)) { break }
      $n = $s.EndRead($ar)
      if ($n -le 0) { break }                                           # EOF -> payload complete
      $mem.Write($buf, 0, $n)
    }
    return [System.Text.Encoding]::UTF8.GetString($mem.ToArray())
  } catch { return '' }
}

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
  if ($Body) { return $Body }
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

function Invoke-Send([string]$toOwner,[string]$fromOwner,[string]$subj,[string]$kind,[string]$inReplyTo,[string]$text) {
  Require-Bus
  if (-not $toOwner -or -not $fromOwner -or -not $subj) { throw 'send/reply require -To -From -Subject' }
  $id     = New-MsgId
  $iso    = (Get-Date).ToString('o')
  $thread = if ($inReplyTo) { $inReplyTo } else { $id }
  # -text lets an internal caller (the arm-gate) supply the body directly: Get-BodyText reads the -Body param,
  # which on a hook path carries the hook's JSON payload, not message text.
  $bodyText = if ($text) { $text } else { (Get-BodyText) }
  $content = "# " + $subj + "`n`n" +
             "| Field | Value |`n|---|---|`n" +
             "| From | "   + $fromOwner + " |`n" +
             "| To | "     + $toOwner   + " |`n" +
             "| Date | "   + $iso       + " |`n" +
             "| Thread | " + $thread    + " |`n`n" +
             $bodyText + "`n"
  $tmp   = Join-Path (Sub-Dir $toOwner 'tmp') ($id + '.tmp')
  $final = Join-Path (Sub-Dir $toOwner 'new') (("{0}.from-{1}.{2}.md") -f $id, $fromOwner, $kind)
  Write-Utf8 $tmp $content
  [System.IO.File]::Move($tmp, $final)   # atomic on same NTFS volume; target unique, so no overwrite path
  $id
}

# 🛑 Карантин на время гашения. Пока в шине лежит intent-метка роли, ей НИЧЕГО не шлют: сторожа не
# проверяют почту, баннер молчит. Требование владельца дословно: «с момента начала гашения вотчеры и
# сторожа перестали вбрасывать данные. Чтобы я не опасался, что пока идёт хэндофф, прилетит новая
# задача или сообщение. Почистимся, перезапустимся, и тогда пожалуйста.»
# Метку ставит фаза 1 контроллера ПОСЛЕ отправки задачи завершения (иначе роль не проснулась бы на неё)
# и снимает фаза 2 перед убийством. Прервали гашение — метка остаётся; её чистит запуск пула.
# ⚠️ Проверять надо ДО Invoke-Check, а не глушить его вывод: Invoke-Check помечает разовые пинги
# прочитанными в реестре, и «проверили, но промолчали» означало бы, что пинг не разбудит уже НИКОГДА.
function Test-ShutdownQuiet([string]$o) {
  if ([string]::IsNullOrWhiteSpace($o) -or [string]::IsNullOrWhiteSpace($BusRoot)) { return $false }
  try { return (Test-Path (Join-Path (Join-Path $BusRoot '.control') ("shutdown-intent-{0}" -f $o))) } catch { return $false }
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
  # Point at the file explicitly. Claiming is NOT reading: on 2026-07-27 a lead claimed a shutdown task,
  # never opened the body, and ran the procedure from memory - with a flag path that had moved a day earlier.
  # `mine` printed the path too, but buried among other lines; here it is the next thing the agent sees.
  Write-Output ("READ THIS FIRST (the body is NOT shown above): {0}" -f $dest)
}

function Invoke-Ack([string]$o,[string]$mid) {
  Require-Bus
  if (-not $mid) { throw 'ack requires -Id' }
  $m = Get-ChildItem -Path (Sub-Dir $o 'cur') -Filter ($mid + '.from-*') -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $m) { Write-Output ("ACK-MISS: {0} not in cur/{1}" -f $mid, $o); return }
  [System.IO.File]::Move($m.FullName, (Join-Path (Archive-Dir) $m.Name))
  Write-Output ("ACKED: {0}" -f $mid)
}

<#
    ready - ЕДИНСТВЕННЫЙ способ подтвердить готовность к гашению.

    ЗАЧЕМ (инцидент 2026-07-27): раньше контроллер клал путь флага в тело задачи, а агент создавал файл
    руками. Лид <pool-a> задачу заклеймил, тело НЕ открыл, выполнил процедуру по памяти прошлых гашений
    и написал флаг по устаревшему пути (~\.claude\.control\ вместо шины). Контроллер флага не увидел ->
    «ТАЙМАУТ» -> роль осталась незакрытой. Путь, собранный агентом из текста, не может быть надёжным:
    он живёт в его памяти и переживает compact. Здесь путь знает СКРИПТ - ошибиться нечем.

    ИНВАРИАНТЫ (нарушишь - вернёшь инцидент):
      * Флаг = РАЗРЕШЕНИЕ УБИТЬ сессию. Поэтому команда не создаёт его безусловно: нужен живой intent
        (контроллер начал гашение) И заклеймленная/отакченная задача от контроллера свежее intent'а.
        Без этих двух условий флаг был бы «стоячим разрешением» - например, от субагента, который
        наследует env и физически может позвать ready, пока главный агент ещё работает.
      * Адрес флага НЕ параметр протокола: и шина, и owner берутся из env сессии, как во всех остальных
        командах. В тексте задачи путь остаётся только как справка для диагностики, не как инструкция.
      * Гард по «запись обновлена» СОЗНАТЕЛЬНО не ставится. Прежняя причина - handoff-файлы лежат не у
        всех рядом с шиной (<sub-a> - 9 ролей в <umbrella>\<sub-a>\, operator <pool-a> - в 03_data\) - с
        переездом памяти в <cwd>\.memory\<роль> отпала. Решение осталось тем же по причине СИЛЬНЕЕ:
        замер может не удаться сам по себе (хранилище пусто у ещё не переехавшей роли; MEMORY.md
        залочен ровно тем, что его переписывают), и гард отказывал бы роли, которая всё сделала.
        Факт записи остаётся ДИАГНОСТИКОЙ в отчёте контроллера, не гейтом.
#>
function Invoke-Ready([string]$o) {
  Require-Bus
  if (-not $o) { throw 'ready requires -Owner (or set $env:AGENT_OWNER - normally your pool wrapper does)' }
  $cdir   = Join-Path $BusRoot '.control'
  $intent = Join-Path $cdir ("shutdown-intent-{0}" -f $o)
  if (-not (Test-Path $intent)) {
    Write-Output ("READY-REFUSED: no active shutdown for '{0}' - nothing to confirm." -f $o)
    Write-Output "  This flag authorizes the controller to KILL your session. With no live shutdown intent"
    Write-Output "  it would be a standing permission, so no flag is created."
    return
  }
  $intentMs = [long]((Get-Item $intent).LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds
  $task = $null
  foreach ($d in @((Sub-Dir $o 'cur'), (Archive-Dir))) {
    foreach ($f in @(Get-ChildItem -Path $d -Filter '*.from-pool-controller.*' -File -ErrorAction SilentlyContinue)) {
      $p = Parse-MsgName $f.Name
      if (-not $p) { continue }
      $ms = 0
      if (-not [long]::TryParse((($p.id -split '-')[0]), [ref]$ms)) { continue }
      if ($ms -ge $intentMs) { $task = $f; break }
    }
    if ($task) { break }
  }
  if (-not $task) {
    Write-Output ("READY-REFUSED: '{0}' has not taken the shutdown task yet." -f $o)
    Write-Output "  Claim it and READ ITS BODY first - the body carries the current instructions:"
    Write-Output ("     pool.ps1 mine -Owner {0}" -f $o)
    return
  }
  # Аудит памяти ПЕРЕД флагом: агент только что дописал память и дальше молчит (любой его ход сотрёт
  # флаг), поэтому фиксация истории и структурная проверка не могут быть его последним действием -
  # он про них просто не вспомнит. Аудит молчит у ролей, которые ещё на общей памяти.
  try {
    $auditor = Join-Path $PSScriptRoot 'memory-audit.ps1'
    if (Test-Path $auditor) { & $auditor -Owner $o -Reason 'ready' | ForEach-Object { Write-Output $_ } }
  } catch { Write-Output ("  [memory-audit] пропущен: {0}" -f $_.Exception.Message) }

  [void](Ensure-Dir $cdir)
  $flag = Join-Path $cdir ("shutdown-ready-{0}" -f $o)
  [System.IO.File]::WriteAllText($flag, '', $script:U8)
  Write-Output ("READY: {0}" -f $flag)
  Write-Output "Now stop: any further turn of YOURS clears this flag by design (the controller would then skip you)."
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

# Watcher detection: wake on any pending TASK in new/<owner>/. A task keeps waking every fresh watcher until it is
# claimed OUT of new/ - the claim (file leaves new/), NOT the fire, is the suppressor. This closes the starvation hole
# where a task rung once (baseline-on-fire) but not yet claimed - agent busy / wake lost / re-armed before claiming -
# went silent forever. note-wake is the ONE exception: it is a one-shot ping (dismiss, not claim), so the ledger DOES
# remember it - wake once, then quiet even while it still sits in new/. Signal = presence in new/ (+ ledger for
# note-wake only), NOT mtime. On fire, ledger := the note-wake ids currently pending (tasks are deliberately not recorded).
function Invoke-Check([string]$o, [string]$OnlyFrom = '') {
  Require-Bus
  # 🛑 $OnlyFrom — режим карантина гашения. Под intent-меткой сторож зовёт проверку ИМЕННО так:
  # видит только письма контроллера и НЕ ТРОГАЕТ реестр `seen-<owner>`. Оба условия несущие.
  # Пропускать контроллера обязательно: задача завершения доставляется роли той же побудкой, и
  # «молчать обо всём» означало бы, что роль никогда о ней не узнает — гашение висело бы до таймаута
  # (замерено оппонентом: сторож опрашивает раз в 20–45 с, метка встаёт за миллисекунды, так что
  # перестановка порядка записи метки этого НЕ лечит — лечит только фильтр).
  # Не трогать реестр обязательно: он подавляет повторные разовые пинги, и запись под карантином
  # пометила бы проглоченный пинг виденным — он не разбудил бы роль уже никогда.
  $ledger = Join-Path (Ledger-Dir) ("seen-{0}.txt" -f $o)
  $seen = @{}
  if (Test-Path $ledger) { foreach ($l in [System.IO.File]::ReadAllLines($ledger)) { $t = "$l".Trim(); if ($t) { $seen[$t] = $true } } }
  $pings = @()     # note-wake ids currently pending (the ONLY kind the ledger suppresses: a one-shot ping, not a task)
  $wake  = @()     # ids to wake on this pass
  foreach ($f in (Get-ChildItem -Path (Sub-Dir $o 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    $p = Parse-MsgName $f.Name; if (-not $p) { continue }
    if ($OnlyFrom -and $p.from -ne $OnlyFrom) { continue }     # quarantine: nobody but the controller
    if (-not (Is-Wakeable $f.Name)) { continue }               # quiet note / migration: never wakes
    if ($p.kind -eq 'note-wake') {
      $pings += $p.id
      if (-not $seen.ContainsKey($p.id)) { $wake += $p.id }     # one-shot: wake once, then the ledger keeps it quiet
    } else {
      $wake += $p.id                                            # a task: wake every fresh watcher until claimed out of new/
    }
  }
  if ($wake.Count -gt 0) {
    # Persist ONLY the note-wake pings. Tasks are intentionally not recorded: their suppressor is the claim
    # (file leaves new/), so an un-claimed task keeps waking each re-arm instead of starving after one silent fire.
    if (-not $OnlyFrom) { [System.IO.File]::WriteAllLines($ledger, [string[]]$pings, $script:U8) }   # quarantine never marks anything seen
    Write-Output ("[WAKE] {0}: {1} new" -f $o, $wake.Count)
    foreach ($n in $wake) { Write-Output ("   new: {0}" -f $n) }
  } else {
    Write-Output ("[no-wake] {0}: nothing new" -f $o)
  }
}

# --- watcher liveness by REAL process (not heartbeat freshness). The lock carries "<pid>|<startTicks>|<iso>"
# where the ISO is the ARM time and is diagnostic only - nothing parses it, freshness comes from the file mtime:
# a watcher is truly alive only if that PID runs AND its process StartTime matches (guards PID reuse). Used by the
# arm path (newest-wins supersede) and the Stop-hook arm-gate. Old-format locks (pre-2026-07, ISO only) parse to
# pid 0 -> reported not-alive -> a fresh re-arm supersedes them. Board freshness (Get-WatchState) stays unchanged.
function Read-WatchLock([string]$o) {
  $lock = Join-Path (Join-Path $BusRoot '.watch') ("lock-{0}.txt" -f $o)
  if (-not (Test-Path $lock)) { return $null }   # not armed: keep this fast path, the arm-gate hits it every Stop
  # Opened with FileShare.ReadWrite ON PURPOSE. `File.ReadAllText` asks for FileShare.Read, and a LIVE watcher holds
  # the file for writing - so Windows refused the open, the catch returned $null, and "no lock" reads as "no watcher"
  # while the watcher is right there. That is the same duplicate-watcher hole from the other side. Two attempts: with
  # the writer no longer truncating (see Write-WatchLockFull), the only thing left to lose a read to is the instant
  # of a full rewrite, which happens once per arm.
  $raw = ''
  for ($i = 0; $i -lt 2; $i++) {
    try {
      $fs = New-Object System.IO.FileStream($lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try { $sr = New-Object System.IO.StreamReader($fs); try { $raw = $sr.ReadToEnd().Trim() } finally { $sr.Dispose() } } finally { $fs.Dispose() }
    } catch { $raw = '' }
    if ($raw) { break }
    Start-Sleep -Milliseconds 50
  }
  if (-not $raw) { return $null }
  $parts = $raw -split '\|'
  $wpid = 0; [void][int]::TryParse([string]$parts[0], [ref]$wpid)
  $ticks = [long]0; if ($parts.Count -ge 2) { [void][long]::TryParse([string]$parts[1], [ref]$ticks) }
  [pscustomobject]@{ path = $lock; procId = $wpid; startTicks = $ticks }
}
# Process identity stamp, used ONLY to compare a live pid against the one recorded in the watch lock.
# Windows: StartTime.Ticks, exactly as before.
# Linux: field 22 of /proc/<pid>/stat (scheduler ticks since boot) - NOT StartTime, and the difference is a
# real defect, not a style choice. .NET derives StartTime on Linux as "boot time + starttime" and reads boot
# time with floating precision, so TWO DIFFERENT PROCESSES get different values for the SAME pid. Measured on
# the server stand: the lock written by a live monitor read back as 639214528081472580, while three foreign
# reads of that same pid gave ...475505 / ...483488 / ...478954 (0.3-1.1 ms apart, and never twice the same).
# An equality check therefore NEVER matches: the arm-gate sees "watcher dead" on every Stop and blocks the role
# in a loop, while the board shows `w off` next to a monitor that is in fact polling. The /proc field is a
# fixed integer and reads identically from any process. Zero = "cannot tell", and callers treat that as "skip
# the identity check" rather than "dead" (same as the old catch{} did).
function Get-ProcStartStamp([int]$procId) {
  if ($script:OnWindows) {
    try { return [long](Get-Process -Id $procId -ErrorAction Stop).StartTime.Ticks } catch { return [long]0 }
  }
  try {
    $stat = [System.IO.File]::ReadAllText("/proc/$procId/stat")
    # field 2 (comm) is the process name in parentheses and MAY contain spaces and parentheses itself, so the
    # only safe split point is the LAST ')': everything after it is fixed-width fields. state becomes index 0,
    # so overall field 22 (starttime) is index 19.
    $f = ($stat.Substring($stat.LastIndexOf(')') + 2)) -split '\s+'
    # ZOMBIE: a dead process whose parent never reaped it still HAS a /proc entry, Get-Process still finds it,
    # and field 22 still reads its original value - so the identity check would match and the caller would call
    # a dead watcher alive. Windows has no such state (a finished process is simply gone). -1 says "definitely
    # dead", which the caller must distinguish from 0 = "could not tell".
    if ($f[0] -eq 'Z') { return [long](-1) }
    $start = [long]$f[19]
    # Field 22 counts from BOOT, so the counter restarts on every reboot - unlike the Windows value, which is
    # absolute time and can never repeat. A lock file outlives a reboot, so pid+ticks could coincide again and
    # a stale lock would read as a live watcher. Mixing in the boot moment restores uniqueness across reboots.
    $btime = [long]0
    foreach ($line in [System.IO.File]::ReadAllLines('/proc/stat')) {
      if ($line.StartsWith('btime ')) { $btime = [long]$line.Substring(6).Trim(); break }
    }
    return $btime * 1000000 + $start
  } catch { return [long]0 }
}
function Test-ProcessAlive([int]$procId, [long]$startTicks) {
  if ($procId -le 0) { return $false }
  $p = $null; try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { return $false }
  if (-not $p) { return $false }
  if ($startTicks -gt 0) {
    # ⚠️ Windows-ветка остаётся НАТИВНОЙ намеренно (блокер, найденный ведущим на ревью). На 5.1
    # $p.StartTime для процесса, который нам не дают инспектировать, НЕ бросает - он тихо отдаёт
    # $null; здесь таких pid 143 из 474 (System, csrss, svchost, антивирус) - ровно тот класс, куда
    # попадает и вотчер. Нативная сверка читает $null как «не тот процесс» и возвращает false, то
    # есть гейт требует взвода. Через общий Get-ProcStartStamp это стало бы 0 -> сверка личности
    # ПРОПУСКАЕТСЯ -> «вотчер жив» -> гейт молчит. Отказ не гипотетический: monitor свой лок никогда
    # не удаляет, после резкого конца сессии на диске остаётся pid|stamp, pid переиспользуется - и
    # роль стоит без побудки. Замер на одном локе: оригинал exit 2, общая ветка exit 0.
    if ($script:OnWindows) { try { if ($p.StartTime.Ticks -ne $startTicks) { return $false } } catch { } }
    else {
      $now = Get-ProcStartStamp $procId
      if ($now -lt 0) { return $false }                              # zombie: /proc entry without a process
      if ($now -gt 0 -and $now -ne $startTicks) { return $false }
    }
  }
  return $true
}
function Test-WatcherAlive([string]$o) { $lk = Read-WatchLock $o; if (-not $lk) { return $false }; Test-ProcessAlive $lk.procId $lk.startTicks }
# Is an arm for this owner ALREADY booting? (a `watch` process exists but has not written its lock yet). Lets the
# arm-gate tell "arming, wait" apart from "nothing armed" instead of reading the boot window as a failure. Matched on
# the owner arg only: BusRoot carries quotes/backslashes and is fragile to match; a cross-pool same-owner false
# positive would only cost a few seconds of waiting on a path that is already blocking.
function Test-ArmInFlight([string]$o) {
  $rxCmd = '(?i)pool\.ps1["'']?\s+(watch|monitor)\b'   # monitor is the continuous sibling; both count as "arming"
  $rxOwn = '(?i)-Owner\s+["'']?' + [regex]::Escape($o) + '(?=["'']|\s|$)'
  if ($script:OnWindows) {
    $procs = @()
    try { $procs = @(Get-CimInstance -Query "SELECT CommandLine FROM Win32_Process WHERE Name='powershell.exe'" -ErrorAction Stop) } catch { return $false }
    foreach ($p in $procs) {
      if ($p.CommandLine -and $p.CommandLine -match $rxCmd -and $p.CommandLine -match $rxOwn) { return $true }
    }
    return $false
  }
  # Linux: the same question, asked of /proc. Deliberately NOT `ps` and NOT Get-Process().CommandLine -
  # /proc is always there, needs no external binary, and does not depend on how pwsh was built. Arguments
  # in /proc/<pid>/cmdline are NUL-separated; joining them with a space gives the same shape the WMI
  # CommandLine has, so both branches feed the identical regexes above.
  try {
    foreach ($d in [System.IO.Directory]::EnumerateDirectories('/proc')) {
      $n = 0
      if (-not [int]::TryParse([System.IO.Path]::GetFileName($d), [ref]$n)) { continue }   # only numeric dirs are processes
      $cl = ''
      # A process can exit between the listing and the read - that is normal, skip it quietly.
      try { $cl = ([System.IO.File]::ReadAllText((Join-Path $d 'cmdline'))) -replace "`0", ' ' } catch { continue }
      if ($cl -and $cl -match $rxCmd -and $cl -match $rxOwn) { return $true }
    }
  } catch { return $false }
  return $false
}
# --- Heartbeat, rewritten 2026-08-03 after a field defect: `Set-Content` here killed the whole watcher on a
# lock-file race. Six crashes across four roles in two days (<pool-a>, 30-31.07), two distinct failure texts on
# this one line: a sharing violation, and "stream is not readable" WITH A ZERO-BYTE lock left on disk.
# The zero-byte outcome is the dangerous one: truncate succeeded, write did not. The board (Get-WatchState) only
# looks at LastWriteTime, so it still reports `w on`; the arm-gate reads the CONTENT, gets pid 0, demands an arm -
# and the newest-wins supersede cannot kill the prior watcher either (it reads pid 0 too). Result: TWO live
# watchers on one owner, both writing the same file. The race feeds itself.
#
# Fix: stop rewriting the content every tick. `pid|startTicks` never change while the process lives, and the third
# field (ISO) is parsed by NOBODY (the board lives on LastWriteTime). So the content is written ONCE at arm, and
# each tick only touches the file's timestamp: that needs FILE_WRITE_ATTRIBUTES, not access to the data, so the
# conflict surface shrinks by an order of magnitude and truncation cannot happen at all. The ISO field therefore
# now records the ARM time, not the last beat - it is diagnostic only.
function Write-WatchLockFull([string]$lock, [int]$procId, [long]$startTicks) {
  $text  = '{0}|{1}|{2}' -f $procId, $startTicks, (Get-Date).ToString('o')
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($text + "`r`n")   # CRLF keeps the on-disk shape Set-Content used
  for ($i = 0; $i -lt 3; $i++) {
    try {
      [void](Ensure-Dir (Split-Path $lock -Parent))                 # .watch can be gone (fresh bus / cleaned by hand)
      # OpenOrCreate + SetLength AFTER the write (never Create): a failed write leaves the PREVIOUS content intact
      # instead of a zero-byte lock. FileShare.Read (not ReadWrite): a second writer is refused - that is what the
      # retry below absorbs - while readers are let in.
      $fs = New-Object System.IO.FileStream($lock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
      try { $fs.Write($bytes, 0, $bytes.Length); $fs.SetLength($bytes.Length); $fs.Flush() } finally { $fs.Dispose() }
      return $true
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $false
}
function Touch-WatchLock([string]$lock) {
  try { [System.IO.File]::SetLastWriteTime($lock, (Get-Date)); return $true } catch { return $false }
}
# One beat. Returns $false only if BOTH the touch and the full rewrite failed - the caller counts those in a row,
# because a heartbeat that fails forever is exactly as invisible as the crash this replaced (board says off, the
# arm-gate demands an arm every Stop, and the agent stacks duplicate watchers on a monitor that is in fact alive).
function Write-WatchLock([string]$lock, [int]$procId, [long]$startTicks) {
  if (Touch-WatchLock $lock) { return $true }        # normal path: the file exists and only its mtime moves
  Write-WatchLockFull $lock $procId $startTicks      # gone (a fired `watch` deletes it) or the touch was refused
}

# Background "sleeping watcher": polls check; on first fire prints claim/work + exits (harness wakes the agent).
# NEWEST-WINS: on arm, if a prior watcher for this owner is truly alive, it is superseded (killed) and this one
# takes over - no more "fresh lock -> exit" self-elision (that let an orphan block the real watcher). Re-arm is the
# agent's job (a watcher cannot wake an idle session itself); the Stop-hook arm-gate makes that deterministic.
function Invoke-Watch([string]$o,[int]$interval) {
  Require-Bus
  $lock  = Join-Path (Watch-Dir) ("lock-{0}.txt" -f $o)
  $myStart = Get-ProcStartStamp $PID   # cross-platform stamp; the reader must compare like with like
  $prev = Read-WatchLock $o
  if ($prev -and $prev.procId -ne $PID -and (Test-ProcessAlive $prev.procId $prev.startTicks)) {
    # normal re-arm has no live prior (it fired and exited), so this only supersedes an orphan/duplicate
    try { Stop-Process -Id $prev.procId -Force -ErrorAction Stop; Write-Output ("[WATCH] {0}: superseded prior watcher (pid {1})" -f $o, $prev.procId) } catch { }
  }
  $reArm = '  Bash(run_in_background:true): ' + (Get-SelfCommand 'watch' $o $BusRoot)
  [void](Write-WatchLockFull $lock $PID $myStart)   # identity written once; the loop only touches the timestamp
  $missed = 0
  while ($true) {
    if (Write-WatchLock $lock $PID $myStart) { $missed = 0 } else { $missed++ }
    if ($missed -eq 3) { Write-Output ("[WATCH] {0}: heartbeat lock is not writable ({1}) - the watcher is alive, but the board and the Stop arm-gate may stop seeing it. Check for a SECOND watcher of yours writing the same file." -f $o, $lock) }
    $qOnly = if (Test-ShutdownQuiet $o) { 'pool-controller' } else { '' }   # quarantine: only the controller gets through, ledger untouched
    $det = Invoke-Check $o $qOnly
    if (($det -join "`n") -match '\[WAKE\]') {
      if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
      $ids = @()
      foreach ($line in $det) { $mm = [regex]::Match($line, 'new:\s*(\S+)'); if ($mm.Success) { $ids += $mm.Groups[1].Value } }
      # Order is claim -> re-arm -> work (NOT re-arm first). Wake is claim-gated: a task keeps waking every fresh
      # watcher until it leaves new/, so re-arming BEFORE claiming makes the new watcher re-fire on the same task ->
      # the agent re-arms in a loop and panics. Claim (ms) moves it to cur/ and breaks that; re-arm still precedes work.
      Write-Output ("[WATCH] {0}: {1} new task(s)." -f $o, $ids.Count)
      Write-Output "STEP 1 (do FIRST): claim each below - a claim moves it into your cur/ so this watcher stops re-firing on it (leaving it in new/ makes every re-arm wake you again):"
      foreach ($n in $ids) { Write-Output ("   {0}   ->  pool.ps1 claim -Owner {1} -Id {0}" -f $n, $o) }
      Write-Output "STEP 2 (still BEFORE you start working): re-arm the watcher:"
      Write-Output $reArm
      Write-Output "STEP 3: do the claimed work; reply/ack when done."
      # Migration notice (wake order claim -> re-arm -> work) removed 2026-07-27: pools have cycled.
      # Kept the wake output SHORT on purpose - this is the exact turn where the agent must go read the task,
      # and every extra line here competes for that attention.
      return
    }
    Start-Sleep -Seconds $interval
  }
}

# --- CONTINUOUS watcher (2026-07-30). Sibling of Invoke-Watch, NOT a replacement: same detection (Invoke-Check),
# same lock/heartbeat, but it NEVER exits. Armed with the Monitor tool (persistent:true), where every printed line
# reaches the agent as a notification mid-conversation.
# WHY: the harness reaps background Bash tasks at will (measured: 11 reaps in a day, 47s..10min apart), and EVERY
# reap wakes the agent = a full turn with full context = usage burned. That cost, not the re-arm itself, is what
# made the owner switch pool watchers off. A watcher that does not exit removes those turns entirely.
# WAKE-LOOP TRAP DOES NOT APPLY HERE: the trap needs a re-arm before the claim (the fresh watcher sees the task
# still in new/ and fires again). There is no re-arm here. The claim stays the suppressor, and re-announcing is
# rate-limited by MonRepeatSeconds, so an unclaimed task nags rarely instead of looping.
# LOCK IS THE SAME FILE on purpose: the Stop-hook arm-gate and the board read liveness from it, so neither needs a
# single edit - and if this monitor is ever reaped, the lock goes stale and the gate demands an arm exactly as today.
$script:MonRepeatSeconds = 900   # re-announce an unclaimed task at most this often (a lost notification must not lose the task)
function Say-Mon([string]$s) {
  # Write straight to the console and flush: a process that never exits has no flush-on-exit, and a block-buffered
  # pipe would swallow every notification while looking exactly like "nothing arrived".
  [Console]::Out.WriteLine($s); [Console]::Out.Flush()
}
function Invoke-Monitor([string]$o,[int]$interval) {
  Require-Bus
  $lock  = Join-Path (Watch-Dir) ("lock-{0}.txt" -f $o)
  $myStart = Get-ProcStartStamp $PID   # cross-platform stamp; the reader must compare like with like
  $prev = Read-WatchLock $o
  if ($prev -and $prev.procId -ne $PID -and (Test-ProcessAlive $prev.procId $prev.startTicks)) {
    try { Stop-Process -Id $prev.procId -Force -ErrorAction Stop; Say-Mon ("[MONITOR] {0}: superseded prior watcher (pid {1})" -f $o, $prev.procId) } catch { }
  }
  Say-Mon ("[MONITOR] {0}: armed, polling every {1}s. It does NOT exit on a task - nothing to re-arm." -f $o, $interval)
  $saidKey = ''
  $saidAt  = [datetime]::MinValue
  [void](Write-WatchLockFull $lock $PID $myStart)   # identity written once; the loop only touches the timestamp
  $missed = 0
  while ($true) {
    if (Write-WatchLock $lock $PID $myStart) { $missed = 0 } else { $missed++ }
    # Say it, do not die of it: a monitor that beats into the void looks exactly like a monitor with no mail.
    if ($missed -eq 3) { Say-Mon ("[MONITOR] {0}: heartbeat lock is not writable ({1}) - I am alive, but the board and the Stop arm-gate may stop seeing me. Most likely a SECOND watcher of yours is writing the same file; tell Launcher if it persists." -f $o, $lock) }
    $qOnly = if (Test-ShutdownQuiet $o) { 'pool-controller' } else { '' }   # quarantine: only the controller gets through, ledger untouched
    $det = Invoke-Check $o $qOnly                # captured, not printed: only OUR lines become notifications
    $ids = @()
    if (($det -join "`n") -match '\[WAKE\]') {
      foreach ($line in $det) { $mm = [regex]::Match($line, 'new:\s*(\S+)'); if ($mm.Success) { $ids += $mm.Groups[1].Value } }
    }
    if ($ids.Count -eq 0) {
      $saidKey = ''; $saidAt = [datetime]::MinValue
    } else {
      $key = (($ids | Sort-Object) -join ',')
      $quiet = ((Get-Date) - $saidAt).TotalSeconds
      if ($key -ne $saidKey -or $quiet -ge $script:MonRepeatSeconds) {
        if ($key -eq $saidKey) {
          Say-Mon ("[MONITOR] {0}: still {1} unclaimed task(s) - the earlier notice was not acted on." -f $o, $ids.Count)
        } else {
          Say-Mon ("[MONITOR] {0}: {1} new task(s)." -f $o, $ids.Count)
        }
        Say-Mon "STEP 1 (do FIRST): claim each below - a claim moves it into your cur/ and this monitor goes quiet about it:"
        foreach ($n in $ids) { Say-Mon ("   {0}   ->  pool.ps1 claim -Owner {1} -Id {0}" -f $n, $o) }
        Say-Mon "STEP 2: do the claimed work; reply/ack when done. Nothing to re-arm."
        $saidKey = $key; $saidAt = Get-Date
      }
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
    $payload = Read-HookPayload $Body
    if ([string]::IsNullOrWhiteSpace($payload)) { return }
    $o = $null; try { $o = $payload | ConvertFrom-Json } catch { return }
    if (-not $o) { return }
    $adir = Join-Path (Join-Path $BusRoot '.activity') $Owner
    switch ("$($o.hook_event_name)") {
      'UserPromptSubmit' {
        Write-ActivityState $adir 'busy'; Clear-StaleSubMarkers $adir
        # Внешний контроллер завершения: НОВЫЙ ход агента = handoff устарел -> флаг готовности
        # инвалидируется. Стираем ТОЛЬКО здесь (не на Stop: флаг ставится в конце handoff-хода,
        # Stop бы его сразу снёс).
        #
        # НО ход бывает и НЕ агентский. Завершение фоновой задачи (одноразовый вотчер отстрелялся;
        # вытесненный chat_sentinel упал) харнесс кладёт в ТУ ЖЕ очередь промптов, что и ввод
        # человека -> новый promptId -> этот хук. Слепое стирание убивало флаг сразу после его
        # создания: воспроизведено на operator/<pool-a> и methodist/<pool-b> 2026-07-27.
        #
        # Замер 2026-07-27 (транскрипты <pool-a> + <pool-b> + launcher): машинный ход несёт
        # origin.kind=task-notification / promptSource=system (1246 шт.) против typed/human (715),
        # разделение чистое, а ТЕКСТ такого хода буквально начинается с <task-notification>.
        # Матчим по СЫРОМУ payload, а не по имени поля: док обещает user_message, замер даёт
        # prompt — имя нестабильно, подстрока нет.
        #
        # ИНВАРИАНТЫ (не отменять молча):
        #   1. Ход человека флаг стирает — иначе -KillOnly погасит сессию с протухшим handoff.
        #   2. Машинная побудка флаг НЕ стирает — иначе см. инцидент выше.
        #   3. Условие только СУЖАЕТ стирание: не распознали признак -> $machineWake=$false ->
        #      поведение ровно сегодняшнее. Регресс невозможен по построению (важно: файл общий
        #      на все пулы и приземляется на живые сессии немедленно).
        #   4. Флаг лежит В ШИНЕ ПУЛА (<BusRoot>\.control\, перенос 2026-07-27), не в общем
        #      ~\.claude\.control: имена ролей повторяются между пулами, и общий каталог давал
        #      кросс-пул — ход человека в одном пуле сносил отметку одноимённой роли в другом.
        #      Слаг пула хуку недоступен, а BusRoot есть всегда -> адресуемся точно.
        #   5. Признак ПОДТВЕРЖДЁН прямым замером на живом пуле (зонд 2026-07-27, снят после подтверждения):
        #      57 машинных побудок против 40 человеческих, разделение чистое, ложных срабатываний нет.
        $machineWake = ($payload -match '<task-notification>')
        if (-not $machineWake) {
          try { $rf = Join-Path (Join-Path $BusRoot '.control') ("shutdown-ready-{0}" -f $Owner); if (Test-Path $rf) { Remove-Item $rf -Force -ErrorAction SilentlyContinue } } catch { }
        }
      }
      'Stop'             { Write-ActivityState $adir 'idle' }
      'SubagentStart'    { if ($o.agent_id) { [void](Ensure-Dir $adir); [System.IO.File]::WriteAllText((Join-Path $adir ("sub-{0}" -f $o.agent_id)), '', $script:U8) } }
      'SubagentStop'     { if ($o.agent_id) { Remove-Item (Join-Path $adir ("sub-{0}" -f $o.agent_id)) -Force -ErrorAction SilentlyContinue } }
      default { }
    }
  } catch { }
}

# Stop-hook ARM-GATE (global hook, self-gated by env POOL_WATCHER=1 -> only watcher roles; else instant no-op).
# On the MAIN session's Stop, if no watcher is truly alive, emit decision:block with a re-arm instruction ->
# the harness holds the turn and the agent arms (in the MAIN context -> a wake-capable, harness-tracked watcher).
# Wired ONLY to `Stop` (never SubagentStop) -> a subagent never arms -> the orphan-birth path is closed.
# Backoff marker (.watch/armgate-<owner>.txt): if we blocked <30s ago and a watcher STILL is not up, arming is
# failing (antivirus/binary) -> do NOT block again (warn instead) so a broken spawn can never wedge the session.
function Invoke-ArmGate {
  if ($env:POOL_WATCHER -ne '1') { return }                                             # opt-in: only watcher roles
  if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($BusRoot)) { return }
  $payload = Read-HookPayload $Body
  $evt = ''
  if ($payload) { try { $evt = "$(($payload | ConvertFrom-Json).hook_event_name)" } catch { } }
  if ($evt -and $evt -ne 'Stop') { return }                                             # SubagentStop / other -> ignore
  $mark = Join-Path (Watch-Dir) ("armgate-{0}.txt" -f $Owner)
  $off  = Join-Path (Watch-Dir) ("armgate-off-{0}.txt" -f $Owner)   # "disengage already announced" (one note per incident)
  if (Test-WatcherAlive $Owner) {
    if (Test-Path $mark) { Remove-Item $mark -Force -ErrorAction SilentlyContinue }      # armed -> clear backoff
    if (Test-Path $off)  { Remove-Item $off  -Force -ErrorAction SilentlyContinue }      # incident over -> re-arm the announcement
    return
  }
  # An arm spawned this turn needs ~1s of PowerShell startup before its watcher writes the first lock. A Stop landing
  # inside that window would report "no watcher" although arming DID succeed -> the agent re-arms a duplicate and
  # burns a turn on a phantom failure. So when an arm is already in flight, wait for its lock instead of blocking.
  # Costs nothing on the healthy path (watcher alive -> returned above) and nothing when no arm is running.
  if (Test-ArmInFlight $Owner) {
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 150
      if (Test-WatcherAlive $Owner) {
        if (Test-Path $mark) { Remove-Item $mark -Force -ErrorAction SilentlyContinue }
        if (Test-Path $off)  { Remove-Item $off  -Force -ErrorAction SilentlyContinue }
        return
      }
    }
  }
  # Backoff counts ATTEMPTS, not seconds. Elapsed time cannot tell "the spawn is broken" from "the watcher armed,
  # fired and exited": both leave no live watcher at the next Stop. The old <30s window therefore disengaged the
  # gate silently in the very state where it matters most - a task waiting in new/ wakes a fresh watcher on its
  # first poll, so the watcher dies within seconds of EVERY arm. (Incident 2026-07-27, <pool-a>/operator.)
  # Marker payload is "<blocks>|<iso>": the count is bumped only when this gate actually blocks, and reset only
  # when this gate sees a live watcher (above) - i.e. it counts consecutive arms that left nothing alive behind.
  # A pre-2026-07-27 ISO-only marker parses to 0, so the first Stop after rollout blocks (safe direction).
  $blocks = 0
  try {
    if (Test-Path $mark) {
      $mAge = ((Get-Date) - (Get-Item $mark).LastWriteTime).TotalSeconds
      # Older than the board's own staleness bar (150s, see Get-WatchState) -> a leftover from an earlier struggle,
      # not evidence about this one -> start counting over. This is also the self-heal: a disengaged gate re-arms
      # itself after one quiet window instead of staying off until a human intervenes. Safe direction, because a
      # reset only ever restores BLOCKING - and a runaway block->arm->block loop cycles in seconds, so it can
      # never outlive the marker and slip past the cap.
      if ($mAge -le 150) { [void][int]::TryParse((([System.IO.File]::ReadAllText($mark)).Trim() -split '\|')[0], [ref]$blocks) }
    }
  } catch { $blocks = 0 }
  # Cap of 2: two blocks are the MINIMUM that closes the hole above (block -> arm -> instant fire -> block -> arm
  # -> claim), and one more would only add a wasted turn when the spawn is genuinely dead. Past the cap the gate
  # steps aside, because a broken spawn must never wedge a session - that is the whole reason a backoff exists.
  if ($blocks -ge 2) {
    # Count only WAKEABLE mail: a quiet note (including this gate's own disengage note) never wakes a watcher, so
    # counting it would tell the agent to "claim" something that is dismissed, not claimed - and point at the wrong cause.
    $pending = 0
    try { $pending = @(Get-ChildItem -Path (Sub-Dir $Owner 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { Is-Wakeable $_.Name }).Count } catch { }
    $why = if ($pending -gt 0) {
      "Most likely cause: $pending message(s) still sit in your new/ - an unclaimed task wakes each fresh watcher immediately, so every arm dies on the spot. Claim them first (pool.ps1 claim -Owner $Owner -Id <id>), then arm."
    } else {
      "Most likely cause: the spawn itself is failing (antivirus blocking child processes) - report that to Launcher and carry on."
    }
    # exit 0 stderr reaches NOBODY (only an exit-2 Stop hook talks to the model), so the safety net used to switch
    # itself off invisibly - which is how this bug survived unnoticed. Leave a quiet note instead: kind `note` never
    # wakes a watcher (Is-Wakeable), and Invoke-Hook surfaces it as [POOL NOTE] on the agent's very next turn.
    # Guarded by $off so one incident produces one note, and recovery (watcher alive) re-arms the announcement.
    if (-not (Test-Path $off)) {
      try {
        [void](Invoke-Send $Owner 'system' ("arm-gate disengaged - '$Owner' is idling WITHOUT a watcher") 'note' '' `
          ("The Stop arm-gate blocked twice, both arms left no live watcher, so it has stepped aside to avoid wedging you.`n`n$why`n`nArm with the Monitor tool (persistent=true): $(Get-SelfCommand 'monitor' $Owner $BusRoot)`n`nUntil a watcher is alive you will NOT be woken by incoming pool messages. Clear this note with: pool.ps1 dismiss -Owner $Owner"))
        Set-Content -Path $off -Value ((Get-Date).ToString('o')) -Encoding ASCII
      } catch { }
    }
    [Console]::Error.WriteLine("[POOL WATCHER] '$Owner': arming was requested twice and still no live watcher. NOT blocking again (a broken spawn must never wedge you). $why")
    return
  }
  try { Set-Content -Path $mark -Value ('{0}|{1}' -f ($blocks + 1), (Get-Date).ToString('o')) -Encoding ASCII } catch { }
  # Block the stop via EXIT CODE 2: the harness restarts the turn and feeds this stderr text to the agent, which then
  # arms the watcher. (exit-2 + stderr reaches the model; a stdout `reason` on a Stop hook would show only to the user.)
  [Console]::Error.WriteLine("No live pool watcher for '$Owner'. Before you stop, arm the CONTINUOUS monitor - use the Monitor tool with persistent=true (NOT a background Bash task), command:  $(Get-SelfCommand 'monitor' $Owner $BusRoot)  -- it wakes you on incoming pool tasks while you idle and does NOT exit when one arrives, so there is nothing to re-arm afterwards. Claim the task as usual: the claim is what makes it go quiet.  NB this is ROUTINE, not a fault: a monitor lives only as long as the session, so you land here after a fresh start or a /compact - not because anything broke. Just arm it: do NOT investigate, do NOT hunt processes or locks, and do NOT run `pool.ps1 armgate` by hand to double-check - it is a hook, not a diagnostic (it reads stdin, so a manual call sits there forever). Only if the Monitor tool is unavailable to you, fall back to the old one-shot watcher: same command with `watch` instead of `monitor`, launched as a Bash tool call with run_in_background=true - it fires once and must be re-armed every time. If arming genuinely fails twice in a row, this gate stops blocking and tells you so.")
  exit 2
}

# Tiny ANSI painter: wraps text in an SGR color for a live terminal; plain when output is redirected
# (capture/pipe/selftest stay clean, and everything stays on the success stream via Write-Output).
function Paint([string]$text, [string]$sgr) {
  if (-not $script:useColor -or -not $sgr) { return $text }
  $e = [char]27
  $e + '[' + $sgr + 'm' + $text + $e + '[0m'
}

# Watcher liveness from its heartbeat lock (.watch/lock-<owner>.txt): a watcher re-stamps its mtime every cycle
# (content is written once at arm) and deletes it on fire/exit. Fresh lock = armed & sleeping; stale = died/froze; absent = not armed (or the
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

# One-line memory footer under the board (target config §6: the memory board lives next to the task
# board). A SUMMARY only - per-role detail stays in memory-board.ps1, which is a separate, occasional
# run and may spend a process per role on the structural checker.
#
# Three deliberate restraints:
#  - nothing is printed unless the roll-out switch is on for THIS pool, so today every board stays
#    byte-identical to what it is now;
#  - cwd is read from the marker the launcher wrote (Resolve-AgentMemoryCwdForBus), never guessed
#    from the bus path - that guess is wrong for 5 pools out of 17, and wrong in the silent direction;
#  - no invented thresholds. Only facts the owner can act on: how many stores exist, the highest
#    index fill, and which roles have a store with no index at all (nothing there reaches the context).
#    Red is reserved for the two states that are facts rather than opinions: the ceiling is already
#    reached, or a store has no index.
function Write-MemoryFooter([object[]]$Rows, [string]$Bus, [string]$Tag) {
  $mod = Join-Path $PSScriptRoot 'agent-memory.ps1'
  if (-not (Test-Path $mod)) { return }
  . $mod
  $cwd = Resolve-AgentMemoryCwdForBus -BusRoot $Bus
  if (-not $cwd) { return }                                  # cwd unknown - say nothing rather than lie
  if (-not (Test-AgentMemoryEnabled -Cwd $cwd)) { return }   # not rolled out here - board unchanged

  $have = 0; $maxPct = 0; $maxWho = ''; $noIndex = @(); $unknown = 0
  foreach ($r in $Rows) {
    if (-not (Test-AgentOwnerName -Owner $r.name)) { continue }   # bus mailbox that cannot be a store name
    $st = Get-AgentMemoryStats -RoleDir (Join-Path (Join-Path $cwd '.memory') $r.name)
    if ($st.Unknown) { $unknown++; continue }
    if (-not $st.Exists) { continue }
    $have++
    if (-not $st.HasIndex) { $noIndex += $r.name; continue }
    if ($st.Pct -gt $maxPct) { $maxPct = $st.Pct; $maxWho = $r.name }
  }

  $line = "memory  {0}/{1} stores" -f $have, $Rows.Count
  if ($maxPct) { $line += "   index max {0}% in {1}" -f $maxPct, $maxWho }
  if ($noIndex.Count) { $line += "   NO INDEX: " + ($noIndex -join ', ') }
  if ($unknown) { $line += "   {0} busy" -f $unknown }
  $sgr = if ($noIndex.Count -or $maxPct -ge 100) { '91' } elseif ($have -eq 0) { '93' } else { '90' }
  Write-Output (Paint $line $sgr)
  # Подсказка обязана быть КОПИРУЕМОЙ. Тег в шапке борда - имя каталога рядом с шиной, а memory-board
  # спрашивает СЛАГ манифеста; на первом же живом пуле они разошлись (`.launcher` против `<organizer-pool>`),
  # и совет не сработал бы. Слаг берём из манифеста, если он лежит в cwd; не нашёлся - даём -All,
  # который верен всегда.
  $slug = $null
  try {
    $mf = Join-Path $cwd 'pool.manifest.json'
    if (Test-Path -LiteralPath $mf) { $slug = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json).slug }
  } catch { $slug = $null }
  $hint = if ($slug) { 'memory-board.ps1 -Pool ' + $slug } else { 'memory-board.ps1 -All' }
  Write-Output (Paint ("        detail: " + $hint) '90')
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
  # «Каталога шины нет» и «шина пустая» — РАЗНЫЕ вещи. Первое почти всегда = кривой путь (поле bus в
  # манифесте / POOL_BUS_ROOT во wrapper'е), и молчать о нём нельзя: серое '(empty bus)' на этом месте
  # маскировало баг 2026-07-27 — борд «DIV Extraction» выглядел просто пустым окном. Одна строка, не простыня.
  if (-not (Test-Path $BusRoot)) { Write-Output (Paint ('bus dir NOT FOUND: ' + $BusRoot) '91'); return }

  $dot = [char]0x25CF; $ring = [char]0x25CB; $br = [char]0x2514
  $hr  = [string]([char]0x2500) * [Math]::Min($W - 1, 72)
  $tag = try { Split-Path (Split-Path $BusRoot -Parent) -Leaf } catch { '' }

  # Roster of pool roles, if the launcher left one. Anything unparseable = no roster.
  $roster = $null
  try {
    $rf = Join-Path (Join-Path $BusRoot '.control') 'roster'
    if (Test-Path -LiteralPath $rf) {
      $roster = @(($L1RosterRead = [System.IO.File]::ReadAllText($rf)) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($_ -notmatch '^#') })
      if ($roster.Count -eq 0) { $roster = $null }
    }
  } catch { $roster = $null }

  $rows = @(Get-ChildItem -Path $BusRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(\.|_|archive$)' } | Sort-Object Name | ForEach-Object {
      [pscustomobject]@{
        name = $_.Name
        new  = @(Get-ChildItem (Join-Path $_.FullName 'new') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { -not (Is-Migration $_.Name) -and -not (Is-Note $_.Name) })
        cur  = @(Get-ChildItem (Join-Path $_.FullName 'cur') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { -not (Is-Migration $_.Name) -and -not (Is-Note $_.Name) })
        w    = (Get-WatchState $_.Name)
        a    = (Get-ActivityState $_.Name)
        role = ($null -eq $roster) -or ($roster -contains $_.Name)
      }
    })
  $arch  = @(Get-ChildItem (Join-Path $BusRoot 'archive') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
  $tPend  = [int](($rows | ForEach-Object { $_.new.Count } | Measure-Object -Sum).Sum)
  $tProg  = [int](($rows | ForEach-Object { $_.cur.Count } | Measure-Object -Sum).Sum)
  $roles   = @($rows | Where-Object { $_.role })
  $guests  = @($rows | Where-Object { -not $_.role })
  $tArmed  = [int](@($roles | Where-Object { $_.w.state -eq 'on' }).Count)
  $tActive = [int](@($rows | Where-Object { $_.a.act -eq 'busy' -or $_.a.act -eq 'busy?' -or $_.a.act -eq 'sub' }).Count)
  # "working" = fresh busy / running subagents / stale-busy? whose watcher is STILL alive (process up, just a long
  # quiet turn -> would otherwise falsely read as "stopped"). busy? with a dead/absent watcher = likely crashed ->
  # NOT counted, so the idle-notification can still fire. Drives the idle-notification trigger.
  $script:LastWorking = [int](@($rows | Where-Object { $_.a.act -eq 'busy' -or $_.a.act -eq 'sub' -or ($_.a.act -eq 'busy?' -and $_.w.state -eq 'on') }).Count)
  $script:LastTag = $tag

  Write-Output ((Paint ("POOL BOARD  " + $tag) '1;36') + (Paint ('   ' + (Get-Date).ToString('HH:mm:ss')) '90'))
  Write-Output (Paint $hr '36')
  Write-Output (
    (Paint ("{0} agents" -f $roles.Count) '97') + (Paint '  |  ' '90') +
    (Paint ("{0} pending" -f $tPend) $(if ($tPend) { '93' } else { '90' })) + (Paint '   ' '90') +
    (Paint ("{0} in progress" -f $tProg) $(if ($tProg) { '92' } else { '90' })) + (Paint '   ' '90') +
    (Paint ("{0} done" -f $arch) '90') + (Paint '  |  ' '90') +
    (Paint ("{0}/{1} watchers" -f $tArmed, $roles.Count) $(if ($roles.Count -and $tArmed -eq $roles.Count) { '92' } elseif ($tArmed -eq 0) { '90' } else { '93' })) + (Paint '  |  ' '90') +
    (Paint ("{0} active" -f $tActive) $(if ($tActive) { '93' } else { '90' }))
  )
  Write-Output (Paint $hr '90')

  foreach ($r in ($roles + $guests)) {
    # Guests are mailboxes in this bus that are not roles of the pool (a peer from another
    # pool writing to us). They are shown, but never counted as membership.
    if ($guests.Count -and $r -eq $guests[0]) {
      Write-Output (Paint ('  ' + [string][char]0x2500 + ' guests of this bus (not pool roles)') '90')
    }
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

  # Memory summary goes LAST, and inside try/catch. Both matter: $script:LastWorking / $script:LastTag
  # are already set above, so nothing here can break the idle notification, and the board runs in an
  # endless redraw loop - an escaping exception would kill the loop and leave a stale window that
  # still looks alive (the worst failure mode a monitor can have).
  try { Write-MemoryFooter -Rows $roles -Bus $BusRoot -Tag $tag } catch { }
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
          # Windows only, on purpose. notify-pool-idle.ps1 draws a DESKTOP notification (System.Windows.Forms /
          # BurntToast); on a headless server there is nobody to show it to, and spawning it would only start a
          # process that dies on the first Windows-only assembly. Before this change the Linux path was dead by
          # accident (no `powershell` executable) - resolving the interpreter would have quietly revived it,
          # because the enabling sentinel `.board-notify` travels with the tool directory.
          if ($script:OnWindows) {
            try { Start-Process powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Pool "{1}"' -f $n, $script:LastTag) | Out-Null } catch { }
          }
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
  'ready' { Invoke-Ready $Owner }
  'check' { Invoke-Check $Owner }
  'watch' { Invoke-Watch $Owner $IntervalSeconds }
  'monitor' { $iv = if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $IntervalSeconds } else { 20 }; Invoke-Monitor $Owner $iv }
  'hook'  { Invoke-Hook }
  'activity' { Invoke-Activity }
  'armgate' { Invoke-ArmGate }
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
  'help'  { Get-Content $PSCommandPath -TotalCount 40 }   # = длина шапки-справки; растёт вместе с ней
}
