#requires -version 5
# Global Stop-hook DETECTOR (pilot). When a POOL session's transcript shows the harness marker
# "malformed and could not be parsed" (the model leaked a tool_call as TEXT -> format drift),
# fire a Windows notification AND append a durable record to a global JSONL log for later analysis.
# DETECT + NOTIFY + LOG. No treatment (that stays gated until detection proves out on the live set).
#
# Non-blocking (always exit 0): never holds the stop. Gated to pool agents (POOL_BUS_ROOT + AGENT_OWNER
# set) so plain launcher/devops sessions are excluded. Stop fires on every turn-end, so we DEDUP via a
# per-owner offset file <POOL_BUS_ROOT>/.watch/malformed-<owner>.txt (stores the transcript byte length
# last processed): only markers in the NEW region since last check trigger a notification. First sight
# of a transcript is silent (records length, no notify for pre-existing history) -> forward-looking.
#
# For each firing the log captures: timestamp, owner, pool, session, count (new markers this turn),
# recovered (did the model self-correct after the LAST marker -> a real "type":"tool_use" or a clean
# "stop_reason":"end_turn" appears in the tail), and a sanitized snippet of the leaked block ("what").
# Self-correction/leak structure verified against real transcripts 2026-07-13 (see reference memo).
#
# ASCII-only on purpose (no BOM trap under PS 5.1). -SelfTest runs synthetic detection cases; it never
# fires a real notification (analysis is pure; Start-Process lives only in the live path).
param([switch]$SelfTest)
$ErrorActionPreference = 'SilentlyContinue'

$MARKER = 'malformed and could not be parsed'
$NOTIFY = 'C:\workspace-root\.launcher\pool-bus\notify-malformed.ps1'
$LOG    = Join-Path $env:USERPROFILE '.claude\malformed-log.jsonl'

# Analyze the NEW region of $transcriptPath since the byte length recorded in $stateFile, then advance
# $stateFile to the current length. Returns [pscustomobject] { Count; Recovered; Snippet }.
#   Count     - number of marker occurrences in the new region.
#   Recovered - (Count>0) does the tail after the LAST marker contain a valid "type":"tool_use" or a
#               "stop_reason":"end_turn"? -> the turn moved on cleanly = model self-corrected.
#   Snippet   - (Count>0) short one-line preview of the leaked block before the FIRST marker.
# First sight (no state) records length and returns a zero result when $firstSightSilent. A shorter file
# than recorded (new session / reset) resets silently.
function Get-RegionAnalysis([string]$transcriptPath, [string]$stateFile, [bool]$firstSightSilent = $true) {
  $res = [pscustomobject]@{ Count = 0; Recovered = $false; Snippet = '' }
  if (-not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath)) { return $res }
  $len = (Get-Item -LiteralPath $transcriptPath).Length
  $haveState = Test-Path -LiteralPath $stateFile
  $prev = 0
  if ($haveState) {
    $raw = (Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue)
    [void][int64]::TryParse(("$raw").Trim(), [ref]$prev)
  } elseif ($firstSightSilent) {
    Set-Content -LiteralPath $stateFile -Value $len -Encoding ASCII
    return $res
  }
  if ($len -le $prev) { Set-Content -LiteralPath $stateFile -Value $len -Encoding ASCII; return $res }
  $region = ''
  $fs = [System.IO.File]::Open($transcriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    [void]$fs.Seek($prev, [System.IO.SeekOrigin]::Begin)
    $sr = New-Object System.IO.StreamReader($fs)
    $region = $sr.ReadToEnd()
    $sr.Dispose()
  } finally { $fs.Dispose() }
  Set-Content -LiteralPath $stateFile -Value $len -Encoding ASCII

  $count = ([regex]::Matches($region, [regex]::Escape($MARKER))).Count
  $res.Count = $count
  if ($count -gt 0) {
    $lastIdx = $region.LastIndexOf($MARKER)
    $tail = if ($lastIdx -ge 0) { $region.Substring($lastIdx + $MARKER.Length) } else { '' }
    $res.Recovered = ($tail -match '"type":"tool_use"') -or ($tail -match '"stop_reason":"end_turn"')

    $firstIdx = $region.IndexOf($MARKER)
    $before = if ($firstIdx -ge 0) { $region.Substring(0, $firstIdx) } else { $region }
    $inv = $before.LastIndexOf('<invoke')
    if ($inv -ge 0) {
      $start = [Math]::Max(0, $inv - 12)
      $sniplen = [Math]::Min(150, $before.Length - $start)
      $slice = $before.Substring($start, $sniplen)
    } elseif ($before.Length -gt 150) {
      $slice = $before.Substring($before.Length - 150)
    } else {
      $slice = $before
    }
    $res.Snippet = (($slice -replace '\\n', ' ') -replace '\\r', ' ' -replace '\s+', ' ').Trim()
  }
  return $res
}

