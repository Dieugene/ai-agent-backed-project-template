#requires -version 5
<#
  Pool Launcher (prototype) — терминальный пикер пулов поверх pool.manifest.json.
  Поток: выбрать пул (fzf, сортировка по недавности) -> выбрать режим/роли ->
         сгенерировать разовый Warp tab-config (команды только в выбранных панелях) ->
         открыть Warp. Цикл. Синглтон. Esc — шаг назад по уровням (роли -> режим -> пулы -> выход).
         Доднятие в пустой панели — через Ctrl-Shift-R (Warp Workflows).

  Запуск:        powershell -NoProfile -ExecutionPolicy Bypass -File launch-pool.ps1
  Самопроверка:  ... -File launch-pool.ps1 -SelfTest   (без fzf и без Warp: дискаверинг + генерация TOML)
#>
[CmdletBinding()]
param(
  [string[]]$Roots = @('C:\workspace-root'),
  [switch]$SelfTest,
  [switch]$NoSingleton
)

$ErrorActionPreference = 'Stop'

# --- UTF-8 в консоли: нужно и для пайпа в fzf, и для кириллицы ---
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
} catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
# Общая библиотека манифеста (Resolve-PoolBus / Resolve-PoolCwd / аудит). Шину НЕЛЬЗЯ выводить как
# `root\.bus`: у пулов внутри монорепо root — каталог батников, а шина в другом месте (баг 2026-07-27).
. (Join-Path $PSScriptRoot 'pool-manifest.ps1')

# Sostav pula - v samu shinu, ryadom s markerom cwd. Doska znaet tolko put k shine: manifest ey
# ne nayti (u chasti pulov on lezhit v DOCHERNEM kataloge otnositelno roditelya shiny), a podyom
# vverh po derevu odnazhdy podcepit CHUZHOY manifest i molcha obyavit zhivye roli gostyami. Fayl
# vnutri toy shiny, kotoruyu opisyvaet, chuzhim byt ne mozhet po postroeniyu. Pishem pri kazhdom
# obrashchenii k pulu, poetomu add-peer podhvatyvaetsya sam. Nikogda ne fatalno: net fayla -
# doska schitaet kak ranshe, vseh.
# VNIMANIE: PORYADOK strok v rospisi ne kosmetika - po pozicii roli statusnaya stroka beret
# cvet ee plashki (sm. statusline-command.sh). Perestavish roli v manifeste - perekrasish
# ves pul. Sortirovat rospis' po alfavitu NELZYA.
<# A REMOTE pool is one whose role wrappers ssh into a server. Detected from the wrapper itself,
   not from a manifest field: the field would have to be maintained by hand and would drift,
   whereas the ssh line IS the thing that makes the pool remote. #>
function Test-RemotePool($pool) {
    foreach ($r in @($pool.roles)) {
        if (-not $r.bat) { continue }
        $bat = Join-Path $pool.root $r.bat
        if (-not (Test-Path -LiteralPath $bat)) { continue }
        try { $txt = Get-Content -LiteralPath $bat -Raw -ErrorAction Stop } catch { continue }
        if ($txt -match '(?im)^[^\r\n]*\bssh\b') { return $true }
    }
    return $false
}

