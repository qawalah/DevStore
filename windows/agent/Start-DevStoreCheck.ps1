<#
.SYNOPSIS
  Runs the DevStore Updater now instead of waiting for the next 10-minute run.
  Needs admin (the DevStore Manager asks for it with a UAC prompt).
#>
$ErrorActionPreference = 'Stop'
Start-ScheduledTask -TaskName 'DevStore Updater'
