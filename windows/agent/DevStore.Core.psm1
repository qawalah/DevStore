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
    # $Source 'starred': a starred repo (not built by DevStore), installed its own way.
    param([hashtable]$Config, [string]$Repo, [bool]$Present, [string]$Source = '')
    $apps = @()
    if ($Config.ContainsKey('apps') -and $null -ne $Config['apps']) { $apps = @($Config['apps']) }
    $others = @($apps | Where-Object { $_ -and $_['repo'] -ine $Repo })
    if ($Present) {
        $existing = @($apps | Where-Object { $_ -and $_['repo'] -ieq $Repo })
        if ($existing.Count -gt 0) { $Config['apps'] = $apps; return $Config }
        $entry = @{ repo = $Repo }
        if ($Source -eq 'starred') { $entry['source'] = 'starred' }
        $others += $entry
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
    if ($action -eq 'set-starred') {
        # Install newly starred repos by themselves: 'on' or 'off'.
        $value = [string]$Request['value']
        if ($value -notin @('on', 'off')) { return $null }
        return @{ action = $action; repo = $null; mode = $null; value = $value }
    }
    if ($action -eq 'set-files') {
        # The files to install from a starred repo's release: name patterns (version = *) and the main program.
        $repo = [string]$Request['repo']
        if (-not (Test-DevStoreRepoName $repo)) { return $null }
        if ($Request['clear'] -eq $true) { return @{ action = $action; repo = $repo; mode = $null; patterns = @(); main = ''; clear = $true } }
        $patterns = @(@($Request['patterns']) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        if ($patterns.Count -lt 1 -or $patterns.Count -gt $script:StarredMaxFiles) { return $null }
        foreach ($p in $patterns) {
            if ($p -notmatch '^[A-Za-z0-9._+*-]{1,120}\.(zip|exe)$' -or $p.Contains('..')) { return $null }
        }
        $main = [string]$Request['main']
        if ($main -and ($main -notmatch '^[A-Za-z0-9._+-]{1,120}\.exe$' -or $main.Contains('..'))) { return $null }
        return @{ action = $action; repo = $repo; mode = $null; patterns = $patterns; main = $main; clear = $false }
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
    if ($action -notin @('install', 'remove', 'apply', 'check-app')) { return $null }
    if (-not (Test-DevStoreRepoName $repo)) { return $null }
    $source = $null
    $mode = $null
    if ($action -eq 'install' -and [string]$Request['source'] -eq 'starred') { $source = 'starred' }
    # An install may say how its updates should arrive.
    if ($action -eq 'install' -and [string]$Request['mode'] -in $script:UpdateModes) { $mode = [string]$Request['mode'] }
    return @{ action = $action; repo = $repo; mode = $mode; source = $source }
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
    # Nothing is downloaded here: installing is Update-DevStoreStarredApp's job.
    param($Repo, $Releases, $Override = $null)
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
        # The files DevStore would install on this PC (a set, or the user's own choice), if the release has any.
        $set = Select-DevStoreStarredAssets -Assets $rel.assets -Tag ([string]$rel.tag_name) -Override $Override
        $picked = @($set['assets'])
        $latest['windowsFiles'] = @($picked | ForEach-Object { @{ name = [string]$_.name; size = [long]$_.size } })
        $latest['windowsOverride'] = ($null -ne $Override)
        $latest['windowsError'] = $set['error']
        # 'windows' stays the one file the old single pick would take, when it is in the set (else the first).
        $win = $null
        if ($picked.Count) {
            $old = Select-DevStoreStarredAsset -Assets $rel.assets
            $win = @($picked | Where-Object { $old -and $_.name -eq $old.name }) | Select-Object -First 1
            if (-not $win) { $win = $picked[0] }
        }
        if ($win) { $latest['windows'] = @{ name = [string]$win.name; size = [long]$win.size } } else { $latest['windows'] = $null }
    }
    return @{ repo = $name; description = [string]$Repo.description; url = $repoUrl; avatar = $avatar; latest = $latest }
}

# ---------------------------------------------------------------- installing starred apps
# Starred repos aren't built by DevStore, so their releases follow no format:
# any tag, any file names. These pick the newest stable release, the file in
# it that is a Windows download DevStore can install (a .zip or a portable
# .exe, never an installer), and the program inside it.

$script:StarredPrefix = 'starred-'

function Select-DevStoreStarredRelease {
    # Newest published, non-prerelease release (by publish date), whatever its tag.
    param($Releases)
    $flat = foreach ($x in @($Releases)) { if ($x -is [System.Array]) { foreach ($y in $x) { $y } } else { $x } }
    $ok = @($flat | Where-Object { $_ -and -not $_.draft -and -not $_.prerelease -and $_.tag_name })
    if (-not $ok.Count) { return $null }
    return @($ok | Sort-Object -Descending { [string]$_.published_at })[0]
}

function Get-DevStoreStarredAssetScore {
    # How likely a release file is the Windows build to install. $null = never.
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if ($n -notmatch '\.(zip|exe)$') { return $null }
    $isExe = $n.EndsWith('.exe')
    if ($n -match '(?<![a-z])(linux|darwin|mac|macos|osx|apple|android|ios|freebsd|openbsd|source|src|symbols|debug)(?![a-z])') { return $null }
    if ($n -match 'arm64|aarch64|(?<![a-z])arm(?![a-z])') { return $null }
    # Installers can't be run silently in a reliable way, so they stay "download in browser".
    if ($n -match 'setup|installer|(?<![a-z])install(?![a-z])|(?<![a-z])inst(?![a-z])') { return $null }
    $windows = $n -match '(?<![a-z])win(dows)?(32|64)?(?![a-z])|(?<![a-z])pc(?![a-z])'
    if (-not $isExe -and -not $windows) { return $null }   # a zip with no Windows in its name could be anything
    $score = 0
    if ($windows) { $score += 10 }
    if ($isExe) { $score += 2 }
    if ($n -match 'x86[_-]64|x64|amd64|win64|64-?bit') { $score += 5 }
    elseif ($n -match '(?<![a-z0-9])(x86|i[36]86|ia32|32-?bit)(?![a-z0-9])') { $score -= 5 }
    if ($n -match 'portable') { $score += 3 }
    return $score
}

function Select-DevStoreStarredAsset {
    # The release file to install on this PC, or $null when there is none.
    param($Assets)
    $best = $null
    $bestScore = $null
    foreach ($a in @($Assets)) {
        if ($null -eq $a -or -not $a.name) { continue }
        $score = Get-DevStoreStarredAssetScore -Name ([string]$a.name)
        if ($null -eq $score) { continue }
        if ($null -eq $bestScore -or $score -gt $bestScore) { $best = $a; $bestScore = $score }
    }
    return $best
}

# ---- a set of files per release (an exe plus its libraries, say)
$script:VersionTokenPattern = '(?<![A-Za-z0-9])(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)+)'
$script:AssetSystemWords = 'windows|win32|win64|win|x64|x86_64|x86-64|x86|amd64|i686|i586|i386|ia32|32-bit|64-bit|32bit|64bit|mingw64|mingw32|mingw|msvc|ucrt|gnu|pc|portable|unpatched|patched'
$script:AssetSkipWords = 'headers|include|sdk|docs|web|wasm|browser|checksums|sha256|sha256sums|sig|signature'
$script:AssetVariantWords = 'unpatched|legacy|lite|noavx|old|compat'
$script:StarredMaxFiles = 4
$script:StarredMaxBytes = 600MB

function Get-DevStoreAssetBaseName {
    # 'prx-windows-unpatched-v0.1.5.zip' -> 'prx': the file's name without its extension,
    # version, system and variant words. Files with the same base name are versions of one thing.
    param([string]$Name, [string]$Tag)
    $n = ($Name.ToLowerInvariant() -replace '\.(zip|exe)$', '')
    if ($Tag) { $n = [regex]::Replace($n, [regex]::Escape($Tag.ToLowerInvariant()), ' ') }
    $n = [regex]::Replace($n, $script:VersionTokenPattern, ' ')
    $n = [regex]::Replace($n, "(?<![a-z0-9])($($script:AssetSystemWords))(?![a-z0-9])", ' ')
    $n = [regex]::Replace($n, '[-_. ]+', '-').Trim('-')
    return $n
}

function ConvertTo-DevStoreStandaloneExeName {
    # 'relinker-v0.1.5.exe' -> 'relinker.exe', so the command is the same after every update.
    param([string]$Name, [string]$Tag)
    $stem = ($Name -replace '\.exe$', '')
    $clean = $stem
    if ($Tag) { $clean = [regex]::Replace($clean, '[-_. ]*' + [regex]::Escape($Tag) + '$', '', 'IgnoreCase') }
    $clean = [regex]::Replace($clean, '[-_. ]*' + $script:VersionTokenPattern + '$', '', 'IgnoreCase')
    if (-not $clean) { return $Name }
    return "$clean.exe"
}

function ConvertTo-DevStoreAssetPattern {
    # 'relinker-v0.1.5.exe' -> 'relinker-*.exe': the version becomes *, so the choice carries to the next release.
    param([string]$Name, [string]$Tag)
    $ms = [regex]::Matches($Name, $script:VersionTokenPattern)
    if ($ms.Count -gt 0) {
        $m = $ms[$ms.Count - 1]
        return $Name.Substring(0, $m.Index) + '*' + $Name.Substring($m.Index + $m.Length)
    }
    return $Name
}

function Test-DevStoreAssetPattern {
    # True when $Name is $Pattern, with * standing for exactly one version token (not a glob).
    param([string]$Pattern, [string]$Name)
    $rx = '^' + ([regex]::Escape($Pattern) -replace '\\\*', "(?:$($script:VersionTokenPattern))") + '$'
    return [regex]::IsMatch($Name, $rx, 'IgnoreCase')
}

function Set-DevStoreStarredFiles {
    # The files the user chose for a starred repo (config.starredFiles[repo]); -Clear goes back to automatic.
    param([hashtable]$Config, [string]$Repo, [string[]]$Patterns = @(), [string]$Main = '', [bool]$Clear = $false)
    $map = @{}
    if ($Config.ContainsKey('starredFiles') -and $Config['starredFiles'] -is [hashtable]) {
        foreach ($k in $Config['starredFiles'].Keys) { if ($k -ine $Repo) { $map[$k] = $Config['starredFiles'][$k] } }
    }
    if (-not $Clear) { $map[$Repo] = @{ patterns = @($Patterns); main = $Main } }
    $Config['starredFiles'] = $map
    return $Config
}

function Get-DevStoreStarredFiles {
    # @{ patterns; main } the user chose for this repo, or $null (automatic).
    param([hashtable]$Config, [string]$Repo)
    if (-not $Config.ContainsKey('starredFiles') -or $Config['starredFiles'] -isnot [hashtable]) { return $null }
    foreach ($k in $Config['starredFiles'].Keys) {
        if ($k -ieq $Repo) { return $Config['starredFiles'][$k] }
    }
    return $null
}

function Select-DevStoreStarredAssets {
    # The Windows files of a release to install together. Returns
    # @{ assets = @(...); error = <string or $null> }; an empty set without an error
    # means the release has nothing DevStore can install.
    param($Assets, [string]$Tag, $Override = $null)
    if ($null -ne $Override) {
        $picked = @()
        foreach ($pattern in @($Override['patterns'])) {
            $hits = @(@($Assets) | Where-Object { $_ -and $_.name -and (Test-DevStoreAssetPattern -Pattern ([string]$pattern) -Name ([string]$_.name)) })
            if ($hits.Count -eq 0) { return @{ assets = @(); error = "Your chosen file $pattern is not in $Tag." } }
            if ($hits.Count -gt 1) { return @{ assets = @(); error = "Your chosen file $pattern matches more than one file in $Tag." } }
            $picked += $hits[0]
        }
        return @{ assets = $picked; error = $null }
    }
    $groups = @{}
    foreach ($a in @($Assets)) {
        if ($null -eq $a -or -not $a.name) { continue }
        $name = [string]$a.name
        $score = Get-DevStoreStarredAssetScore -Name $name
        if ($null -eq $score) { continue }
        $lower = $name.ToLowerInvariant()
        if ($lower -match "(?<![a-z0-9])($($script:AssetSkipWords))(?![a-z0-9])") { continue }
        if ($lower -match "(?<![a-z0-9])($($script:AssetVariantWords))(?![a-z0-9])") { $score -= 20 }
        $base = Get-DevStoreAssetBaseName -Name $name -Tag $Tag
        if (-not $base) { $base = $lower }
        $cur = $groups[$base]
        if ($null -eq $cur -or $score -gt $cur.score -or ($score -eq $cur.score -and $name.Length -lt ([string]$cur.asset.name).Length)) {
            $groups[$base] = @{ asset = $a; score = $score }
        }
    }
    $chosen = @($groups.Keys | Sort-Object | ForEach-Object { $groups[$_].asset })
    if (-not $chosen.Count) {
        # The set rules skip some words (web, docs, sdk...) that an ordinary app name can contain:
        # whatever the old one-file rule installs, still installs.
        $single = Select-DevStoreStarredAsset -Assets $Assets
        if ($single) { $chosen = @($single) }
    }
    $bytes = [long]0
    foreach ($a in $chosen) { $bytes += [long]$a.size }
    if ($chosen.Count -gt $script:StarredMaxFiles -or $bytes -gt $script:StarredMaxBytes) {
        $mb = [math]::Round($bytes / 1MB)
        return @{ assets = @(); error = "This release has more Windows files than DevStore installs by itself ($($chosen.Count) files, $mb MB). Use Choose files… to pick what you need." }
    }
    return @{ assets = $chosen; error = $null }
}

function Get-DevStorePeSubsystem {
    # 'cli' for a console program, 'gui' for everything else, including files that aren't readable programs.
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 0x40) { return 'gui' }
    if ($Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { return 'gui' }
    $pe = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($pe -lt 0 -or ($pe + 24 + 70) -gt $Bytes.Length) { return 'gui' }
    if ($Bytes[$pe] -ne 0x50 -or $Bytes[$pe + 1] -ne 0x45 -or $Bytes[$pe + 2] -ne 0 -or $Bytes[$pe + 3] -ne 0) { return 'gui' }
    if ([BitConverter]::ToUInt16($Bytes, $pe + 24 + 68) -eq 3) { return 'cli' }
    return 'gui'
}

function Get-DevStorePeSubsystemOfFile {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4096
            $n = $fs.Read($buf, 0, $buf.Length)
            $head = New-Object byte[] $n
            [Array]::Copy($buf, $head, $n)
        }
        finally { $fs.Dispose() }
        return (Get-DevStorePeSubsystem -Bytes $head)
    }
    catch { return 'gui' }
}

