# agent-memory.ps1 - ONE copy for the whole workspace (same model as pool.ps1 / remote-bridge).
#
# WHAT IT DOES
#   Claude Code keeps auto-memory in ~/.claude/projects/<sanitized-cwd>/memory/ and always
#   injects MEMORY.md from there. The path is derived from cwd, so every role of a pool
#   (they share one cwd) writes into ONE pile. This module gives each role its own store:
#
#       <cwd>\.memory\<owner>\          bodies + MEMORY.md index, plus a local git repo
#       <cwd>\.memory\.settings\<owner>.json   settings file handed to `claude --settings`
#
# CONTRACT
#   Get-AgentMemoryArgs [-Owner <name>] [-Cwd <path>] [-Quiet]
#     -> @('--settings', '<file>')   owner set   : role-private memory
#     -> @()                         owner empty : plain session, engine default (contract of
#                                                  <umbrella>\scripts\launch-claude.ps1 - do not break it)
#     -> throws                      owner set but unusable, or directory cannot be created
#
# WHY A SETTINGS FILE AND NOT A JSON STRING
#   PowerShell 5.1 strips inner quotes when passing an argument to a native exe. Measured
#   2026-07-31: --settings '{"autoMemoryDirectory":"..."}' arrives as {autoMemoryDirectory:...}.
#   The engine discards an invalid path SILENTLY and falls back to the shared default, so the
#   failure would be invisible. A file path survives any quoting.
#
# WHY cwd AND NOT THE MANIFEST'S PROJECT ROOT
#   cwd is exactly what the engine itself uses to derive the default store, so this stays a
#   split of the existing location rather than a move to a new one. Split pools (<monorepo>)
#   therefore keep memory next to the cwd their wrappers actually set.

# NB: deliberately no Set-StrictMode here. This file is dot-sourced INTO the pool launchers,
# and strict mode would then apply to their code too (e.g. `exit $LASTEXITCODE` before any
# native call would start throwing). A module must not change its host's rules.

function Test-AgentOwnerName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Owner)
    if ([string]::IsNullOrWhiteSpace($Owner)) { return $false }
    # Owner becomes a directory name and a settings file name: no path separators, no wildcards,
    # no spaces (they would also break every downstream -Owner argument). The first character must
    # not be a dot - otherwise '..' would resolve .memory\.. back to the project root itself, which
    # .gitignore does NOT cover. Caught by the unit checks, not by review.
    return ($Owner -match '^[A-Za-z0-9_][A-Za-z0-9._-]*$')
}

function Get-AgentMemoryPaths {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [string]$Cwd = (Get-Location).Path
    )
    $root = Join-Path $Cwd '.memory'
    [PSCustomObject]@{
        Root         = $root
        RoleDir      = Join-Path $root $Owner
        SettingsDir  = Join-Path $root '.settings'
        SettingsFile = Join-Path (Join-Path $root '.settings') "$Owner.json"
    }
}

