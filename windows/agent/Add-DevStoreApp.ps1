<#
.SYNOPSIS
  Adds a GitHub repo (owner/name) to the DevStore Updater and installs it now.
.EXAMPLE
  .\Add-DevStoreApp.ps1 -Repo qawalah/my-app
#>
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Root = 'C:\DevStore'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevStore.Core.psm1') -Force

if (-not (Test-DevStoreRepoName $Repo)) { throw "'$Repo' isn't a valid owner/repo name." }
$path = Join-Path $Root 'config.json'
$config = Read-DevStoreJson -Path $path -Default @{ apps = @() }
$config = Set-DevStoreConfigApp -Config $config -Repo $Repo -Present $true
Write-DevStoreJson -Path $path -Object $config
Write-Output "Added $Repo. Installing now..."
Start-ScheduledTask -TaskName 'DevStore Updater'
