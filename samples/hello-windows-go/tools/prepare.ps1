# Sample "prepare" script: runs after the build, before packaging. Real apps
# use this to download extra parts (for example an AI engine) into the package.
if (-not $env:DEVSTORE_OUT) { throw 'DEVSTORE_OUT is not set' }
$engine = Join-Path $env:DEVSTORE_OUT 'engine'
New-Item -ItemType Directory -Path $engine -Force | Out-Null
Set-Content -Path (Join-Path $engine 'engine.txt') -Value 'downloaded by prepare.ps1'
Write-Output "prepare.ps1 wrote $engine"
