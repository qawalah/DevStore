# DevStore.Agent: side effects for the DevStore Windows updater (GitHub API,
# downloads, junctions, services, shortcuts) plus the per-app update flow.
# Must stay compatible with Windows PowerShell 5.1.

Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'DevStore.Core.psm1')

$script:UserAgent = 'DevStore-Updater'
$script:HealthSeconds = 30

function Join-DevStorePath { [System.IO.Path]::Combine([string[]]$args) }

function Get-DevStoreTimestamp { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# ---------------------------------------------------------------- logging

function Write-DevStoreLog {
    param([string]$Root, [string]$Message, [string]$App = '-')
    $dir = Join-DevStorePath $Root 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-DevStorePath $dir ('updater-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $App, $Message
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- token

function Read-DevStoreTokens {
    # All GitHub accounts, main account first: @(@{login; token}, ...).
    param([string]$Root)
    $file = Join-DevStorePath $Root 'token.dat'
    if (-not (Test-Path -LiteralPath $file)) { throw "token.dat not found in $Root. Run DevStoreSetup.exe again." }
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String((Get-Content -LiteralPath $file -Raw).Trim())
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'LocalMachine')
    return @(ConvertFrom-DevStoreTokenText ([System.Text.Encoding]::UTF8.GetString($plain)))
}

function Write-DevStoreTokens {
    param([string]$Root, $List)
    Add-Type -AssemblyName System.Security
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-DevStoreTokenText $List))
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')
    Set-Content -LiteralPath (Join-DevStorePath $Root 'token.dat') -Value ([Convert]::ToBase64String($enc)) -Encoding ascii
}

# ---------------------------------------------------------------- GitHub

function Initialize-DevStoreHttp {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
}

function Get-DevStoreLogin {
    # The GitHub username a token belongs to (also checks the token works).
    param([string]$Token)
    Initialize-DevStoreHttp
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = $script:UserAgent }
    try {
        return [string](Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -Method Get -UseBasicParsing).login
    }
    catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) { throw 'GitHub rejected this token (HTTP 401). Check it was copied completely and has not expired.' }
        throw
    }
}

function Get-DevStoreReleases {
    param([string]$Repo, [string]$Token)
    Initialize-DevStoreHttp
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'User-Agent'           = $script:UserAgent
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$Repo/releases?per_page=30"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseBasicParsing
        $list = New-Object System.Collections.ArrayList
        foreach ($r in $resp) { [void]$list.Add($r) }   # foreach unrolls 5.1's single-array output
        return $list.ToArray()
    }
    catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 404) { throw "Repo $Repo not found, or the token can't read it (HTTP 404)." }
        if ($code -eq 401) { throw 'GitHub token rejected (HTTP 401). It may have expired: re-run Install-DevStoreAgent.ps1.' }
        throw
    }
}

function Get-DevStoreRepoTree {
    # Every file path in the repo at a tag (one API call).
    param([string]$Repo, [string]$Ref, [string]$Token)
    Initialize-DevStoreHttp
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = $script:UserAgent }
    $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/git/trees/$([uri]::EscapeDataString($Ref))?recursive=1" `
        -Headers $headers -Method Get -UseBasicParsing
    $paths = New-Object System.Collections.ArrayList
    foreach ($e in $resp.tree) { if ($e.type -eq 'blob') { [void]$paths.Add([string]$e.path) } }
    return $paths.ToArray()
}

function Save-DevStoreRepoFile {
    # Downloads one file from the repo at a tag.
    param([string]$Repo, [string]$Path, [string]$Ref, [string]$Token, [string]$OutFile)
    Initialize-DevStoreHttp
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github.raw'; 'User-Agent' = $script:UserAgent }
    $escaped = ($Path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/contents/$escaped`?ref=$([uri]::EscapeDataString($Ref))" `
        -Headers $headers -OutFile $OutFile -UseBasicParsing
}

function Save-DevStoreAsset {
    # Private release assets redirect to a signed storage URL. Windows
    # PowerShell 5.1 forwards the Authorization header on redirects, which the
    # storage host rejects, so follow the redirect manually without it.
    param([string]$Repo, [string]$AssetId, [string]$Token, [string]$OutFile)
    Initialize-DevStoreHttp
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "https://api.github.com/repos/$Repo/releases/assets/$AssetId")
        [void]$req.Headers.Add('Authorization', "Bearer $Token")
        [void]$req.Headers.Add('Accept', 'application/octet-stream')
        [void]$req.Headers.Add('User-Agent', $script:UserAgent)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        if ([int]$resp.StatusCode -ge 300 -and [int]$resp.StatusCode -lt 400) {
            $location = $resp.Headers.Location
            $resp.Dispose()
            $req2 = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $location)
            [void]$req2.Headers.Add('User-Agent', $script:UserAgent)
            $resp = $client.SendAsync($req2, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        }
        if (-not $resp.IsSuccessStatusCode) { throw "Download of asset $AssetId failed: HTTP $([int]$resp.StatusCode)" }
        $out = [System.IO.File]::Create($OutFile)
        try { [void]$resp.Content.CopyToAsync($out).GetAwaiter().GetResult() } finally { $out.Dispose() }
        $resp.Dispose()
    }
    finally {
        $client.Dispose()
    }
}

