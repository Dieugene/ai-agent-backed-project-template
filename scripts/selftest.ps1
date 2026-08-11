# selftest.ps1 - end-to-end verification of the shared pool.ps1 maildir bus.
# ASCII source; Cyrillic test data built from codepoints (no source literal). Runs on a throwaway temp bus.
$ErrorActionPreference = 'Stop'
$pool  = Join-Path $PSScriptRoot 'pool.ps1'
# --- platform. The same file has to run under Windows PowerShell 5.1 and under pwsh 7 on Linux (pools are
# moving to a server). A test runner that dies on its OWN platform assumptions produces red that says nothing
# about the code under test - that is worse than no test, because red gets ignored. Mirrors pool.ps1: only the
# interpreter name, its flags and the temp root differ.
$OnWin = $true
try { $iw = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($iw) { $OnWin = [bool]$iw.Value } } catch { }
$PSExe = if ($OnWin) { 'powershell' } else { try { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { 'pwsh' } }
# Flags come from a FUNCTION, and it returns with a leading comma, for one measured reason: an `if` whose
# branch yields a ONE-element array hands back a plain String, and `+` then CONCATENATES instead of appending.
# On the server that produced the argument `-NoProfile-File`, pwsh never started, no lock appeared, the gate
# blocked - two red checks and a usage banner, all from a missing space. Windows never saw it: its branch has
# three elements, so the array stayed an array. The bug lived in the branch that was SHORTER.
function Get-PSFlags([bool]$onWin) {
  [string[]]$fl = if ($onWin) { @('-NoProfile','-ExecutionPolicy','Bypass') } else { @('-NoProfile') }
  return ,$fl                      # leading comma: without it PowerShell unrolls a one-element array right back
}
[string[]]$PSFlg = Get-PSFlags $OnWin
$Tmp   = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
$bus   = Join-Path $Tmp ('pool-proto-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$cyr   = -join ([char[]](0x041F,0x0440,0x0438,0x0432,0x0435,0x0442))   # "Privet" in Cyrillic
$bodyf = Join-Path $Tmp ("pool-proto-body-{0}.txt" -f $PID)   # pid in the name: /tmp is shared on a server
[System.IO.File]::WriteAllText($bodyf, $cyr, (New-Object System.Text.UTF8Encoding($false)))
$R = @(); function A($n,$c){ $script:R += [pscustomobject]@{ t=$n; p=[bool]$c } }

# --- core flow: send -> inbox -> check(fire) -> check(idempotent) -> claim -> reply -> check(architect) -> ack ---
$id1  = (& $pool send -To backend-sub-a -From architect-sub-a -Subject SmokeOne -BodyFile $bodyf -BusRoot $bus) | Select-Object -Last 1
$inb  = & $pool inbox -Owner backend-sub-a -BusRoot $bus
$c1   = & $pool check -Owner backend-sub-a -BusRoot $bus
$c2   = & $pool check -Owner backend-sub-a -BusRoot $bus
$cl   = & $pool claim -Owner backend-sub-a -Id $id1 -BusRoot $bus
$c3   = & $pool check -Owner backend-sub-a -BusRoot $bus
$inb2 = & $pool inbox -Owner backend-sub-a -BusRoot $bus
$id2  = (& $pool reply -To architect-sub-a -From backend-sub-a -Subject SmokeReply -Body ok -InReplyTo $id1 -BusRoot $bus) | Select-Object -Last 1
$ac   = & $pool check -Owner architect-sub-a -BusRoot $bus
$ak   = & $pool ack -Owner backend-sub-a -Id $id1 -BusRoot $bus
$arch = Get-ChildItem (Join-Path $bus 'archive') -Filter ($id1 + '*') -File
$del  = [System.IO.File]::ReadAllText($arch.FullName, [System.Text.Encoding]::UTF8)
$bytes= [System.IO.File]::ReadAllBytes($arch.FullName)
$srcN = ([regex]::Matches($cyr, '[Ѐ-ӿ]')).Count
$delN = ([regex]::Matches($del, '[Ѐ-ӿ]')).Count

A 'send returns id'         ($id1 -match '^\d+-[0-9a-f]{10}$')
A 'inbox shows msg'         (($inb  -join "`n") -match [regex]::Escape($id1))
A 'check fires on new'          (($c1   -join "`n") -match 'WAKE')
A 'task re-wakes until claimed' (($c2   -join "`n") -match 'WAKE')
A 'claim ok'                    (($cl   -join "`n") -match 'CLAIMED')
A 'no-wake after claim'         (($c3   -join "`n") -match 'no-wake')
A 'inbox clean post-claim'      (($inb2 -join "`n") -match 'clean')
A 'reply fresh distinct id' (($id2 -match '^\d+-[0-9a-f]{10}$') -and ($id2 -ne $id1))
A 'id sortable id1<id2'     ([string]::CompareOrdinal($id1,$id2) -lt 0)
A 'reply wakes architect'   (($ac   -join "`n") -match 'WAKE')
A 'ack to archive'          (($ak   -join "`n") -match 'ACKED')
A 'cyrillic round-trips'    (($delN -ge $srcN) -and ($srcN -gt 0) -and ($del -match [regex]::Escape($cyr)))
A 'no BOM in message'       (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))

# --- hook (env-driven banner; silent for non-pool sessions) ---
& $pool send -To qa-sub-a -From architect-sub-a -Subject HookProbe -Body x -BusRoot $bus | Out-Null
$env:AGENT_OWNER = 'qa-sub-a'; $env:POOL_BUS_ROOT = $bus
$hk = & $pool hook
A 'hook emits POOL INBOX'   (($hk -join "`n") -match 'qa-sub-a: 1 pending')
$env:AGENT_OWNER = ''
$hkS = & $pool hook
A 'hook silent w/o owner'    ([string]::IsNullOrEmpty(($hkS -join '')))
$env:POOL_BUS_ROOT = ''

# --- карантин гашения: под intent-меткой роли ей не вбрасывают ничего ---
# Проверяем ТРИ вещи, и третья важнее первых двух: гард обязан стоять ДО вызова Invoke-Check.
# Если его переставить после, сторож промолчит, но реестр `seen-<owner>` уже перепишется — и
# проглоченный разовый пинг не разбудит роль НИКОГДА. Тест структурный, потому что цикл сторожа
# в наборе не поднять, а именно порядок здесь и есть предмет ошибки.
$qOwner = 'quarantine-sub-a'
& $pool send -To $qOwner -From architect-sub-a -Subject QuietProbe -Body z -BusRoot $bus | Out-Null
$qCtl = Join-Path $bus '.control'
if (-not (Test-Path $qCtl)) { New-Item -ItemType Directory -Force -Path $qCtl | Out-Null }
$qIntent = Join-Path $qCtl ("shutdown-intent-{0}" -f $qOwner)
$env:AGENT_OWNER = $qOwner; $env:POOL_BUS_ROOT = $bus
$qBefore = & $pool hook
[System.IO.File]::WriteAllText($qIntent, '')
$qUnder  = & $pool hook
$qCheck  = & $pool check -Owner $qOwner -BusRoot $bus
Remove-Item $qIntent -Force -ErrorAction SilentlyContinue
$qAfter  = & $pool hook
$env:AGENT_OWNER = ''; $env:POOL_BUS_ROOT = ''

$qSrc = [System.IO.File]::ReadAllText($pool, [System.Text.Encoding]::UTF8)
$qGuards = ([regex]::Matches($qSrc, '(?m)^\s*\$qOnly = if \(Test-ShutdownQuiet \$o\)[^\r\n]*\r?\n\s*\$det = Invoke-Check \$o \$qOnly')).Count
$qCalls  = ([regex]::Matches($qSrc, '(?m)^\s*\$det = Invoke-Check \$o \$qOnly')).Count
$qLedger = ([regex]::Matches($qSrc, 'if \(-not \$OnlyFrom\) \{ \[System.IO.File\]::WriteAllLines')).Count

A 'quarantine: banner speaks without the mark'   (($qBefore -join "`n") -match ($qOwner + ': 1 pending'))
A 'quarantine: banner still speaks (own turn, not an inbound wake)' (($qUnder -join "`n") -match ($qOwner + ': 1 pending'))
A 'quarantine: banner returns once mark is gone' (($qAfter  -join "`n") -match ($qOwner + ': 1 pending'))
A 'quarantine: watchers pass the controller-only filter into the check' (($qCalls -gt 0) -and ($qGuards -eq $qCalls))
A 'quarantine: ledger write is skipped in quarantine mode' ($qLedger -eq 1)
A 'quarantine: direct check stays unfiltered (manual diagnostics)' (($qCheck -join "`n") -match 'WAKE')
# --- watch fires immediately (message already present -> no Start-Sleep reached) ---
& $pool send -To metrics-sub-a -From architect-sub-a -Subject WatchProbe -Body y -BusRoot $bus | Out-Null
$w = & $pool watch -Owner metrics-sub-a -BusRoot $bus -IntervalSeconds 1
$wS = ($w -join "`n")
A 'watch fires + re-arm'    (($wS -match 'STEP 1') -and ($wS -match 'watch -Owner metrics-sub-a'))
A 'watch: claim before re-arm' (($wS -match 'STEP 1[^\r\n]*claim') -and ($wS.IndexOf('claim') -ge 0) -and ($wS.IndexOf('claim') -lt $wS.IndexOf('watch -Owner metrics-sub-a')))

# --- board prints a table ---
$bd = & $pool board -BusRoot $bus
A 'board prints table'      ((($bd -join "`n") -match 'POOL BOARD') -and (($bd -join "`n") -match 'qa-sub-a'))

# --- board hides migration notices (from=migration) ---
& $pool send -To listing-sub-a -From migration -Subject 'MIGNOTICE-HIDE-ME' -Body x -Kind notice -BusRoot $bus | Out-Null
$bdm = & $pool board -BusRoot $bus
A 'board hides migration note' (-not (($bdm -join "`n") -match 'MIGNOTICE-HIDE-ME'))

# --- mine (personal plate: own cur/ in-progress + new/ pending) ---
$mid = (& $pool send -To devops-sub-a -From architect-sub-a -Subject MineCur -Body z -BusRoot $bus) | Select-Object -Last 1
& $pool claim -Owner devops-sub-a -Id $mid -BusRoot $bus | Out-Null                                       # -> cur
& $pool send -To devops-sub-a -From architect-sub-a -Subject MinePending -Body z2 -BusRoot $bus | Out-Null  # -> new
$mn  = & $pool mine -Owner devops-sub-a -BusRoot $bus
$mnS = ($mn -join "`n")
A 'mine shows own cur'      (($mnS -match '1 in progress \(cur\), 1 pending \(new\)') -and ($mnS -match [regex]::Escape($mid)) -and ($mnS -match 'MineCur'))
A 'mine shows own new'      ($mnS -match 'MinePending')

# --- note channel: a message, NOT a task (hidden from board, separate inbox section, dismiss not claim/ack) ---
# quiet note: shown under [POOL NOTE], NOT counted as pending, does NOT wake the watcher
$nq    = (& $pool note -To note-quiet-sub-a -From architect-sub-a -Subject QuietNoteMsg -Body n1 -BusRoot $bus) | Select-Object -Last 1
$nqInb = & $pool inbox -Owner note-quiet-sub-a -BusRoot $bus
$nqChk = & $pool check -Owner note-quiet-sub-a -BusRoot $bus
A 'note send returns id'    ($nq -match '^\d+-[0-9a-f]{10}$')
A 'note in [POOL NOTE]'     ((($nqInb -join "`n") -match 'POOL NOTE') -and (($nqInb -join "`n") -match [regex]::Escape($nq)))
A 'quiet note not pending'  (($nqInb -join "`n") -match 'clean \(0 pending\)')
A 'quiet note no wake'      (($nqChk -join "`n") -match 'no-wake')

# waking note (-Wake): DOES wake the watcher, exactly like a task
$nw     = (& $pool note -To note-wake-sub-a -From architect-sub-a -Subject WakeNoteMsg -Body n2 -Wake -BusRoot $bus) | Select-Object -Last 1
$nwChk  = & $pool check -Owner note-wake-sub-a -BusRoot $bus
$nwChk2 = & $pool check -Owner note-wake-sub-a -BusRoot $bus
A 'waking note wakes'       (($nwChk  -join "`n") -match 'WAKE')
A 'waking note one-shot'    (($nwChk2 -join "`n") -match 'no-wake')

# board hides notes (both quiet and waking)
$bdn = & $pool board -BusRoot $bus
A 'board hides notes'       (-not (($bdn -join "`n") -match 'QuietNoteMsg|WakeNoteMsg'))

# task + note coexist for one owner: pending counts only the task; the note is shown separately
& $pool send -To note-mix-sub-a -From architect-sub-a -Subject MixTask -Body t -BusRoot $bus | Out-Null
& $pool note -To note-mix-sub-a -From architect-sub-a -Subject MixNote -Body n -BusRoot $bus | Out-Null
$mix = ((& $pool inbox -Owner note-mix-sub-a -BusRoot $bus) -join "`n")
A 'note no inflate pending' (($mix -match 'note-mix-sub-a: 1 pending') -and ($mix -match 'POOL NOTE'))

# dismiss clears a note in one step (new/ -> archive); inbox shows no note afterwards
$nd     = (& $pool note -To note-dismiss-sub-a -From architect-sub-a -Subject DismissMe -Body d -BusRoot $bus) | Select-Object -Last 1
$dis    = ((& $pool dismiss -Owner note-dismiss-sub-a -Id $nd -BusRoot $bus) -join "`n")
$ndInb  = ((& $pool inbox -Owner note-dismiss-sub-a -BusRoot $bus) -join "`n")
$ndArch = Get-ChildItem (Join-Path $bus 'archive') -Filter ($nd + '*') -File
A 'dismiss note->archive'   (($dis -match 'DISMISSED') -and ($ndArch) -and (-not ($ndInb -match 'POOL NOTE')))

# --- watcher liveness on the board: w on (fresh lock) / w off (no lock) / w stale (old lock) + header count ---
# Locks placed by hand: a real `watch` fires instantly here (message already present) and deletes its own lock.
$wd = Join-Path $bus '.watch'; [System.IO.Directory]::CreateDirectory($wd) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $wd 'lock-backend-sub-a.txt'), (Get-Date).ToString('o'), (New-Object System.Text.ASCIIEncoding))  # fresh -> on
$lkStale = Join-Path $wd 'lock-architect-sub-a.txt'
[System.IO.File]::WriteAllText($lkStale, 'x', (New-Object System.Text.ASCIIEncoding))
(Get-Item $lkStale).LastWriteTime = (Get-Date).AddSeconds(-600)                                                                          # old -> stale
$bd  = & $pool board -BusRoot $bus            # re-capture so the sample output below shows the watcher column
$bdS = ($bd -join "`n")
A 'board w on (fresh lock)'  ($bdS -match 'backend-sub-a[^\r\n]*w on')
A 'board w off (no lock)'    ($bdS -match 'qa-sub-a[^\r\n]*w off')
A 'board w stale (old lock)' ($bdS -match 'architect-sub-a[^\r\n]*w stale')
A 'board header counts armed'($bdS -match '\b1/\d+ watchers\b')

