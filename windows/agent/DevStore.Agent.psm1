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

function Read-DevStoreToken {
    param([string]$Root)
    $file = Join-DevStorePath $Root 'token.dat'
    if (-not (Test-Path -LiteralPath $file)) { throw "token.dat not found in $Root. Re-run Install-DevStoreAgent.ps1." }
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String((Get-Content -LiteralPath $file -Raw).Trim())
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'LocalMachine')
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Write-DevStoreToken {
    param([string]$Root, [string]$Token)
    Add-Type -AssemblyName System.Security
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')
    Set-Content -LiteralPath (Join-DevStorePath $Root 'token.dat') -Value ([Convert]::ToBase64String($enc)) -Encoding ascii
}

# ---------------------------------------------------------------- GitHub

function Initialize-DevStoreHttp {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
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
        return @(Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseBasicParsing)
    }
    catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 404) { throw "Repo $Repo not found, or the token can't read it (HTTP 404)." }
        if ($code -eq 401) { throw 'GitHub token rejected (HTTP 401). It may have expired: re-run Install-DevStoreAgent.ps1.' }
        throw
    }
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
        $req.Headers.Add('Authorization', "Bearer $Token")
        $req.Headers.Add('Accept', 'application/octet-stream')
        $req.Headers.Add('User-Agent', $script:UserAgent)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        if ([int]$resp.StatusCode -ge 300 -and [int]$resp.StatusCode -lt 400) {
            $location = $resp.Headers.Location
            $resp.Dispose()
            $req2 = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $location)
            $req2.Headers.Add('User-Agent', $script:UserAgent)
            $resp = $client.SendAsync($req2, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        }
        if (-not $resp.IsSuccessStatusCode) { throw "Download of asset $AssetId failed: HTTP $([int]$resp.StatusCode)" }
        $out = [System.IO.File]::Create($OutFile)
        try { $resp.Content.CopyToAsync($out).GetAwaiter().GetResult() } finally { $out.Dispose() }
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

function Copy-DevStoreAppState {
    param($AppState)
    $s = @{ bad = @() }
    if ($null -ne $AppState) {
        foreach ($k in @($AppState.Keys)) { $s[$k] = $AppState[$k] }
    }
    if ($null -eq $s['bad']) { $s['bad'] = @() }
    $s['bad'] = @($s['bad'])
    foreach ($k in 'name', 'type', 'exe', 'displayName', 'installed', 'previous', 'latest', 'status', 'lastError') {
        if (-not $s.ContainsKey($k)) { $s[$k] = $null }
    }
    return $s
}

function Update-DevStoreApp {
    # Brings one app up to date. Never throws: failures end up in status/lastError.
    param([string]$Repo, $AppState, [string]$Root, [string]$Token)
    $s = Copy-DevStoreAppState $AppState
    $s['lastChecked'] = Get-DevStoreTimestamp
    $logName = $Repo
    try {
        $release = Select-DevStoreRelease -Releases (Get-DevStoreReleases -Repo $Repo -Token $Token) -Bad $s['bad']
        if ($null -eq $release) {
            if (-not $s['installed']) {
                $s['status'] = 'error'
                $s['lastError'] = 'No windows-v release found yet.'
            }
            return $s
        }
        $version = (ConvertFrom-DevStoreTag $release.tag_name).ToString()
        $s['latest'] = $version
        $action = Get-DevStoreAction -AppState $s -Version $version
        if ($action -eq 'none') {
            if ($s['status'] -ne 'rolledback') { $s['status'] = 'ok'; $s['lastError'] = $null }
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

        if ($action -eq 'update' -and $s['type'] -eq 'gui' -and (Test-DevStoreGuiRunning -AppDir $appDir)) {
            if ($s['status'] -ne 'pending') { Write-DevStoreLog -Root $Root -App $name -Message "v$version waiting for the app to close" }
            $s['status'] = 'pending'
            return $s
        }

        # Download and verify.
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

        # Extract and read the manifest.
        $versionsDir = Join-DevStorePath $appDir 'versions'
        $target = Join-DevStorePath $versionsDir $version
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
        Remove-Item -LiteralPath $zip, $sha -Force -ErrorAction SilentlyContinue
        $manifest = Read-DevStoreJson -Path (Join-DevStorePath $target 'devstore.json') -Default $null
        if ($null -eq $manifest) { throw "devstore.json missing from the $version build." }
        if ($manifest['name'] -ne $name) { throw "devstore.json name '$($manifest['name'])' doesn't match '$name'." }
        $type = $manifest['type']
        if ($type -notin @('gui', 'service')) { throw "devstore.json type '$type' is not gui or service." }
        $exe = "$name.exe"
        if (-not (Test-Path -LiteralPath (Join-DevStorePath $target $exe))) { throw "$exe missing from the $version build." }
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
            Write-DevStoreLog -Root $Root -App $name -Message "updated v$old -> v$version"
        }

        $s['name'] = $name
        $s['type'] = $type
        $s['exe'] = $exe
        $s['displayName'] = $displayName
        $s['previous'] = $old
        $s['installed'] = $version
        $s['status'] = 'ok'
        $s['lastError'] = $null

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

function Invoke-DevStoreUpdaterRun {
    # One updater pass over every app in config.json. Writes state.json.
    param([string]$Root)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\DevStoreUpdater')
    if (-not $mutex.WaitOne(0)) {
        Write-DevStoreLog -Root $Root -Message 'another updater run is in progress; exiting'
        return
    }
    try {
        $config = Read-DevStoreJson -Path (Join-DevStorePath $Root 'config.json') -Default @{ apps = @() }
        $statePath = Join-DevStorePath $Root 'state.json'
        $state = Read-DevStoreJson -Path $statePath -Default @{}
        $oldApps = @{}
        if ($state.ContainsKey('apps') -and $state['apps'] -is [hashtable]) { $oldApps = $state['apps'] }
        $newApps = @{}
        $errors = 0
        $runError = $null

        try { $token = Read-DevStoreToken -Root $Root }
        catch { $token = $null; $runError = $_.Exception.Message }

        if ($token) {
            foreach ($entry in @($config['apps'])) {
                if ($null -eq $entry -or -not $entry['repo']) { continue }
                $repo = [string]$entry['repo']
                $prev = $null
                if ($oldApps.ContainsKey($repo)) { $prev = $oldApps[$repo] }
                try {
                    $s = Update-DevStoreApp -Repo $repo -AppState $prev -Root $Root -Token $token
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

        $state['apps'] = $newApps
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

Export-ModuleMember -Function Join-DevStorePath, Write-DevStoreLog, Read-DevStoreToken, Write-DevStoreToken,
    Get-DevStoreReleases, Save-DevStoreAsset, Set-DevStoreJunction, Get-DevStoreJunctionTarget,
    Test-DevStoreGuiRunning, New-DevStoreShortcut, Remove-DevStoreShortcut, Install-DevStoreService,
    Uninstall-DevStoreService, Stop-DevStoreService, Start-DevStoreServiceHealthy, Update-DevStoreApp,
    Invoke-DevStoreUpdaterRun