# ---------------------------------------------------------------- files

function Set-DevStoreJunction {
    # Points $Link (a directory junction) at $Target, replacing any old junction.
    param([string]$Link, [string]$Target)
    if (Test-Path -LiteralPath $Link) {
        # Directory.Delete on a junction removes only the link, never the target's files.
        [System.IO.Directory]::Delete($Link)
    }
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
}

function Get-DevStoreJunctionTarget {
    param([string]$Link)
    if (-not (Test-Path -LiteralPath $Link)) { return $null }
    $t = (Get-Item -LiteralPath $Link).Target
    return @($t)[0]
}

function Test-DevStoreGuiRunning {
    # True if any process runs an exe from inside the app's folder.
    param([string]$AppDir)
    $prefix = $AppDir.TrimEnd('\') + '\'
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $p = $null
        try { $p = $_.Path } catch { }
        $p -and $p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return [bool]$running
}

function Test-DevStoreOldProcessRunning {
    # True if a process from the app's folder started before $Since (UTC ISO time),
    # i.e. an old copy that hasn't been restarted since an update.
    param([string]$AppDir, [string]$Since)
    $cut = [datetime]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    $prefix = $AppDir.TrimEnd('\') + '\'
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null; $start = $null
        try { $path = $p.Path; $start = $p.StartTime } catch { }
        if ($path -and $start -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $start.ToUniversalTime() -lt $cut) { return $true }
    }
    return $false
}

function New-DevStoreShortcut {
    param([string]$DisplayName, [string]$Target)
    $dir = Join-DevStorePath $env:ProgramData 'Microsoft' 'Windows' 'Start Menu' 'Programs' 'DevStore'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-DevStorePath $dir "$DisplayName.lnk"))
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = Split-Path -Parent $Target
    $lnk.Save()
}

function Remove-DevStoreShortcut {
    param([string]$DisplayName)
    $file = Join-DevStorePath $env:ProgramData 'Microsoft' 'Windows' 'Start Menu' 'Programs' 'DevStore' "$DisplayName.lnk"
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

# ---------------------------------------------------------------- services (WinSW)

function Get-DevStoreServicePaths {
    param([string]$Root, [string]$Name)
    $dir = Join-DevStorePath $Root 'apps' $Name 'service'
    return @{
        Dir = $dir
        Exe = Join-DevStorePath $dir "devstore-$Name.exe"
        Xml = Join-DevStorePath $dir "devstore-$Name.xml"
    }
}

function Install-DevStoreService {
    param([string]$Root, [string]$Name, [string]$Exe)
    $p = Get-DevStoreServicePaths -Root $Root -Name $Name
    if (-not (Test-Path -LiteralPath $p.Dir)) { New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-DevStorePath $Root 'tools' 'winsw.exe') -Destination $p.Exe -Force
    $logDir = Join-DevStorePath $Root 'logs' $Name
    $exePath = Join-DevStorePath $Root 'apps' $Name 'current' $Exe
    Set-Content -LiteralPath $p.Xml -Value (New-DevStoreWinswXml -Name $Name -Exe $exePath -LogDir $logDir) -Encoding UTF8
    if (-not (Get-Service -Name "devstore-$Name" -ErrorAction SilentlyContinue)) {
        & $p.Exe install | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "WinSW install failed for devstore-$Name (exit $LASTEXITCODE)" }
    }
}

function Uninstall-DevStoreService {
    param([string]$Root, [string]$Name)
    $p = Get-DevStoreServicePaths -Root $Root -Name $Name
    if (Get-Service -Name "devstore-$Name" -ErrorAction SilentlyContinue) {
        Stop-DevStoreService -Name $Name
        & $p.Exe uninstall | Out-Null
    }
}

function Stop-DevStoreService {
    param([string]$Name)
    $svc = Get-Service -Name "devstore-$Name" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Stopped') { return }
    Stop-Service -Name "devstore-$Name" -Force -NoWait -ErrorAction SilentlyContinue
    try {
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    catch {
        throw "devstore-$Name did not stop within 30 seconds"
    }
}

function Start-DevStoreServiceHealthy {
    # Starts the service and returns $true only if the app process (a child of
    # the WinSW wrapper) has stayed alive for the whole health window.
    param([string]$Name, [string]$Exe)
    try {
        Start-Service -Name "devstore-$Name" -ErrorAction Stop
    }
    catch {
        return $false
    }
    $deadline = (Get-Date).AddSeconds($script:HealthSeconds)
    $firstPid = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $svc = Get-CimInstance Win32_Service -Filter "Name='devstore-$Name'"
        if (-not $svc -or $svc.State -ne 'Running') { return $false }
        $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.ProcessId)" |
            Where-Object { $_.Name -ieq $Exe } | Select-Object -First 1
        if (-not $child) { return $false }
        if ($null -eq $firstPid) { $firstPid = $child.ProcessId }
        elseif ($child.ProcessId -ne $firstPid) { return $false }   # crashed and was restarted
    }
    return $true
}

# ---------------------------------------------------------------- update flow