# --- activity tracking on the board: busy (UserPromptSubmit) / sub<N> (SubagentStart) / idle (Stop) ---
# `activity` is a hook command; here we feed payloads via -Body (the real hook reads them from stdin).
& $pool send -To act-sub-a -From architect-sub-a -Subject ActSeed -Body x -BusRoot $bus | Out-Null   # give act-<sub-a> a board row
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"UserPromptSubmit"}' -BusRoot $bus | Out-Null
$bAct1 = ((& $pool board -BusRoot $bus) -join "`n")
A 'activity busy on prompt'  ($bAct1 -match 'act-sub-a[^\r\n]*act busy')
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"SubagentStart","agent_id":"s1"}' -BusRoot $bus | Out-Null
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"SubagentStart","agent_id":"s2"}' -BusRoot $bus | Out-Null
$bAct2 = ((& $pool board -BusRoot $bus) -join "`n")
A 'activity counts subagents' ($bAct2 -match 'act-sub-a[^\r\n]*act sub2')
# Stop must NOT drop live sub-markers: background subagents outlive the parent turn, so the board stays sub2 (not idle)
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"Stop"}' -BusRoot $bus | Out-Null
$bAct3 = ((& $pool board -BusRoot $bus) -join "`n")
A 'stop keeps live sub markers' ($bAct3 -match 'act-sub-a[^\r\n]*act sub2')
$subLive = @(Get-ChildItem (Join-Path (Join-Path $bus '.activity') 'act-sub-a') -Filter 'sub-*' -File -ErrorAction SilentlyContinue).Count
A 'live markers survive stop'   ($subLive -eq 2)
# subagents finish -> SubagentStop drops markers -> board falls back to the idle state Stop set above
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"SubagentStop","agent_id":"s1"}' -BusRoot $bus | Out-Null
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"SubagentStop","agent_id":"s2"}' -BusRoot $bus | Out-Null
$bAct4 = ((& $pool board -BusRoot $bus) -join "`n")
A 'idle after last subagent'    ($bAct4 -match 'act-sub-a[^\r\n]*act idle')
# orphan backstop: a stale marker (>2h, missed SubagentStop) is swept on the next UserPromptSubmit; live markers stay
$stale = Join-Path (Join-Path (Join-Path $bus '.activity') 'act-sub-a') 'sub-orphan'
[System.IO.File]::WriteAllText($stale, '')
(Get-Item $stale).LastWriteTime = (Get-Date).AddHours(-3)
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"SubagentStart","agent_id":"live1"}' -BusRoot $bus | Out-Null
& $pool activity -Owner act-sub-a -Body '{"hook_event_name":"UserPromptSubmit"}' -BusRoot $bus | Out-Null
A 'orphan marker swept'         (-not (Test-Path $stale))
A 'fresh marker kept on sweep'  (Test-Path (Join-Path (Join-Path (Join-Path $bus '.activity') 'act-sub-a') 'sub-live1'))
Remove-Item (Join-Path (Join-Path (Join-Path $bus '.activity') 'act-sub-a') 'sub-live1') -Force -ErrorAction SilentlyContinue

