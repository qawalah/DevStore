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

    It 'repairs a state entry that was saved as a list (bug in 1.0.0)' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.0.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $broken = @($null, $null, @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'ok' })

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $broken -Root $Root -Token 't'

        $s | Should -BeOfType [hashtable]
        $s.status | Should -Be 'ok'
        $s.installed | Should -Be '1.0.0'
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreAsset -Times 0
    }

    It 'notify mode: only reports that an update exists' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.1.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $state -Root $Root -Token 't' -Mode 'notify'

        $s.status | Should -Be 'available'
        $s.latest | Should -Be '1.1.0'
        $s.installed | Should -Be '1.0.0'
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreAsset -Times 0
    }

    It 'download mode: downloads once, waits, then installs when asked' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.1.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $state = @{ name = 'hello'; type = 'gui'; exe = 'hello.exe'; installed = '1.0.0'; bad = @(); status = 'ok' }

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $state -Root $Root -Token 't' -Mode 'download'
        $s.status | Should -Be 'ready'
        $s.installed | Should -Be '1.0.0'
        Test-Path (P $Root apps hello versions 1.1.0 hello.exe) | Should -BeTrue
        Should -Invoke -ModuleName DevStore.Agent Set-DevStoreJunction -Times 0

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $s -Root $Root -Token 't' -Mode 'download'
        $s.status | Should -Be 'ready'

        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $s -Root $Root -Token 't' -Mode 'download' -Apply
        $s.status | Should -Be 'ok'
        $s.installed | Should -Be '1.1.0'
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreAsset -Times 2 -Exactly
    }

    It 'a first install happens whatever the update mode' {
        $rel = New-FakeRelease -Name 'hello' -Version '1.0.0' -Type 'gui'
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases { @($rel) }
        $s = Update-DevStoreApp -Repo 'qawalah/hello' -AppState $null -Root $Root -Token 't' -Mode 'notify'
        $s.installed | Should -Be '1.0.0'
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
        Mock -ModuleName DevStore.Agent Read-DevStoreTokens { @(@{ login = 'qawalah'; token = 'token' }) }
        Mock -ModuleName DevStore.Agent Initialize-DevStoreLayout {}
        Mock -ModuleName DevStore.Agent Update-DevStoreCatalog {}
        Mock -ModuleName DevStore.Agent Update-DevStoreAgentFiles { $false }
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

    It 'stores only the app state even if commands leak output' {
        Mock -ModuleName DevStore.Agent Update-DevStoreApp {
            $null
            'stray text'
            @{ name = 'b'; status = 'ok'; installed = '1.0.0'; bad = @() }
        }

        Invoke-DevStoreUpdaterRun -Root $Root

        $state = Read-DevStoreJson -Path (Join-Path $Root 'state.json') -Default @{}
        $state.apps['qawalah/b'] | Should -BeOfType [hashtable]
        $state.apps['qawalah/b'].installed | Should -Be '1.0.0'
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
        Mock -ModuleName DevStore.Agent Read-DevStoreTokens { throw 'token.dat not found' }

        Invoke-DevStoreUpdaterRun -Root $Root

        $state = Read-DevStoreJson -Path (Join-Path $Root 'state.json') -Default @{}
        $state.lastRunResult | Should -Match 'token'
    }
}

