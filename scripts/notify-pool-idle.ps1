#requires -version 5
# Показывает Windows-уведомление «пул полностью остановился». Зовётся бордом (pool.ps1 board -Watch -Notify)
# один раз на переход active->0. BurntToast если установлен, иначе встроенный NotifyIcon balloon (без зависимостей).
param([string]$Pool = 'pool')
$ErrorActionPreference = 'SilentlyContinue'

$title = 'Пул остановился'
$body  = "$Pool — все агенты завершили работу, субагентов нет."

try {
  if (Get-Module -ListAvailable -Name BurntToast) {
    Import-Module BurntToast -ErrorAction Stop
    New-BurntToastNotification -Text $title, $body
  } else {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.ShowBalloonTip(10000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 6   # держим иконку живой, пока balloon рисуется
    $ni.Visible = $false
    $ni.Dispose()
  }
} catch { }
