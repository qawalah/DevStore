<#
.SYNOPSIS
  One DevStore Updater pass. Run by the "DevStore Updater" scheduled task
  (as SYSTEM, at startup and every 10 minutes).
#>
param([string]$Root = 'C:\DevStore')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevStore.Agent.psm1') -Force
Invoke-DevStoreUpdaterRun -Root $Root