Describe 'Update-DevStoreCatalog' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:Fixtures = Join-Path $script:Root 'fixtures'
        New-Item -ItemType Directory -Path $script:Fixtures -Force | Out-Null
        @{ name = 'tool'; displayName = 'Tool Box'; description = 'Does tool things.'; type = 'gui'; version = '2.0.0' } |
            ConvertTo-Json | Set-Content (Join-Path $script:Fixtures 'store.json')
        foreach ($f in 'store-icon.png', 'store-screenshot-1.png', 'store-screenshot-2.png') {
            Set-Content -Path (Join-Path $script:Fixtures $f) -Value "png $f"
        }
        $script:ToolRelease = [pscustomobject]@{ tag_name = 'windows-v2.0.0'; draft = $false; prerelease = $false; published_at = '2026-10-30T10:00:00Z'
            assets = @('tool-2.0.0-win-x64.zip', 'tool-2.0.0-win-x64.zip.sha256', 'store.json', 'store-icon.png', 'store-screenshot-1.png', 'store-screenshot-2.png' |
                ForEach-Object { [pscustomobject]@{ id = $_; name = $_ } }) }
        Mock -ModuleName DevStore.Agent Get-DevStoreAccessibleRepos {
            @([pscustomobject]@{ full_name = 'qawalah/Tool'; description = 'from GitHub'; private = $true },
              [pscustomobject]@{ full_name = 'qawalah/AndroidOnly'; description = 'phone app'; private = $true })
        }
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases {
            param($Repo, $Token)
            if ($Repo -eq 'qawalah/Tool') { return @($script:ToolRelease) }
            return @([pscustomobject]@{ tag_name = 'android-v1.0+1'; draft = $false; prerelease = $false; assets = @() })
        }
        Mock -ModuleName DevStore.Agent Save-DevStoreAsset {
            param($Repo, $AssetId, $Token, $OutFile)
            Copy-Item (Join-Path $script:Fixtures $AssetId) $OutFile
        }
        Mock -ModuleName DevStore.Agent Get-DevStoreRepoTree { @() }
        Mock -ModuleName DevStore.Agent Save-DevStoreRepoFile { param($Repo, $Path, $Ref, $Token, $OutFile) Set-Content $OutFile "png $Path" }
    }

    It 'takes screenshots and the icon from the repo when the release has none' {
        $script:ToolRelease.assets = @($script:ToolRelease.assets | Where-Object { $_.name -like 'tool-*' })
        Mock -ModuleName DevStore.Agent Get-DevStoreRepoTree {
            @('windows/devstore.json', 'windows/docs/screenshots/01.png', 'windows/docs/screenshots/02.png', 'windows/store/icon.png')
        }
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 't' }) -ReleaseCache @{}
        $app = (Read-DevStoreJson -Path (Join-Path $Root 'catalog.json') -Default @{}).apps['qawalah/Tool']
        @($app.screenshots).Count | Should -Be 2
        Test-Path (Join-Path $Root $app.icon) | Should -BeTrue
        Should -Invoke -ModuleName DevStore.Agent Get-DevStoreRepoTree -Times 1 -ParameterFilter { $Ref -eq 'windows-v2.0.0' }
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreRepoFile -Times 3 -Exactly
    }

    It 'refreshes listings cached before repo screenshots were supported' {
        Write-DevStoreJson -Path (Join-Path $Root 'catalog.json') -Object @{ apps = @{ 'qawalah/Tool' = @{ latest = '2.0.0'; displayName = 'old' } } }
        New-Item -ItemType Directory -Path (Join-Path $Root 'catalog/qawalah__tool') -Force | Out-Null
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 't' }) -ReleaseCache @{}
        (Read-DevStoreJson -Path (Join-Path $Root 'catalog.json') -Default @{}).apps['qawalah/Tool'].displayName | Should -Be 'Tool Box'
    }

    It 'lists only repos with Windows releases, with store details cached locally' {
        $cache = @{}
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 't' }) -ReleaseCache $cache

        $cat = Read-DevStoreJson -Path (Join-Path $Root 'catalog.json') -Default @{}
        @($cat.apps.Keys) | Should -Be @('qawalah/Tool')
        $app = $cat.apps['qawalah/Tool']
        $app.displayName | Should -Be 'Tool Box'
        $app.description | Should -Be 'Does tool things.'
        $app.latest | Should -Be '2.0.0'
        $app.name | Should -Be 'tool'
        Test-Path (Join-Path $Root $app.icon) | Should -BeTrue
        @($app.screenshots).Count | Should -Be 2
        $cache.ContainsKey('qawalah/Tool') | Should -BeTrue
    }

    It 'downloads store files only once per version' {
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 't' }) -ReleaseCache @{}
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 't' }) -ReleaseCache @{}
        Should -Invoke -ModuleName DevStore.Agent Save-DevStoreAsset -Times 4 -Exactly
    }

    It 'falls back to the GitHub description when a release has no store.json' {
        $script:ToolRelease.assets = @($script:ToolRelease.assets | Where-Object { $_.name -like 'tool-*' })
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 't' }) -ReleaseCache @{}
        $app = (Read-DevStoreJson -Path (Join-Path $Root 'catalog.json') -Default @{}).apps['qawalah/Tool']
        $app.description | Should -Be 'from GitHub'
        $app.displayName | Should -Be 'tool'
        $app.icon | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DevStoreRequests' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'requests') -Force | Out-Null
        Mock -ModuleName DevStore.Agent Remove-DevStoreAppCore {}
    }

    It 'applies install, remove and check requests, then deletes them' {
        $req = Join-Path $Root 'requests'
        '{"action":"install","repo":"qawalah/new"}' | Set-Content (Join-Path $req '1.json')
        '{"action":"remove","repo":"qawalah/old"}' | Set-Content (Join-Path $req '2.json')
        '{"action":"check"}' | Set-Content (Join-Path $req '3.json')
        'not json' | Set-Content (Join-Path $req '4.json')
        $config = @{ apps = @(@{ repo = 'qawalah/old' }) }

        $result = Invoke-DevStoreRequests -Root $Root -Config $config

        @($result.config.apps | ForEach-Object { $_.repo }) | Should -Be @('qawalah/new')
        Should -Invoke -ModuleName DevStore.Agent Remove-DevStoreAppCore -Times 1 -ParameterFilter { $Repo -eq 'qawalah/old' }
        @(Get-ChildItem $req).Count | Should -Be 0
        $result.changed | Should -BeTrue
    }

    It 'collects apply requests and changes update modes' {
        $req = Join-Path $Root 'requests'
        '{"action":"apply","repo":"qawalah/a"}' | Set-Content (Join-Path $req '1.json')
        '{"action":"set-updates","repo":"qawalah/a","mode":"notify"}' | Set-Content (Join-Path $req '2.json')
        '{"action":"set-updates","mode":"download"}' | Set-Content (Join-Path $req '3.json')

        $result = Invoke-DevStoreRequests -Root $Root -Config @{ apps = @(@{ repo = 'qawalah/a' }) }

        @($result.apply) | Should -Be @('qawalah/a')
        $result.config.apps[0].updates | Should -Be 'notify'
        $result.config.defaultUpdates | Should -Be 'download'
    }

    It 'does nothing when there are no requests' {
        $result = Invoke-DevStoreRequests -Root $Root -Config @{ apps = @() }
        $result.changed | Should -BeFalse
    }
}

