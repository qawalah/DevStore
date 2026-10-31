BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'DevStore.Core.psm1') -Force

    function New-Release($Tag, [switch]$Draft, [switch]$Prerelease) {
        [pscustomobject]@{ tag_name = $Tag; draft = [bool]$Draft; prerelease = [bool]$Prerelease; assets = @() }
    }
}

Describe 'ConvertFrom-DevStoreTag' {
    It 'parses windows tags' {
        ConvertFrom-DevStoreTag 'windows-v1.2.3' | Should -Be ([version]'1.2.3')
    }
    It 'rejects android and malformed tags' {
        ConvertFrom-DevStoreTag 'android-v1.0+3' | Should -BeNullOrEmpty
        ConvertFrom-DevStoreTag 'windows-v1.2' | Should -BeNullOrEmpty
        ConvertFrom-DevStoreTag 'v1.2.3' | Should -BeNullOrEmpty
        ConvertFrom-DevStoreTag '' | Should -BeNullOrEmpty
    }
}

Describe 'Select-DevStoreRelease' {
    It 'picks the highest semver windows release, not the newest string' {
        $r = @(
            (New-Release 'windows-v1.9.0'),
            (New-Release 'windows-v1.10.0'),
            (New-Release 'android-v9.9.9+99'),
            (New-Release 'nonsense')
        )
        (Select-DevStoreRelease -Releases $r -Bad @()).tag_name | Should -Be 'windows-v1.10.0'
    }
    It 'skips drafts and prereleases' {
        $r = @(
            (New-Release 'windows-v1.0.0'),
            (New-Release 'windows-v2.0.0' -Draft),
            (New-Release 'windows-v3.0.0' -Prerelease)
        )
        (Select-DevStoreRelease -Releases $r -Bad @()).tag_name | Should -Be 'windows-v1.0.0'
    }
    It 'skips bad versions but takes a newer good one' {
        $r = @((New-Release 'windows-v1.0.0'), (New-Release 'windows-v1.1.0'), (New-Release 'windows-v1.2.0'))
        (Select-DevStoreRelease -Releases $r -Bad @('1.2.0')).tag_name | Should -Be 'windows-v1.1.0'
        $r += New-Release 'windows-v1.3.0'
        (Select-DevStoreRelease -Releases $r -Bad @('1.2.0')).tag_name | Should -Be 'windows-v1.3.0'
    }
    It 'copes with a list nested inside a list (Windows PowerShell 5.1 Invoke-RestMethod)' {
        $inner = @((New-Release 'windows-v1.0.0'), (New-Release 'windows-v1.2.0'))
        (Select-DevStoreRelease -Releases @(, $inner) -Bad @()).tag_name | Should -Be 'windows-v1.2.0'
    }
    It 'returns null when nothing qualifies' {
        Select-DevStoreRelease -Releases @() -Bad @() | Should -BeNullOrEmpty
        Select-DevStoreRelease -Releases @((New-Release 'android-v1+1')) -Bad @() | Should -BeNullOrEmpty
    }
}

Describe 'Read-DevStoreJson / Write-DevStoreJson' {
    It 'returns the default for a missing, empty or corrupt file' {
        $p = Join-Path $TestDrive 'missing.json'
        (Read-DevStoreJson -Path $p -Default @{ apps = @{} }).apps.Count | Should -Be 0
        Set-Content -Path $p -Value ''
        (Read-DevStoreJson -Path $p -Default @{ x = 1 }).x | Should -Be 1
        Set-Content -Path $p -Value '{"apps": {"a": '
        (Read-DevStoreJson -Path $p -Default @{ x = 2 }).x | Should -Be 2
    }
    It 'round-trips nested data as hashtables and leaves no temp file' {
        $p = Join-Path $TestDrive 'state.json'
        $state = @{ lastRun = '2026-10-28T10:00:00Z'; apps = @{ 'qawalah/x' = @{ installed = '1.0.0'; bad = @('0.9.0') } } }
        Write-DevStoreJson -Path $p -Object $state
        Test-Path "$p.tmp" | Should -BeFalse
        $back = Read-DevStoreJson -Path $p -Default @{}
        $back | Should -BeOfType [hashtable]
        $back.apps['qawalah/x'].installed | Should -Be '1.0.0'
        @($back.apps['qawalah/x'].bad) | Should -Be @('0.9.0')
    }
    It 'keeps single-item arrays as arrays' {
        $p = Join-Path $TestDrive 'arr.json'
        Write-DevStoreJson -Path $p -Object @{ bad = @('1.0.0') }
        (Get-Content $p -Raw) | Should -Match '\[\s*"1\.0\.0"\s*\]'
    }
}

