# DevStore.Core: pure decision logic for the DevStore Windows updater.
# No network, services or file-system side effects except the JSON helpers.
# Must stay compatible with Windows PowerShell 5.1.

Set-StrictMode -Version 2

$script:TagPattern = '^windows-v(\d+\.\d+\.\d+)$'

function ConvertFrom-DevStoreTag {
    param([string]$Tag)
    if ($Tag -match $script:TagPattern) { return [version]$Matches[1] }
    return $null
}

function Select-DevStoreRelease {
    # Highest-version published windows-v release whose version isn't marked bad.
    param($Releases, [string[]]$Bad = @())
    $best = $null
    $bestVersion = $null
    # Flatten one level: Windows PowerShell 5.1 can hand over [[release, ...]].
    $flat = foreach ($x in @($Releases)) {
        if ($x -is [System.Array]) { foreach ($y in $x) { $y } } else { $x }
    }
    foreach ($r in @($flat)) {
        if ($null -eq $r -or $r.draft -or $r.prerelease) { continue }
        $v = ConvertFrom-DevStoreTag $r.tag_name
        if ($null -eq $v) { continue }
        if (@($Bad) -contains $v.ToString()) { continue }
        if ($null -eq $bestVersion -or $v -gt $bestVersion) {
            $best = $r
            $bestVersion = $v
        }
    }
    return $best
}

function ConvertTo-DevStoreHashtable {
    # ConvertFrom-Json gives PSCustomObjects; PS 5.1 has no -AsHashtable.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-DevStoreHashtable $p.Value
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @(foreach ($i in $InputObject) { ConvertTo-DevStoreHashtable $i })
        return , $list
    }
    return $InputObject
}

function Read-DevStoreJson {
    # Missing, empty or corrupt file -> $Default. Objects come back as hashtables.
    param([string]$Path, $Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
        $obj = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $obj) { return $Default }
        return ConvertTo-DevStoreHashtable $obj
    }
    catch {
        return $Default
    }
}