function Initialize-AgentMemoryRepo {
    param([Parameter(Mandatory)][string]$RoleDir)
    # One local repo per role, inside the role's own folder: history of memory edits without any
    # chance of reaching the project repo or a remote. Per-role (not per-pool) because seven roles
    # committing into one index would collide. Never fatal - memory works without history.
    if (Test-Path (Join-Path $RoleDir '.git')) { return $true }
    try {
        $null = & git -C $RoleDir init -q 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Path of the workspace-wide switch, in a variable so a self-test can point it at a path that does not
# exist and still exercise the OFF branch. Once the switch is actually created, the OFF branch becomes
# untestable on this machine — and a permanently red test is worse than no test: the next person either
# learns to ignore red or "fixes" working code. Do NOT delete the real flag to test; override this.
# Флаг лежит РЯДОМ С ЭТИМ ФАЙЛОМ, а не по абсолютному пути. На Windows значение то же самое (модуль и
# флаг оба в pool-bus), но зашитый D:\... на сервере не существует - и ветка «не раскатано» срабатывала
# молча: роль получала пустой settings, то есть стартовала БЕЗ своей памяти и БЕЗ хуков сжатия, и
# заметить это можно было только по пустому файлу настроек. Поймано сухим прогоном подъёма роли на Linux.
# ⚠️ Фолбэк не косметика: $PSScriptRoot ПУСТ, когда тело файла исполняется без файловой идентичности
# (например, Invoke-Expression над содержимым или пересозданная в другом рансспейсе функция), а
# Join-Path с пустым Path БРОСАЕТ - и падал бы сам дот-сорс, то есть роль вообще не стартовала бы.
# Строка выполняется на верхнем уровне, вне try. Зашитая константа так упасть не могла.
$script:AgentMemoryGlobalFlag = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'agent-memory.enabled' }
                               else { '<workspace-root>\.launcher\pool-bus\agent-memory.enabled' }

function Test-AgentMemoryEnabled {
    param([string]$Cwd = (Get-Location).Path)
    # Roll-out switch. The launchers are patched, but nothing changes until one of these exists:
    #   <каталог этого модуля>\agent-memory.enabled             - весь воркспейс (на рабочей машине это
    #                                                             <workspace-root>\.launcher\pool-bus\)
    #   ⚠️ флаг лежит РЯДОМ С МОДУЛЕМ: копируя pool-bus в другое пространство, копировать и его,
    #      иначе роли там тихо стартуют с общей памятью и без хуков сжатия
    #   <cwd>\.memory\.enabled                                  - this project only (pool by pool)
    #   $env:AGENT_MEMORY = '1'                                 - a single run (testing)
    # Reason it exists: switching a role to a private store before the migration procedure is ready
    # would hand it an EMPTY memory and hide the old one. Flipping the switch is the owner's step.
    if ($env:AGENT_MEMORY -eq '1') { return $true }
    if (Test-Path $script:AgentMemoryGlobalFlag) { return $true }
    # Два Join-Path вместо одного с обратным слэшем внутри: на Linux '.memory\.enabled' - это ОДНО имя
    # файла с обратным слэшем в середине, а не файл в подкаталоге, и популовый флаг там не сработал бы.
    if (Test-Path (Join-Path (Join-Path $Cwd '.memory') '.enabled')) { return $true }
    return $false
}

function Register-AgentMemoryBusCwd {
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [string]$BusRoot = $env:POOL_BUS_ROOT
    )
    # Leave a pointer to the role's launch-cwd on its bus.
    #
    # WHY: the task board (pool.ps1) knows ONLY the bus path, while the memory store is derived from
    # the cwd the wrapper sets with `cd /d`. For split pools these are DIFFERENT directories - the
    # <sub-1> / auditors / agentic buses live in <monorepo>\01_projects\<project>\.bus while
    # their cwd is <workspace-root>\<monorepo>; search / team buses live under <umbrella>\<project>
    # while their cwd is <workspace-root>\<umbrella>. Deriving cwd from the bus path would miss the
    # store for 5 pools out of 17 (21 roles) - and miss it SILENTLY, which is the exact failure class
    # this module is built to avoid. Here both values are known for certain, so we record it once at
    # launch and the board reads it back instead of guessing.
    #
    # Never fatal: without the marker the board simply says nothing about memory.
    if ([string]::IsNullOrWhiteSpace($BusRoot)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $BusRoot)) { return $false }
        $ctl = Join-Path $BusRoot '.control'
        if (-not (Test-Path -LiteralPath $ctl)) { $null = New-Item -ItemType Directory -Path $ctl -Force -ErrorAction Stop }
        # All roles of one pool write the same path, so a concurrent write is harmless; a locked
        # file just means the marker keeps the value the previous role wrote.
        [System.IO.File]::WriteAllText((Join-Path $ctl 'cwd'), $Cwd, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Resolve-AgentMemoryCwdForBus {
    param([Parameter(Mandatory)][string]$BusRoot)
    # The reverse lookup, for readers that only have a bus path (the board).
    # Order matters: what a role recorded at launch first, a guess second - and the guess only when
    # it is visible on disk. Silence beats a wrong answer here: a miss would report "no memory" for a
    # role whose memory is fine.
    try {
        $marker = Join-Path (Join-Path $BusRoot '.control') 'cwd'
        if (Test-Path -LiteralPath $marker) {
            $p = ([System.IO.File]::ReadAllText($marker)).Trim()
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    } catch { }
    try {
        $parent = Split-Path $BusRoot -Parent
        if ($parent -and (Test-Path -LiteralPath (Join-Path $parent '.memory'))) { return $parent }
    } catch { }
    return $null
}

function Get-AgentMemoryStats {
    param([Parameter(Mandatory)][string]$RoleDir)
    # Read-only, and cheap on purpose: measured 1.2 ms over the largest real store (85 entries) with
    # DirectoryInfo.GetFiles. The board redraws every few seconds, so no external processes and no
    # reading of bodies. Deliberately NO cache: it would make the memory columns older than their
    # neighbours in the same row while saving a fraction of the redraw interval.
    #
    # HasIndex is separate from Entries because "store without MEMORY.md" is the dangerous state and a
    # percentage cannot express it: nothing written there reaches the context automatically.
    $s = [PSCustomObject]@{
        Exists = $false; HasIndex = $false; Entries = 0
        IndexLines = 0; IndexBytes = 0; Pct = 0; Bound = ''; Unknown = $false; LastWrite = $null
    }
    try {
        $di = New-Object System.IO.DirectoryInfo($RoleDir)
        if (-not $di.Exists) { return $s }
        $s.Exists = $true
        $files = @($di.GetFiles('*.md'))
        $s.Entries = @($files | Where-Object { $_.Name -ne 'MEMORY.md' }).Count
        # LastWrite is computed BEFORE the index is read, and deliberately so: reading MEMORY.md can
        # fail on a sharing violation exactly when the engine rewrites it, and that is the moment the
        # shutdown controller samples "did this role write anything". Order it the other way and an
        # unrelated read failure erases the timestamp, turning a successful write into a false alarm.
        $last = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($last) { $s.LastWrite = $last.LastWriteTime }
        $idx = $files | Where-Object { $_.Name -eq 'MEMORY.md' } | Select-Object -First 1
        if ($idx) {
            $s.HasIndex = $true
            $t = [System.IO.File]::ReadAllText($idx.FullName)
            # Engine ceiling: 200 lines OR 25000 bytes, whichever comes first. Report the binding one,
            # otherwise "90 lines, 86%" reads as a contradiction (measured on the launcher store).
            $s.IndexLines = @($t -split "`r?`n").Count
            $s.IndexBytes = [System.Text.Encoding]::UTF8.GetByteCount($t)
            $pl = [math]::Round(100 * $s.IndexLines / 200)
            $pb = [math]::Round(100 * $s.IndexBytes / 25000)
            if ($pl -ge $pb) { $s.Pct = $pl; $s.Bound = 'lines' } else { $s.Pct = $pb; $s.Bound = 'bytes' }
        }
    } catch {
        # The engine rewrites MEMORY.md and the PreCompact audit runs git in the same directory, so a
        # sharing violation is a normal outcome: "no data this pass", not an error.
        $s.Unknown = $true
    }
    return $s
}

function New-AgentMemoryNeutralSettings {
    # An empty settings object: valid JSON, overrides nothing, memory stays wherever it is today.
    param([Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][string]$Cwd)
    if (-not (Test-AgentOwnerName -Owner $Owner)) { return @() }
    $p = Get-AgentMemoryPaths -Owner $Owner -Cwd $Cwd
    try {
        if (-not (Test-Path $p.SettingsDir)) { $null = New-Item -ItemType Directory -Path $p.SettingsDir -Force -ErrorAction Stop }
        [System.IO.File]::WriteAllText($p.SettingsFile, '{}', (New-Object System.Text.UTF8Encoding($false)))
        return @('--settings', $p.SettingsFile)
    } catch {
        return @()   # cannot write - fall back to not passing the flag at all
    }
}

function Get-AgentMemoryArgs {
    param(
        [string]$Owner = $env:AGENT_OWNER,
        [string]$Cwd = (Get-Location).Path,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($Owner)) { return @() }   # plain session - leave the engine alone

    # Record cwd on the bus for readers that only know the bus path. Done before the roll-out check on
    # purpose: the board must be able to say "not rolled out here" instead of staying blind.
    $null = Register-AgentMemoryBusCwd -Cwd $Cwd

    if (-not (Test-AgentMemoryEnabled -Cwd $Cwd)) {
        # Not rolled out here yet. Callers that always pass --settings (the .bat launchers) still need
        # a valid file - a MISSING one makes claude refuse to start - so hand them an empty override.
        return (New-AgentMemoryNeutralSettings -Owner $Owner -Cwd $Cwd)
    }

    if (-not (Test-AgentOwnerName -Owner $Owner)) {
        throw "[agent-memory] AGENT_OWNER '$Owner' is not usable as a directory name (allowed: letters, digits, . _ -). Refusing to start: the engine would silently fall back to shared memory."
    }

    if (-not (Test-Path -LiteralPath $Cwd)) {
        throw "[agent-memory] working directory '$Cwd' does not exist - refusing to start with shared memory."
    }

    $p = Get-AgentMemoryPaths -Owner $Owner -Cwd $Cwd

    # Defence in depth: whatever the name did, the store must stay under <cwd>\.memory\.
    $expected = [System.IO.Path]::GetFullPath((Join-Path $Cwd '.memory')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not ([System.IO.Path]::GetFullPath($p.RoleDir) + [System.IO.Path]::DirectorySeparatorChar).StartsWith($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[agent-memory] resolved store '$($p.RoleDir)' escapes '$expected' - refusing."
    }

    foreach ($d in @($p.Root, $p.RoleDir, $p.SettingsDir)) {
        if (-not (Test-Path $d)) {
            try { $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop }
            catch { throw "[agent-memory] cannot create '$d': $($_.Exception.Message). Refusing to start with shared memory." }
        }
    }

    # Rewritten on every launch: the file is derived state, never hand-edited.
    #
    # The PreCompact hook runs the same audit as `pool ready`: commit the memory, then report structure.
    # It is here rather than in the prompt because compaction can happen with nobody watching (the
    # shutdown controller compacts headless), and an instruction nobody reads protects nothing.
    # Measured 2026-07-31: PreCompact does fire on our headless compact, and hooks from --settings ADD
    # to the pool's own hooks instead of replacing them - so this cannot switch the bus hooks off.
    # Interpreter and script path are BOTH resolved, not hardcoded: the same file has to write a working
    # hook line under Windows PowerShell 5.1 and under pwsh 7 on Linux (pools are moving to a server).
    # -ExecutionPolicy exists only on Windows; $IsWindows exists only in PS 6+ ($null under 5.1 = Windows).
    # $PSScriptRoot is safe here even though this file is dot-sourced into the launchers: verified on 5.1
    # that inside a dot-sourced file's function it still resolves to THIS file's directory, not the host's.
    # On Windows both strings come out byte-for-byte as the hardcoded ones did.
    # Get-Variable, not a direct $IsWindows: this file is dot-sourced into launchers whose strict-mode setting
    # is not ours to assume, and under Set-StrictMode naming an undefined variable throws. Absent = 5.1 = Windows.
    $onWin  = $true
    try { $v = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($v) { $onWin = [bool]$v.Value } } catch { }
    $psExe  = if ($onWin) { 'powershell' } else { try { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { 'pwsh' } }
    $psFlag = if ($onWin) { '-NoProfile -ExecutionPolicy Bypass' } else { '-NoProfile' }
    $auditCmd = ('{0} {1} -File ' -f $psExe, $psFlag) +
                ('"{0}" ' -f (Join-Path $PSScriptRoot 'memory-audit.ps1')) +
                ('-Owner "{0}" -Cwd "{1}" -Reason precompact' -f $Owner, $Cwd)
    # SessionStart с matcher `compact` возвращает роли точку входа в память СРАЗУ ПОСЛЕ сжатия.
    # Почему именно так, а не инструкцией: сжатие уносит из контекста всё прочитанное, оглавление
    # движок вклеивает заново, но тела записей - нет, и роль в них не идёт: пересказ выглядит полным.
    # Замерено 04.08 на пробном стенде: stdout SessionStart ДОХОДИТ до модели (маркер процитирован),
    # а тело записи памяти в контекст не попадает. Matcher узкий намеренно: на startup/resume роль и
    # так получает стартовый промпт и `pool mine`, там впрыск был бы двойной оплатой.
    $injectCmd = ('{0} {1} -File ' -f $psExe, $psFlag) +
                 ('"{0}" ' -f (Join-Path $PSScriptRoot 'memory-inject.ps1')) +
                 ('-Owner "{0}" -Cwd "{1}"' -f $Owner, $Cwd)
    $payload = [ordered]@{
        autoMemoryDirectory = $p.RoleDir
        hooks = [ordered]@{
            PreCompact   = @( [ordered]@{ hooks = @( [ordered]@{ type = 'command'; command = $auditCmd } ) } )
            SessionStart = @( [ordered]@{ matcher = 'compact'; hooks = @( [ordered]@{ type = 'command'; command = $injectCmd } ) } )
        }
    }
    # -Depth обязателен: по умолчанию ConvertTo-Json уплощает всё глубже второго уровня и пишет вместо
    # вложенного объекта строку "System.Collections.Specialized.OrderedDictionary". JSON при этом
    # остаётся ВАЛИДНЫМ, движок его молча принимает - и хука просто нет. Поймано на себе 31.07.
    $json = ($payload | ConvertTo-Json -Compress -Depth 8)
    try {
        [System.IO.File]::WriteAllText($p.SettingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        throw "[agent-memory] cannot write '$($p.SettingsFile)': $($_.Exception.Message)"
    }

    # Read back what we just wrote. Measured 2026-07-31: a MALFORMED settings file is ignored
    # SILENTLY (session starts on the shared default), while a MISSING one refuses to start.
    # So the dangerous failure is a corrupt file, and only a read-back catches it.
    # Проверяем ВСЁ, ради чего писали, а не одно поле: первая версия сверяла только путь и пропустила
    # уплощённый хук - файл был валиден, роль стартовала, а страховки не было.
    try {
        $check = (Get-Content -LiteralPath $p.SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json)
        if ($check.autoMemoryDirectory -ne $p.RoleDir) { throw 'path mismatch after write' }
        $hookCmd = $null
        try { $hookCmd = $check.hooks.PreCompact[0].hooks[0].command } catch { $hookCmd = $null }
        if (-not $hookCmd -or $hookCmd -notlike '*memory-audit.ps1*') { throw 'PreCompact audit hook did not survive serialization' }
        # Тот же контроль для второго хука: уплощение бьёт по вложенности, а он лежит на уровень глубже
        # (matcher + hooks), то есть рискует ровно так же. Проверяем и matcher - без него хук стрелял бы
        # на каждом старте, а не только после сжатия.
        $injCmd = $null; $injMatch = $null
        try { $injCmd = $check.hooks.SessionStart[0].hooks[0].command; $injMatch = $check.hooks.SessionStart[0].matcher } catch { $injCmd = $null }
        if (-not $injCmd -or $injCmd -notlike '*memory-inject.ps1*') { throw 'SessionStart inject hook did not survive serialization' }
        if ($injMatch -ne 'compact') { throw 'SessionStart matcher did not survive serialization' }
    } catch {
        throw "[agent-memory] settings file '$($p.SettingsFile)' did not read back as valid JSON ($($_.Exception.Message)). Refusing to start: the engine would ignore it silently and use shared memory."
    }

    $null = Initialize-AgentMemoryRepo -RoleDir $p.RoleDir

    if (-not $Quiet) { Write-Host "[agent-memory] $Owner -> $($p.RoleDir)" }
    return @('--settings', $p.SettingsFile)
}
