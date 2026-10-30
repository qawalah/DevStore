BeforeAll {
    $agentDir = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $agentDir 'DevStore.Core.psm1') -Force
    Import-Module (Join-Path $agentDir 'DevStore.Agent.psm1') -Force

    function P { [System.IO.Path]::Combine([string[]]$args) }

    # Builds a release zip + .sha256 the way windows-release.yml does, and
    # returns a fake GitHub release object pointing at them.
    function New-FakeRelease {
        param([string]$Name, [string]$Version, [string]$Type, [switch]$BadHash, [switch]$NoSha, [switch]$UpdateWhileRunning)
        $src = Join-Path $TestDrive "src-$Name-$Version"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $src "$Name.exe") -Value "fake exe $Version"
        $manifest = @{ name = $Name; type = $Type; entry = 'main.py'; version = $Version }
        if ($UpdateWhileRunning) { $manifest.updateWhileRunning = $true }
        $manifest | ConvertTo-Json |
            Set-Content -Path (Join-Path $src 'devstore.json')
        $zipName = "$Name-$Version-win-x64.zip"
        $zip = Join-Path $script:Fixtures $zipName
        Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -Force
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($BadHash) { $hash = '0' * 64 }
        Set-Content -Path "$zip.sha256" -Value "$hash  $zipName" -NoNewline
        $assets = @([pscustomobject]@{ id = "$zipName"; name = $zipName })
        if (-not $NoSha) { $assets += [pscustomobject]@{ id = "$zipName.sha256"; name = "$zipName.sha256" } }
        [pscustomobject]@{ tag_name = "windows-v$Version"; draft = $false; prerelease = $false; assets = $assets }
    }
}