function Write-DevStoreJson {
    # Write to <path>.tmp, then replace, so readers never see a half-written file.
    param([string]$Path, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 10
    $tmp = "$Path.tmp"
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-DevStoreAction {
    # 'install' (nothing installed), 'update' (newer version) or 'none'.
    param($AppState, [string]$Version)
    if ($null -eq $AppState -or -not $AppState['installed']) { return 'install' }
    if ([version]$Version -gt [version]$AppState['installed']) { return 'update' }
    return 'none'
}

function Get-DevStorePruneList {
    # Installed version folders to delete: everything except current and previous.
    param([string[]]$Versions, [string]$Current, [string]$Previous)
    $keep = @($Current, $Previous) | Where-Object { $_ }
    return @(@($Versions) | Where-Object { $_ -and ($keep -notcontains $_) })
}

function Test-DevStoreHash {
    # $ShaText is the content of a .sha256 file: "<hex>  <filename>" or just "<hex>".
    param([string]$File, [string]$ShaText)
    if ([string]::IsNullOrWhiteSpace($ShaText)) { return $false }
    $expected = ($ShaText.Trim() -split '\s+')[0]
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') { return $false }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    return ($actual -ieq $expected)
}

function New-DevStoreWinswXml {
    # WinSW v2 service definition; the exe path points at the 'current' junction.
    param([string]$Name, [string]$Exe, [string]$LogDir)
    $e = [System.Security.SecurityElement]
    return @"
<service>
  <id>devstore-$($e::Escape($Name))</id>
  <name>DevStore: $($e::Escape($Name))</name>
  <description>Installed and updated by the DevStore Updater.</description>
  <executable>$($e::Escape($Exe))</executable>
  <startmode>Automatic</startmode>
  <stoptimeout>30 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec"/>
  <logpath>$($e::Escape($LogDir))</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
</service>
"@
}

function Test-DevStoreRepoName {
    param([string]$Repo)
    return ($Repo -match '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' -and $Repo -notmatch '\.\.')
}

function Set-DevStoreConfigApp {
    # Adds ($Present = $true) or removes a repo in config.apps; case-insensitive, idempotent.
    param([hashtable]$Config, [string]$Repo, [bool]$Present)
    $apps = @()
    if ($Config.ContainsKey('apps') -and $null -ne $Config['apps']) { $apps = @($Config['apps']) }
    $others = @($apps | Where-Object { $_ -and $_['repo'] -ine $Repo })
    if ($Present) {
        $existing = @($apps | Where-Object { $_ -and $_['repo'] -ieq $Repo })
        if ($existing.Count -gt 0) { $Config['apps'] = $apps; return $Config }
        $others += @{ repo = $Repo }
    }
    $Config['apps'] = $others
    return $Config
}

function ConvertTo-DevStoreSafeName {
    # 'Owner/Repo' -> 'owner__repo', for cache folder names.
    param([string]$Repo)
    return ($Repo.ToLowerInvariant() -replace '/', '__' -replace '[^a-z0-9._-]', '_')
}

$script:UpdateModes = @('auto', 'download', 'notify')

function ConvertFrom-DevStoreRequest {
    # Validates a request file written by the Manager. Returns @{action; repo; mode} or $null.
    param($Request)
    if ($null -eq $Request -or $Request -isnot [hashtable] -or -not $Request.ContainsKey('action')) { return $null }
    $action = [string]$Request['action']
    if ($action -eq 'check') { return @{ action = 'check'; repo = $null; mode = $null } }
    $repo = [string]$Request['repo']
    if ($action -eq 'set-updates') {
        $mode = [string]$Request['mode']
        if ($mode -notin ($script:UpdateModes + 'default')) { return $null }
        if ($repo -and -not (Test-DevStoreRepoName $repo)) { return $null }
        if (-not $repo -and $mode -eq 'default') { return $null }
        if (-not $repo) { $repo = $null }
        return @{ action = $action; repo = $repo; mode = $mode }
    }
    if ($action -notin @('install', 'remove', 'apply')) { return $null }
    if (-not (Test-DevStoreRepoName $repo)) { return $null }
    return @{ action = $action; repo = $repo; mode = $null }
}

function Get-DevStoreUpdateMode {
    # 'auto' (download and install), 'download' (download, install on request)
    # or 'notify' (only show that an update exists). Per app, else the default.
    param([hashtable]$Config, [string]$Repo)
    foreach ($e in @($Config['apps'])) {
        if ($e -and $e['repo'] -ieq $Repo -and $e.ContainsKey('updates') -and $e['updates'] -in $script:UpdateModes) { return $e['updates'] }
    }
    if ($Config.ContainsKey('defaultUpdates') -and $Config['defaultUpdates'] -in $script:UpdateModes) { return $Config['defaultUpdates'] }
    return 'auto'
}

function Set-DevStoreConfigUpdates {
    # Sets an app's update mode ('default' clears it), or the default when $Repo is empty.
    param([hashtable]$Config, [string]$Repo, [string]$Mode)
    if (-not $Repo) { $Config['defaultUpdates'] = $Mode; return $Config }
    foreach ($e in @($Config['apps'])) {
        if ($e -and $e['repo'] -ieq $Repo) {
            if ($Mode -eq 'default') { [void]$e.Remove('updates') } else { $e['updates'] = $Mode }
        }
    }
    return $Config
}

function ConvertFrom-DevStoreTokenText {
    # token.dat holds one raw token (older installs) or JSON {"tokens":[{login,token}]}.
    # Like the other list functions here, callers wrap the result in @().
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $t = $Text.Trim()
    if ($t.StartsWith('{')) {
        $obj = ConvertTo-DevStoreHashtable ($t | ConvertFrom-Json)
        return @(@($obj['tokens']) | Where-Object { $_ -and $_['token'] } | ForEach-Object { @{ login = $_['login']; token = $_['token'] } })
    }
    return @(@{ login = $null; token = $t })
}

function ConvertTo-DevStoreTokenText {
    param($List)
    $tokens = @(@($List) | ForEach-Object { [ordered]@{ login = $_['login']; token = $_['token'] } })
    return (ConvertTo-Json -InputObject @{ tokens = $tokens } -Depth 4 -Compress)
}

function Set-DevStoreTokenEntry {
    # 'replace': this becomes the only account. 'add': add or update it, keeping the others.
    param($List, [string]$Login, [string]$Token, [string]$Mode = 'replace')
    $entry = @{ login = $Login; token = $Token }
    if ($Mode -ne 'add') { return @($entry) }
    $out = @()
    $found = $false
    foreach ($e in @($List)) {
        if ($e -and $e['login'] -and $e['login'] -ieq $Login) { $out += $entry; $found = $true } elseif ($e) { $out += $e }
    }
    if (-not $found) { $out += $entry }
    return $out
}

function Select-DevStoreStoreAssets {
    # Store listing files attached to a release by windows-release.yml.
    param($Release)
    $assets = @($Release.assets)
    $meta = $assets | Where-Object { $_.name -eq 'store.json' } | Select-Object -First 1
    $icon = $assets | Where-Object { $_.name -eq 'store-icon.png' } | Select-Object -First 1
    $shots = @($assets | Where-Object { $_.name -match '^store-screenshot-(\d+)\.png$' } |
        Sort-Object { [int]($_.name -replace '^store-screenshot-(\d+)\.png$', '$1') } | Select-Object -First 6)
    return @{ meta = $meta; icon = $icon; screenshots = $shots }
}

Export-ModuleMember -Function ConvertFrom-DevStoreTag, Select-DevStoreRelease, ConvertTo-DevStoreHashtable,
    Read-DevStoreJson, Write-DevStoreJson, Get-DevStoreAction, Get-DevStorePruneList, Test-DevStoreHash,
    New-DevStoreWinswXml, Test-DevStoreRepoName, Set-DevStoreConfigApp, ConvertTo-DevStoreSafeName,
    ConvertFrom-DevStoreRequest, Select-DevStoreStoreAssets, Get-DevStoreUpdateMode, Set-DevStoreConfigUpdates,
    ConvertFrom-DevStoreTokenText, ConvertTo-DevStoreTokenText, Set-DevStoreTokenEntry
