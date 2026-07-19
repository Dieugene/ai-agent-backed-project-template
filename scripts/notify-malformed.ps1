#requires -version 5
# Windows notification: a pool session leaked a tool call as TEXT (malformed / format drift).
# Sibling of notify-pool-idle.ps1 (same BurntToast -> NotifyIcon balloon fallback, no dependencies).
# Called by the Stop-hook detector (stop-detect-malformed.ps1) when the session transcript shows the
# harness marker "malformed and could not be parsed". ASCII-only on purpose (no BOM trap under PS 5.1).
param([string]$Owner = 'session', [int]$Count = 0, [switch]$Recovered)
$ErrorActionPreference = 'SilentlyContinue'

if ($Recovered) {
  # The model leaked a tool_call as TEXT but self-corrected on retry. Informational: logged, no action.
  $title = 'Pool: malformed tool-call (self-healed)'
  $body  = "${Owner}: leaked a tool_call as TEXT (format drift) but recovered on its own. Logged, no action needed. Watch for a run of these -> reseat."
  if ($Count -gt 1) { $body = "${Owner}: $Count malformed tool-calls, self-corrected. Logged. A run of these = reseat candidate." }
} else {
  # Leaked and did NOT visibly recover this turn -> action-needed.
  $title = 'Pool: malformed tool-call leak'
  $body  = "${Owner}: emitted a tool_call as TEXT and did NOT self-correct. Check the session -- /compact is unreliable; if the poison reached the handoff, reseat + scrub handoff."
  if ($Count -gt 1) { $body = "${Owner}: $Count malformed tool-calls, no self-correct (format drift). Check/reseat -- /compact unreliable if handoff poisoned." }
}

try {
  if (Get-Module -ListAvailable -Name BurntToast) {
    Import-Module BurntToast -ErrorAction Stop
    New-BurntToastNotification -Text $title, $body
  } else {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Warning
    $ni.Visible = $true
    $ni.ShowBalloonTip(10000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Warning)
    Start-Sleep -Seconds 6   # keep the tray icon alive while the balloon renders
    $ni.Visible = $false
    $ni.Dispose()
  }
} catch { }
