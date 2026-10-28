BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'DevStore.Core.psm1') -Force

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