function Get-DevStoreCliShortcutArguments {
    # powershell.exe arguments for a command-line tool's shortcut: a terminal in the app's folder,
    # with that folder first on PATH for that window only.
    param([string]$Dir)
    $q = $Dir.Replace("'", "''")
    return "-NoExit -NoProfile -ExecutionPolicy Bypass -Command `"`$env:Path = '$q;' + `$env:Path; Set-Location -LiteralPath '$q'`""
}

function Get-DevStoreStarredFolderName {
    # The version folder of a release built from a user-chosen set of files: '<tag>-<4 hex of the chosen names>'.
    param([string]$Tag, [string[]]$Names)
    $joined = (@($Names | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join '|')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hex = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    return (ConvertTo-DevStoreVersionFolder $Tag) + '-' + $hex.Substring(0, 4)
}

function Select-DevStoreStarredExe {
    # The program to open from an unpacked release: @(@{ path = 'sub\app.exe'; size }) -> 'sub\app.exe'.
    # Skips uninstallers, updaters, crash reporters and helpers; prefers the repo's
    # name, then files near the top, then the biggest.
    param($Files, [string]$Repo)
    $norm = { param($t) ($t.ToLowerInvariant() -replace '[^a-z0-9]', '') }
    $want = & $norm (($Repo -split '/')[-1])
    $best = $null
    $bestKey = $null
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        $path = ([string]$f['path']) -replace '/', '\'
        $leaf = ($path -split '\\')[-1].ToLowerInvariant()
        if ($leaf -notmatch '\.exe$') { continue }
        if ($leaf -match '^(unins|uninstall)|setup|installer|^update(r)?\.exe$|crash|helper|vc_?redist|^createdump|^elevate') { continue }
        $stem = & $norm ($leaf -replace '\.exe$', '')
        $match = 0
        if ($want -and $stem -eq $want) { $match = 2 } elseif ($want -and $stem -and ($stem.Contains($want) -or $want.Contains($stem))) { $match = 1 }
        $depth = @($path -split '\\').Count
        $key = @($match, (-$depth), [long]$f['size'])
        $better = $false
        if ($null -eq $bestKey) { $better = $true }
        else {
            for ($i = 0; $i -lt 3; $i++) {
                if ($key[$i] -gt $bestKey[$i]) { $better = $true; break }
                if ($key[$i] -lt $bestKey[$i]) { break }
            }
        }
        if ($better) { $best = $path; $bestKey = $key }
    }
    return $best
}

function ConvertTo-DevStoreStarredAppName {
    # 'Some.One/My_Tool' -> 'starred-some-one--my-tool': the app's folder under apps\.
    param([string]$Repo)
    $parts = $Repo.ToLowerInvariant() -split '/'
    $clean = @($parts | ForEach-Object { ($_ -replace '[^a-z0-9]+', '-').Trim('-') })
    return $script:StarredPrefix + ($clean -join '--')
}

function ConvertTo-DevStoreVersionFolder {
    # A release tag as a safe folder name ('v1.2/beta' -> 'v1.2-beta').
    param([string]$Tag)
    $f = ($Tag -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.')
    if (-not $f) { $f = 'release' }
    if ($f.Length -gt 60) { $f = $f.Substring(0, 60) }
    return $f
}

function Get-DevStoreAssetSha256 {
    # GitHub's own sha256 for a release file ('digest': 'sha256:<hex>'), or $null.
    param($Asset)
    $d = [string](Get-DevStoreProperty -Object $Asset -Name 'digest')
    if ($d -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1] }
    return $null
}

function Get-DevStoreStarredAutoInstall {
    # Which starred repos to install by themselves: ones starred since the last
    # look (not in $Known) that have a Windows download, when auto-install is on.
    # The first look only remembers what's there, so turning it on never installs
    # everything you starred before. Returns @{ install = @(repos); known = @(repos) }.
    param($Repos, $Known, [hashtable]$Config)
    $now = @(@($Repos) | Where-Object { $_ -and $_['repo'] } | ForEach-Object { [string]$_['repo'] })
    $install = @()
    if ($null -ne $Known -and $Config['starredAutoInstall'] -eq $true) {
        $configured = @(@($Config['apps']) | Where-Object { $_ } | ForEach-Object { [string]$_['repo'] })
        foreach ($r in @($Repos)) {
            if (-not $r -or -not $r['repo']) { continue }
            $name = [string]$r['repo']
            if (@($Known | Where-Object { $_ -ieq $name }).Count) { continue }
            if (@($configured | Where-Object { $_ -ieq $name }).Count) { continue }
            $latest = $r['latest']
            if ($latest -is [hashtable] -and $latest['windows']) {
                # Several files need a click: automatic installs stay as simple as they always were.
                if ($latest.ContainsKey('windowsFiles') -and @($latest['windowsFiles']).Count -ne 1) { continue }
                $install += $name
            }
        }
    }
    return @{ install = $install; known = $now }
}

# ---------------------------------------------------------------- Docker apps on the NAS

$script:DockerTagPattern = '^docker-v(\d+\.\d+\.\d+)$'
$script:NasUrlPattern = '^https?://[A-Za-z0-9.-]+(:\d{1,5})?/?$'

function Get-DevStoreProperty {
    # $Object.$Name, or $null when it isn't there (strict mode throws on missing properties).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

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
            $c = @($Containers | Where-Object { (Get-DevStoreProperty $_ 'image') -and (ConvertTo-DevStoreImageName ([string](Get-DevStoreProperty $_ 'image'))) -eq $d['image'] }) | Select-Object -First 1
        }
        if ($c) {
            $entry['container'] = [string](Get-DevStoreProperty $c 'name')
            $published = $null
            try { $published = [DateTimeOffset]::Parse([string]$d['publishedAt'], [Globalization.CultureInfo]::InvariantCulture) } catch { $published = $null }
            $running = Get-DevStoreProperty $c 'running'
            if ($null -ne $running -and -not $running) { $entry['status'] = 'stopped' }
            elseif ((Get-DevStoreProperty $c 'stale') -or $null -eq $scan -or ($published -and $scan -lt $published)) { $entry['status'] = 'pending' }
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

# ---------------------------------------------------------------- per-platform listing

$script:AndroidTagPattern = '^android-v(.+)\+(\d+)$'
$script:Platforms = @('windows', 'android', 'docker')

function Get-DevStoreAndroidRelease {
    # The newest published android-v<versionName>+<versionCode> release (by versionCode).
    param($Releases)
    $best = $null
    $bestCode = -1
    $bestName = $null
    foreach ($r in @($Releases)) {
        if ($null -eq $r -or (Get-DevStoreProperty $r 'draft') -or (Get-DevStoreProperty $r 'prerelease')) { continue }
        $m = [regex]::Match([string](Get-DevStoreProperty $r 'tag_name'), $script:AndroidTagPattern)
        if (-not $m.Success) { continue }
        $code = [int]$m.Groups[2].Value
        if ($code -gt $bestCode) { $best = $r; $bestCode = $code; $bestName = $m.Groups[1].Value }
    }
    if ($null -eq $best) { return $null }
    return @{ version = $bestName; code = $bestCode; tag = [string]$best.tag_name
        publishedAt = (ConvertTo-DevStoreUtcText (Get-DevStoreProperty $best 'published_at')) }
}

function Select-DevStorePlatformShots {
    # Screenshots per platform from a repo's file list: store/screenshots/<windows|android|docker>/*.png,
    # next to the app's devstore.json or at the repo root. Up to 6 each, sorted by name.
    param([string[]]$Paths)
    $Paths = @($Paths)
    $manifest = @($Paths | Where-Object { $_ -match '(^|/)devstore\.json$' } | Sort-Object { $_.Length }) | Select-Object -First 1
    $prefixes = @('')
    if ($manifest -and $manifest -match '/') { $prefixes = @($manifest.Substring(0, $manifest.LastIndexOf('/') + 1), '') }
    $out = @{}
    foreach ($platform in $script:Platforms) {
        $shots = @()
        foreach ($pre in $prefixes) {
            if ($shots.Count) { break }
            $dir = "${pre}store/screenshots/$platform/"
            $shots = @($Paths | Where-Object {
                    $_.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) -and $_ -match '\.png$' -and $_.Substring($dir.Length) -notmatch '/'
                } | Sort-Object | Select-Object -First 6)
        }
        $out[$platform] = $shots
    }
    return $out
}

Export-ModuleMember -Function ConvertFrom-DevStoreTag, Select-DevStoreRelease, ConvertTo-DevStoreHashtable,
    Read-DevStoreJson, Write-DevStoreJson, Get-DevStoreAction, Get-DevStorePruneList, Test-DevStoreHash,
    New-DevStoreWinswXml, Test-DevStoreRepoName, Set-DevStoreConfigApp, ConvertTo-DevStoreSafeName,
    ConvertFrom-DevStoreRequest, Select-DevStoreStoreAssets, Get-DevStoreUpdateMode, Set-DevStoreConfigUpdates,
    ConvertFrom-DevStoreTokenText, ConvertTo-DevStoreTokenText, Set-DevStoreTokenEntry, Select-DevStoreRepoStoreFiles,
    ConvertFrom-DevStorePrTag, Get-DevStorePrBuilds, Select-DevStoreChannelRelease, Get-DevStoreReleaseVersion,
    Get-DevStoreChannel, Set-DevStoreConfigChannel, Test-DevStoreStarredDue, Get-DevStoreGitHubUrl,
    ConvertTo-DevStoreStarredEntry, Get-DevStoreDockerRelease, ConvertTo-DevStoreImageName, Get-DevStoreNasApps,
    Set-DevStoreConfigNas, ConvertTo-DevStoreUtcText, Get-DevStoreProperty,
    Get-DevStoreAndroidRelease, Select-DevStorePlatformShots,
    Select-DevStoreStarredRelease, Get-DevStoreStarredAssetScore, Select-DevStoreStarredAsset, Select-DevStoreStarredExe,
    Get-DevStoreAssetBaseName, ConvertTo-DevStoreStandaloneExeName, Select-DevStoreStarredAssets,
    Get-DevStoreStarredFolderName, Get-DevStorePeSubsystem, Get-DevStorePeSubsystemOfFile, Get-DevStoreCliShortcutArguments,
    ConvertTo-DevStoreAssetPattern, Test-DevStoreAssetPattern, Set-DevStoreStarredFiles, Get-DevStoreStarredFiles,
    ConvertTo-DevStoreStarredAppName, ConvertTo-DevStoreVersionFolder, Get-DevStoreAssetSha256, Get-DevStoreStarredAutoInstall