Describe 'Update-DevStoreApp' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:Fixtures = Join-Path $script:Root 'fixtures'
        New-Item -ItemType Directory -Path $script:Fixtures -Force | Out-Null
        $script:Junctions = @{}

        Mock -ModuleName DevStore.Agent Save-DevStoreAsset {
            param($Repo, $AssetId, $Token, $OutFile)
            Copy-Item (Join-Path $script:Fixtures $AssetId) $OutFile
        }
        Mock -ModuleName DevStore.Agent Set-DevStoreJunction {
            param($Link, $Target)
            $script:Junctions[$Link] = $Target
        }
        Mock -ModuleName DevStore.Agent Get-DevStoreJunctionTarget { param($Link) $script:Junctions[$Link] }
        Mock -ModuleName DevStore.Agent Test-DevStoreGuiRunning { $false }
        Mock -ModuleName DevStore.Agent New-DevStoreShortcut {}
        Mock -ModuleName DevStore.Agent Install-DevStoreService {}
        Mock -ModuleName DevStore.Agent Uninstall-DevStoreService {}
        Mock -ModuleName DevStore.Agent Stop-DevStoreService {}
        Mock -ModuleName DevStore.Agent Start-DevStoreServiceHealthy { $true }
    }

    It 'installs a GUI app on first run and creates a shortcut' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.0.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $null -Root $Root -Token 't'

        $s.status | Should -Be 'ok'
        $s.installed | Should -Be '1.0.0'
        $s.latest | Should -Be '1.0.0'
        $s.type | Should -Be 'gui'
        $s.name | Should -Be 'hello'
        $s.exe | Should -Be 'hello.exe'
        Test-Path (P $Root apps hello versions 1.0.0 hello.exe) | Should -BeTrue
        $script:Junctions[(P $Root apps hello current)] | Should -Be (P $Root apps hello versions 1.0.0)
        Should -Invoke -ModuleName DevStore.Agent New-DevStoreShortcut -Times 1
    }

    It 'does nothing when the latest version is installed' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.0.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'ok'
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreAsset -Times 0
    }

    It 'defers a GUI update while the app is running' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.1.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        Mock -ModuleName DevStore.Agent Test-DevStoreGuiRunning { $true }
        $state = @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'pending'
        $s.installed | Should -Be '1.0.0'
        $s.latest | Should -Be '1.1.0'
        Should -Invoke -ModuleName DevStore.Agent Set-DevStoreJunction -Times 0
    }

    It 'updates a GUI app once it is closed and keeps the previous version' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.1.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'pending' }

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'ok'
        $s.installed | Should -Be '1.1.0'
        $s.previous | Should -Be '1.0.0'
    }

    It 'updates a healthy service: stop, swap, start' {
        $rel = New-FakeRelease -Name 'svc' -Version '2.0.0' -Type 'service'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'svc'; type = 'service'; exe = 'svc.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/svc' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'ok'
        $s.installed | Should -Be '2.0.0'
        Should -Invoke -ModuleName DevStore.Agent Stop-DevStoreService -Times 1
        Should -Invoke -ModuleName DevStore.Agent Start-DevStoreServiceHealthy -Times 1
    }

    It 'rolls back a service that fails its health check and marks the version bad' {
        $rel = New-FakeRelease -Name 'svc' -Version '2.0.0' -Type 'service'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $script:healthCalls = 0
        Mock -ModuleName DevStore.Agent Start-DevStoreServiceHealthy {
            $script:healthCalls++
            return ($script:healthCalls -gt 1)   # new version fails, old version starts again
        }
        $state = @{ name = 'svc'; type = 'service'; exe = 'svc.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/svc' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'rolledback'
        $s.installed | Should -Be '1.0.0'
        @($s.bad) | Should -Contain '2.0.0'
        $s.lastError | Should -Match '2\.0\.0'
        $script:Junctions[(P $Root apps svc current)] | Should -Be (P $Root apps svc versions 1.0.0)
    }

    It 'keeps the rolled-back status until a newer version installs' {
        $rel = New-FakeRelease -Name 'svc' -Version '2.0.0' -Type 'service'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'svc'; type = 'service'; exe = 'svc.exe'; installed = '1.0.0'; bad = @('2.0.0'); status = 'rolledback'; lastError = 'v2.0.0 failed' }

        $s = Update-DevStoreApp -Repo 'qawalah/svc' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'rolledback'
        $s.installed | Should -Be '1.0.0'
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreAsset -Times 0
    }

    It 'rejects a hash mismatch without touching the installed version' {
        $rel = New-FakeRelease -Name 'svc' -Version '2.0.0' -Type 'service' -BadHash
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'svc'; type = 'service'; exe = 'svc.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/svc' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'error'
        $s.lastError | Should -Match 'hash'
        $s.installed | Should -Be '1.0.0'
        Should -Invoke -ModuleName DevStore.Agent Stop-DevStoreService -Times 0
    }

    It 'reports a release without a .sha256 asset' {
        $rel = New-FakeRelease -Name 'svc' -Version '2.0.0' -Type 'service' -NoSha
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }

        $s = Update-DevStoreApp -Repo 'qawalah/svc' -AppState $null -Root $Root -Token 't'

        $s.status | Should -Be 'error'
        $s.lastError | Should -Match 'sha256'
    }

    It 'never throws: API errors become status error' {
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { throw 'HTTP 401 Bad credentials' }

        $s = Update-DevStoreApp -Repo 'qawalah/x' -AppState $null -Root $Root -Token 't'

        $s.status | Should -Be 'error'
        $s.lastError | Should -Match '401'
        $s.lastChecked | Should -Not -BeNullOrEmpty
    }

    It 'remembers updateWhileRunning from the installed build' {
        $rel = New-FakeRelease -Name 'tray' -Version '1.0.0' -Type 'gui' -UpdateWhileRunning
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }

        $s = Update-DevStoreApp -Repo 'qawalah/tray' -AppState $null -Root $Root -Token 't'

        $s.updateWhileRunning | Should -BeTrue
    }

    It 'updates a running tray app that opted in, and flags a restart' {
        $rel = New-FakeRelease -Name 'tray' -Version '1.1.0' -Type 'gui' -UpdateWhileRunning
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        Mock -ModuleName DevStore.Agent Test-DevStoreGuiRunning { $true }
        foreach ($v in '0.9.0', '1.0.0') { New-Item -ItemType Directory -Path (P $Root apps tray versions $v) -Force | Out-Null }
        $state = @{ name = 'tray'; type = 'gui'; exe = 'tray.exe'; installed = '1.0.0'; previous = '0.9.0'; bad = @(); status = 'ok'; updateWhileRunning = $true }

        $s = Update-DevStoreApp -Repo 'qawalah/tray' -AppState $state -Root $Root -Token 't'

        $s.status | Should -Be 'ok'
        $s.installed | Should -Be '1.1.0'
        $s.restartPending | Should -BeTrue
        $script:Junctions[(P $Root apps tray current)] | Should -Be (P $Root apps tray versions 1.1.0)
        # Nothing is deleted while the app runs: it may still use an older folder.
        (Get-ChildItem (P $Root apps tray versions)).Name | Sort-Object | Should -Be @('0.9.0', '1.0.0', '1.1.0')
    }

    It 'clears the restart flag once the app is closed' {
        $rel = New-FakeRelease -Name 'tray' -Version '1.1.0' -Type 'gui' -UpdateWhileRunning
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'tray'; type = 'gui'; exe = 'tray.exe'; installed = '1.1.0'; bad = @(); status = 'ok'; updateWhileRunning = $true; restartPending = $true }

        $s = Update-DevStoreApp -Repo 'qawalah/tray' -AppState $state -Root $Root -Token 't'

        $s.restartPending | Should -BeFalse
    }

    It 'prunes versions older than current and previous' {
        foreach ($v in '0.8.0', '0.9.0', '1.0.0') {
            New-Item -ItemType Directory -Path (P $Root apps hello versions $v) -Force | Out-Null
        }
        $rel = New-FakeRelease -Name 'hello' -Version '1.1.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        Update-DevStoreApp -Repo 'qawalah/hello' -AppState $state -Root $Root -Token 't' | Out-Null

        (Get-ChildItem (P $Root apps hello versions)).Name | Sort-Object | Should -Be @('1.0.0', '1.1.0')
    }
}