function Select-DevStoreHashtable {
    # PowerShell functions return everything a command prints, not just the
    # 'return' value. Keep only the last hashtable (repairs entries that 1.0.0
    # saved as [null, null, {...}]).
    param($Value)
    $found = $null
    foreach ($v in @($Value)) { if ($v -is [hashtable]) { $found = $v } }
    return $found
}

function Copy-DevStoreAppState {
    param($AppState)
    $AppState = Select-DevStoreHashtable $AppState
    $s = @{ bad = @() }
    if ($null -ne $AppState) {
        foreach ($k in @($AppState.Keys)) { $s[$k] = $AppState[$k] }
    }
    if ($null -eq $s['bad']) { $s['bad'] = @() }
    $s['bad'] = @($s['bad'])
    foreach ($k in 'name', 'type', 'exe', 'displayName', 'installed', 'previous', 'latest', 'status', 'lastError') {
        if (-not $s.ContainsKey($k)) { $s[$k] = $null }
    }
    foreach ($k in 'updateWhileRunning', 'restartPending') {
        $s[$k] = [bool]($s.ContainsKey($k) -and $s[$k])
    }
    return $s
}

function Update-DevStoreApp {
    # Brings one app up to date. Never throws: failures end up in status/lastError.
    # -Mode: 'auto' installs updates, 'download' only downloads them (status
    # 'ready'), 'notify' only reports them (status 'available'). -Apply installs
    # a waiting update now. A first install always happens.
    param([string]$Repo, $AppState, [string]$Root, [string]$Token, $Releases = $null,
        [string]$Mode = 'auto', [switch]$Apply, [string]$Channel = 'stable')
    $s = Copy-DevStoreAppState $AppState
    $s['lastChecked'] = Get-DevStoreTimestamp
    $logName = $Repo
    try {
        if ($null -eq $Releases) { $Releases = Get-DevStoreReleases -Repo $Repo -Token $Token }
        # 'stable', or 'pr-<N>' to follow a pull request's test builds.
        $s['channel'] = $Channel
        $release = Select-DevStoreChannelRelease -Releases $Releases -Channel $Channel -Bad $s['bad']
        $s['channelMissing'] = [bool]($Channel -ne 'stable' -and $release -and -not (ConvertFrom-DevStorePrTag $release.tag_name))
        if ($null -eq $release) {
            if (-not $s['installed']) {
                $s['status'] = 'error'
                $s['lastError'] = 'No windows-v release found yet.'
            }
            return $s
        }
        $version = Get-DevStoreReleaseVersion $release
        if (-not (ConvertFrom-DevStorePrTag $release.tag_name)) { $s['latest'] = $version }
        $action = Get-DevStoreAction -AppState $s -Version $version
        # Switching between stable and a test build is the user's explicit choice: apply it now.
        $installedPr = $null
        if ([string]$s['installed'] -match '-pr(\d+)\.') { $installedPr = [int]$Matches[1] }
        $releasePr = $null
        $prTag = ConvertFrom-DevStorePrTag $release.tag_name
        if ($prTag) { $releasePr = $prTag.pr }
        if ($action -eq 'update' -and $installedPr -ne $releasePr) { $Apply = $true }
        if ($action -eq 'none') {
            if ($s['status'] -ne 'rolledback') { $s['status'] = 'ok'; $s['lastError'] = $null }
            if ($s['restartPending'] -and $s['name']) {
                # Still waiting only while a copy started before the update is running.
                # (Older state has no updatedAt: drop the stale flag.)
                $s['restartPending'] = $false
                if ($s.ContainsKey('updatedAt') -and $s['updatedAt']) {
                    $s['restartPending'] = Test-DevStoreOldProcessRunning -AppDir (Join-DevStorePath $Root 'apps' $s['name']) -Since $s['updatedAt']
                }
            }
            return $s
        }

        $zipAsset = @($release.assets | Where-Object { $_.name -like "*-$version-win-x64.zip" }) | Select-Object -First 1
        if (-not $zipAsset) { throw "Release $($release.tag_name) has no *-$version-win-x64.zip asset." }
        $shaAsset = @($release.assets | Where-Object { $_.name -eq "$($zipAsset.name).sha256" }) | Select-Object -First 1
        if (-not $shaAsset) { throw "Release $($release.tag_name) has no $($zipAsset.name).sha256 asset." }
        $name = $zipAsset.name.Substring(0, $zipAsset.name.Length - "-$version-win-x64.zip".Length)
        if ($s['name'] -and $s['name'] -ne $name) { throw "Release name '$name' doesn't match installed app '$($s['name'])'." }
        if ($name -notmatch '^[a-z0-9-]+$') { throw "Invalid app name '$name' in release asset." }
        $logName = $name
        $appDir = Join-DevStorePath $Root 'apps' $name

        $waitForUser = ($action -eq 'update' -and -not $Apply)
        if ($waitForUser -and $Mode -eq 'notify') {
            if ($s['status'] -ne 'available') { Write-DevStoreLog -Root $Root -App $name -Message "v$version is available" }
            $s['status'] = 'available'
            return $s
        }

        # Download, verify and extract once per version (.verified marks a complete copy).
        $versionsDir = Join-DevStorePath $appDir 'versions'
        $target = Join-DevStorePath $versionsDir $version
        $verified = Join-DevStorePath $target '.verified'
        if (-not (Test-Path -LiteralPath $verified)) {
            $dl = Join-DevStorePath $Root 'downloads'
            if (-not (Test-Path -LiteralPath $dl)) { New-Item -ItemType Directory -Path $dl -Force | Out-Null }
            $zip = Join-DevStorePath $dl $zipAsset.name
            $sha = "$zip.sha256"
            Save-DevStoreAsset -Repo $Repo -AssetId $zipAsset.id -Token $Token -OutFile $zip
            Save-DevStoreAsset -Repo $Repo -AssetId $shaAsset.id -Token $Token -OutFile $sha
            $hashOk = Test-DevStoreHash -File $zip -ShaText (Get-Content -LiteralPath $sha -Raw)
            if (-not $hashOk) {
                Remove-Item -LiteralPath $zip, $sha -Force -ErrorAction SilentlyContinue
                throw "Downloaded $($zipAsset.name) failed its sha256 hash check; will retry next run."
            }
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
            Remove-Item -LiteralPath $zip, $sha -Force -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $verified -Value $version
        }
        $manifest = Read-DevStoreJson -Path (Join-DevStorePath $target 'devstore.json') -Default $null
        if ($null -eq $manifest) { throw "devstore.json missing from the $version build." }
        if ($manifest['name'] -ne $name) { throw "devstore.json name '$($manifest['name'])' doesn't match '$name'." }
        $type = $manifest['type']
        if ($type -notin @('gui', 'service')) { throw "devstore.json type '$type' is not gui or service." }
        $exe = "$name.exe"
        if (-not (Test-Path -LiteralPath (Join-DevStorePath $target $exe))) { throw "$exe missing from the $version build." }

        if ($waitForUser -and $Mode -eq 'download') {
            if ($s['status'] -ne 'ready') { Write-DevStoreLog -Root $Root -App $name -Message "v$version downloaded, ready to install" }
            $s['status'] = 'ready'
            return $s
        }

        # Tray/background GUI apps can opt in to updating while they run
        # ("updateWhileRunning" in devstore.json): the new version starts next launch.
        $running = ($action -eq 'update' -and $s['type'] -eq 'gui' -and (Test-DevStoreGuiRunning -AppDir $appDir))
        if ($running -and -not $s['updateWhileRunning']) {
            if ($s['status'] -ne 'pending') { Write-DevStoreLog -Root $Root -App $name -Message "v$version waiting for the app to close" }
            $s['status'] = 'pending'
            return $s
        }

        $displayName = $name
        if ($manifest.ContainsKey('displayName') -and $manifest['displayName']) { $displayName = $manifest['displayName'] }

        $current = Join-DevStorePath $appDir 'current'
        $old = $s['installed']

        if ($action -eq 'install') {
            Set-DevStoreJunction -Link $current -Target $target
            if ($type -eq 'service') {
                Install-DevStoreService -Root $Root -Name $name -Exe $exe
                if (-not (Start-DevStoreServiceHealthy -Name $name -Exe $exe)) {
                    Uninstall-DevStoreService -Root $Root -Name $name
                    $s['bad'] = @($s['bad']) + $version
                    throw "v$version didn't stay running for $($script:HealthSeconds) s after install; marked bad."
                }
            }
            else {
                New-DevStoreShortcut -DisplayName $displayName -Target (Join-DevStorePath $current $exe)
            }
            Write-DevStoreLog -Root $Root -App $name -Message "installed v$version"
        }
        else {
            $oldTarget = Join-DevStorePath $versionsDir $old
            if ($type -eq 'service') {
                Stop-DevStoreService -Name $name
                Set-DevStoreJunction -Link $current -Target $target
                if (-not (Start-DevStoreServiceHealthy -Name $name -Exe $exe)) {
                    Stop-DevStoreService -Name $name
                    Set-DevStoreJunction -Link $current -Target $oldTarget
                    $restored = Start-DevStoreServiceHealthy -Name $name -Exe $exe
                    $s['bad'] = @($s['bad']) + $version
                    $s['status'] = 'rolledback'
                    $s['lastError'] = "v$version didn't stay running for $($script:HealthSeconds) s; rolled back to v$old."
                    if (-not $restored) { $s['lastError'] += " v$old also failed to start." }
                    Write-DevStoreLog -Root $Root -App $name -Message $s['lastError']
                    return $s
                }
            }
            else {
                Set-DevStoreJunction -Link $current -Target $target
                New-DevStoreShortcut -DisplayName $displayName -Target (Join-DevStorePath $current $exe)
            }
            if ($running) {
                Write-DevStoreLog -Root $Root -App $name -Message "updated v$old -> v$version (app is running; the new version starts next time it's opened)"
            }
            else {
                Write-DevStoreLog -Root $Root -App $name -Message "updated v$old -> v$version"
            }
        }

        $s['name'] = $name
        $s['type'] = $type
        $s['exe'] = $exe
        $s['displayName'] = $displayName
        $s['updateWhileRunning'] = [bool]($manifest.ContainsKey('updateWhileRunning') -and $manifest['updateWhileRunning'])
        $s['restartPending'] = [bool]$running
        if ($running) { $s['updatedAt'] = Get-DevStoreTimestamp }
        $s['previous'] = $old
        $s['installed'] = $version
        $s['status'] = 'ok'
        $s['lastError'] = $null

        if ($running) { return $s }   # never delete old folders while the app may still use one
        $existing = @(Get-ChildItem -LiteralPath $versionsDir -Directory | ForEach-Object { $_.Name })
        foreach ($v in (Get-DevStorePruneList -Versions $existing -Current $version -Previous $old)) {
            Remove-Item -LiteralPath (Join-DevStorePath $versionsDir $v) -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $s
    }
    catch {
        $s['status'] = 'error'
        $s['lastError'] = $_.Exception.Message
        try { Write-DevStoreLog -Root $Root -App $logName -Message "error: $($s['lastError'])" } catch { }
        return $s
    }
}

function Get-DevStoreAccessibleRepos {
    # Every repo the token can read (up to 300), most recently pushed first.
    param([string]$Token)
    Initialize-DevStoreHttp
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'User-Agent'           = $script:UserAgent
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $all = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le 3; $page++) {
        try {
            $resp = Invoke-RestMethod -Uri "https://api.github.com/user/repos?per_page=100&sort=pushed&page=$page" -Headers $headers -Method Get -UseBasicParsing
        }
        catch {
            # A GitHub App token (used by DevStore's own CI test) can't call /user/repos.
            if ($page -ne 1) { throw }
            $resp = (Invoke-RestMethod -Uri 'https://api.github.com/installation/repositories?per_page=100' -Headers $headers -Method Get -UseBasicParsing).repositories
        }
        $count = 0
        foreach ($r in $resp) { [void]$all.Add($r); $count++ }   # foreach unrolls 5.1's single-array output
        if ($count -lt 100) { break }
    }
    return $all.ToArray()
}