# Back-compat thin wrapper (keeps the original name/contract for callers and tests that only need count).
function Get-NewLeakCount([string]$transcriptPath, [string]$stateFile, [bool]$firstSightSilent = $true) {
  return (Get-RegionAnalysis $transcriptPath $stateFile $firstSightSilent).Count
}

# Append one JSON line to the global log, serialized across concurrent pool sessions via a named mutex.
function Write-LogLine([string]$logPath, [string]$json) {
  $mtx = New-Object System.Threading.Mutex($false, 'Global\claude-malformed-log')
  $got = $false
  try { $got = $mtx.WaitOne(2000) }
  catch [System.Threading.AbandonedMutexException] { $got = $true }
  catch { $got = $false }
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($logPath, $json + "`n", $enc)
  } catch { }
  finally { if ($got) { try { $mtx.ReleaseMutex() } catch { } }; $mtx.Dispose() }
}

if ($SelfTest) {
  $tmp = Join-Path $env:TEMP ('malftest-' + [guid]::NewGuid().ToString('N'))
  [void][System.IO.Directory]::CreateDirectory($tmp)
  $u8 = New-Object System.Text.UTF8Encoding($false)
  $fail = 0
  function Chk($c,$l){ if($c){Write-Host ('  PASS  ' + $l) -ForegroundColor Green}else{Write-Host ('  FAIL  ' + $l) -ForegroundColor Red; $script:fail++} }
  function MkFile($name,$text){ $p = Join-Path $tmp $name; [System.IO.File]::WriteAllText($p, $text, $u8); return $p }

  $markerLine = 'Your tool call was malformed and could not be parsed. Please retry.'
  $withMarker = 'x' + "`n" + $markerLine + "`n"
  $clean      = 'line1' + "`n" + 'line2' + "`n"

  # --- original count/dedup contract (unchanged) ---
  $t1 = MkFile 't1.jsonl' $withMarker
  $s1 = Join-Path $tmp 's1.txt'
  Chk ((Get-NewLeakCount $t1 $s1 $true) -eq 0) 'T1 first-sight silent (no notify on history)'
  Chk (Test-Path -LiteralPath $s1)             'T1 state file created'

  $s2 = Join-Path $tmp 's2.txt'; Set-Content -LiteralPath $s2 -Value 0 -Encoding ASCII
  Chk ((Get-NewLeakCount $t1 $s2 $true) -eq 1) 'T2 detects 1 new marker from offset 0'

  $t3 = MkFile 't3.jsonl' $clean
  $s3 = Join-Path $tmp 's3.txt'; Set-Content -LiteralPath $s3 -Value 0 -Encoding ASCII
  Chk ((Get-NewLeakCount $t3 $s3 $true) -eq 0) 'T3 clean transcript -> no false positive'

  $s4 = Join-Path $tmp 's4.txt'; Set-Content -LiteralPath $s4 -Value 0 -Encoding ASCII
  [void](Get-NewLeakCount $t1 $s4 $true)
  Chk ((Get-NewLeakCount $t1 $s4 $true) -eq 0) 'T4 dedup: same content not re-notified'

  $t5 = MkFile 't5.jsonl' $clean
  $s5 = Join-Path $tmp 's5.txt'; Set-Content -LiteralPath $s5 -Value 0 -Encoding ASCII
  [void](Get-NewLeakCount $t5 $s5 $true)
  [System.IO.File]::AppendAllText($t5, $MARKER + "`n", $u8)
  Chk ((Get-NewLeakCount $t5 $s5 $true) -eq 1) 'T5 growth: only newly-appended marker counts'

  $t6 = MkFile 't6.jsonl' ('a ' + $MARKER + ' b' + "`n" + $MARKER + "`n")
  $s6 = Join-Path $tmp 's6.txt'; Set-Content -LiteralPath $s6 -Value 0 -Encoding ASCII
  Chk ((Get-NewLeakCount $t6 $s6 $true) -eq 2) 'T6 counts multiple markers in new region'

  # --- new: recovery + snippet (mirrors real transcript shape) ---
  $leakText = '{"type":"text","text":"count\n<invoke name=\"Bash\">\n<parameter name=\"command\">powershell ...</parameter>"}'
  $recovered = $leakText + "`n" + $markerLine + "`n" + '{"type":"tool_use","id":"toolu_x","name":"Bash"}' + "`n"
  $t7 = MkFile 't7.jsonl' $recovered
  $s7 = Join-Path $tmp 's7.txt'; Set-Content -LiteralPath $s7 -Value 0 -Encoding ASCII
  $r7 = Get-RegionAnalysis $t7 $s7 $true
  Chk ($r7.Count -eq 1)                 'T7 recovery case: count=1'
  Chk ($r7.Recovered -eq $true)         'T7 recovered=true (tool_use after marker)'
  Chk ($r7.Snippet.Contains('<invoke')) 'T7 snippet captures the leaked <invoke'

  $stuck = '{"type":"text","text":"x<invoke name=\"Bash\">"}' + "`n" + $markerLine + "`n" + '{"type":"text","text":"still confused"}' + "`n"
  $t8 = MkFile 't8.jsonl' $stuck
  $s8 = Join-Path $tmp 's8.txt'; Set-Content -LiteralPath $s8 -Value 0 -Encoding ASCII
  $r8 = Get-RegionAnalysis $t8 $s8 $true
  Chk ($r8.Count -eq 1)          'T8 stuck case: count=1'
  Chk ($r8.Recovered -eq $false) 'T8 recovered=false (no tool_use / no end_turn after marker)'

  $endturn = '{"type":"text","text":"y<invoke name=\"Bash\">"}' + "`n" + $markerLine + "`n" + '{"role":"assistant","stop_reason":"end_turn"}' + "`n"
  $t9 = MkFile 't9.jsonl' $endturn
  $s9 = Join-Path $tmp 's9.txt'; Set-Content -LiteralPath $s9 -Value 0 -Encoding ASCII
  $r9 = Get-RegionAnalysis $t9 $s9 $true
  Chk ($r9.Recovered -eq $true) 'T9 recovered=true (clean end_turn after marker)'

  $noinvoke = 'garbage assistant text with no invoke tag but still failed to parse somehow here' + "`n" + $markerLine + "`n" + '{"type":"tool_use","name":"Bash"}' + "`n"
  $t10 = MkFile 't10.jsonl' $noinvoke
  $s10 = Join-Path $tmp 's10.txt'; Set-Content -LiteralPath $s10 -Value 0 -Encoding ASCII
  $r10 = Get-RegionAnalysis $t10 $s10 $true
  Chk ($r10.Snippet.Length -gt 0)          'T10 snippet fallback non-empty when no <invoke>'
  Chk (-not $r10.Snippet.Contains('<invoke')) 'T10 fallback snippet has no <invoke>'

  # --- new: log line write + JSON validity ---
  $tlog = Join-Path $tmp 'log.jsonl'
  $rec = [ordered]@{ ts='2026-07-13T00:00:00'; owner='tech-lead-div'; pool='D:\p\.bus'; session='sid'; count=1; recovered=$true; snippet=$r7.Snippet; transcript=$t7 }
  Write-LogLine $tlog ($rec | ConvertTo-Json -Compress -Depth 4)
  Write-LogLine $tlog ($rec | ConvertTo-Json -Compress -Depth 4)
  $logLines = Get-Content -LiteralPath $tlog
  Chk ($logLines.Count -eq 2) 'T11 log: two appends -> two lines'
  $ok = $true; foreach ($ll in $logLines) { try { [void]($ll | ConvertFrom-Json) } catch { $ok = $false } }
  Chk $ok                     'T11 log: each line is valid JSON'
  $parsed = $logLines[0] | ConvertFrom-Json
  Chk ($parsed.recovered -eq $true -and $parsed.owner -eq 'tech-lead-div') 'T11 log: fields round-trip'

  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host ''
  if ($fail -eq 0) { Write-Host 'SELFTEST ALL PASS' -ForegroundColor Green; exit 0 } else { Write-Host ("$fail FAILED") -ForegroundColor Red; exit 1 }
}

