# Sweep every role memory store in the workspace: structural check + two things the checker misses
#  - missing frontmatter (no description => the engine will never surface the record)
#  - identical bodies shared between roles of one pool (the "common pot was split by copying" smell)
# Writes a UTF-8 report; console output stays ASCII so PS 5.1 cannot mangle it.
param([string]$Out)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $env:TEMP 'memory-sweep-report.md' }
$out = $Out
$checker = 'C:\workspace-root\.launcher\pool-bus\memory-check.ps1'
$rep = New-Object System.Collections.Generic.List[string]

$stores = @(Get-ChildItem -Path 'C:\workspace-root' -Filter 'MEMORY.md' -File -Recurse -Depth 4 -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -like '*\.memory\*' } | Sort-Object DirectoryName)

$rep.Add('# Аудит хранилищ памяти ролей')
$rep.Add('')
$rep.Add(('Хранилищ найдено: {0}' -f $stores.Count))
$rep.Add('')

# --- per-store pass ---
$byPool = @{}
$noHead = New-Object System.Collections.Generic.List[string]
$issues = New-Object System.Collections.Generic.List[string]

foreach ($s in $stores) {
    $dir = $s.DirectoryName
    $role = Split-Path $dir -Leaf
    $poolPath = Split-Path (Split-Path $dir -Parent) -Parent
    $pool = Split-Path $poolPath -Leaf
    if (-not $byPool.ContainsKey($pool)) { $byPool[$pool] = New-Object System.Collections.Generic.List[object] }

    $bodies = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Where-Object { $_.Name -ne 'MEMORY.md' })
    $missing = 0
    $hashes = @{}
    foreach ($b in $bodies) {
        $txt = [IO.File]::ReadAllText($b.FullName, [Text.Encoding]::UTF8)
        if ($txt.TrimStart([char]0xFEFF) -notmatch '^\s*---\s*\r?\n') { $missing++ }
        # body without frontmatter for cross-role comparison
        $core = $txt -replace '(?s)^\s*\ufeff?---.*?\r?\n---\s*\r?\n', ''
        $core = ($core -replace '\s+', ' ').Trim()
        if ($core.Length -gt 200) {
            $md5 = [Security.Cryptography.MD5]::Create()
            $h = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($core))).Replace('-','')
            $hashes[$h] = $b.Name
        }
    }
    if ($missing -gt 0) { $noHead.Add(('{0}/{1}: без шапки {2} из {3}' -f $pool, $role, $missing, $bodies.Count)) }

    $idx = [IO.File]::ReadAllText($s.FullName, [Text.Encoding]::UTF8)
    $idxLines = @($idx -split '\r?\n' | Where-Object { $_.Trim() }).Count
    $byPool[$pool].Add([pscustomobject]@{ Role = $role; Dir = $dir; Count = $bodies.Count; IdxLines = $idxLines; IdxChars = $idx.Length; Hashes = $hashes })

    $res = & powershell -NoProfile -ExecutionPolicy Bypass -File $checker -Dir $dir 2>&1
    $txtRes = ($res | Out-String)
    if ($txtRes -notmatch 'структурных замечаний нет') {
        $lines = @($txtRes -split '\r?\n' | Where-Object { $_ -match '^\s*[-!*~]' -and $_ -notmatch 'слабая эвристика' })
        if ($lines.Count) { $issues.Add(('## {0}/{1}' -f $pool, $role)); foreach ($l in $lines) { $issues.Add($l.TrimEnd()) } }
    }
    Write-Host ('checked: ' + $pool + '/' + $role + '  (' + $bodies.Count + ')')
}

# --- cross-role duplicate bodies inside one pool ---
$rep.Add('## Копии между ролями одного пула (признак растаскивания общего котла)')
$rep.Add('')
$dupFound = $false
foreach ($pool in ($byPool.Keys | Sort-Object)) {
    $roles = $byPool[$pool]
    if ($roles.Count -lt 2) { continue }
    $seen = @{}
    foreach ($r in $roles) {
        foreach ($h in $r.Hashes.Keys) {
            if (-not $seen.ContainsKey($h)) { $seen[$h] = New-Object System.Collections.Generic.List[string] }
            $seen[$h].Add(($r.Role + ':' + $r.Hashes[$h]))
        }
    }
    $dups = @($seen.Keys | Where-Object { $seen[$_].Count -gt 1 })
    if ($dups.Count) {
        $dupFound = $true
        $rep.Add(('- **{0}**: одинаковых тел {1}' -f $pool, $dups.Count))
        foreach ($d in ($dups | Select-Object -First 5)) { $rep.Add(('    - ' + ($seen[$d] -join '  ==  '))) }
    }
}
if (-not $dupFound) { $rep.Add('Совпадающих тел между ролями НЕТ ни в одном пуле.') }
$rep.Add('')

$rep.Add('## Записи без шапки (движок не подложит: нет description)')
$rep.Add('')
if ($noHead.Count) { foreach ($n in $noHead) { $rep.Add('- ' + $n) } } else { $rep.Add('Таких нет.') }
$rep.Add('')

$rep.Add('## Потолок индекса (предел 200 строк / 25000 знаков)')
$rep.Add('')
foreach ($pool in ($byPool.Keys | Sort-Object)) {
    foreach ($r in $byPool[$pool]) {
        $pct = [math]::Round(100.0 * $r.IdxChars / 25000.0)
        if ($pct -ge 70 -or $r.IdxLines -ge 150) { $rep.Add(('- {0}/{1}: {2} строк / {3} знаков = {4}% потолка' -f $pool, $r.Role, $r.IdxLines, $r.IdxChars, $pct)) }
    }
}
$rep.Add('')

$rep.Add('## Структурные замечания проверялки')
$rep.Add('')
if ($issues.Count) { foreach ($i in $issues) { $rep.Add($i) } } else { $rep.Add('Замечаний нет ни у кого.') }
$rep.Add('')

$rep.Add('## Состав по пулам')
$rep.Add('')
foreach ($pool in ($byPool.Keys | Sort-Object)) {
    $roles = $byPool[$pool]
    $sum = ($roles | Measure-Object -Property Count -Sum).Sum
    $rep.Add(('- **{0}**: ролей {1}, записей {2} ({3})' -f $pool, $roles.Count, $sum, (($roles | ForEach-Object { $_.Role + ':' + $_.Count }) -join ', ')))
}

[IO.File]::WriteAllLines($out, [string[]]$rep, (New-Object Text.UTF8Encoding($false)))
Write-Host ('report written: ' + $out)