function Remove-DevStoreAppCore {
    # Uninstalls an app's service, shortcut and program files and drops its state.
    # Data in %ProgramData%\<name> is kept.
    param([string]$Root, [string]$Repo, [hashtable]$State)
    if (-not $State.ContainsKey('apps') -or $State['apps'] -isnot [hashtable]) { $State['apps'] = @{} }
    $key = @($State['apps'].Keys | Where-Object { $_ -ieq $Repo }) | Select-Object -First 1
    if (-not $key) { return }
    $app = Select-DevStoreHashtable $State['apps'][$key]
    if ($app -and $app['name']) {
        $name = $app['name']
        if ($app['type'] -eq 'service') { Uninstall-DevStoreService -Root $Root -Name $name }
        $display = $name
        if ($app['displayName']) { $display = $app['displayName'] }
        Remove-DevStoreShortcut -DisplayName $display
        $appDir = Join-DevStorePath $Root 'apps' $name
        $current = Join-DevStorePath $appDir 'current'
        if (Test-Path -LiteralPath $current) { [System.IO.Directory]::Delete($current) }
        if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
        Write-DevStoreLog -Root $Root -App $name -Message "removed (data in $env:ProgramData\$name kept)"
    }
    $State['apps'].Remove($key)
}

function Invoke-DevStoreRequests {
    # Applies install/remove/check requests the Manager dropped in <Root>\requests.
    param([string]$Root, [hashtable]$Config, [hashtable]$State = @{ apps = @{} })
    $dir = Join-DevStorePath $Root 'requests'
    $changed = $false
    $check = $false
    $apply = @()
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object LastWriteTime)) {
            $req = ConvertFrom-DevStoreRequest (Read-DevStoreJson -Path $f.FullName -Default $null)
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            if ($null -eq $req) { Write-DevStoreLog -Root $Root -Message "ignored an invalid request ($($f.Name))"; continue }
            switch ($req['action']) {
                'install' {
                    $Config = Set-DevStoreConfigApp -Config $Config -Repo $req['repo'] -Present $true
                    Write-DevStoreLog -Root $Root -App $req['repo'] -Message 'install requested'
                }
                'remove' {
                    Remove-DevStoreAppCore -Root $Root -Repo $req['repo'] -State $State
                    $Config = Set-DevStoreConfigApp -Config $Config -Repo $req['repo'] -Present $false
                }
                'check' { $check = $true }
                'apply' { $apply += $req['repo'] }
                'set-channel' {
                    $Config = Set-DevStoreConfigChannel -Config $Config -Repo $req['repo'] -Channel $req['channel']
                    $apply += $req['repo']
                    Write-DevStoreLog -Root $Root -App $req['repo'] -Message "now following $($req['channel'] -replace '^pr-', 'test builds of PR #')"
                }
                'set-updates' {
                    $Config = Set-DevStoreConfigUpdates -Config $Config -Repo $req['repo'] -Mode $req['mode']
                    $what = 'new apps'
                    if ($req['repo']) { $what = $req['repo'] }
                    Write-DevStoreLog -Root $Root -Message "updates for $what set to $($req['mode'])"
                }
            }
            $changed = $true
        }
    }
    return @{ config = $Config; changed = $changed; check = $check; apply = $apply }
}

