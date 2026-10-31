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
    # 'install' (nothing installed), 'update' (newer version, or a switch between
    # a stable release and a pull-request test build, either way) or 'none'.
    param($AppState, [string]$Version)
    if ($null -eq $AppState -or -not $AppState['installed']) { return 'install' }
    $installed = [string]$AppState['installed']
    if ($installed -eq $Version) { return 'none' }
    if ($installed -match '-' -or $Version -match '-') { return 'update' }
    if ([version]$Version -gt [version]$installed) { return 'update' }
    return 'none'
}

$script:PrTagPattern = '^windows-v(\d+\.\d+\.\d+)-pr(\d+)\.(\d+)$'

function ConvertFrom-DevStorePrTag {
    # 'windows-v1.3.0-pr12.7' -> @{ version = '1.3.0-pr12.7'; pr = 12; build = 7 }, else $null.
    param([string]$Tag)
    if ($Tag -match $script:PrTagPattern) {
        return @{ version = "$($Matches[1])-pr$($Matches[2]).$($Matches[3])"; pr = [int]$Matches[2]; build = [int]$Matches[3] }
    }
    return $null
}

function Get-DevStorePrBuilds {
    # Newest test build of each pull request: @{ pr; version; title; tag; publishedAt }, by PR number.
    param($Releases)
    $best = @{}
    foreach ($r in @($Releases)) {
        if ($null -eq $r -or $r.draft) { continue }
        $t = ConvertFrom-DevStorePrTag $r.tag_name
        if ($null -eq $t) { continue }
        if (-not $best.ContainsKey($t.pr) -or $t.build -gt $best[$t.pr].build) {
            $title = [string]$r.name
            if (-not $title) { $title = "PR #$($t.pr)" }
            $best[$t.pr] = @{ pr = $t.pr; build = $t.build; version = $t.version; title = $title
                tag = $r.tag_name; publishedAt = [string]$r.published_at }
        }
    }
    return @($best.Keys | Sort-Object | ForEach-Object { $best[$_] })
}

function Select-DevStoreChannelRelease {
    # 'stable' -> newest normal release. 'pr-<N>' -> newest test build of that PR
    # (not marked bad); falls back to stable when the PR has none (e.g. closed).
    param($Releases, [string]$Channel = 'stable', [string[]]$Bad = @())
    if ($Channel -match '^pr-(\d+)$') {
        $pr = [int]$Matches[1]
        $flat = foreach ($x in @($Releases)) { if ($x -is [System.Array]) { foreach ($y in $x) { $y } } else { $x } }
        $best = $null; $bestBuild = -1
        foreach ($r in @($flat)) {
            if ($null -eq $r -or $r.draft) { continue }
            $t = ConvertFrom-DevStorePrTag $r.tag_name
            if ($null -eq $t -or $t.pr -ne $pr -or (@($Bad) -contains $t.version)) { continue }
            if ($t.build -gt $bestBuild) { $best = $r; $bestBuild = $t.build }
        }
        if ($best) { return $best }
    }
    return Select-DevStoreRelease -Releases $Releases -Bad $Bad
}

function Get-DevStoreReleaseVersion {
    # The version string a release installs as: '1.2.0' or '1.3.0-pr12.7'.
    param($Release)
    $t = ConvertFrom-DevStorePrTag $Release.tag_name
    if ($t) { return $t.version }
    return (ConvertFrom-DevStoreTag $Release.tag_name).ToString()
}

function Get-DevStoreChannel {
    param([hashtable]$Config, [string]$Repo)
    foreach ($e in @($Config['apps'])) {
        if ($e -and $e['repo'] -ieq $Repo -and $e.ContainsKey('channel') -and $e['channel'] -match '^(stable|pr-\d+)$') { return $e['channel'] }
    }
    return 'stable'
}

