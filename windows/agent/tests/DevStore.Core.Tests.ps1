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