function Update-DevStoreCatalog {
    # Finds every repo with a Windows release and writes catalog.json for the
    # Manager's Discover page. Store files (icon, screenshots) are cached per
    # version in <Root>\catalog\<owner__repo>. Fills $ReleaseCache[repo].
    param([string]$Root, $Tokens, [hashtable]$ReleaseCache = @{}, [hashtable]$RepoTokens = @{})
    $catPath = Join-DevStorePath $Root 'catalog.json'
    $old = Read-DevStoreJson -Path $catPath -Default @{}
    $oldApps = @{}
    if ($old.ContainsKey('apps') -and $old['apps'] -is [hashtable]) { $oldApps = $old['apps'] }
    $apps = @{}
    $Tokens = @($Tokens)
    $main = $Tokens[0]['login']
    if (-not $main) {
        # Unknown main account (older token entry, or a token that can't read /user): nothing is marked shared.
        try { $main = Get-DevStoreLogin -Token $Tokens[0]['token'] } catch { $main = $null }
    }
    # Each repo is read with the first account that can see it.
    $seen = New-Object System.Collections.ArrayList
    foreach ($account in $Tokens) {
        try { $listed = @(Get-DevStoreAccessibleRepos -Token $account['token']) }
        catch { Write-DevStoreLog -Root $Root -Message "couldn't list repos for $($account['login']): $($_.Exception.Message)"; continue }
        foreach ($r in $listed) {
            $name = [string]$r.full_name
            if (@($RepoTokens.Keys | Where-Object { $_ -ieq $name }).Count -eq 0) {
                $RepoTokens[$name] = $account['token']
                [void]$seen.Add($r)
            }
        }
    }
    foreach ($repoInfo in $seen) {
        $repo = [string]$repoInfo.full_name
        $Token = $RepoTokens[$repo]
        $owner = ($repo -split '/')[0]
        try {
            $releases = @(Get-DevStoreReleases -Repo $repo -Token $Token)
            $ReleaseCache[$repo] = $releases
            $release = Select-DevStoreRelease -Releases $releases -Bad @()
            if ($null -eq $release) { continue }
            $version = (ConvertFrom-DevStoreTag $release.tag_name).ToString()
            $zip = @($release.assets | Where-Object { $_.name -like "*-$version-win-x64.zip" }) | Select-Object -First 1
            if (-not $zip) { continue }
            $name = $zip.name.Substring(0, $zip.name.Length - "-$version-win-x64.zip".Length)
            $safe = ConvertTo-DevStoreSafeName $repo
            $cacheRel = "catalog\$safe"
            $cacheDir = Join-DevStorePath $Root 'catalog' $safe
            $prev = Select-DevStoreHashtable $oldApps[$repo]
            $store = Select-DevStoreStoreAssets $release
            $previews = @(Get-DevStorePrBuilds -Releases $releases | ForEach-Object {
                    @{ pr = $_.pr; version = $_.version; title = $_.title; publishedAt = $_.publishedAt } })
            $entry = @{
                previews = $previews
                repo = $repo; owner = $owner; shared = [bool]($main -and $owner -ine $main)
                name = $name; displayName = $name; latest = $version; type = $null
                description = [string]$repoInfo.description; icon = $null; screenshots = @()
                publishedAt = [string]$release.published_at
            }
            # storeVersion 2: listings may also take pictures from the repo itself.
            if ($prev -and $prev['latest'] -eq $version -and $prev['storeVersion'] -ge 2 -and (Test-Path -LiteralPath $cacheDir)) {
                foreach ($k in 'displayName', 'description', 'type', 'icon', 'screenshots') { $entry[$k] = $prev[$k] }
            }
            else {
                if (Test-Path -LiteralPath $cacheDir) { Remove-Item -LiteralPath $cacheDir -Recurse -Force }
                New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                if ($store['meta']) {
                    $metaFile = Join-DevStorePath $cacheDir 'store.json'
                    Save-DevStoreAsset -Repo $repo -AssetId $store['meta'].id -Token $Token -OutFile $metaFile
                    $meta = Read-DevStoreJson -Path $metaFile -Default @{}
                    if ($meta['displayName']) { $entry['displayName'] = [string]$meta['displayName'] }
                    if ($meta['description']) { $entry['description'] = [string]$meta['description'] }
                    if ($meta['type']) { $entry['type'] = [string]$meta['type'] }
                }
                if ($store['icon']) {
                    Save-DevStoreAsset -Repo $repo -AssetId $store['icon'].id -Token $Token -OutFile (Join-DevStorePath $cacheDir 'icon.png')
                    $entry['icon'] = "$cacheRel\icon.png"
                }
                $shots = @()
                $i = 0
                foreach ($a in @($store['screenshots'])) {
                    $i++
                    Save-DevStoreAsset -Repo $repo -AssetId $a.id -Token $Token -OutFile (Join-DevStorePath $cacheDir "screenshot-$i.png")
                    $shots += "$cacheRel\screenshot-$i.png"
                }
                # No pictures in the release (e.g. built before DevStore attached them):
                # take them from the repo at this release's tag.
                if (-not $entry['icon'] -or $shots.Count -eq 0) {
                    try {
                        $picked = Select-DevStoreRepoStoreFiles -Paths @(Get-DevStoreRepoTree -Repo $repo -Ref $release.tag_name -Token $Token)
                        if (-not $entry['icon'] -and $picked['icon']) {
                            Save-DevStoreRepoFile -Repo $repo -Path $picked['icon'] -Ref $release.tag_name -Token $Token -OutFile (Join-DevStorePath $cacheDir 'icon.png')
                            $entry['icon'] = "$cacheRel\icon.png"
                        }
                        if ($shots.Count -eq 0) {
                            foreach ($p in @($picked['screenshots'])) {
                                $i++
                                Save-DevStoreRepoFile -Repo $repo -Path $p -Ref $release.tag_name -Token $Token -OutFile (Join-DevStorePath $cacheDir "screenshot-$i.png")
                                $shots += "$cacheRel\screenshot-$i.png"
                            }
                        }
                    }
                    catch { Write-DevStoreLog -Root $Root -App $repo -Message "couldn't read store pictures from the repo: $($_.Exception.Message)" }
                }
                $entry['screenshots'] = $shots
            }
            $entry['storeVersion'] = 2
            $apps[$repo] = $entry
        }
        catch {
            Write-DevStoreLog -Root $Root -App $repo -Message "couldn't read releases: $($_.Exception.Message)"
        }
    }
    Write-DevStoreJson -Path $catPath -Object @{ updated = Get-DevStoreTimestamp; account = $main; apps = $apps }
}