# --- shutdown-ready invalidation: an AGENT turn must clear it, a MACHINE wake must not (incident 2026-07-27) ---
# The harness delivers a finished background task (one-shot watcher fired and exited; superseded sentinel died)
# through the same prompt queue as human input -> new promptId -> this hook. Blind wiping killed the readiness
# flag seconds after the agent created it. The turn text carries <task-notification>, so the two are separable.
$rdyOwner = 'act-sub-a'
$rdyFlag  = Join-Path (Join-Path $bus '.control') ("shutdown-ready-{0}" -f $rdyOwner)   # in the POOL BUS, not the shared ~\.claude\.control
[void][System.IO.Directory]::CreateDirectory((Split-Path $rdyFlag -Parent))
  function Set-RdyFlag { [System.IO.File]::WriteAllText($rdyFlag, '') }
  # 1. plain human turn -> flag cleared (guard against the sniff swallowing real work)
  Set-RdyFlag
  & $pool activity -Owner $rdyOwner -Body '{"hook_event_name":"UserPromptSubmit","prompt":"a plain human turn"}' -BusRoot $bus | Out-Null
  A 'ready flag cleared by human turn'  (-not (Test-Path $rdyFlag))
  # 2. machine wake -> flag survives. THE regression test for the incident.
  Set-RdyFlag
  & $pool activity -Owner $rdyOwner -Body '{"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>x</task-id>\n<summary>Background command completed</summary>\n</task-notification>"}' -BusRoot $bus | Out-Null
  A 'ready flag survives machine wake'  (Test-Path $rdyFlag)
  # 3. same, but the text sits in a DIFFERENT field: the match is on the raw payload on purpose, because the
  #    field name proved unstable (docs promise user_message, measurement gives prompt). Breaks if someone
  #    "improves" this into $o.prompt -match ...
  Remove-Item $rdyFlag -Force -ErrorAction SilentlyContinue; Set-RdyFlag
  & $pool activity -Owner $rdyOwner -Body '{"hook_event_name":"UserPromptSubmit","user_message":"<task-notification>\n<task-id>y</task-id>\n</task-notification>"}' -BusRoot $bus | Out-Null
  A 'raw-payload match, not field name' (Test-Path $rdyFlag)
  # 4. no text field at all -> fall back to today's behaviour (fail-safe: the condition may only NARROW wiping)
  & $pool activity -Owner $rdyOwner -Body '{"hook_event_name":"UserPromptSubmit"}' -BusRoot $bus | Out-Null
  A 'no text field -> legacy wipe'      (-not (Test-Path $rdyFlag))
  # 5. pool scope: the same owner in ANOTHER pool must not have its flag wiped from here. Role names repeat
  #    across pools (lead/operator/builder in two, tech-lead/qa in three) and the shared ~\.claude\.control
  #    used to make one pool's human turn clear another pool's readiness. The bus makes it structural.
  $otherBus  = Join-Path $Tmp ('pool-selftest-otherbus-' + $PID)
  $otherFlag = Join-Path (Join-Path $otherBus '.control') ("shutdown-ready-{0}" -f $rdyOwner)
  [void][System.IO.Directory]::CreateDirectory((Split-Path $otherFlag -Parent))
  [System.IO.File]::WriteAllText($otherFlag, '')
  & $pool activity -Owner $rdyOwner -Body '{"hook_event_name":"UserPromptSubmit","prompt":"human turn in THIS pool"}' -BusRoot $bus | Out-Null
  A 'other pool flag untouched'         (Test-Path $otherFlag)
  Remove-Item $otherBus -Recurse -Force -ErrorAction SilentlyContinue

