# memory-audit.ps1 - автоматический аудит памяти роли: зафиксировать историю и проверить структуру.
#
# Зовётся НЕ агентом вручную, а обвязкой в двух точках:
#   * `pool ready`  - агент подтвердил готовность к гашению (память дописана, дальше он молчит);
#   * хук PreCompact - контекст вот-вот сожмут, в том числе автоматически, без участия человека.
#
# Почему не строкой в инструкции: помнить в конце сессии про две команды - самое ненадёжное место
# ровно там, где надёжность и нужна. Агент пишет память, механику выполняет обвязка.
#
#   powershell -File memory-audit.ps1 -Owner <роль> [-Cwd <путь>] [-Reason ready|precompact]
#
# Ничего не чинит и ничего не удаляет. Коммитит - да: незафиксированная запись теряется целиком,
# а замечание проверки - повод посмотреть, а не причина не сохранять.

param(
    [AllowEmptyString()][string]$Owner = $env:AGENT_OWNER,
    [string]$Cwd = (Get-Location).Path,
    [string]$Reason = 'manual'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

if ([string]::IsNullOrWhiteSpace($Owner)) { return }   # не роль пула - тихо выходим

# Каталог ищем вверх от текущего: агент мог уйти вглубь проекта, и тогда <cwd>\.memory не существует.
function Find-MemoryDir([string]$start, [string]$owner) {
    $d = $start
    for ($i = 0; $i -lt 6 -and $d; $i++) {
        $cand = Join-Path (Join-Path $d '.memory') $owner
        if (Test-Path $cand) { return $cand }
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

$dir = Find-MemoryDir -start $Cwd -owner $Owner
if (-not $dir) { return }   # память по-старому (переключатель не раскатан) - молчим, это не ошибка

Write-Output ("[memory-audit] {0} ({1})" -f $Owner, $Reason)

# --- 1. зафиксировать историю -------------------------------------------------
if (Test-Path (Join-Path $dir '.git')) {
    $st = @(& git -C $dir status --porcelain 2>$null)
    if ($st.Count -gt 0) {
        $null = & git -C $dir add -A 2>&1
        $msg = "memory: $Reason ($($st.Count) файлов)"
        $out = & git -C $dir -c user.name=$Owner -c user.email="$Owner@local" commit -q -m $msg 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Output ("  зафиксировано изменений: {0}" -f $st.Count) }
        else { Write-Output ("  коммит не прошёл: {0}" -f ($out -join ' ')) }
    } else {
        Write-Output '  изменений нет'
    }
} else {
    Write-Output '  истории нет (репозиторий не инициализирован) - записи сохранены, версий не будет'
}

# --- 2. структурная проверка --------------------------------------------------
$checker = Join-Path $PSScriptRoot 'memory-check.ps1'
if (Test-Path $checker) {
    $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $checker -Dir $dir -Quiet 2>&1)
    $notes = @($lines | Where-Object { $_ -match '^\s+- ' })
    if ($notes.Count -eq 0) { Write-Output '  структура: замечаний нет' }
    else {
        # Печатаем НЕСКОЛЬКО, а не всё: это последние строки перед сжатием или гашением, и простыня
        # из тридцати однотипных пунктов там не помогает никому. Полный список - у самой проверки.
        Write-Output ("  структура: замечаний {0}" -f $notes.Count)
        foreach ($n in ($notes | Select-Object -First 5)) { Write-Output ("  {0}" -f $n.TrimEnd()) }
        if ($notes.Count -gt 5) {
            Write-Output ("    ... и ещё {0}. Весь список: memory-check.ps1 -Dir `"{1}`"" -f ($notes.Count - 5), $dir)
        }
    }
}