Describe 'Get-DevStoreAction' {
    It 'installs when there is no state or nothing installed' {
        Get-DevStoreAction -AppState $null -Version '1.0.0' | Should -Be 'install'
        Get-DevStoreAction -AppState @{ installed = $null } -Version '1.0.0' | Should -Be 'install'
    }
    It 'does nothing for the same or an older version' {
        Get-DevStoreAction -AppState @{ installed = '1.2.0' } -Version '1.2.0' | Should -Be 'none'
        Get-DevStoreAction -AppState @{ installed = '1.2.0' } -Version '1.1.0' | Should -Be 'none'
    }
    It 'updates for a newer version' {
        Get-DevStoreAction -AppState @{ installed = '1.2.0' } -Version '1.10.0' | Should -Be 'update'
    }
}

Describe 'Get-DevStorePruneList' {
    It 'keeps current and previous only' {
        $r = Get-DevStorePruneList -Versions @('1.0.0', '1.1.0', '1.2.0', '1.3.0') -Current '1.3.0' -Previous '1.2.0'
        $r | Sort-Object | Should -Be @('1.0.0', '1.1.0')
    }
    It 'handles no previous' {
        Get-DevStorePruneList -Versions @('1.0.0') -Current '1.0.0' -Previous $null | Should -BeNullOrEmpty
    }
}

Describe 'Test-DevStoreHash' {
    It 'matches the sha256 file format case-insensitively and rejects mismatches' {
        $f = Join-Path $TestDrive 'a.zip'
        Set-Content -Path $f -Value 'hello' -NoNewline
        $h = (Get-FileHash $f -Algorithm SHA256).Hash
        Test-DevStoreHash -File $f -ShaText "$($h.ToLower())  a.zip" | Should -BeTrue
        Test-DevStoreHash -File $f -ShaText $h | Should -BeTrue
        Test-DevStoreHash -File $f -ShaText ('0' * 64) | Should -BeFalse
        Test-DevStoreHash -File $f -ShaText '' | Should -BeFalse
    }
}

Describe 'New-DevStoreWinswXml' {
    It 'produces a WinSW config for the app' {
        $xml = [xml](New-DevStoreWinswXml -Name 'my-svc' -Exe 'C:\DevStore\apps\my-svc\current\my-svc.exe' -LogDir 'C:\DevStore\logs\my-svc')
        $xml.service.id | Should -Be 'devstore-my-svc'
        $xml.service.executable | Should -Be 'C:\DevStore\apps\my-svc\current\my-svc.exe'
        $xml.service.startmode | Should -Be 'Automatic'
        $xml.service.stoptimeout | Should -Be '30 sec'
        $xml.service.onfailure.action | Should -Be 'restart'
        $xml.service.logpath | Should -Be 'C:\DevStore\logs\my-svc'
    }
    It 'escapes XML special characters' {
        { [xml](New-DevStoreWinswXml -Name 'a' -Exe 'C:\a&b\x.exe' -LogDir 'C:\l') } | Should -Not -Throw
    }
}

Describe 'Set-DevStoreConfigApp' {
    It 'adds and removes repos idempotently, case-insensitively' {
        $c = @{ apps = @() }
        $c = Set-DevStoreConfigApp -Config $c -Repo 'qawalah/x' -Present $true
        $c = Set-DevStoreConfigApp -Config $c -Repo 'Qawalah/X' -Present $true
        @($c.apps).Count | Should -Be 1
        $c = Set-DevStoreConfigApp -Config $c -Repo 'qawalah/y' -Present $true
        $c = Set-DevStoreConfigApp -Config $c -Repo 'QAWALAH/x' -Present $false
        @($c.apps | ForEach-Object { $_.repo }) | Should -Be @('qawalah/y')
    }
    It 'works on a config with no apps key' {
        $c = Set-DevStoreConfigApp -Config @{} -Repo 'qawalah/x' -Present $true
        @($c.apps).Count | Should -Be 1
    }
}