function Set-DevStoreConfigChannel {
    param([hashtable]$Config, [string]$Repo, [string]$Channel)
    foreach ($e in @($Config['apps'])) {
        if ($e -and $e['repo'] -ieq $Repo) {
            if ($Channel -eq 'stable') { [void]$e.Remove('channel') } else { $e['channel'] = $Channel }
        }
    }
    return $Config
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
    if ($action -eq 'set-nas') {
        # Watchtower's address ('' turns NAS status off) and API token ('' keeps the stored one).
        $url = [string]$Request['url']
        $token = [string]$Request['token']
        if ($url -and $url -notmatch $script:NasUrlPattern) { return $null }
        if ($token -and ($token.Length -gt 256 -or $token -match '\s')) { return $null }
        return @{ action = $action; repo = $null; mode = $null; url = $url; token = $token }
    }
    $repo = [string]$Request['repo']
    if ($action -eq 'set-updates') {
        $mode = [string]$Request['mode']
        if ($mode -notin ($script:UpdateModes + 'default')) { return $null }
        if ($repo -and -not (Test-DevStoreRepoName $repo)) { return $null }
        if (-not $repo -and $mode -eq 'default') { return $null }
        if (-not $repo) { $repo = $null }
        return @{ action = $action; repo = $repo; mode = $mode }
    }
    if ($action -eq 'set-channel') {
        $channel = [string]$Request['channel']
        if ($channel -notmatch '^(stable|pr-\d{1,6})$' -or -not (Test-DevStoreRepoName $repo)) { return $null }
        return @{ action = $action; repo = $repo; mode = $null; channel = $channel }
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

function Select-DevStoreRepoStoreFiles {
    # Picks an icon and up to 6 screenshots from a repo's file list (git tree
    # paths), for releases that don't carry store files. Looks next to the
    # app's devstore.json first, then at the repo root.
    param([string[]]$Paths)
    $Paths = @($Paths)
    $manifest = @($Paths | Where-Object { $_ -match '(^|/)devstore\.json$' } | Sort-Object { $_.Length }) | Select-Object -First 1
    $app = ''
    if ($manifest -and $manifest -match '/') { $app = $manifest.Substring(0, $manifest.LastIndexOf('/') + 1) }
    $prefixes = @($app)
    if ($app) { $prefixes += '' }
    $shots = @()
    foreach ($pre in $prefixes) {
        foreach ($d in 'store/screenshots/', 'screenshots/', 'docs/screenshots/', 'store/') {
            if ($shots.Count) { break }
            $dir = "$pre$d"
            $shots = @($Paths | Where-Object {
                    $_.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) -and $_ -match '\.png$' -and
                    $_.Substring($dir.Length) -notmatch '/' -and $_.Substring($dir.Length) -notmatch '^icon'
                } | Sort-Object)
        }
    }
    $icon = $null
    foreach ($pre in $prefixes) {
        foreach ($c in 'store/icon.png', 'icon.png', 'assets/icon.png', 'winres/icon.png') {
            if (-not $icon) { $icon = @($Paths | Where-Object { $_ -ieq "$pre$c" }) | Select-Object -First 1 }
        }
    }
    if (-not $icon) {
        $under = @($Paths | Where-Object { $_.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) -and $_ -match '(^|/)icon[^/]*\.png$' })
        $icon = @($under | Where-Object { $_ -match 'icon-512\.png$' }) + @($under | Where-Object { $_ -match 'icon-256\.png$' }) + $under |
            Select-Object -First 1
    }
    return @{ icon = $icon; screenshots = @($shots | Select-Object -First 6) }
}

