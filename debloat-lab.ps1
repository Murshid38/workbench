<#
debloat-lab.ps1 - trim a Windows 11 Pro lab VM for the Workbench Windows milestones (W1-W7, N4).

Run in Windows PowerShell 5.1 (powershell.exe, not pwsh), as Administrator,
logged in as the account you work in, AFTER taking a VM snapshot:

  powershell -ExecutionPolicy Bypass -File .\debloat-lab.ps1 -DryRun   # print every step, change nothing
  powershell -ExecutionPolicy Bypass -File .\debloat-lab.ps1           # do it, then reboot

Every step prints before it runs. A step that fails prints a warning and the
script carries on. Restoring the snapshot undoes everything.

Deliberately KEPT, because a milestone needs it:
  WerSvc (Windows Error Reporting)              W4: WER and minidumps of your own crashes
  EventLog, WMI, ETW                            W7: the ETW consumer pane, WPR and WPA
  App packages (AppXSvc, App Installer, winget) WinDbg is a packaged app
  Print Spooler and Microsoft Print to PDF      W2: printing a session
  Font smoothing (ClearType)                    W1: your GDI glyph atlas should look like real Windows text
  Windows Terminal                              W2: compare your ConPTY terminal with Microsoft's
  Defender                                      stays on; your work folders are excluded instead
  Windows Update                                stays, but only notifies; you choose when to update
#>
param(
    [switch]$DryRun,
    [string[]]$ExcludePaths = @('C:\work', 'C:\tools'),
    [switch]$CleanComponents   # DISM /ResetBase: frees GBs, but installed updates can no longer be uninstalled
)

$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Administrator) PowerShell.'
}

function Step([string]$What, [scriptblock]$Action) {
    Write-Host "-> $What"
    if ($DryRun) { return }
    try { & $Action } catch { Write-Warning "   skipped: $($_.Exception.Message)" }
}

function Set-Dword([string]$Path, [string]$Name, [int]$Value) {
    Step "registry $Path\$Name = $Value" {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
}

# 1. Inbox apps nothing in this lab uses. Removed for every existing user, and
#    deprovisioned so a new user profile doesn't get them back.
$apps = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
    'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps',
    'Microsoft.People', 'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.YourPhone',
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsAlarms', 'Microsoft.WindowsCamera', 'Microsoft.MicrosoftStickyNotes',
    'Microsoft.549981C3F5F10',                    # Cortana
    'Microsoft.Copilot', 'Microsoft.Windows.DevHome',
    'MicrosoftWindows.Client.WebExperience',      # Widgets
    'MSTeams', 'MicrosoftTeams', 'Clipchamp.Clipchamp',
    'MicrosoftCorporationII.QuickAssist', 'MicrosoftCorporationII.MicrosoftFamily'
)
foreach ($app in $apps) {
    Step "remove app $app" {
        Get-AppxPackage -AllUsers -Name $app | Remove-AppxPackage -AllUsers
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $app |
            Remove-AppxProvisionedPackage -Online | Out-Null
    }
}

# 2. OneDrive: syncs and indexes in the background; a lab VM has nothing to sync.
Step 'uninstall OneDrive' {
    winget uninstall --id Microsoft.OneDrive --exact --silent --accept-source-agreements
    if ($LASTEXITCODE) { throw "winget exit code $LASTEXITCODE (not installed?)" }
}

# 3. Policies: less telemetry, no web results or suggestions in Start, no widgets,
#    Edge stops running once its window is closed, updates wait for you.
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0   # Pro treats 0 as "Required"
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
Set-Dword 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2       # notify before download

# 4. Services this VM never needs. Disabled, not deleted:
#    Set-Service -Name <name> -StartupType Manual brings one back.
$services = @(
    'DiagTrack',          # Connected User Experiences and Telemetry
    'dmwappushservice',   # WAP push messages, used by telemetry
    'SysMain',            # Superfetch: prefetching onto a virtual disk is wasted I/O
    'WSearch',            # indexer: would re-index every build output; Start still finds apps
    'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
    'MapsBroker', 'lfsvc', 'RetailDemo', 'Fax', 'wisvc', 'PhoneSvc', 'WbioSrvc', 'bthserv'
)
foreach ($svc in $services) {
    Step "disable service $svc" {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled
    }
}

# 5. Scheduled tasks that collect compatibility and usage data.
$tasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
)
foreach ($task in $tasks) {
    Step "disable task $task" {
        $cut = $task.LastIndexOf('\') + 1
        Disable-ScheduledTask -TaskPath $task.Substring(0, $cut) -TaskName $task.Substring($cut) | Out-Null
    }
}

# 6. Power and disk. The VM's snapshots replace System Restore and hibernation.
Step 'power: High performance plan' {
    powercfg /setactive SCHEME_MIN
    if ($LASTEXITCODE) { throw "powercfg exit code $LASTEXITCODE" }
}
Step 'power: no hibernation file (frees as much disk as the VM has RAM)' {
    powercfg /hibernate off
    if ($LASTEXITCODE) { throw "powercfg exit code $LASTEXITCODE" }
}
Step 'System Restore off' { Disable-ComputerRestore -Drive "$env:SystemDrive\" }
Step 'reserved storage off' {
    DISM.exe /Online /Set-ReservedStorageState /State:Disabled /Quiet
    if ($LASTEXITCODE) { throw "DISM exit code $LASTEXITCODE" }
}
if ($CleanComponents) {
    Step 'component store cleanup with /ResetBase (takes minutes)' {
        DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
        if ($LASTEXITCODE) { throw "DISM exit code $LASTEXITCODE" }
    }
}

# 7. Defender stays on. Your own debugger writing into other processes, and the
#    W6 injection and hooking test programs, look like malware to it, and scanning
#    every build output slows each build. Exclude only your folders.
foreach ($dir in $ExcludePaths) {
    Step "Defender: exclude $dir" {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Add-MpPreference -ExclusionPath $dir
    }
}

Write-Host ''
Write-Host 'Done. Reboot, then do these by hand:'
Write-Host '  SystemPropertiesPerformance.exe: choose "Adjust for best performance",'
Write-Host '      then tick "Smooth edges of screen fonts" again (W1 needs real font smoothing)'
Write-Host '  Windows Security > Device security > Core isolation: Memory integrity off'
Write-Host '  manage-bde -status: if C: is encrypted, turn Device encryption off'