function Get-DevStoreAgentVersion {
    # The VERSION file next to the updater scripts; $null when missing or unreadable.
    param([string]$Dir)
    $file = Join-DevStorePath $Dir 'VERSION'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return [version]((Get-Content -LiteralPath $file -Raw).Trim()) } catch { return $null }
}

function Update-DevStoreAgentFiles {
    # Self-update: the Manager's release carries the updater scripts in agent\.
    # Copy them over <Root>\agent only if they are a newer version: never back.
    param([string]$Root)
    $bundled = Join-DevStorePath $Root 'apps' 'devstore-manager' 'current' 'agent'
    if (-not (Test-Path -LiteralPath $bundled)) { return $false }
    $target = Join-DevStorePath $Root 'agent'
    $new = Get-DevStoreAgentVersion -Dir $bundled
    if ($null -eq $new) { return $false }   # Manager releases from before scripts had a version
    $old = Get-DevStoreAgentVersion -Dir $target
    if ($null -ne $old -and $new -le $old) { return $false }
    foreach ($f in @(Get-ChildItem -LiteralPath $bundled -File | Where-Object { $_.Extension -in '.ps1', '.psm1' -or $_.Name -eq 'VERSION' })) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-DevStorePath $target $f.Name) -Force
    }
    Write-DevStoreLog -Root $Root -Message "updater scripts updated to $new from the DevStore Manager release"
    return $true
}