function Test-DevStoreStarredDue {
    # Starred repos are re-read at most hourly (they change rarely and may be many),
    # or right away when the user clicked Check for updates.
    param([string]$Last, [datetime]$Now = (Get-Date).ToUniversalTime(), [switch]$Force)
    if ($Force -or -not $Last) { return $true }
    try {
        $t = [datetime]::Parse($Last, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    }
    catch { return $true }
    return (($Now.ToUniversalTime() - $t).TotalMinutes -ge 60)
}

function Get-DevStoreGitHubUrl {
    # Only https://github.com/... links (and GitHub's avatar host) are kept: the
    # window opens them in the browser, so nothing else may get through.
    param([string]$Url, [string]$Fallback, [string]$Domain = 'github.com')
    if ($Url -and $Url -match "^https://$([regex]::Escape($Domain))/") { return $Url }
    return $Fallback
}

function ConvertTo-DevStoreStarredEntry {
    # A starred repo and its newest stable release, as plain data for the window.
    # Watch only: nothing here is ever downloaded or run by DevStore.
    param($Repo, $Releases)
    $name = [string]$Repo.full_name
    $repoUrl = Get-DevStoreGitHubUrl -Url ([string]$Repo.html_url) -Fallback "https://github.com/$name"
    $avatar = $null
    if ($Repo.PSObject.Properties['owner'] -and $Repo.owner) {
        $avatar = Get-DevStoreGitHubUrl -Url ([string]$Repo.owner.avatar_url) -Fallback $null -Domain 'avatars.githubusercontent.com'
    }
    $flat = foreach ($x in @($Releases)) { if ($x -is [System.Array]) { foreach ($y in $x) { $y } } else { $x } }
    $rel = @($flat | Where-Object { $_ -and -not $_.draft -and -not $_.prerelease }) | Select-Object -First 1
    $latest = $null
    if ($rel) {
        $notes = [string]$rel.body
        if ($notes.Length -gt 4000) { $notes = $notes.Substring(0, 3990) + ' …' }
        $assets = @(@($rel.assets) | Where-Object { $_ } | ForEach-Object {
                $u = Get-DevStoreGitHubUrl -Url ([string]$_.browser_download_url) -Fallback $null
                if ($u) { @{ name = [string]$_.name; size = [long]$_.size; url = $u } }
            } | Select-Object -First 20)
        $title = [string]$rel.name
        if (-not $title) { $title = [string]$rel.tag_name }
        $latest = @{
            tag = [string]$rel.tag_name; title = $title; publishedAt = [string]$rel.published_at; notes = $notes
            url = (Get-DevStoreGitHubUrl -Url ([string]$rel.html_url) -Fallback "$repoUrl/releases"); assets = $assets
        }
    }
    return @{ repo = $name; description = [string]$Repo.description; url = $repoUrl; avatar = $avatar; latest = $latest }
}

# ---------------------------------------------------------------- Docker apps on the NAS

$script:DockerTagPattern = '^docker-v(\d+\.\d+\.\d+)$'
$script:NasUrlPattern = '^https?://[A-Za-z0-9.-]+(:\d{1,5})?/?$'

function ConvertTo-DevStoreUtcText {
    # API times as 'yyyy-MM-ddTHH:mm:ssZ'. PowerShell 7 turns ISO strings into DateTime;
    # 5.1 leaves them as text.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function Get-DevStoreDockerRelease {
    # The newest published docker-v<X.Y.Z> release (by number), with the image its
    # notes name ("Image `ghcr.io/o/n:1.2.3`", written by docker-release.yml).
    param($Releases)
    $best = $null
    $bestVersion = $null
    foreach ($r in @($Releases)) {
        if ($null -eq $r -or $r.draft -or $r.prerelease) { continue }
        $m = [regex]::Match([string]$r.tag_name, $script:DockerTagPattern)
        if (-not $m.Success) { continue }
        $v = [version]$m.Groups[1].Value
        if ($null -eq $bestVersion -or $v -gt $bestVersion) { $best = $r; $bestVersion = $v }
    }
    if ($null -eq $best) { return $null }
    $image = $null
    $name = $null
    $im = [regex]::Match([string]$best.body, 'ghcr\.io/[A-Za-z0-9._/-]+')
    if ($im.Success) {
        $image = $im.Value.ToLowerInvariant()
        $name = ($image -split '/')[-1]
    }
    return @{ version = $bestVersion.ToString(); tag = [string]$best.tag_name; publishedAt = (ConvertTo-DevStoreUtcText $best.published_at); image = $image; name = $name }
}

function ConvertTo-DevStoreImageName {
    # 'GHCR.io/O/n:latest' or '...@sha256:...' -> 'ghcr.io/o/n' (registry ports are kept).
    param([string]$Image)
    $i = $Image.ToLowerInvariant()
    $at = $i.IndexOf('@')
    if ($at -ge 0) { $i = $i.Substring(0, $at) }
    $colon = $i.LastIndexOf(':')
    if ($colon -gt $i.LastIndexOf('/')) { $i = $i.Substring(0, $colon) }
    return $i
}

function Get-DevStoreNasApps {
    # Per repo with a Docker release: what the NAS runs, from Watchtower's containers.
    # ok = running the newest version; pending = Watchtower hasn't updated it yet;
    # stopped; missing = no container uses the image.
    param([hashtable]$Docker, $Containers, [string]$LastScan)
    $scan = $null
    if ($LastScan) { try { $scan = [DateTimeOffset]::Parse($LastScan, [Globalization.CultureInfo]::InvariantCulture) } catch { $scan = $null } }
    $out = @{}
    foreach ($repo in @($Docker.Keys)) {
        $d = $Docker[$repo]
        $entry = @{ name = $d['name']; latest = $d['version']; publishedAt = $d['publishedAt']; container = $null; status = 'missing' }
        $c = $null
        if ($d['image']) {
            $c = @($Containers | Where-Object { $_ -and $_.image -and (ConvertTo-DevStoreImageName ([string]$_.image)) -eq $d['image'] }) | Select-Object -First 1
        }
        if ($c) {
            $entry['container'] = [string]$c.name
            $published = $null
            try { $published = [DateTimeOffset]::Parse([string]$d['publishedAt'], [Globalization.CultureInfo]::InvariantCulture) } catch { $published = $null }
            if (-not $c.running) { $entry['status'] = 'stopped' }
            elseif ($c.stale -or $null -eq $scan -or ($published -and $scan -lt $published)) { $entry['status'] = 'pending' }
            else { $entry['status'] = 'ok' }
        }
        $out[$repo] = $entry
    }
    return $out
}

function Set-DevStoreConfigNas {
    # Watchtower's address for NAS status; '' turns it off.
    param([hashtable]$Config, [string]$Url)
    if ($Url) { $Config['nas'] = @{ watchtower = $Url } }
    elseif ($Config.ContainsKey('nas')) { $Config.Remove('nas') }
    return $Config
}

Export-ModuleMember -Function ConvertFrom-DevStoreTag, Select-DevStoreRelease, ConvertTo-DevStoreHashtable,
    Read-DevStoreJson, Write-DevStoreJson, Get-DevStoreAction, Get-DevStorePruneList, Test-DevStoreHash,
    New-DevStoreWinswXml, Test-DevStoreRepoName, Set-DevStoreConfigApp, ConvertTo-DevStoreSafeName,
    ConvertFrom-DevStoreRequest, Select-DevStoreStoreAssets, Get-DevStoreUpdateMode, Set-DevStoreConfigUpdates,
    ConvertFrom-DevStoreTokenText, ConvertTo-DevStoreTokenText, Set-DevStoreTokenEntry, Select-DevStoreRepoStoreFiles,
    ConvertFrom-DevStorePrTag, Get-DevStorePrBuilds, Select-DevStoreChannelRelease, Get-DevStoreReleaseVersion,
    Get-DevStoreChannel, Set-DevStoreConfigChannel, Test-DevStoreStarredDue, Get-DevStoreGitHubUrl,
    ConvertTo-DevStoreStarredEntry, Get-DevStoreDockerRelease, ConvertTo-DevStoreImageName, Get-DevStoreNasApps,
    Set-DevStoreConfigNas, ConvertTo-DevStoreUtcText