Describe 'Update-DevStoreAgentFiles' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:Bundled = Join-Path $script:Root 'apps/devstore-manager/current/agent'
        $script:Installed = Join-Path $script:Root 'agent'
        New-Item -ItemType Directory -Path $script:Bundled, $script:Installed -Force | Out-Null
        Set-Content (Join-Path $script:Installed 'DevStore.Agent.psm1') 'old'
        Set-Content (Join-Path $script:Installed 'VERSION') '2.1.0'
    }

    It 'copies newer updater scripts shipped with the Manager' {
        Set-Content (Join-Path $Bundled 'DevStore.Agent.psm1') 'new'
        Set-Content (Join-Path $Bundled 'DevStoreUpdater.ps1') 'new runner'
        Set-Content (Join-Path $Bundled 'VERSION') '2.2.0'

        Update-DevStoreAgentFiles -Root $Root | Should -BeTrue

        Get-Content (Join-Path $Installed 'DevStore.Agent.psm1') | Should -Be 'new'
        Test-Path (Join-Path $Installed 'DevStoreUpdater.ps1') | Should -BeTrue
        Get-Content (Join-Path $Installed 'VERSION') | Should -Be '2.2.0'
    }

    It 'never goes back to older scripts' {
        Set-Content (Join-Path $Bundled 'DevStore.Agent.psm1') 'older'
        Set-Content (Join-Path $Bundled 'VERSION') '2.0.9'
        Update-DevStoreAgentFiles -Root $Root | Should -BeFalse
        Get-Content (Join-Path $Installed 'DevStore.Agent.psm1') | Should -Be 'old'
    }

    It 'ignores Manager releases from before scripts had a version' {
        Set-Content (Join-Path $Bundled 'DevStore.Agent.psm1') 'unversioned'
        Update-DevStoreAgentFiles -Root $Root | Should -BeFalse
    }

    It 'upgrades installs from before scripts had a version' {
        Remove-Item (Join-Path $Installed 'VERSION')
        Set-Content (Join-Path $Bundled 'DevStore.Agent.psm1') 'new'
        Set-Content (Join-Path $Bundled 'VERSION') '2.1.0'
        Update-DevStoreAgentFiles -Root $Root | Should -BeTrue
    }

    It 'leaves the same version alone' {
        Set-Content (Join-Path $Bundled 'DevStore.Agent.psm1') 'same'
        Set-Content (Join-Path $Bundled 'VERSION') '2.1.0'
        Update-DevStoreAgentFiles -Root $Root | Should -BeFalse
    }

    It 'does nothing without a Manager install' {
        Remove-Item $Bundled -Recurse -Force
        Update-DevStoreAgentFiles -Root $Root | Should -BeFalse
    }
}

