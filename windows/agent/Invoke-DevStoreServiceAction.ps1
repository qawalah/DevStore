<#
.SYNOPSIS
  Starts, stops or restarts a DevStore-managed service (devstore-<Name>).
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9-]+$')][string]$Name,
    [Parameter(Mandatory = $true)][ValidateSet('Start', 'Stop', 'Restart')][string]$Action
)
$ErrorActionPreference = 'Stop'
$svc = "devstore-$Name"
switch ($Action) {
    'Start' { Start-Service -Name $svc }
    'Stop' { Stop-Service -Name $svc -Force }
    'Restart' { Restart-Service -Name $svc -Force }
}
