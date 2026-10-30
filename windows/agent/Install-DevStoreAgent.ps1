<#
.SYNOPSIS
  Installs (or upgrades) the DevStore Updater on this Windows PC.

.DESCRIPTION
  Run once from an elevated PowerShell, from a checkout or download of the
  DevStore repo:

      powershell -ExecutionPolicy Bypass -File .\windows\agent\Install-DevStoreAgent.ps1

  It's safe to re-run: it upgrades the agent scripts and keeps your apps,
  state and token. Pass -NewToken to replace the GitHub token.

  What it does:
    - creates C:\DevStore and locks its permissions down
    - stores your GitHub token encrypted (DPAPI, this machine only)
    - downloads WinSW (the service wrapper) and checks its hash
    - registers the "DevStore Updater" scheduled task (SYSTEM, at startup + every 10 min)
    - adds the DevStore Manager app (repo qawalah/devstore) to the app list
#>
param(
    [string]$Root = 'C:\DevStore',
    [string]$ManagerRepo = 'qawalah/devstore',
    [switch]$NewToken,
    [switch]$NoManager
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (right-click > Run as administrator).'
}

$WinswUrl = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
$WinswSha256 = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
$TaskName = 'DevStore Updater'

Import-Module (Join-Path $PSScriptRoot 'DevStore.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevStore.Agent.psm1') -Force

Write-Output "Installing DevStore Updater to $Root"

# 1. Folders and agent scripts.
foreach ($d in '', 'agent', 'tools', 'apps', 'logs', 'downloads') {
    $p = Join-Path $Root $d
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } |
    Copy-Item -Destination (Join-Path $Root 'agent') -Force

# 2. Permissions: SYSTEM + Administrators full; Users read/execute (to run
#    GUI apps and let the Manager read state). SIDs keep this locale-proof.
& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Setting permissions on $Root failed (icacls exit $LASTEXITCODE)." }

# 3. GitHub token (fine-grained, read-only Contents).
$tokenFile = Join-Path $Root 'token.dat'
# DevStoreSetup.exe passes the token in DEVSTORE_TOKEN (never on the command line).
$envToken = $env:DEVSTORE_TOKEN
if ($envToken -or $NewToken -or -not (Test-Path -LiteralPath $tokenFile)) {
    if ($envToken) {
        $token = $envToken.Trim()
    }
    else {
        Write-Output ''
        Write-Output 'Paste a fine-grained GitHub token with read-only "Contents" access to your app repos'
        Write-Output '(github.com > Settings > Developer settings > Fine-grained tokens). Input is hidden.'
        $secure = Read-Host -Prompt 'GitHub token' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'No token entered.' }
        $token = $token.Trim()
    }
    Write-Output "Checking the token against $ManagerRepo..."
    Get-DevStoreReleases -Repo $ManagerRepo -Token $token | Out-Null
    Write-DevStoreToken -Root $Root -Token $token
    Write-Output 'Token OK and stored (encrypted for this machine).'
}
& icacls.exe $tokenFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Locking down $tokenFile failed (icacls exit $LASTEXITCODE)." }

# 4. WinSW service wrapper, pinned by hash.
$winsw = Join-Path (Join-Path $Root 'tools') 'winsw.exe'
$haveWinsw = (Test-Path -LiteralPath $winsw) -and ((Get-FileHash -LiteralPath $winsw -Algorithm SHA256).Hash -ieq $WinswSha256)
if (-not $haveWinsw) {
    Write-Output 'Downloading WinSW v2.12.0...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = "$winsw.download"
    Invoke-WebRequest -Uri $WinswUrl -OutFile $tmp -UseBasicParsing
    if ((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash -ine $WinswSha256) {
        Remove-Item -LiteralPath $tmp -Force
        throw 'WinSW download failed its hash check; not installing it.'
    }
    Move-Item -LiteralPath $tmp -Destination $winsw -Force
}

# 5. App list: make sure the DevStore Manager is in it.
$configPath = Join-Path $Root 'config.json'
$config = Read-DevStoreJson -Path $configPath -Default @{ apps = @() }
if (-not $NoManager) { $config = Set-DevStoreConfigApp -Config $config -Repo $ManagerRepo -Present $true }
elseif (-not $config.ContainsKey('apps')) { $config['apps'] = @() }
Write-DevStoreJson -Path $configPath -Object $config

# 6. Scheduled task: SYSTEM, at startup and every 10 minutes.
$script = Join-Path (Join-Path $Root 'agent') 'DevStoreUpdater.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Root `"$Root`""
$every10 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
$atStartup = New-ScheduledTaskTrigger -AtStartup
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($every10, $atStartup) `
    -Principal $taskPrincipal -Settings $settings -Description 'Installs and updates apps released through DevStore.' -Force | Out-Null

Write-DevStoreLog -Root $Root -Message 'agent installed/upgraded'
Start-ScheduledTask -TaskName $TaskName

Write-Output ''
Write-Output 'Done. The updater is running its first pass now.'
Write-Output "  Add an app:   powershell -ExecutionPolicy Bypass -File $Root\agent\Add-DevStoreApp.ps1 -Repo qawalah/<app>"
Write-Output '  Or use the DevStore Manager from the Start menu once it has installed (a few minutes).'
Write-Output "  Logs:         $Root\logs"