Describe 'Test-DevStoreRepoName' {
    It 'validates owner/repo' {
        Test-DevStoreRepoName 'qawalah/my-app' | Should -BeTrue
        Test-DevStoreRepoName 'qawalah/my.app_2' | Should -BeTrue
        Test-DevStoreRepoName 'qawalah' | Should -BeFalse
        Test-DevStoreRepoName 'a/b; rm' | Should -BeFalse
        Test-DevStoreRepoName '../x/y' | Should -BeFalse
    }
}

Describe 'ConvertTo-DevStoreSafeName' {
    It 'makes a folder-safe name from owner/repo' {
        ConvertTo-DevStoreSafeName 'Qawalah/My.App_2' | Should -Be 'qawalah__my.app_2'
    }
}

Describe 'ConvertFrom-DevStoreRequest' {
    It 'accepts install, remove and check requests' {
        (ConvertFrom-DevStoreRequest @{ action = 'install'; repo = 'qawalah/x' }).action | Should -Be 'install'
        (ConvertFrom-DevStoreRequest @{ action = 'remove'; repo = 'qawalah/x' }).repo | Should -Be 'qawalah/x'
        (ConvertFrom-DevStoreRequest @{ action = 'check' }).action | Should -Be 'check'
    }
    It 'rejects bad requests' {
        ConvertFrom-DevStoreRequest @{ action = 'install'; repo = 'bad repo' } | Should -BeNullOrEmpty
        ConvertFrom-DevStoreRequest @{ action = 'delete-everything'; repo = 'qawalah/x' } | Should -BeNullOrEmpty
        ConvertFrom-DevStoreRequest $null | Should -BeNullOrEmpty
        ConvertFrom-DevStoreRequest @{ repo = 'qawalah/x' } | Should -BeNullOrEmpty
    }
}

Describe 'Select-DevStoreStoreAssets' {
    It 'finds store.json, the icon and up to 6 screenshots in order' {
        $names = @('app-1.0.0-win-x64.zip', 'store.json', 'store-icon.png') + (1..8 | ForEach-Object { "store-screenshot-$_.png" })
        $rel = [pscustomobject]@{ assets = @($names | ForEach-Object { [pscustomobject]@{ id = $_; name = $_ } }) }
        $a = Select-DevStoreStoreAssets $rel
        $a.meta.name | Should -Be 'store.json'
        $a.icon.name | Should -Be 'store-icon.png'
        @($a.screenshots).Count | Should -Be 6
        $a.screenshots[0].name | Should -Be 'store-screenshot-1.png'
    }
    It 'copes with a release without store files' {
        $rel = [pscustomobject]@{ assets = @([pscustomobject]@{ id = 1; name = 'x-1.0.0-win-x64.zip' }) }
        $a = Select-DevStoreStoreAssets $rel
        $a.meta | Should -BeNullOrEmpty
        $a.icon | Should -BeNullOrEmpty
        @($a.screenshots).Count | Should -Be 0
    }
}

Describe 'GitHub account list (tokens)' {
    It 'reads the old single-token format' {
        $list = @(ConvertFrom-DevStoreTokenText 'github_pat_old')
        @($list).Count | Should -Be 1
        $list[0].token | Should -Be 'github_pat_old'
        $list[0].login | Should -BeNullOrEmpty
    }
    It 'round-trips several accounts' {
        $list = @(@{ login = 'qawalah'; token = 'a' }, @{ login = 'alialyami90'; token = 'b' })
        $back = @(ConvertFrom-DevStoreTokenText (ConvertTo-DevStoreTokenText $list))
        @($back | ForEach-Object { $_.login }) | Should -Be @('qawalah', 'alialyami90')
        $back[1].token | Should -Be 'b'
    }
    It 'adds or replaces accounts' {
        $list = @(@{ login = 'qawalah'; token = 'a' })
        $list = @(Set-DevStoreTokenEntry -List $list -Login 'alialyami90' -Token 'b' -Mode 'add')
        $list = @(Set-DevStoreTokenEntry -List $list -Login 'ALIALYAMI90' -Token 'c' -Mode 'add')
        @($list).Count | Should -Be 2
        $list[1].token | Should -Be 'c'
        $list = @(Set-DevStoreTokenEntry -List $list -Login 'qawalah' -Token 'd' -Mode 'replace')
        @($list).Count | Should -Be 1
        $list[0].token | Should -Be 'd'
    }
    It 'treats empty text as no accounts' {
        @(ConvertFrom-DevStoreTokenText '').Count | Should -Be 0
    }
}