Describe 'Update-DevStoreCatalog with several accounts' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Mock -ModuleName DevStore.Agent Get-DevStoreAccessibleRepos {
            param($Token)
            if ($Token -eq 'mine') { return @([pscustomobject]@{ full_name = 'qawalah/Tool'; description = 'mine' }) }
            return @([pscustomobject]@{ full_name = 'alialyami90/JIC'; description = 'shared' },
                     [pscustomobject]@{ full_name = 'qawalah/Tool'; description = 'seen twice' })
        }
        Mock -ModuleName DevStore.Agent Get-DevStoreReleases {
            param($Repo, $Token)
            $n = ($Repo -split '/')[1].ToLower()
            @([pscustomobject]@{ tag_name = 'windows-v1.0.0'; draft = $false; prerelease = $false; published_at = ''
                assets = @([pscustomobject]@{ id = 1; name = "$n-1.0.0-win-x64.zip" }) })
        }
        Mock -ModuleName DevStore.Agent Save-DevStoreAsset {}
        Mock -ModuleName DevStore.Agent Get-DevStoreRepoTree { @() }
    }

    It 'lists repos from every account, marks other owners as shared and remembers which token reads each' {
        $repoTokens = @{}
        Update-DevStoreCatalog -Root $Root -Tokens @(@{ login = 'qawalah'; token = 'mine' }, @{ login = 'alialyami90'; token = 'theirs' }) `
            -ReleaseCache @{} -RepoTokens $repoTokens

        $cat = Read-DevStoreJson -Path (Join-Path $Root 'catalog.json') -Default @{}
        $cat.apps['qawalah/Tool'].shared | Should -BeFalse
        $cat.apps['alialyami90/JIC'].shared | Should -BeTrue
        $cat.apps['alialyami90/JIC'].owner | Should -Be 'alialyami90'
        $repoTokens['qawalah/Tool'] | Should -Be 'mine'
        $repoTokens['alialyami90/JIC'] | Should -Be 'theirs'
        $cat.account | Should -Be 'qawalah'
    }
}