function Write-PoolRoster([object]$pool, [string]$busDir) {
  try {
    if (-not $pool -or -not $busDir -or -not (Test-Path -LiteralPath $busDir)) { return }
    $owners = @($pool.roles | ForEach-Object { $_.owner } | Where-Object { $_ })
    if ($owners.Count -eq 0) { return }
    $ctl = Join-Path $busDir '.control'
    if (-not (Test-Path -LiteralPath $ctl)) { $null = New-Item -ItemType Directory -Path $ctl -Force -ErrorAction Stop }
    $body = "# Roles of this pool. Written by the picker; the board tells guests apart by it. Derived file." + [char]10 + (($owners -join [string][char]10) + [string][char]10)
    [System.IO.File]::WriteAllText((Join-Path $ctl 'roster'), $body, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

$Fzf    = Join-Path $Here 'bin\fzf.exe'
$StateD = Join-Path $Here '.state'
$MruPath = Join-Path $StateD 'mru.json'
$PidF   = Join-Path $StateD 'owner.pid'
$TabCfg = Join-Path $env:APPDATA 'warp\Warp\data\tab_configs'

# ---------- генерация TOML (тестируется в -SelfTest, без fzf) ----------
function Build-Panes {
  param($node, $manifest, $selected, $focusOwner, [ref]$counter, $acc)
  $n = $counter.Value; $counter.Value = $counter.Value + 1
  $id = "p$n"
  if ($node.PSObject.Properties.Name -contains 'role') {
    $owner = $node.role
    $role  = $manifest.roles | Where-Object { $_.owner -eq $owner } | Select-Object -First 1
    $block = @('[[panes]]', ('id = "{0}"' -f $id), 'type = "terminal"', ("directory = '{0}'" -f $manifest.root))
    if (($selected -contains $owner) -and $role) {
      $bat = '{0}\{1}' -f $manifest.root, $role.bat
      $block += ("commands = ['cmd /c `"{0}`"']" -f $bat)
    } elseif ($role) {
      # Пустая (незапущенная) панель: одна строка-подсказка — как поднять эту роль
      # (Warp Workflow по Ctrl-Shift-R или прямой запуск .bat). ASCII — чтобы не ловить кодовую страницу cmd.
      $bat  = '{0}\{1}' -f $manifest.root, $role.bat
      $hint = 'cmd /c echo [{0}] empty pane -- launch: cmd /c "{1}"  or Warp Workflows Ctrl-Shift-R search {0}' -f $owner, $bat
      $block += ("commands = ['{0}']" -f $hint)
    }
    if ($owner -eq $focusOwner) { $block += 'is_focused = true' }
    [void]$acc.Add([pscustomobject]@{ N = $n; Text = ($block -join "`r`n") })
  } else {
    $childIds = @()
    foreach ($c in $node.children) {
      $childIds += (Build-Panes -node $c -manifest $manifest -selected $selected -focusOwner $focusOwner -counter $counter -acc $acc)
    }
    $kids  = ($childIds | ForEach-Object { '"{0}"' -f $_ }) -join ', '
    $block = @('[[panes]]', ('id = "{0}"' -f $id), ('split = "{0}"' -f $node.split), ('children = [{0}]' -f $kids))
    [void]$acc.Add([pscustomobject]@{ N = $n; Text = ($block -join "`r`n") })
  }
  return $id
}

# Auto-layout when a manifest has no explicit `layout`: lead first, pack roles into columns of <=2 panes,
# columns laid out left-to-right (respects "max 2 vertical, grow right"). Returns a node tree like manifest.layout.
function Build-AutoLayout($roles) {
  $ordered = @(@($roles | Where-Object { $_.lead }) + @($roles | Where-Object { -not $_.lead }))
  $leaves  = @($ordered | ForEach-Object { [pscustomobject]@{ role = $_.owner } })
  $cols = @()
  for ($i = 0; $i -lt $leaves.Count; $i += 2) {
    if ($i + 1 -lt $leaves.Count) {
      $cols += ,([pscustomobject]@{ split = 'vertical'; children = @($leaves[$i], $leaves[$i + 1]) })
    } else {
      $cols += ,($leaves[$i])
    }
  }
  # Вершина — ПЕРВАЯ КОЛОНКА, а не первый лист: при ровно двух ролях колонка собиралась и тут же
  # выбрасывалась, окно открывалось с одной панелью (баг 2026-08-03: <organizer-pool>, <pool-f>,
  # <pool-e>). Хуже того, при выборе одной НЕ-ведущей роли не стартовало вообще ничего.
  # При одной роли $cols[0] — тот же самый лист, поведение не меняется.
  if ($cols.Count -le 1) { return $cols[0] }
  return [pscustomobject]@{ split = 'horizontal'; children = $cols }
}

function New-PoolToml {
  param($m, $selected)
  $counter = 0
  $acc = New-Object System.Collections.ArrayList
  $focus = if ($selected -contains $m.lead) { $m.lead } else { @($selected)[0] }
  $layout = if (($m.PSObject.Properties.Name -contains 'layout') -and $m.layout) { $m.layout } else { Build-AutoLayout $m.roles }
  [void](Build-Panes -node $layout -manifest $m -selected $selected -focusOwner $focus -counter ([ref]$counter) -acc $acc)
  $head = @('# Auto-generated by Pool Launcher (prototype). Do not edit by hand.',
            ('name  = "{0}"' -f $m.title),
            ('title = "{0}"' -f $m.slug))
  if ($m.color) { $head += ('color = "{0}"' -f $m.color) }
  $body = ($acc | Sort-Object N | ForEach-Object { $_.Text }) -join "`r`n`r`n"
  return ($head -join "`r`n") + "`r`n`r`n" + $body + "`r`n"
}

# ---------- дискаверинг манифестов (рекурсивно до глубины 3; тяжёлые/служебные папки мимо) ----------
function Get-ManifestsUnder($dir, $depth, $acc) {
  $mf = Join-Path $dir 'pool.manifest.json'
  if (Test-Path $mf) { [void]$acc.Add($mf) }
  if ($depth -le 0) { return }
  Get-ChildItem -Path $dir -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(node_modules|\.git|\.bus|\.warp|\.state|\.inbox)$' } |
    ForEach-Object { Get-ManifestsUnder $_.FullName ($depth - 1) $acc }
}
function Find-Manifests {
  $acc = New-Object System.Collections.ArrayList
  foreach ($root in $Roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch '^(node_modules|\.git|\.bus|\.warp|\.state|\.inbox)$' } |
      ForEach-Object { Get-ManifestsUnder $_.FullName 3 $acc }
  }
  $acc | Select-Object -Unique
}

function Read-Json($path) { Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json }

# Control/meta сессии (Launcher, DevOps-оркестратор) — не проектные пулы: описаны централизованно в
# launcher-овском control.json (массив manifest-подобных объектов), чтобы не писать в чужие зоны (.devops и пр.).
function Get-ControlPools {
  $cf = Join-Path $Here 'control.json'
  if (-not (Test-Path $cf)) { return @() }
  try { $items = @((Get-Content -Raw -Encoding UTF8 $cf | ConvertFrom-Json)) } catch { return @() }
  # Помечаем ЗДЕСЬ, а не флагом в control.json: признак нельзя забыть проставить в файле.
  # Раньше control-записи отличали по пустому `root` — но root у них задан (<workspace-root>), поэтому
  # гарды `if (-not $pool.root)` были мертвы: [Борд] Launcher открывал пустое окно на <workspace-root>\.bus,
  # [Завершить] падало в throw «манифест пула 'launcher' не найден» (баг 2026-07-27).
  foreach ($i in $items) { Add-Member -InputObject $i -NotePropertyName control -NotePropertyValue $true -Force }
  return $items
}

<# Control-запись (Launcher / DevOps) — не пул: ни шины, ни контроллера гашения. #>
function Test-IsControlPool($pool) {
  if (-not $pool) { return $false }
  if ($pool.PSObject.Properties.Name -contains 'control') { return [bool]$pool.control }
  return (-not $pool.root)
}

function Load-Mru {
  if (Test-Path $MruPath) { try { return (Get-Content -Raw -Encoding UTF8 $MruPath | ConvertFrom-Json) } catch { return $null } }
  return $null
}
function Save-Mru($obj) { ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $MruPath -Encoding UTF8 }
function Mru-Time($mru, $slug) {
  if ($mru -and ($mru.PSObject.Properties.Name -contains $slug)) { try { return [datetime]$mru.$slug } catch { } }
  return [datetime]::MinValue
}

# ---------- fzf ----------
function Invoke-Fzf {
  param([string[]]$Items, [string]$Prompt, [string]$Header, [switch]$Multi)
  $a = @('--no-sort','--no-unicode','--layout=reverse','--height=70%','--border','--info=inline','--cycle',
         '--prompt', ($Prompt + ' '), '--header', $Header)
  if ($Multi) { $a += @('--multi','--marker=*') }
  $sel = $Items | & $Fzf @a
  return $sel
}

# ---------- self-test ----------
if ($SelfTest) {
  Write-Host "== SelfTest: дискаверинг ==" -ForegroundColor Cyan
  $paths = Find-Manifests
  $paths | ForEach-Object { Write-Host "  manifest: $_" }
  foreach ($p in $paths) {
    $m = Read-Json $p
    Write-Host "`n== $($m.slug) :: режим 'Ведущий' (только $($m.lead)) ==" -ForegroundColor Cyan
    Write-Host (New-PoolToml $m @($m.lead))
    Write-Host "== $($m.slug) :: режим 'Полный' (все $($m.roles.Count)) ==" -ForegroundColor Cyan
    Write-Host (New-PoolToml $m @($m.roles.owner))
  }
  Write-Host "`n== auto-layout demo (5 ролей без явного layout -> 3 колонки) ==" -ForegroundColor Cyan
  $demo = [pscustomobject]@{ slug='demo'; title='Demo'; project='auto'; root='D:\x'; color='cyan'; lead='r1';
    roles=@(
      [pscustomobject]@{owner='r1';title='R1';bat='r1.bat';lead=$true},
      [pscustomobject]@{owner='r2';title='R2';bat='r2.bat'},
      [pscustomobject]@{owner='r3';title='R3';bat='r3.bat'},
      [pscustomobject]@{owner='r4';title='R4';bat='r4.bat'},
      [pscustomobject]@{owner='r5';title='R5';bat='r5.bat'}) }
  Write-Host (New-PoolToml $demo @($demo.roles.owner))
  Write-Host ("== control.json: загружено записей = " + (@(Get-ControlPools).Count) + " ==") -ForegroundColor Cyan

  # Инвариант раскладки: сколько ролей — столько терминальных панелей, сколько выбрано — столько
  # реальных запусков (остальные панели несут строку-подсказку). Печати TOML для этого мало: она
  # ничего не утверждает, и потерянная панель прожила незамеченной при живом самотесте.
  Write-Host "`n== инвариант раскладки: панель на каждую роль ==" -ForegroundColor Cyan
  $layoutBad = 0
  $reTerm = '(?m)^type = "terminal"'
  $reRun  = '(?m)^commands = \[''cmd /c "'      # запуск батника; подсказка пустой панели идёт через `echo`
  foreach ($p in $paths) {
    $m = $null
    try { $m = Read-Json $p } catch { continue }
    $owners = @($m.roles.owner)
    # Число панелей от выбора не зависит — зависит только то, где команда, а где подсказка.
    $scen = New-Object System.Collections.ArrayList
    [void]$scen.Add($owners)                 # все роли
    [void]$scen.Add(@($m.lead))              # только ведущий
    [void]$scen.Add(@($owners[-1]))          # только последняя роль (у большинства пулов — не ведущий)
    foreach ($sel in $scen) {
      $toml = New-PoolToml $m $sel
      $term = ([regex]::Matches($toml, $reTerm)).Count
      $run  = ([regex]::Matches($toml, $reRun)).Count
      if ($term -ne $owners.Count -or $run -ne @($sel).Count) {
        $layoutBad++
        Write-Host ("  [FAIL] {0}: ролей={1}, панелей={2}, запусков={3} (ожидалось {4})" -f $m.slug, $owners.Count, $term, $run, @($sel).Count) -ForegroundColor Red
      }
    }
  }
  # Синтетика 1..9 пиннит и само правило укладки: не больше двух панелей по вертикали, колонки вправо.
  foreach ($k in 1..9) {
    $roles = @(1..$k | ForEach-Object { [pscustomobject]@{ owner = "r$_"; title = "R$_"; bat = "r$_.bat" } })
    $mk = [pscustomobject]@{ slug = "synth$k"; title = "S$k"; project = 'synthetic'; root = 'D:\x'; lead = 'r1'; roles = $roles }
    $toml = New-PoolToml $mk @($roles.owner)
    $term = ([regex]::Matches($toml, $reTerm)).Count
    $cols = ([regex]::Matches($toml, '(?m)^split = "vertical"')).Count
    if ($term -ne $k -or $cols -ne [math]::Floor($k / 2)) {
      $layoutBad++
      Write-Host ("  [FAIL] synth {0}: панелей={1}, колонок-по-два={2} (ожидалось {0} и {3})" -f $k, $term, $cols, [math]::Floor($k / 2)) -ForegroundColor Red
    }
  }
  if ($layoutBad) { Write-Host ("== нарушений раскладки: {0} ==" -f $layoutBad) -ForegroundColor Red }
  else { Write-Host "== раскладка: панель на каждую роль, нарушений нет ==" -ForegroundColor Green }

  # Аудит по ЖИВОМУ диску: манифест обязан сходиться с wrapper'ами. Источник истины о шине и cwd —
  # `set POOL_BUS_ROOT=` и `cd /d` в батнике (с ними реально стартует сессия), манифест лишь отражает их.
  # Именно расхождение этих двух картин дало баг 2026-07-27 (борд смотрел в несуществующий scripts\.bus).
  # Control-записи мимо: у них нет ни пула, ни шины.
  Write-Host "`n== аудит манифестов против wrapper'ов ==" -ForegroundColor Cyan
  $auditManifests = @()
  foreach ($p in $paths) { try { $auditManifests += (Read-Json $p) } catch { Write-Host "  [FAIL] нечитаемый манифест: $p" -ForegroundColor Red } }
  $badPools = Invoke-PoolManifestAudit $auditManifests
  if ($badPools) { Write-Host ("== пулов с расхождениями: {0} ==" -f $badPools) -ForegroundColor Red }
  else { Write-Host "== расхождений нет ==" -ForegroundColor Green }

  # Предохранитель от повторного запуска. Гоняем ЧИСТЫЕ функции на фикстурах: живые процессы меняются
  # посекундно, самотест на них начал бы «падать» оттого, что кто-то закрыл окно. Командные строки —
  # дословно с живой машины (03.08.2026), включая ненормализованный путь ведущей роли <organizer-pool>.
  Write-Host "`n== предохранитель: разбор командных строк и сопоставление ролей ==" -ForegroundColor Cyan
  $script:guardBad = 0
  function TGuard($name, $cond) {
    if (-not $cond) { $script:guardBad++; Write-Host ("  [FAIL] " + $name) -ForegroundColor Red }
  }
  # Чистка меток гашения перед подъёмом пула. Тест структурный: сам блок сидит в теле интерактивного
  # цикла и юнитом не вызывается, а сломать его можно двумя способами — убрать совсем либо переставить
  # ПОСЛЕ открытия окна, и тогда роль стартует ещё в карантине и молча не услышит шину.
  # ⚠️ Искомое СОБИРАЕТСЯ ИЗ КУСКОВ намеренно: цельный литерал тест нашёл бы сам в себе и был бы
  # зелёным всегда — поймано мутацией, которая не покраснела (второй случай этого класса за день).
  $lpSrc  = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8)
  # Ищем ВЫЗОВ, а не упоминание: имя метки встречается и в комментариях рядом, поэтому в якорь входит
  # сам параметр фильтра — иначе тест остаётся зелёным, когда чистка ищет уже не то (тоже поймано мутацией).
  $needle = "-Filter 'shutdown-" + "intent-*'"
  $iClear = $lpSrc.IndexOf($needle)
  $iOpen  = $lpSrc.IndexOf('warp://tab_config/{0}?new_window' + '=true')
  TGuard 'метки гашения чистятся при запуске пула' ($iClear -ge 0)
  TGuard 'чистка стоит ДО открытия окна пула' (($iClear -ge 0) -and ($iOpen -gt $iClear))
  TGuard 'чистятся только intent-метки, ready не трогаем' ($lpSrc.IndexOf('shutdown-' + 'ready-*') -lt 0)
  $clSubA  = '"C:\WINDOWS\system32\cmd.exe" /c C:\workspace-root\umbrella\sub-a\claude-devops-sub-a.bat'
  $clLead = '"C:\WINDOWS\system32\cmd.exe" /c C:\workspace-root\.launcher\scripts\..\..\launcher.bat'
  TGuard 'путь .bat вынимается, путь самого cmd.exe — нет' (@(Get-BatPathsFromCmdLine $clSubA).Count -eq 1)
  TGuard 'путь .bat совпадает дословно' ((Get-BatPathsFromCmdLine $clSubA)[0] -ieq 'C:\workspace-root\umbrella\sub-a\claude-devops-sub-a.bat')
  TGuard '`..\..` схлопывается (иначе ведущая роль organizer-pool невидима)' ((Get-BatPathsFromCmdLine $clLead)[0] -ieq 'C:\workspace-root\launcher.bat')
  TGuard 'путь в кавычках и с пробелом' ((Get-BatPathsFromCmdLine 'cmd.exe /c "D:\p q\x.bat"')[0] -ieq 'D:\p q\x.bat')
  TGuard 'нет .bat -> пусто' (@(Get-BatPathsFromCmdLine 'powershell -File D:\x.ps1').Count -eq 0)
  TGuard 'пустая строка -> пусто' (@(Get-BatPathsFromCmdLine '').Count -eq 0)

  $mA = [pscustomobject]@{ slug='a'; root='D:\a'; bus='D:\a\.bus'; roles=@([pscustomobject]@{ owner='lead'; bat='claude-lead.bat' }) }
  $mB = [pscustomobject]@{ slug='b'; root='D:\b'; bus='D:\b\.bus'; roles=@([pscustomobject]@{ owner='lead'; bat='claude-lead.bat' }) }
  $paneA = [pscustomobject]@{ Owner='lead'; Bat='D:\a\claude-lead.bat'; Bus='D:\a\.bus'; ProcId=1 }
  TGuard 'роль своего пула — жива' (Test-PoolRoleLive $mA $mA.roles[0] @($paneA))
  TGuard 'одноимённая роль ЧУЖОГО пула — не жива (разводит шина)' (-not (Test-PoolRoleLive $mB $mB.roles[0] @($paneA)))
  # fresh-session.ps1 поднимает ту же роль обёрткой claude-<owner>-2.bat и манифест НЕ правит:
  # сравнение имён файлов дало бы «не жива» и разрешило дубль. Ключ — AGENT_OWNER.
  $paneFresh = [pscustomobject]@{ Owner='lead'; Bat='D:\a\claude-lead-2.bat'; Bus='D:\a\.bus'; ProcId=2 }
  TGuard 'клон fresh-session той же роли — жива' (Test-PoolRoleLive $mA $mA.roles[0] @($paneFresh))
  # В одном каталоге живут claude-div-dev.bat и claude-div-dev-internal.bat (<monorepo>) —
  # похожие имена НЕ должны склеиваться, иначе роль молча не поднимется.
  $paneNear = [pscustomobject]@{ Owner='div-dev-internal'; Bat='D:\a\claude-div-dev-internal.bat'; Bus='D:\a\.bus'; ProcId=3 }
  $mDev = [pscustomobject]@{ slug='d'; root='D:\a'; bus='D:\a\.bus'; roles=@([pscustomobject]@{ owner='div-dev'; bat='claude-div-dev.bat' }) }
  TGuard 'сосед с похожим именем — не жива' (-not (Test-PoolRoleLive $mDev $mDev.roles[0] @($paneNear)))
  # Control-запись (DevOps): шины нет ни у пула, ни у обёртки — сопоставление по нормализованному пути.
  $mCtl  = [pscustomobject]@{ slug='c'; root='C:\workspace-root'; roles=@([pscustomobject]@{ owner='devops-orchestrator'; bat='devops-orchestrator-2.bat' }) }
  $paneC = [pscustomobject]@{ Owner='devops-orchestrator'; Bat='C:\workspace-root\devops-orchestrator-2.bat'; Bus=$null; ProcId=4 }
  TGuard 'control-запись без шины — жива по пути обёртки' (Test-PoolRoleLive $mCtl $mCtl.roles[0] @($paneC))
  # Битые данные не имеют права бросать: косметика не роняет инструмент.
  $mBad = [pscustomobject]@{ slug='x'; roles=@([pscustomobject]@{ owner='y' }) }
  TGuard 'роль без bat/root — false, без исключения' (-not (Test-PoolRoleLive $mBad $mBad.roles[0] @($paneA)))
  TGuard 'пустой список панелей — false' (-not (Test-PoolRoleLive $mA $mA.roles[0] @()))
  if ($script:guardBad) { Write-Host ("== предохранитель: провалов {0} ==" -f $script:guardBad) -ForegroundColor Red }
  else { Write-Host "== предохранитель: все проверки прошли ==" -ForegroundColor Green }
  return
}

# ---------- синглтон ----------
$created = $false
$mtx = New-Object System.Threading.Mutex($true, 'Global\PoolLauncherProto', [ref]$created)
if (-not $NoSingleton -and -not $created) {
  if (Test-Path $PidF) {
    $opid = (Get-Content $PidF -ErrorAction SilentlyContinue | Select-Object -First 1)
    $p = Get-Process -Id $opid -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne 0) {
      try {
        Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
'@ -ErrorAction SilentlyContinue
        [Native.Win]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
        [Native.Win]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
      } catch {}
    }
  }
  Write-Host "Pool Launcher уже запущен — окно выведено на передний план." -ForegroundColor Yellow
  Start-Sleep -Milliseconds 900
  exit 0
}
New-Item -ItemType Directory -Force -Path $StateD | Out-Null
Set-Content -Path $PidF -Value $PID -Encoding ASCII

# ---------- главный цикл (Esc = шаг назад по уровням) ----------
try {
  while ($true) {                                   # уровень ПУЛА
    $manifests = @()
    foreach ($p in (Find-Manifests)) { try { $m = Read-Json $p; $manifests += $m } catch {} }
    $manifests += (Get-ControlPools)
    if (-not $manifests) { Write-Host "Манифесты пулов не найдены под: $($Roots -join ', ')" -ForegroundColor Red; break }

    $mru = Load-Mru
    # Живость для списка — КОСМЕТИКА, один снимок на построение. В решении о запуске он не участвует:
    # пикер живёт минутами (открыл, отвлёкся, вернулся), и за это время роль успевает умереть или
    # подняться мимо пикера — гейт ниже берёт свой, свежий снимок.
    $liveSnap = $null
    try { $liveSnap = Get-LiveAgentPanes } catch { $liveSnap = $null }
    # обычные пулы — по недавности; архивные — отдельной группой внизу, с пометкой [архив]
    $normal = @($manifests | Where-Object { -not $_.archive } | Sort-Object @{ Expression = { Mru-Time $mru $_.slug }; Descending = $true }, @{ Expression = { $_.title } })
    $arch   = @($manifests | Where-Object { $_.archive } | Sort-Object @{ Expression = { $_.title } })
    $pools = @($normal) + @($arch)
    $map = [ordered]@{}
    foreach ($pl in $pools) {
      $when = Mru-Time $mru $pl.slug
      $pre  = if ($pl.archive) { '[архив] ' } else { '' }
      $tag  = if ($when -eq [datetime]::MinValue) { '' } else { '   (последний: ' + $when.ToString('dd.MM HH:mm') + ')' }
      # Метка только когда есть что показать: «живо 0/7» у всех давно погашенных — шум в строке,
      # где уже стоят [архив] и время последнего запуска. Счёт через @() — Where-Object при нуле
      # совпадений отдаёт $null, и `.Count` молча дал бы пустое место вместо цифры.
      $liveTag = ''
      if ($liveSnap -and $liveSnap.Ok) {
        try {
          $roles = @($pl.roles)
          $nLive = @($roles | Where-Object { Test-PoolRoleLive $pl $_ $liveSnap.Panes }).Count
          if ($nLive -gt 0) { $liveTag = ('   [живо {0}/{1}]' -f $nLive, $roles.Count) }
        } catch { $liveTag = '' }   # кривой манифест не имеет права ронять весь список
      }
      $map[($pre + ('{0}  —  {1}{2}{3}' -f $pl.title, $pl.project, $tag, $liveTag))] = $pl
    }
    $poolSel = Invoke-Fzf -Items ([string[]]$map.Keys) -Prompt 'Пул>' -Header 'Выбор пула  |  Enter — далее, Esc — выход'
    if (-not $poolSel) { break }                    # Esc на пуле -> выход из пикера
    $pool = $map[[string]$poolSel]

    while ($true) {                                 # уровень ДЕЙСТВИЯ (пульт: запустить / завершить / борд)
      $actItems = @(
        '[Запустить] — поднять сессии пула',
        '[Завершить] — handoff -> гашение -> compact (в отдельном окне)',
        '[Борд]      — открыть/поднять живую доску пула',
        '[Память]    — борд долговременной памяти ролей'
      )
      $actSel = Invoke-Fzf -Items $actItems -Prompt 'Действие>' -Header ('Пул: ' + $pool.title + '  |  Esc — назад к пулам')
      if (-not $actSel) { break }                   # Esc на действии -> назад к списку пулов

      # ----- [Борд]: открыть живую доску (idempotent board-window.ps1 по ЯВНОМУ пути шины) -----
      # Ветка «запустить board-<slug>.bat, если найдётся» СНЯТА намеренно: имена этих батников на диске
      # со слагом не совпадают (board-audit.bat, board-daily.bat, board-economic.bat), т.е. ветка была
      # лотереей, а её промах молча уводил на фолбэк `root\.bus` — исходный баг «борд открывается пустым».
      # Истина о шине теперь одна — Resolve-PoolBus; батники-обёртки её лишь дублировали.
      if ($actSel.StartsWith('[Борд')) {
        if (Test-IsControlPool $pool) { Write-Host 'Это control-сессия без пула — доски нет.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 900; continue }
        $busDir = Resolve-PoolBus $pool
        if (-not $busDir) { Write-Host ('У пула "{0}" в манифесте нет ни bus, ни root — доску открыть не из чего.' -f $pool.title) -ForegroundColor Red; Start-Sleep -Milliseconds 1500; continue }
        if (-not (Test-Path $busDir)) {
          # Пустое окно вместо доски — ровно тот симптом, с которого начался баг 2026-07-27. Молчать нельзя.
          Write-Host ('Шины нет на диске: {0}' -f $busDir) -ForegroundColor Red
          Write-Host 'Пул ещё ни разу не переписывался, либо в манифесте кривой путь (поле bus). Окно не открываю.' -ForegroundColor Yellow
          Start-Sleep -Milliseconds 2500
          continue
        }
        Write-PoolRoster $pool $busDir
        $bw = Join-Path (Split-Path $Here -Parent) 'pool-bus\board-window.ps1'
        Start-Process 'powershell' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$bw,'-BusRoot',$busDir)
        Write-Host ('Доска "{0}" открыта: {1}' -f $pool.title, $busDir) -ForegroundColor Green
        Start-Sleep -Milliseconds 700
        continue                                     # назад к выбору действия
      }

      # ----- [Память]: борд долговременной памяти ролей -----
      # Здесь это дёшево и правильно по построению: манифест уже загружен, значит cwd берётся из него
      # (Resolve-PoolCwd), а не выводится из пути шины - вывод из шины промахнулся бы у сплит-пулов
      # (<monorepo>, <umbrella>), где шина лежит в подпроекте, а cwd - в корне монорепо.
      if ($actSel.StartsWith('[Память')) {
        $mb = Join-Path (Split-Path $Here -Parent) 'pool-bus\memory-board.ps1'
        if (-not (Test-Path $mb)) { Write-Host ('Не найден: ' + $mb) -ForegroundColor Red; Start-Sleep -Milliseconds 1500; continue }
        Start-Process 'powershell' -ArgumentList @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',$mb,'-Pool',$pool.slug)
        Write-Host ('Борд памяти "{0}" открыт.' -f $pool.title) -ForegroundColor Green
        Start-Sleep -Milliseconds 700
        continue
      }

      $isShutdown = $actSel.StartsWith('[Завершить')
      if ($isShutdown -and (Test-IsControlPool $pool)) { Write-Host 'Control-сессия: завершение через контроллер не поддерживается.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 900; continue }
      $verb = if ($isShutdown) { 'Завершить' } else { 'Запустить' }

      while ($true) {                               # уровень РЕЖИМА (тот же пул + действие)
        $modeItems = @(
          ('[Полный]  — все роли ({0})' -f $pool.roles.Count),
          ('[Ведущий] — только {0}' -f $pool.lead),
          '[Выбрать вручную]'
        )
        $modeSel = Invoke-Fzf -Items $modeItems -Prompt 'Режим>' -Header ($verb + ' | Пул: ' + $pool.title + '  |  Esc — назад к действию')
        if (-not $modeSel) { break }                # Esc на режиме -> назад к выбору действия

        $selected = $null
        if ($modeSel.StartsWith('[Полный')) {
          $selected = @($pool.roles.owner)
        } elseif ($modeSel.StartsWith('[Ведущий')) {
          $selected = @($pool.lead)
        } else {
          $rmap = [ordered]@{}
          foreach ($r in $pool.roles) {
            $mark = if ($r.lead) { '  [лид]' } else { '' }
            $rmap[('{0}  ({1}){2}' -f $r.title, $r.owner, $mark)] = $r.owner
          }
          $rSel = Invoke-Fzf -Items ([string[]]$rmap.Keys) -Prompt 'Роли>' -Header ('TAB — отметить, Enter — ' + $verb + ', Esc — назад к режиму') -Multi
          if (-not $rSel) { continue }              # Esc на ролях -> назад к режиму
          $selected = @($rSel | ForEach-Object { $rmap[[string]$_] })
        }
        if (-not $selected) { continue }            # ничего не выбрано -> назад к режиму

        # ----- [Завершить]: контроллер в отдельном окне (killer pool-safe; -Only при подмножестве ролей) -----
        if ($isShutdown) {
          $allRoles = ($selected.Count -eq $pool.roles.Count)
          $scopeTxt = if ($allRoles) { 'ВЕСЬ пул' } else { ('роли: ' + ($selected -join ', ')) }
          $confSel = Invoke-Fzf -Items @(('[Да] завершить — ' + $scopeTxt), '[Отмена]') -Prompt 'Подтверди>' -Header ('Завершить «' + $pool.title + '»? ' + $scopeTxt)   # « » вместо " — вложенные " ломают передачу --header в fzf под PS5.1 (баг «unknown option» на title с пробелом, напр. «<SUB-A> Assistant»)
          if (-not $confSel -or $confSel.StartsWith('[Отмена')) { continue }
          $shPs1  = Join-Path (Split-Path $Here -Parent) 'pool-bus\pool-shutdown.ps1'
          $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',$shPs1,'-Pool',$pool.slug,'-Full','-CloseWindow')
          if (-not $allRoles) { $psArgs += @('-Only', ($selected -join ',')) }
          Start-Process 'powershell' -ArgumentList $psArgs
          Write-Host ('Завершение "{0}" запущено в отдельном окне ({1}). Compact-окна появятся отдельно.' -f $pool.title, $scopeTxt) -ForegroundColor Green
          Start-Sleep -Milliseconds 700
          break                                      # назад к выбору действия
        }

        # ----- Предохранитель: часть выбранных ролей уже поднята -----
        # Повод (03.08.2026): пул <pool-a> был запущен повторно — забыли, что он уже работает.
        # Дубль даёт две сессии на одном транскрипте (лечится только закрытием окна) и выбивает
        # вотчера прежней роли. Снимок здесь СВОЙ и свежий, а не тот, которым помечен список.
        $live = $null
        try { $live = Get-LiveAgentPanes } catch { $live = $null }
        if (-not $live -or -not $live.Ok) {
          # Отказ проверки — это «не знаю», а не «никто не запущен». Говорим вслух и не блокируем:
          # молчаливое «живо 0» было бы хуже прежнего поведения, потому что выглядит как гарантия.
          Write-Host 'Проверить, что уже поднято, не удалось (WMI не ответил). Запускаю без проверки.' -ForegroundColor Yellow
          Start-Sleep -Milliseconds 1500
        } else {
          $liveSel = @($selected | Where-Object {
            $o = $_
            $r = @($pool.roles | Where-Object { $_.owner -eq $o })
            $r.Count -and (Test-PoolRoleLive $pool $r[0] $live.Panes)
          })
          # A REMOTE pool is the one case where "launch" IS "attach": enter.sh joins the existing
          # tmux window instead of starting a second session, so the incident this guard was built
          # for (03.08: a duplicate session on one transcript) cannot happen there. Closing the Warp
          # window is a DISCONNECT, not a shutdown - and refusing to reopen it left the owner unable
          # to get back to a pool that was alive the whole time (caught on <pool-a>).
          $isRemote = $false
          try { $isRemote = Test-RemotePool $pool } catch { $isRemote = $false }
          if ($liveSel.Count -and $isRemote) {
            Write-Host ('Роли уже подняты на сервере: {0}. Открываю панели — это подключение, а не второй запуск.' -f ($liveSel -join ', ')) -ForegroundColor Cyan
            Write-Host 'Серверный пул: закрытие окна — отключение, а не гашение. Роли живут в tmux.' -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 900
          }
          elseif ($liveSel.Count) {
            $free = @($selected | Where-Object { $liveSel -notcontains $_ })
            if (-not $free.Count) {
              Write-Host ('Все выбранные роли уже подняты: {0}' -f ($liveSel -join ', ')) -ForegroundColor Yellow
              Write-Host 'Окно не открываю. Если панель зависла — сперва заверши пул, потом запускай.' -ForegroundColor DarkGray
              Start-Sleep -Milliseconds 2800
              break                                   # назад к выбору действия; MRU не трогаем — запуска не было
            }
            # Доднять роли в УЖЕ открытое окно нельзя (в живую панель Warp команду извне не впрыснуть),
            # поэтому первый пункт честно говорит про второе окно, а второй — про своё последствие.
            $gItems = @(
              ('[Только незапущенные] — второе окно, в нём: ' + ($free -join ', ')),
              '[Все] — поднять и живые тоже: дубль сессии на том же транскрипте, вотчер прежней будет выбит',
              '[Отмена]'
            )
            $gSel = Invoke-Fzf -Items $gItems -Prompt 'Уже подняты>' -Header ('Уже работают: ' + ($liveSel -join ', ') + '  |  Esc — отмена')
            if (-not $gSel -or $gSel.StartsWith('[Отмена')) { continue }
            if ($gSel.StartsWith('[Только')) { $selected = $free }
          }
        }

        # ----- [Запустить]: генерация Warp tab-config -----
        $toml    = New-PoolToml $pool $selected
        $cfgName = 'poollaunch-' + $pool.slug
        if (-not (Test-Path $TabCfg)) { New-Item -ItemType Directory -Force -Path $TabCfg | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $TabCfg ($cfgName + '.toml')), $toml, (New-Object System.Text.UTF8Encoding($false)))
        Write-PoolRoster $pool (Resolve-PoolBus $pool)
        # 🛑 Снять метки гашения перед подъёмом пула. Под меткой роль в карантине: её сторожа молчат,
        # баннер входящих пуст (см. Test-ShutdownQuiet в pool.ps1). Метку снимает фаза 2 контроллера,
        # но если гашение прервали на середине — Ctrl-C, закрытое окно, таймаут — она остаётся, и
        # поднятая заново роль оказалась бы глухой к соседям, ничем этого не показывая.
        # Запуск пула означает, что гашение окончено, поэтому чистим здесь и без вопросов.
        # ⚠️ Только `shutdown-intent-*`: ready-флаги не трогаем, их семантику знает контроллер.
        $__busQ = Resolve-PoolBus $pool
        if ($__busQ) {
            $__ctl = Join-Path $__busQ '.control'
            if (Test-Path $__ctl) {
                $__stale = @(Get-ChildItem -LiteralPath $__ctl -Filter 'shutdown-intent-*' -File -Force -ErrorAction SilentlyContinue)
                foreach ($__f in $__stale) { Remove-Item -LiteralPath $__f.FullName -Force -ErrorAction SilentlyContinue }
                if ($__stale.Count) {
                    Write-Host ('Снято меток гашения: {0} ({1}) — роли снова слышат шину.' -f $__stale.Count, (($__stale | ForEach-Object { $_.Name -replace '^shutdown-intent-', '' }) -join ', ')) -ForegroundColor Yellow
                }
            }
        }
  Start-Process ('warp://tab_config/{0}?new_window=true' -f $cfgName)

        if (-not $mru) { $mru = New-Object psobject }
        if ($mru.PSObject.Properties.Name -contains $pool.slug) { $mru.$($pool.slug) = (Get-Date).ToString('o') }
        else { $mru | Add-Member -NotePropertyName $pool.slug -NotePropertyValue ((Get-Date).ToString('o')) }
        Save-Mru $mru

        Write-Host ('Запущен пул "{0}". Роли: {1}' -f $pool.title, ($selected -join ', ')) -ForegroundColor Green
        Write-Host 'Пустые панели можно доднять в Warp: Ctrl-Shift-R -> имя роли.' -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 700
        break                                        # после запуска -> назад к выбору действия
      }
    }
  }
}
catch {
  # Любая непредвиденная ошибка НЕ должна молча гасить окно — показываем и ждём Enter.
  Write-Host ''
  Write-Host ('[Pool Launcher] Непредвиденная ошибка: ' + $_.Exception.Message) -ForegroundColor Red
  Write-Host ('  ' + $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
  Read-Host 'Нажми Enter, чтобы закрыть окно'
}
finally {
  if (Test-Path $PidF) { Remove-Item $PidF -Force -ErrorAction SilentlyContinue }
  if ($mtx) { try { $mtx.ReleaseMutex() } catch {}; $mtx.Dispose() }
}