# ---- live ----
if (-not $env:POOL_BUS_ROOT -or -not $env:AGENT_OWNER) { exit 0 }   # pool agents only
$owner = $env:AGENT_OWNER
$in = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
$tp = ''; $sid = ''
if ($in) { try { $j = $in | ConvertFrom-Json; $tp = "$($j.transcript_path)"; $sid = "$($j.session_id)" } catch { } }
if (-not $tp) { exit 0 }
$watch = Join-Path $env:POOL_BUS_ROOT '.watch'
[void][System.IO.Directory]::CreateDirectory($watch)
$state = Join-Path $watch ('malformed-{0}.txt' -f $owner)
$a = Get-RegionAnalysis $tp $state $true
if ($a.Count -gt 0) {
  # durable record for later analysis (pilot observability)
  try {
    $rec = [ordered]@{
      ts         = (Get-Date).ToString('o')
      owner      = $owner
      pool       = "$env:POOL_BUS_ROOT"
      session    = $sid
      count      = $a.Count
      recovered  = [bool]$a.Recovered
      snippet    = $a.Snippet
      transcript = $tp
    }
    Write-LogLine $LOG ($rec | ConvertTo-Json -Compress -Depth 4)
  } catch { }
  # transient toast (text adapts: self-corrected = informational, stuck = action-needed)
  try {
    $recFlag = if ($a.Recovered) { '-Recovered' } else { '' }
    Start-Process powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Owner "{1}" -Count {2} {3}' -f $NOTIFY, $owner, $a.Count, $recFlag) | Out-Null
  } catch { }
}
exit 0