function Initialize-DevStoreLayout {
    # Runs every pass as SYSTEM, so older installs pick up new layout needs:
    # a requests folder normal users can write to, and permission for normal
    # users to start the updater task (the Manager's "Check for updates").
    param([string]$Root, [string]$TaskName = 'DevStore Updater')
    $req = Join-DevStorePath $Root 'requests'
    if (-not (Test-Path -LiteralPath $req)) {
        New-Item -ItemType Directory -Path $req -Force | Out-Null
        & icacls.exe $req /grant '*S-1-5-32-545:(OI)(CI)M' /C /Q | Out-Null
    }
    $marker = Join-DevStorePath $Root 'agent' '.task-permission'
    if (-not (Test-Path -LiteralPath $marker)) {
        try {
            $svc = New-Object -ComObject Schedule.Service
            $svc.Connect()
            $task = $svc.GetFolder('\').GetTask($TaskName)
            $sddl = $task.GetSecurityDescriptor(4)   # DACL only
            if ($sddl -notmatch '\(A;;GRGX;;;AU\)') { $task.SetSecurityDescriptor($sddl + '(A;;GRGX;;;AU)', 0) }
            Set-Content -LiteralPath $marker -Value 'ok'
        }
        catch {
            Write-DevStoreLog -Root $Root -Message "couldn't let normal users start the updater: $($_.Exception.Message)"
        }
    }
}

function Invoke-DevStoreUpdaterRun {
    # One updater pass over every app in config.json. Writes state.json.
    param([string]$Root)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\DevStoreUpdater')
    if (-not $mutex.WaitOne(0)) {
        Write-DevStoreLog -Root $Root -Message 'another updater run is in progress; exiting'
        return
    }
    try {
        try { Initialize-DevStoreLayout -Root $Root } catch { Write-DevStoreLog -Root $Root -Message "layout: $($_.Exception.Message)" }
        $configPath = Join-DevStorePath $Root 'config.json'
        $config = Read-DevStoreJson -Path $configPath -Default @{ apps = @() }
        $statePath = Join-DevStorePath $Root 'state.json'
        $state = Read-DevStoreJson -Path $statePath -Default @{}
        if (-not $state.ContainsKey('apps') -or $state['apps'] -isnot [hashtable]) { $state['apps'] = @{} }
        $requests = Invoke-DevStoreRequests -Root $Root -Config $config -State $state
        if ($requests['changed']) { $config = $requests['config']; Write-DevStoreJson -Path $configPath -Object $config }
        $oldApps = @{}
        if ($state.ContainsKey('apps') -and $state['apps'] -is [hashtable]) { $oldApps = $state['apps'] }
        $newApps = @{}
        $errors = 0
        $runError = $null

        try { $tokens = @(Read-DevStoreTokens -Root $Root) }
        catch { $tokens = @(); $runError = $_.Exception.Message }
        $token = $null
        if ($tokens.Count -gt 0) { $token = $tokens[0]['token'] }
        if (-not $runError -and -not $token) { $runError = 'no GitHub token stored. Run DevStoreSetup.exe again.' }

        $releaseCache = @{}
        $state['catalogError'] = $null
        if ($token) {
            $repoTokens = @{}
            try { Update-DevStoreCatalog -Root $Root -Tokens $tokens -ReleaseCache $releaseCache -RepoTokens $repoTokens }
            catch {
                $state['catalogError'] = $_.Exception.Message
                Write-DevStoreLog -Root $Root -Message "couldn't list your GitHub repos: $($_.Exception.Message)"
            }
            foreach ($entry in @($config['apps'])) {
                if ($null -eq $entry -or -not $entry['repo']) { continue }
                $repo = [string]$entry['repo']
                $prev = $null
                if ($oldApps.ContainsKey($repo)) { $prev = $oldApps[$repo] }
                try {
                    $cached = $null
                    $hit = @($releaseCache.Keys | Where-Object { $_ -ieq $repo }) | Select-Object -First 1
                    if ($hit) { $cached = $releaseCache[$hit] }
                    # The account that can read this repo; else one whose name matches the owner; else the main one.
                    $appToken = $token
                    $tk = @($repoTokens.Keys | Where-Object { $_ -ieq $repo }) | Select-Object -First 1
                    if ($tk) { $appToken = $repoTokens[$tk] }
                    else {
                        $byOwner = @($tokens | Where-Object { $_['login'] -and $_['login'] -ieq ($repo -split '/')[0] }) | Select-Object -First 1
                        if ($byOwner) { $appToken = $byOwner['token'] }
                    }
                    $mode = Get-DevStoreUpdateMode -Config $config -Repo $repo
                    $channel = Get-DevStoreChannel -Config $config -Repo $repo
                    $applyNow = @($requests['apply'] | Where-Object { $_ -ieq $repo }).Count -gt 0
                    $s = Select-DevStoreHashtable (Update-DevStoreApp -Repo $repo -AppState $prev -Root $Root -Token $appToken `
                        -Releases $cached -Mode $mode -Apply:$applyNow -Channel $channel)
                    if ($null -eq $s) { throw 'The updater returned no result for this app.' }
                }
                catch {
                    $s = Copy-DevStoreAppState $prev
                    $s['status'] = 'error'
                    $s['lastError'] = $_.Exception.Message
                    $s['lastChecked'] = Get-DevStoreTimestamp
                }
                if ($s['status'] -eq 'error') { $errors++ }
                $newApps[$repo] = $s
            }
        }
        else {
            $newApps = $oldApps
        }

        try { [void](Update-DevStoreAgentFiles -Root $Root) } catch { Write-DevStoreLog -Root $Root -Message "self-update: $($_.Exception.Message)" }
        $state['apps'] = $newApps
        $state['accounts'] = @($tokens | ForEach-Object { $_['login'] } | Where-Object { $_ })   # names only, never tokens
        $state['lastRun'] = Get-DevStoreTimestamp
        if ($runError) { $state['lastRunResult'] = "failed: $runError" }
        elseif ($errors -gt 0) { $state['lastRunResult'] = "$errors error(s)" }
        else { $state['lastRunResult'] = 'ok' }
        Write-DevStoreJson -Path $statePath -Object $state
        if ($runError) { Write-DevStoreLog -Root $Root -Message "run failed: $runError" }
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function Join-DevStorePath, Select-DevStoreHashtable, Get-DevStoreAccessibleRepos, Get-DevStoreLogin,
    Read-DevStoreTokens, Write-DevStoreTokens,
    Remove-DevStoreAppCore, Invoke-DevStoreRequests, Get-DevStoreRepoTree, Save-DevStoreRepoFile, Update-DevStoreCatalog, Update-DevStoreAgentFiles, Initialize-DevStoreLayout, Write-DevStoreLog,
    Get-DevStoreReleases, Save-DevStoreAsset, Set-DevStoreJunction, Get-DevStoreJunctionTarget,
    Test-DevStoreGuiRunning, Test-DevStoreOldProcessRunning, New-DevStoreShortcut, Remove-DevStoreShortcut, Install-DevStoreService,
    Uninstall-DevStoreService, Stop-DevStoreService, Start-DevStoreServiceHealthy, Update-DevStoreApp,
    Invoke-DevStoreUpdaterRun