Describe 'Update modes' {
    It 'uses the app setting, then the default, then automatic' {
        $c = @{ apps = @(@{ repo = 'qawalah/a'; updates = 'notify' }, @{ repo = 'qawalah/b' }) }
        Get-DevStoreUpdateMode -Config $c -Repo 'QAWALAH/A' | Should -Be 'notify'
        Get-DevStoreUpdateMode -Config $c -Repo 'qawalah/b' | Should -Be 'auto'
        $c.defaultUpdates = 'download'
        Get-DevStoreUpdateMode -Config $c -Repo 'qawalah/b' | Should -Be 'download'
    }
    It 'sets a per-app mode or the default' {
        $c = @{ apps = @(@{ repo = 'qawalah/a' }) }
        $c = Set-DevStoreConfigUpdates -Config $c -Repo 'qawalah/a' -Mode 'download'
        $c.apps[0].updates | Should -Be 'download'
        $c = Set-DevStoreConfigUpdates -Config $c -Repo $null -Mode 'notify'
        $c.defaultUpdates | Should -Be 'notify'
        $c = Set-DevStoreConfigUpdates -Config $c -Repo 'qawalah/a' -Mode 'default'
        $c.apps[0].ContainsKey('updates') | Should -BeFalse
    }
    It 'accepts apply and set-updates requests' {
        (ConvertFrom-DevStoreRequest @{ action = 'apply'; repo = 'qawalah/a' }).action | Should -Be 'apply'
        $r = ConvertFrom-DevStoreRequest @{ action = 'set-updates'; repo = 'qawalah/a'; mode = 'notify' }
        $r.mode | Should -Be 'notify'
        (ConvertFrom-DevStoreRequest @{ action = 'set-updates'; mode = 'download' }).repo | Should -BeNullOrEmpty
        ConvertFrom-DevStoreRequest @{ action = 'set-updates'; repo = 'qawalah/a'; mode = 'sometimes' } | Should -BeNullOrEmpty
    }
}

Describe 'Select-DevStoreRepoStoreFiles' {
    It 'finds screenshots next to devstore.json first (SimDeck layout)' {
        $paths = @('windows/devstore.json', 'docs/images/play.png') + (1..8 | ForEach-Object { 'windows/docs/screenshots/{0:D2}-x.png' -f $_ })
        $r = Select-DevStoreRepoStoreFiles -Paths $paths
        @($r.screenshots).Count | Should -Be 6
        $r.screenshots[0] | Should -Be 'windows/docs/screenshots/01-x.png'
    }
    It 'finds an icon in common places (Werd layout)' {
        $paths = @('server/devstore.json', 'server/web/app/icon-192.png', 'server/web/app/icon-512.png', 'server/winres/icon.png')
        (Select-DevStoreRepoStoreFiles -Paths $paths).icon | Should -Be 'server/winres/icon.png'
        (Select-DevStoreRepoStoreFiles -Paths @('server/devstore.json', 'server/web/app/icon-192.png', 'server/web/app/icon-512.png')).icon |
            Should -Be 'server/web/app/icon-512.png'
    }
    It 'falls back to the repo root and skips icons in screenshot folders' {
        $paths = @('devstore.json', 'screenshots/icon.png', 'screenshots/b.png', 'screenshots/a.png', 'store/icon.png')
        $r = Select-DevStoreRepoStoreFiles -Paths $paths
        $r.icon | Should -Be 'store/icon.png'
        @($r.screenshots) | Should -Be @('screenshots/a.png', 'screenshots/b.png')
    }
    It 'returns nothing for a repo without pictures' {
        $r = Select-DevStoreRepoStoreFiles -Paths @('devstore.json', 'main.py')
        $r.icon | Should -BeNullOrEmpty
        @($r.screenshots).Count | Should -Be 0
    }
}

