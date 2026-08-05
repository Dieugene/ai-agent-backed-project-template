# memory-inject.ps1 - SessionStart-хук: возвращает роли её точку входа в память ПОСЛЕ СЖАТИЯ контекста.
#
# Зачем: сжатие уносит из контекста всё, что роль за сессию читала, а оглавление `MEMORY.md` движок
# вклеивает заново. Оглавление — только строки-указатели; тело записи агент должен открыть сам, и
# именно этого он не делает: пересказ после сжатия выглядит полным, повода идти в память не возникает,
# и провал не виден изнутри. Хук кладёт точку входа прямо в контекст, решения агента не требуется.
#
# Зовётся ТОЛЬКО обвязкой (`agent-memory.ps1` вписывает его в файл настроек роли), matcher `compact`.
# На startup/resume не вешается намеренно: там роль и так получает стартовый промпт и `pool mine`.
#
# Контракт: печатает либо тело якорной записи, либо список открытых задач, либо НИЧЕГО.
# Любая ошибка = тишина и код 0: сорванный хук не должен мешать сессии жить.
#
# Кодировка: файл с BOM (PS 5.1 иначе прочтёт кириллицу как cp1251), вывод принудительно UTF-8 —
# stdout хука уходит В КОНТЕКСТ МОДЕЛИ, и мохибаке там был бы виден на каждом сжатии.

[CmdletBinding()]
param(
    [string]$Owner = $env:AGENT_OWNER,
    [string]$Cwd   = $PWD.Path,
    [int]$Limit    = 4000   # p75 фактического распределения тел task_*.md (59 записей): 73% едут целиком
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Хук обязан быть тихим при любой беде: стартующая сессия важнее подсказки.
trap { exit 0 }

if ([string]::IsNullOrWhiteSpace($Owner)) { exit 0 }

# Каталог памяти ищем вверх от cwd - роль могла уйти вглубь проекта (тот же приём, что в memory-audit).
function Find-MemoryDir([string]$start, [string]$owner) {
    $d = $start
    for ($i = 0; $i -lt 6 -and $d; $i++) {
        $p = [IO.Path]::Combine($d, '.memory', $owner)
        if (Test-Path -LiteralPath $p -PathType Container) { return $p }
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

$dir = Find-MemoryDir $Cwd $Owner
if (-not $dir) { exit 0 }

# Ручной выключатель на роль: якорь распух или мешает - положить файл, не трогая код.
if (Test-Path -LiteralPath ([IO.Path]::Combine($dir, '.noinject'))) { exit 0 }

$index = [IO.Path]::Combine($dir, 'MEMORY.md')
if (-not (Test-Path -LiteralPath $index -PathType Leaf)) { exit 0 }

# --- поиск якоря -------------------------------------------------------------
# Два прохода, и порядок важен. Сначала якорь ПО ИМЕНИ - позиция в оглавлении ненадёжна: роль
# дописывает строки сверху, и «первая ссылка» уезжает на свежую задачу (поймано на компаньоне:
# вместо якоря печаталась текущая работа). Имя задано соглашением в команде сверки памяти.
$anchor = $null
$byName = [IO.Path]::Combine($dir, 'task_session_state.md')
if (Test-Path -LiteralPath $byName -PathType Leaf) { $anchor = $byName }

# Запасной проход: якоря по имени нет - берём первую ссылку на task_ в оглавлении. Это не якорь, но
# ближе к нему, чем ничего, и работает до того, как соглашение доедет до роли.
if (-not $anchor) {
foreach ($line in [IO.File]::ReadAllLines($index)) {
    $m = [regex]::Match($line, '\]\((task_[^)]+\.md)\)')
    if ($m.Success) {
        $cand = [IO.Path]::Combine($dir, $m.Groups[1].Value)
        if (Test-Path -LiteralPath $cand -PathType Leaf) { $anchor = $cand; break }
    }
}
}

if ($anchor) {
    $text = [IO.File]::ReadAllText($anchor).Trim()
    # Шапку с метаданными выбрасываем: в контексте она не работает, а место занимает.
    $text = [regex]::Replace($text, '(?s)^---.*?\r?\n---\r?\n', '')
    $text = $text.Trim()
    $name = [IO.Path]::GetFileName($anchor)

    if ($text.Length -gt $Limit) {
        # Режем СЕРЕДИНУ, а не хвост: в начале записи «что это», в конце - состояние и следующий шаг.
        # Обрезка с конца выбросила бы ровно то, ради чего запись открывают.
        # Доли считаем ОТ предела, а не константой: при малом -Limit фиксированная голова в 1000
        # знаков оказывалась больше самого предела, Substring падал с отрицательной длиной, и хук
        # молча не печатал ничего - тихий отказ вместо обрезки.
        $head = [Math]::Max(200, [int]($Limit / 4))
        $tailLen = $Limit - $head
        $head = $text.Substring(0, $head)
        $tail = $text.Substring($text.Length - $tailLen)
        $text = $head + "`n`n[... середина опущена, запись целиком: " + $anchor + " ...]`n`n" + $tail
    }

    Write-Output "=== ПАМЯТЬ РОЛИ: точка входа после сжатия контекста ($name) ==="
    Write-Output $text
    Write-Output "=== конец записи. Остальное - по строкам оглавления MEMORY.md, тела в контекст не попадают ==="
    exit 0
}

# --- якоря нет: отдаём то, что есть ------------------------------------------
# Так хук полезен и до того, как соглашение о якоре доедет до роли: список открытых задач она иначе
# восстанавливает из оглавления вручную, а после сжатия - не восстанавливает вовсе.
$tasks = @(Get-ChildItem -LiteralPath $dir -Filter 'task_*.md' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 8)
if ($tasks.Count -eq 0) { exit 0 }

Write-Output "=== ПАМЯТЬ РОЛИ: якорной записи нет, вот открытые задачи ==="
Write-Output "Контекст только что сжали. Тела записей в него НЕ попадают - открой нужные сам:"
foreach ($t in $tasks) { Write-Output ("  " + $t.FullName) }
Write-Output "Заведи якорь `task_session_state.md` (где остановился / следующий шаг / условия) и поставь его строку ПЕРВОЙ в MEMORY.md."
exit 0
