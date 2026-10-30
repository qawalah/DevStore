# Runs after the Manager build (devstore.json "prepare"). Ships the updater
# scripts inside the Manager's release, so the updater can update itself:
# after installing a new Manager, it copies agent\* into C:\DevStore\agent.
if (-not $env:DEVSTORE_OUT) { throw 'DEVSTORE_OUT is not set' }
$src = Join-Path $PSScriptRoot '..\..\agent'
$dest = Join-Path $env:DEVSTORE_OUT 'agent'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Get-ChildItem -LiteralPath $src -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Copy-Item -Destination $dest
Write-Output "Bundled $(@(Get-ChildItem $dest).Count) updater scripts into $dest"