# drive a few owners into distinct states purely so the sample board below showcases the new columns
& $pool activity -Owner act-sub-a     -Body '{"hook_event_name":"UserPromptSubmit"}'                  -BusRoot $bus | Out-Null
& $pool activity -Owner act-sub-a     -Body '{"hook_event_name":"SubagentStart","agent_id":"d1"}'     -BusRoot $bus | Out-Null
& $pool activity -Owner act-sub-a     -Body '{"hook_event_name":"SubagentStart","agent_id":"d2"}'     -BusRoot $bus | Out-Null
& $pool activity -Owner backend-sub-a -Body '{"hook_event_name":"UserPromptSubmit"}'                  -BusRoot $bus | Out-Null
& $pool activity -Owner qa-sub-a      -Body '{"hook_event_name":"UserPromptSubmit"}'                  -BusRoot $bus | Out-Null
& $pool activity -Owner qa-sub-a      -Body '{"hook_event_name":"Stop"}'                              -BusRoot $bus | Out-Null
$bd = & $pool board -BusRoot $bus

# --- Stop-hook ARM-GATE: env-gated. Run as a SEPARATE process (as the real hook does) so `exit 2` (block) does
# not terminate this runner; assert on exit code. exit 2 = block+arm, exit 0 = allow. Empty stdin -> treated as Stop. ---
function ArmGateExit([string]$owner, [string]$payload = '') {
  $agArgs = $PSFlg + @('-File',$pool,'armgate','-Owner',$owner,'-BusRoot',$bus)
  if ($OnWin) {
  # Windows: the payload goes in as a FILE. Writing it to the stream is not an option: the child StandardInput
  # carries the console encoding and emits a UTF-8 preamble on the first write (measured with a probe: LEN=37,
  # bytes EF BB BF ahead of the JSON). The gate then fails to parse the JSON, reads the payload as an ordinary
  # Stop and BLOCKS - so 'ignores SubagentStop' goes red on correct code. The cure is StandardInputEncoding on
  # ProcessStartInfo, which does not exist in .NET Framework 4.8 - and 5.1 IS 4.8 (checked with Get-Member).
    $ef = Join-Path $Tmp ('agerr-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $pf = Join-Path $Tmp ('agin-'  + [Guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($pf, $payload)
    $p = Start-Process $PSExe -ArgumentList $agArgs -Wait -PassThru -NoNewWindow -RedirectStandardInput $pf -RedirectStandardError $ef
    Remove-Item $pf,$ef -Force -ErrorAction SilentlyContinue
    return $p.ExitCode
  }
  # Non-Windows: the same Start-Process form never reaches the script - pwsh prints its own usage banner, one
  # per call (13 banners in the server log, exactly the number of calls made before the run died). This form
  # works there and carries no preamble: .NET Core defaults to UTF-8 without a BOM.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $PSExe
  $psi.Arguments = (($PSFlg -join ' ') + (' -File "{0}" armgate -Owner {1} -BusRoot "{2}"' -f $pool, $owner, $bus))
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Write($payload); $p.StandardInput.Close()
  [void]$p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd()   # drain before Wait: a full pipe deadlocks
  $p.WaitForExit()
  return $p.ExitCode
}
$env:POOL_WATCHER = ''                                                                     # opt-out -> instant no-op
A 'armgate no-op without opt-in'      ((ArmGateExit 'ag-off-sub-a') -eq 0)
$env:POOL_WATCHER = '1'
A 'armgate blocks when no watcher'    ((ArmGateExit 'ag-a-sub-a') -eq 2)
# REGRESSION (incident 2026-07-27): the 2nd Stop must STILL block. A watcher that armed, fired on a pending task
# and exited is indistinguishable from a broken spawn by elapsed time - the old <30s window let this pass silently
# and left the session with no watcher at all. Backoff now counts blocks, so it takes the cap (2) to step aside.
A 'armgate re-blocks after dead arm'  ((ArmGateExit 'ag-a-sub-a') -eq 2)
A 'armgate backs off past the cap'    ((ArmGateExit 'ag-a-sub-a') -eq 0)
A 'armgate notes its disengage'       (@(Get-ChildItem (Join-Path (Join-Path $bus 'ag-a-sub-a') 'new') -Filter '*.note.md' -File -ErrorAction SilentlyContinue).Count -eq 1)
A 'armgate notes only once'           (@(Get-ChildItem (Join-Path (Join-Path $bus 'ag-a-sub-a') 'new') -Filter '*.note.md' -File -ErrorAction SilentlyContinue).Count -eq 1 -and (ArmGateExit 'ag-a-sub-a') -eq 0)
A 'armgate ignores SubagentStop'      ((ArmGateExit 'ag-b-sub-a' '{"hook_event_name":"SubagentStop"}') -eq 0)
$agWd = Join-Path $bus '.watch'; [System.IO.Directory]::CreateDirectory($agWd) | Out-Null
$myTicks = if ($OnWin) { (Get-Process -Id $PID).StartTime.Ticks } else { 0 }   # see note: 0 = skip identity, assert on liveness
[System.IO.File]::WriteAllText((Join-Path $agWd 'lock-ag-live-sub-a.txt'), ('{0}|{1}|{2}' -f $PID, $myTicks, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
A 'armgate allows on live watcher'    ((ArmGateExit 'ag-live-sub-a') -eq 0)
[System.IO.File]::WriteAllText((Join-Path $agWd 'lock-ag-dead-sub-a.txt'), ('{0}|{1}|{2}' -f 999999999, 1, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
A 'armgate blocks on dead-pid lock'   ((ArmGateExit 'ag-dead-sub-a') -eq 2)
# REGRESSION (opponent review of the Linux port, 2026-08-04): 5.1 returns $null - NOT a throw - for the StartTime
# of a process it may not inspect (measured: 143 of 474 pids on this box - System, csrss, svchost, AV). An identity
# check that reads "cannot tell" as "skip the check" turns a RECYCLED pid in a stale monitor lock into "watcher
# alive": the gate stops demanding a re-arm and the role then idles unwoken by incoming tasks - the exact wedge the
# gate exists to prevent. A monitor never deletes its lock, so stale locks are the NORMAL state after an abrupt end.
$opaque = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $null -eq (Get-Process -Id $_.Id -ErrorAction SilentlyContinue).StartTime } | Select-Object -First 1)
if ($opaque.Count -eq 1) {
  [System.IO.File]::WriteAllText((Join-Path $agWd 'lock-ag-opaque-sub-a.txt'), ('{0}|{1}|{2}' -f $opaque[0].Id, 123456789, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
  A 'armgate blocks on a pid with unreadable StartTime' ((ArmGateExit 'ag-opaque-sub-a') -eq 2)
}
# REGRESSION, identity of the watcher process. Two halves, and BOTH are needed because every other fixture in
# this file writes the stamp with the same process that later reads it - a stamp that only ever agrees with
# itself passes them all. That is exactly how the Linux defect survived: there .NET derives StartTime from a
# floating boot time, so two readers of the SAME pid get different values and the gate calls a live watcher dead.
# (a) mismatch on a LIVE pid must BLOCK - this is the pid-reuse guard, and it is the half a platform port breaks.
[System.IO.File]::WriteAllText((Join-Path $agWd 'lock-ag-stamp-sub-a.txt'), ('{0}|{1}|{2}' -f $PID, 1, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
A 'armgate blocks on a live pid with a wrong stamp' ((ArmGateExit 'ag-stamp-sub-a') -eq 2)
# (b) a lock written by a REAL watcher process must be ACCEPTED by the gate - cross-process, which is the only
# comparison that happens in the field. Uses `monitor` (the primary arming path), not the one-shot `watch`.
$xpOut  = Join-Path $Tmp ('agxp-out-' + [Guid]::NewGuid().ToString('N') + '.txt')
$xpErr  = Join-Path $Tmp ('agxp-err-' + [Guid]::NewGuid().ToString('N') + '.txt')
$xpArgs = $PSFlg + @('-File',$pool,'monitor','-Owner','ag-xproc-sub-a','-BusRoot',$bus,'-IntervalSeconds','30')
$xp     = Start-Process $PSExe -ArgumentList $xpArgs -PassThru -NoNewWindow -RedirectStandardOutput $xpOut -RedirectStandardError $xpErr
$xpLock = Join-Path $agWd 'lock-ag-xproc-sub-a.txt'
$xpTill = (Get-Date).AddSeconds(15)                              # generous: a cold PowerShell start is ~1s, a loaded box slower
while (-not (Test-Path $xpLock) -and (Get-Date) -lt $xpTill) { Start-Sleep -Milliseconds 200 }
$xpLockOk = Test-Path $xpLock
$xpExit   = if ($xpLockOk) { ArmGateExit 'ag-xproc-sub-a' } else { -1 }
$xpOk     = $xpLockOk -and ($xpExit -eq 0)
A 'armgate accepts a lock written by a real watcher process' $xpOk
if (-not $xpOk) {
  # A red here MUST say which of the three it was - child never started / started too slowly / gate refused a
  # lock it should accept. Measured on the server: this went red while the same comparison passed by hand, and
  # nothing in the output distinguished the cases. The temp files stay on disk when red, for the same reason.
  $xpAlive = $false; try { $xpAlive = -not (Get-Process -Id $xp.Id -ErrorAction Stop).HasExited } catch { }
  $xpSe = ((Get-Content $xpErr -ErrorAction SilentlyContinue) -join ' | ')
  $xpSo = ((Get-Content $xpOut -ErrorAction SilentlyContinue) -join ' | ')
  Write-Output ("  WHY lock={0} gateExit={1} childAlive={2}" -f $xpLockOk, $xpExit, $xpAlive)
  Write-Output ("  WHY cmd={0} {1}" -f $PSExe, ($xpArgs -join ' '))
  Write-Output ("  WHY child stderr: " + $xpSe.Substring(0, [Math]::Min(400, $xpSe.Length)))
  Write-Output ("  WHY child stdout: " + $xpSo.Substring(0, [Math]::Min(400, $xpSo.Length)))
  Write-Output ("  WHY kept: {0} , {1} , lock {2}" -f $xpOut, $xpErr, $xpLock)
}
Stop-Process -Id $xp.Id -Force -ErrorAction SilentlyContinue
if ($xpOk) { Remove-Item $xpOut, $xpErr, $xpLock -Force -ErrorAction SilentlyContinue }
# The block counter must RESET once the gate sees a live watcher, otherwise a pool that recovers stays one Stop
# away from a permanent disengage. Block once, recover, then the next failure must block again from scratch.
$rstLock = Join-Path $agWd 'lock-ag-rst-sub-a.txt'
A 'armgate blocks (reset case)'       ((ArmGateExit 'ag-rst-sub-a') -eq 2)
[System.IO.File]::WriteAllText($rstLock, ('{0}|{1}|{2}' -f $PID, $myTicks, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
A 'armgate allows, clearing counter'  ((ArmGateExit 'ag-rst-sub-a') -eq 0)
Remove-Item $rstLock -Force -ErrorAction SilentlyContinue
A 'armgate blocks again after reset'  ((ArmGateExit 'ag-rst-sub-a') -eq 2)

# --- regression (field defect, <pool-a> 30-31.07: six crashes across four roles in two days). The heartbeat lock
# is a CONTENDED file, and the old code lost on both ends. Writer: Set-Content threw and killed the whole watcher -
# twice over, with two different texts (sharing violation, and "stream is not readable" leaving a ZERO-BYTE lock).
# Reader: ReadAllText asks for FileShare.Read, so a LIVE writer made the open fail -> $null -> "no watcher" while
# the watcher was right there. Either way the arm-gate demands an arm, and the newest-wins arm cannot kill the
# prior watcher (it reads pid 0 / nothing), so the owner ends up with TWO live watchers writing one file.
# Now: content is written once and only the mtime is touched per cycle, the writer shares Read, the reader shares
# ReadWrite, and a failed beat is survivable. ---
$hbLock = Join-Path $agWd 'lock-ag-hb-sub-a.txt'
[System.IO.File]::WriteAllText($hbLock, ('{0}|{1}|{2}' -f $PID, $myTicks, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
$hbFs = New-Object System.IO.FileStream($hbLock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)  # exactly how a live watcher holds it
$hbExit = ArmGateExit 'ag-hb-sub-a'
$hbFs.Dispose()
A 'armgate reads a lock held by a writer' ($hbExit -eq 0)
[System.IO.File]::WriteAllText((Join-Path $agWd 'lock-ag-empty-sub-a.txt'), '', (New-Object System.Text.ASCIIEncoding))
A 'armgate blocks on a zero-byte lock'    ((ArmGateExit 'ag-empty-sub-a') -eq 2)
# Writer side: the watcher must SURVIVE a lock it cannot write, and must not leave a truncated one behind.
# The fixture differs by platform because "unwritable" does. Windows: a FileShare::None handle. Linux has no
# mandatory locking - an open handle stops nobody, the watcher fired, deleted the lock (it does that on WAKE)
# and the read below then killed the WHOLE run, so everything after this point never executed on the server.
# There the fixture is a read-only DIRECTORY: deletion and creation are governed by the directory, not the
# file, so this is what actually makes a lock unwritable on that platform. Rights are restored immediately.
& $pool send -To hb-lock-sub-a -From architect-sub-a -Subject HbProbe -Body z -BusRoot $bus | Out-Null
$hbBusy = Join-Path $agWd 'lock-hb-lock-sub-a.txt'
[System.IO.File]::WriteAllText($hbBusy, ('{0}|{1}|{2}' -f 999999999, 1, (Get-Date).ToString('o')), (New-Object System.Text.ASCIIEncoding))
$hbBusyFs = $null
if ($OnWin) { $hbBusyFs = New-Object System.IO.FileStream($hbBusy, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
else        { & chmod 500 $agWd | Out-Null }
$hbW = ((& $pool watch -Owner hb-lock-sub-a -BusRoot $bus -IntervalSeconds 1) -join "`n")
if ($OnWin) { $hbBusyFs.Dispose() } else { & chmod 700 $agWd | Out-Null }
# Never let a fixture abort the run: a missing file here is a FAILED check, not a dead test session.
$hbAfter = ''
try { $hbAfter = [System.IO.File]::ReadAllText($hbBusy) } catch { $hbAfter = '' }
A 'watch survives an unwritable lock'     ($hbW -match 'STEP 1')
A 'unwritable lock keeps its content'     ($hbAfter.Trim().Length -gt 0)

# --- regression: hook commands run BY HAND (agent tool call) get a stdin that is redirected but NEVER closed.
# ArmGateExit above feeds a FILE (instant EOF), so it cannot see this: a blocking ReadToEnd() there wedges the
# process forever - the hours-old armgate leftovers agents kept finding and misreading as orphans. ---
function HookSurvivesOpenStdin([string]$cmd, [string]$owner, [int]$waitMs = 15000) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $PSExe
  $psi.Arguments = (($PSFlg -join ' ') + " -File `"$pool`" $cmd -Owner $owner -BusRoot `"$bus`"")
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true      # opened and left OPEN on purpose: no EOF ever arrives
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $done = $p.WaitForExit($waitMs)
  if (-not $done) { try { $p.Kill() } catch { } }
  return $done
}
A 'armgate survives open stdin'       (HookSurvivesOpenStdin 'armgate' 'ag-stdin-sub-a')
A 'activity survives open stdin'      (HookSurvivesOpenStdin 'activity' 'ag-stdin-sub-a')

# --- regression: a watcher needs ~1s of PowerShell startup before it writes its first lock, and the agent arms and
# THEN stops - so the gate routinely runs while the arm is still booting. Reading that as "no watcher" made the agent
# re-arm a duplicate and burn a turn on a phantom failure. Timing is not left to luck: the arm is a stub named
# pool.ps1 (so its command line carries the real `pool.ps1 watch -Owner <o>` signature) that writes its lock only
# after 2.5s - far outside any boot jitter, so pre-fix this ALWAYS blocks and post-fix it must always allow. ---
$stubDir = Join-Path $Tmp ('agflight-' + [Guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Force -Path $stubDir)
$stub = Join-Path $stubDir 'pool.ps1'
Set-Content -Path $stub -Encoding ASCII -Value @(
  'param([string]$Cmd,[string]$Owner,[string]$BusRoot)'
  'Start-Sleep -Milliseconds 2500'
  '# Windows: real ticks. Elsewhere 0 = "cannot tell", so the gate answers on pid liveness alone - it compares'
  '# against a /proc value on that platform and .NET ticks could never match it. Same convention as the other'
  '# lock fixtures here. The version test short-circuits before $IsWindows, which does not exist on 5.1.'
  '$t = 0'
  'if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) { $t = (Get-Process -Id $PID).StartTime.Ticks }'
  '$lk = Join-Path (Join-Path $BusRoot ".watch") ("lock-{0}.txt" -f $Owner)'
  '[System.IO.File]::WriteAllText($lk, ("{0}|{1}|{2}" -f $PID, $t, (Get-Date).ToString("o")))'
  'Start-Sleep -Seconds 60'
)
$fwOut  = Join-Path $Tmp ('agfw-out-' + [Guid]::NewGuid().ToString('N') + '.txt')
$fwErr  = Join-Path $Tmp ('agfw-err-' + [Guid]::NewGuid().ToString('N') + '.txt')
$fwArgs = $PSFlg + @('-File',$stub,'watch','-Owner','ag-flight-sub-a','-BusRoot',$bus)
# Output captured, not thrown away: an arm that fails to START is indistinguishable from one the gate refused,
# and that is exactly the ambiguity that cost a round-trip to the server.
if ($OnWin) { $fw = Start-Process $PSExe -ArgumentList $fwArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $fwOut -RedirectStandardError $fwErr }
else        { $fw = Start-Process $PSExe -ArgumentList $fwArgs -PassThru -NoNewWindow -RedirectStandardOutput $fwOut -RedirectStandardError $fwErr }
Start-Sleep -Milliseconds 400                                              # let the stub exist; its lock is still 2.1s away
$fwExit = ArmGateExit 'ag-flight-sub-a'
$fwOk   = ($fwExit -eq 0)
A 'armgate allows an arm in flight'   $fwOk
if (-not $fwOk) {
  $fwAlive = $false; try { $fwAlive = -not (Get-Process -Id $fw.Id -ErrorAction Stop).HasExited } catch { }
  $fwSe = ((Get-Content $fwErr -ErrorAction SilentlyContinue) -join ' | ')
  Write-Output ("  WHY gateExit={0} stubAlive={1}" -f $fwExit, $fwAlive)
  Write-Output ("  WHY cmd={0} {1}" -f $PSExe, ($fwArgs -join ' '))
  Write-Output ("  WHY stub stderr: " + $fwSe.Substring(0, [Math]::Min(400, $fwSe.Length)))
}
Stop-Process -Id $fw.Id -Force -ErrorAction SilentlyContinue
if ($fwOk) { Remove-Item $fwOut, $fwErr -Force -ErrorAction SilentlyContinue }
Remove-Item $stubDir -Recurse -Force -ErrorAction SilentlyContinue
$env:POOL_WATCHER = ''

# --- `ready`: the ONLY way to set a shutdown readiness flag (incident 2026-07-27) ---
# A lead claimed the shutdown task, never opened its body, ran the procedure from memory and wrote the flag
# to the pre-2026-07-27 global path. The controller never saw it -> silent TIMEOUT. The flag address is now
# the script's business, not the agent's. Guards matter as much as the flag: it authorizes a KILL, so it must
# refuse to exist without a live intent and a controller task the agent actually took.
$rdyO   = 'ready-probe-sub-a'
$rdyCtl = Join-Path $bus '.control'
$rdyFlg = Join-Path $rdyCtl ('shutdown-ready-' + $rdyO)
$rdyInt = Join-Path $rdyCtl ('shutdown-intent-' + $rdyO)

$r1 = & $pool ready -Owner $rdyO -BusRoot $bus                      # no intent at all
A 'ready refuses without a shutdown intent'  ((($r1 -join "`n") -match 'READY-REFUSED') -and -not (Test-Path $rdyFlg))

[void][System.IO.Directory]::CreateDirectory($rdyCtl)
[System.IO.File]::WriteAllText($rdyInt, '')
$r2 = & $pool ready -Owner $rdyO -BusRoot $bus                      # intent, but agent never took the task
A 'ready refuses until the task is taken'    ((($r2 -join "`n") -match 'READY-REFUSED') -and -not (Test-Path $rdyFlg))

$rdyId = (& $pool send -To $rdyO -From pool-controller -Subject ShutdownProbe -Body x -BusRoot $bus) | Select-Object -Last 1
$rdyCl = & $pool claim -Owner $rdyO -Id $rdyId -BusRoot $bus
A 'claim points at the task file to read'    (($rdyCl -join "`n") -match 'READ THIS FIRST')

$r3 = & $pool ready -Owner $rdyO -BusRoot $bus                      # intent + claimed controller task
A 'ready sets the flag once conditions hold' ((($r3 -join "`n") -match 'READY:') -and (Test-Path $rdyFlg))
A 'ready flag lands in the POOL bus, not global' (($r3 -join "`n") -match [regex]::Escape($rdyCtl))
A 'ready is idempotent'                      ((& $pool ready -Owner $rdyO -BusRoot $bus) -join "`n") -match 'READY:'

# A task older than the intent must not count: it proves nothing about THIS shutdown cycle.
$rdyO2 = 'ready-stale-sub-a'
$stCtl = Join-Path $bus '.control'
[System.IO.File]::WriteAllText((Join-Path $stCtl ('shutdown-intent-' + $rdyO2)), '')
$stCur = Join-Path (Join-Path $bus $rdyO2) 'cur'
[void][System.IO.Directory]::CreateDirectory($stCur)
[System.IO.File]::WriteAllText((Join-Path $stCur '1000000000000-abcdef0123.from-pool-controller.coord.1.1.md'), 'old')
$r4 = & $pool ready -Owner $rdyO2 -BusRoot $bus
A 'ready ignores a task older than the intent' ((($r4 -join "`n") -match 'READY-REFUSED') -and -not (Test-Path (Join-Path $stCtl ('shutdown-ready-' + $rdyO2))))

# Both branches, not just the current platform's: on Windows the three-element branch can never regress, so a
# check that only looks at $PSFlg would be permanently green here and catch nothing. Count -eq 3 is the point -
# a concatenated String would come back as ONE element.
$flgW = Get-PSFlags $true
$flgL = Get-PSFlags $false
A 'platform flags stay an array on both branches' (($flgW -is [array]) -and ($flgL -is [array]) -and ((@($flgL) + @('-File','x')).Count -eq 3) -and ((@($flgW) + @('-File','x')).Count -eq 5))
# --- companion files. A pool-bus copied WITHOUT its siblings still writes a VALID settings file whose hook
# commands point at scripts that are not there (measured on the Linux port: only *.ps1 were taken, the flag
# file stayed behind). The engine does report it - exit 127 per firing - but nothing reads that, so catch it
# here. Names are read OUT of the scripts, so this cannot rot when a dependency is added; a zero match means
# the regex itself broke, which must fail too, or the check would go green on an empty set.
$sibPat  = 'Join-Path\s+\$PSScriptRoot\s+.([A-Za-z0-9_.-]+\.ps1)'
$sibRefs = @{}
foreach ($src in @($pool, (Join-Path $PSScriptRoot 'agent-memory.ps1'))) {
  if (-not (Test-Path $src)) { continue }
  foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($src), $sibPat)) { $sibRefs[$m.Groups[1].Value] = $true }
}
$sibMissing = @($sibRefs.Keys | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) })
A ("companion scripts present ({0} referenced)" -f $sibRefs.Count) (($sibRefs.Count -ge 2) -and ($sibMissing.Count -eq 0))

$pass = @($R | Where-Object p).Count; $tot = $R.Count
Write-Output ("=== shared pool.ps1 self-test: {0}/{1} PASS on {2} ===" -f $pass, $tot, $(if ($OnWin) { 'windows' } else { 'linux' }))
$R | Where-Object { -not $_.p } | ForEach-Object { Write-Output ("  FAIL: " + $_.t) }
Write-Output ''
Write-Output '--- sample board output ---'
$bd | ForEach-Object { Write-Output $_ }

Remove-Item $bus   -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $bodyf -Force -ErrorAction SilentlyContinue

# The verdict travels in the EXIT CODE, not only in the text: a run with a red check used to exit 0, so any
# pipeline gate keyed on the code reported success on failure. Text is for humans, the code is for gates.
if ($pass -ne $tot) { exit 1 }

