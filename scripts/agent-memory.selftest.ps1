# agent-memory.selftest.ps1 - самопроверка модуля памяти ролей.
#   powershell -File agent-memory.selftest.ps1
# Гоняется на одноразовом каталоге в TEMP, ни один пул не затрагивается.
# Блок 7-8 проверяет ПЕРЕКЛЮЧАТЕЛЬ РАСКАТКИ: при выключенном ничего не меняется ни у кого.
# Unit checks for agent-memory.ps1 on a throwaway tree. No pool is touched.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'agent-memory.ps1')   # РЯДОМ С СОБОЙ, не абсолютом: копия обязана проверять КОПИЮ.
# Абсолютный путь давал ложное зелёное - прогон из песочницы молча проверял живой модуль (поймано на порте 04.08).

$env:AGENT_MEMORY = '1'   # roll-out switch on for the unit checks (off is covered in block 7)

$sandbox = Join-Path $env:TEMP ('agent-memory-test-' + (Get-Random))
$null = New-Item -ItemType Directory -Path $sandbox -Force
$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
  if ($cond) { $script:pass++; "  OK   $name" }
  else       { $script:fail++; "  FAIL $name $detail" }
}

'--- 1. empty owner = plain session, engine untouched'
$r = Get-AgentMemoryArgs -Owner '' -Cwd $sandbox -Quiet
Check 'returns empty array' ($r.Count -eq 0)
Check 'creates nothing on disk' (-not (Test-Path (Join-Path $sandbox '.memory')))