Describe 'Invoke-DevStoreUpdaterRun' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Write-DevStoreJson -Path (Join-Path $Root 'config.json') -Object @{ apps = @(@{ repo = 'qawalah/a' }, @{ repo = 'qawalah/b' }) }
        Mock -ModuleName DevStore.Agent Read-DevStoreToken { 'token' }
    }

    It 'keeps going when one app fails and records the run' {
        Mock -ModuleName DevStore.Agent Update-DevStoreApp {
            param($Repo, $AppState, $Root, $Token)
            if ($Repo -eq 'qawalah/a') { throw 'boom' }
            return @{ name = 'b'; status = 'ok'; installed = '1.0.0'; bad = @() }
        }

        Invoke-DevStoreUpdaterRun -Root $Root

        $state = Read-DevStoreJson -Path (Join-Path $Root 'state.json') -Default @{}
        $state.apps['qawalah/b'].status | Should -Be 'ok'
        $state.apps['qawalah/a'].status | Should -Be 'error'
        $state.apps['qawalah/a'].lastError | Should -Match 'boom'
        $state.lastRun | Should -Not -BeNullOrEmpty
        $state.lastRunResult | Should -Match '1 error'
    }

    It 'drops state for apps removed from config' {
        Write-DevStoreJson -Path (Join-Path $Root 'state.json') -Object @{ apps = @{ 'qawalah/gone' = @{ status = 'ok' } } }
        Mock -ModuleName DevStore.Agent Update-DevStoreApp { @{ status = 'ok'; bad = @() } }

        Invoke-DevStoreUpdaterRun -Root $Root

        $state = Read-DevStoreJson -Path (Join-Path $Root 'state.json') -Default @{}
        $state.apps.ContainsKey('qawalah/gone') | Should -BeFalse
        $state.lastRunResult | Should -Be 'ok'
    }

    It 'records a missing token as the run result' {
        Mock -ModuleName DevStore.Agent Read-DevStoreToken { throw 'token.dat not found' }

        Invoke-DevStoreUpdaterRun -Root $Root

        $state = Read-DevStoreJson -Path (Join-Path $Root 'state.json') -Default @{}
        $state.lastRunResult | Should -Match 'token'
    }
}