Describe 'Test builds from pull requests' {
    BeforeAll {
        function New-Rel($Tag, [switch]$Pre, $Name = '') { [pscustomobject]@{ tag_name = $Tag; draft = $false; prerelease = [bool]$Pre; name = $Name; published_at = '' } }
    }
    It 'parses PR build tags' {
        $t = ConvertFrom-DevStorePrTag 'windows-v1.3.0-pr12.7'
        $t.version | Should -Be '1.3.0-pr12.7'
        $t.pr | Should -Be 12
        $t.build | Should -Be 7
        ConvertFrom-DevStorePrTag 'windows-v1.3.0' | Should -BeNullOrEmpty
    }
    It 'stable ignores test builds; a PR channel takes that PR''s newest build' {
        $rels = @((New-Rel 'windows-v1.2.0'), (New-Rel 'windows-v1.3.0-pr12.5' -Pre), (New-Rel 'windows-v1.3.0-pr12.9' -Pre), (New-Rel 'windows-v1.4.0-pr15.2' -Pre))
        (Select-DevStoreChannelRelease -Releases $rels -Channel 'stable' -Bad @()).tag_name | Should -Be 'windows-v1.2.0'
        (Select-DevStoreChannelRelease -Releases $rels -Channel 'pr-12' -Bad @()).tag_name | Should -Be 'windows-v1.3.0-pr12.9'
        (Select-DevStoreChannelRelease -Releases $rels -Channel 'pr-12' -Bad @('1.3.0-pr12.9')).tag_name | Should -Be 'windows-v1.3.0-pr12.5'
    }
    It 'falls back to stable when the PR has no builds (closed)' {
        $rels = @((New-Rel 'windows-v1.2.0'))
        (Select-DevStoreChannelRelease -Releases $rels -Channel 'pr-99' -Bad @()).tag_name | Should -Be 'windows-v1.2.0'
    }
    It 'lists the newest build of each open PR' {
        $rels = @((New-Rel 'windows-v1.2.0'), (New-Rel 'windows-v1.3.0-pr12.5' -Pre 'PR #12: New menu'), (New-Rel 'windows-v1.3.0-pr12.9' -Pre 'PR #12: New menu'), (New-Rel 'windows-v1.4.0-pr15.2' -Pre 'PR #15: Fix crash'))
        $list = @(Get-DevStorePrBuilds -Releases $rels)
        @($list | ForEach-Object { $_.pr }) | Should -Be @(12, 15)
        $list[0].version | Should -Be '1.3.0-pr12.9'
        $list[0].title | Should -Be 'PR #12: New menu'
    }
    It 'switching between stable and a test build counts as an update both ways' {
        Get-DevStoreAction -AppState @{ installed = '1.2.0' } -Version '1.3.0-pr12.9' | Should -Be 'update'
        Get-DevStoreAction -AppState @{ installed = '1.3.0-pr12.9' } -Version '1.2.0' | Should -Be 'update'
        Get-DevStoreAction -AppState @{ installed = '1.3.0-pr12.9' } -Version '1.3.0-pr12.9' | Should -Be 'none'
        Get-DevStoreAction -AppState @{ installed = '1.3.0' } -Version '1.2.0' | Should -Be 'none'
    }
    It 'reads the channel from config and accepts set-channel requests' {
        $c = @{ apps = @(@{ repo = 'qawalah/a'; channel = 'pr-12' }, @{ repo = 'qawalah/b' }) }
        Get-DevStoreChannel -Config $c -Repo 'qawalah/A' | Should -Be 'pr-12'
        Get-DevStoreChannel -Config $c -Repo 'qawalah/b' | Should -Be 'stable'
        $c = Set-DevStoreConfigChannel -Config $c -Repo 'qawalah/b' -Channel 'pr-3'
        Get-DevStoreChannel -Config $c -Repo 'qawalah/b' | Should -Be 'pr-3'
        (ConvertFrom-DevStoreRequest @{ action = 'set-channel'; repo = 'qawalah/a'; channel = 'pr-12' }).channel | Should -Be 'pr-12'
        (ConvertFrom-DevStoreRequest @{ action = 'set-channel'; repo = 'qawalah/a'; channel = 'stable' }).channel | Should -Be 'stable'
        ConvertFrom-DevStoreRequest @{ action = 'set-channel'; repo = 'qawalah/a'; channel = 'pr-x; rm' } | Should -BeNullOrEmpty
    }
}