'--- 2. valid owner'
$r = Get-AgentMemoryArgs -Owner 'tech-lead' -Cwd $sandbox -Quiet
Check 'two args returned' ($r.Count -eq 2) "got $($r.Count)"
Check 'first arg is --settings' ($r[0] -eq '--settings')
$sf = $r[1]
Check 'settings file exists' (Test-Path $sf)
Check 'role dir exists' (Test-Path (Join-Path $sandbox '.memory\tech-lead'))
Check 'role dir has own git repo' (Test-Path (Join-Path $sandbox '.memory\tech-lead\.git'))
$j = Get-Content $sf -Raw | ConvertFrom-Json
Check 'json carries autoMemoryDirectory' ($null -ne $j.autoMemoryDirectory)
Check 'path is absolute' ([System.IO.Path]::IsPathRooted($j.autoMemoryDirectory))
Check 'path points at the role dir' ($j.autoMemoryDirectory -eq (Join-Path $sandbox '.memory\tech-lead'))
$bytes = [System.IO.File]::ReadAllBytes($sf)
Check 'settings file has no BOM' (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))
# Ловит уплощение вложенных объектов при сериализации: JSON остаётся валидным, хука в нём нет.
$hookCmd = $null
try { $hookCmd = $j.hooks.PreCompact[0].hooks[0].command } catch { $hookCmd = $null }
Check 'PreCompact audit hook survived serialization' ($hookCmd -like '*memory-audit.ps1*') "got '$hookCmd'"
Check 'hook carries this role and cwd' ($hookCmd -like "*-Owner `"tech-lead`"*" -and $hookCmd -like "*$sandbox*")

# Второй хук - впрыск памяти после сжатия. Лежит на уровень глубже (matcher + hooks), поэтому уплощение
# при сериализации бьёт по нему так же, как когда-то по PreCompact; проверяем и команду, и matcher.
$injCmd = $null; $injMatch = $null
try { $injCmd = $j.hooks.SessionStart[0].hooks[0].command; $injMatch = $j.hooks.SessionStart[0].matcher } catch { $injCmd = $null }
Check 'SessionStart inject hook survived serialization' ($injCmd -like '*memory-inject.ps1*') "got '$injCmd'"
Check 'inject hook carries this role and cwd' ($injCmd -like "*-Owner `"tech-lead`"*" -and $injCmd -like "*$sandbox*")
Check 'inject fires only after compaction' ($injMatch -eq 'compact') "got '$injMatch'"

'--- 3. second role of the SAME cwd gets a DIFFERENT store (the whole point)'
$r2 = Get-AgentMemoryArgs -Owner 'qa' -Cwd $sandbox -Quiet
$j2 = Get-Content $r2[1] -Raw | ConvertFrom-Json
Check 'different settings file' ($r2[1] -ne $sf)
Check 'different memory dir' ($j2.autoMemoryDirectory -ne $j.autoMemoryDirectory)
Check 'separate git repos' (Test-Path (Join-Path $sandbox '.memory\qa\.git'))

'--- 4. idempotent: re-launch must not duplicate or fail'
$r3 = Get-AgentMemoryArgs -Owner 'tech-lead' -Cwd $sandbox -Quiet
Check 'same settings path' ($r3[1] -eq $sf)
Check 'role dirs still 2' ((Get-ChildItem (Join-Path $sandbox '.memory') -Directory | Where-Object Name -ne '.settings').Count -eq 2)

'--- 5. bad owner names are refused loudly, never silently shared'
foreach ($bad in @('two words', 'a/b', 'a\b', '..', 'a*b')) {
  $threw = $false
  try { $null = Get-AgentMemoryArgs -Owner $bad -Cwd $sandbox -Quiet } catch { $threw = $true }
  Check "refuses '$bad'" $threw
}

'--- 6. unwritable target fails loudly (no silent fallback)'
$threw = $false
try { $null = Get-AgentMemoryArgs -Owner 'x' -Cwd 'Q:\no-such-drive' -Quiet } catch { $threw = $true }
Check 'refuses unwritable cwd' $threw

'--- 7. roll-out switch OFF: nothing changes for anybody'
# The workspace-wide flag now EXISTS on disk (roll-out happened), so the OFF branch cannot be reached
# by clearing the env var alone — this block went red on correct code until the flag path became
# overridable. We point it at a non-existent path instead of deleting the live flag, and restore it.
$savedFlag = $script:AgentMemoryGlobalFlag
$script:AgentMemoryGlobalFlag = 'Z:\no-such-rollout-flag-xyz-42'
$env:AGENT_MEMORY = ''
$sb2 = Join-Path $env:TEMP ('agent-memory-off-' + (Get-Random))
$null = New-Item -ItemType Directory -Path $sb2 -Force
$r = Get-AgentMemoryArgs -Owner 'tech-lead' -Cwd $sb2 -Quiet
Check 'still returns a settings file (the .bat launchers require one)' ($r.Count -eq 2)
Check 'settings file is the neutral {}' ((Get-Content $r[1] -Raw).Trim() -eq '{}')
Check 'no per-role store is created' (-not (Test-Path (Join-Path $sb2 '.memory\tech-lead')))
Check 'the live workspace flag alone turns it on' ((& { $script:AgentMemoryGlobalFlag = $savedFlag; Test-AgentMemoryEnabled -Cwd $sb2 }))
$script:AgentMemoryGlobalFlag = $savedFlag

'--- 8. per-project switch turns it on for that project only'
$null = New-Item -ItemType File -Path (Join-Path $sb2 '.memory\.enabled') -Force
$r = Get-AgentMemoryArgs -Owner 'tech-lead' -Cwd $sb2 -Quiet
$j = Get-Content $r[1] -Raw | ConvertFrom-Json
Check 'project switch enables the private store' ($j.autoMemoryDirectory -eq (Join-Path $sb2 '.memory\tech-lead'))

'--- 9. Get-AgentMemoryStats: метрики для бордов, строго read-only'
$roleDir = Join-Path $sandbox '.memory\tech-lead'
$st = Get-AgentMemoryStats -RoleDir $roleDir
Check 'store seen as existing' ($st.Exists)
Check 'no MEMORY.md yet -> HasIndex false' (-not $st.HasIndex)
Check 'no index -> percent stays 0' ($st.Pct -eq 0)
[System.IO.File]::WriteAllText((Join-Path $roleDir 'MEMORY.md'), ("- [a](a.md) - x`r`n" * 20))
[System.IO.File]::WriteAllText((Join-Path $roleDir 'a.md'), 'body')
$st = Get-AgentMemoryStats -RoleDir $roleDir
Check 'index detected' ($st.HasIndex)
Check 'entries counted without the index itself' ($st.Entries -eq 1) "got $($st.Entries)"
Check 'binding ceiling named' ($st.Bound -eq 'lines' -or $st.Bound -eq 'bytes')
Check 'last write filled' ($null -ne $st.LastWrite)
$st = Get-AgentMemoryStats -RoleDir (Join-Path $sandbox '.memory\nobody')
Check 'missing store: Exists=false, no throw' (-not $st.Exists)
Check 'stats create nothing on disk' (-not (Test-Path (Join-Path $sandbox '.memory\nobody')))

'--- 10. маркер cwd на шине: борд обязан читать, а не угадывать'

# Шина живёт В СТОРОНЕ от $sandbox намеренно: у $sandbox уже есть .memory (блок 2), и запасной путь
# «родитель шины, если рядом видно .memory» честно сработал бы - первый прогон этого теста поймал
# ровно это. Проверять надо оба пути по отдельности.
$busHome = Join-Path $env:TEMP ('agent-memory-bus-' + (Get-Random))
$bus = Join-Path $busHome '.bus'
$null = New-Item -ItemType Directory -Path $bus -Force
Check 'no marker and no .memory next to bus -> null' ($null -eq (Resolve-AgentMemoryCwdForBus -BusRoot $bus))
$null = New-Item -ItemType Directory -Path (Join-Path $busHome '.memory') -Force
Check 'fallback works when .memory is visible next to the bus' ((Resolve-AgentMemoryCwdForBus -BusRoot $bus) -eq $busHome)
Remove-Item (Join-Path $busHome '.memory') -Recurse -Force
Check 'marker written' (Register-AgentMemoryBusCwd -Cwd $sandbox -BusRoot $bus)
Check 'marker resolves back to the launch cwd' ((Resolve-AgentMemoryCwdForBus -BusRoot $bus) -eq $sandbox)
Check 'marker lives under a dot dir (never becomes a board row)' (Test-Path (Join-Path $bus '.control\cwd'))
Check 'missing bus is not an error' (-not (Register-AgentMemoryBusCwd -Cwd $sandbox -BusRoot (Join-Path $sandbox 'no-such-bus')))
Check 'empty bus root is not an error' (-not (Register-AgentMemoryBusCwd -Cwd $sandbox -BusRoot ''))
[System.IO.File]::WriteAllText((Join-Path $bus '.control\cwd'), 'Q:\gone')
Check 'stale marker is ignored, not trusted' ($null -eq (Resolve-AgentMemoryCwdForBus -BusRoot $bus))

Remove-Item $sandbox, $sb2, $busHome -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS=$pass FAIL=$fail"
# Ненулевой код при провале: без него автогейт по exit code рапортует «прошло» даже при FAIL=5.
# Замерено на неполной копии pool-bus: пять красных проверок и exit 0.
if ($fail -gt 0) { exit 1 }

