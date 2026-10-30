<#
.SYNOPSIS
  Removes an app from the DevStore Updater: stops and uninstalls its service,
  deletes its shortcut and program files. Data in %ProgramData%\<name> is kept.
.EXAMPLE
  .\Remove-DevStoreApp.ps1 -Repo qawalah/my-app
#>
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Root = 'C:\DevStore'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevStore.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevStore.Agent.psm1') -Force

if (-not (Test-DevStoreRepoName $Repo)) { throw "'$Repo' isn't a valid owner/repo name." }

# Wait for any running updater pass so we don't race it.
$mutex = New-Object System.Threading.Mutex($false, 'Global\DevStoreUpdater')
if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(5))) { throw 'The updater is busy; try again in a few minutes.' }
try {
    $configPath = Join-Path $Root 'config.json'
    $statePath = Join-Path $Root 'state.json'
    $config = Read-DevStoreJson -Path $configPath -Default @{ apps = @() }
    $state = Read-DevStoreJson -Path $statePath -Default @{ apps = @{} }
    if (-not $state.ContainsKey('apps') -or $state['apps'] -isnot [hashtable]) { $state['apps'] = @{} }

    Remove-DevStoreAppCore -Root $Root -Repo $Repo -State $state
    Write-DevStoreJson -Path $statePath -Object $state

    $config = Set-DevStoreConfigApp -Config $config -Repo $Repo -Present $false
    Write-DevStoreJson -Path $configPath -Object $config
    Write-Output "Removed $Repo."
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