Describe 'Starred repos (watch only)' {
    It 'is due hourly, or right away when asked' {
        $now = [datetime]'2026-10-31T12:00:00Z'
        Test-DevStoreStarredDue -Last $null -Now $now | Should -BeTrue
        Test-DevStoreStarredDue -Last '2026-10-31T11:30:00Z' -Now $now | Should -BeFalse
        Test-DevStoreStarredDue -Last '2026-10-31T10:59:00Z' -Now $now | Should -BeTrue
        Test-DevStoreStarredDue -Last '2026-10-31T11:59:00Z' -Now $now -Force | Should -BeTrue
    }
    It 'turns a repo and its newest stable release into a plain entry' {
        $repo = [pscustomobject]@{ full_name = 'someone/tool'; description = 'A tool'; html_url = 'https://github.com/someone/tool'
            owner = [pscustomobject]@{ avatar_url = 'https://avatars.githubusercontent.com/u/1?v=4' } }
        $rels = @(
            [pscustomobject]@{ tag_name = 'v2.0.0-beta'; name = 'Beta'; draft = $false; prerelease = $true; published_at = '2026-10-30T00:00:00Z'; body = 'b'; html_url = 'x'; assets = @() },
            [pscustomobject]@{ tag_name = 'v1.9.0'; name = 'Tool 1.9'; draft = $false; prerelease = $false; published_at = '2026-10-20T00:00:00Z'
                body = ('x' * 5000); html_url = 'https://github.com/someone/tool/releases/tag/v1.9.0'
                assets = @([pscustomobject]@{ name = 'tool-setup.exe'; size = 1048576; browser_download_url = 'https://github.com/someone/tool/releases/download/v1.9.0/tool-setup.exe' }) })
        $e = ConvertTo-DevStoreStarredEntry -Repo $repo -Releases $rels
        $e.repo | Should -Be 'someone/tool'
        $e.avatar | Should -Match '^https://avatars\.githubusercontent\.com/'
        $e.latest.tag | Should -Be 'v1.9.0'
        $e.latest.notes.Length | Should -BeLessOrEqual 4000
        $e.latest.assets[0].name | Should -Be 'tool-setup.exe'
        $e.latest.assets[0].url | Should -Match '^https://github\.com/'
    }
    It 'keeps repos without releases, with no latest version' {
        $repo = [pscustomobject]@{ full_name = 'someone/lib'; description = $null; html_url = 'https://github.com/someone/lib'; owner = $null }
        $e = ConvertTo-DevStoreStarredEntry -Repo $repo -Releases @()
        $e.latest | Should -BeNullOrEmpty
    }
    It 'drops links that do not point at GitHub' {
        $repo = [pscustomobject]@{ full_name = 'a/b'; description = ''; html_url = 'javascript:alert(1)'; owner = $null }
        $rels = @([pscustomobject]@{ tag_name = 'v1'; name = ''; draft = $false; prerelease = $false; published_at = ''; body = ''; html_url = 'http://evil'
                assets = @([pscustomobject]@{ name = 'x.exe'; size = 1; browser_download_url = 'https://evil.example/x.exe' }) })
        $e = ConvertTo-DevStoreStarredEntry -Repo $repo -Releases $rels
        $e.url | Should -Be 'https://github.com/a/b'
        $e.latest.url | Should -Be 'https://github.com/a/b/releases'
        @($e.latest.assets).Count | Should -Be 0
    }
}
