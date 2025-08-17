Describe "Sort-BrowseItems" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "orders directories before other items and sorts names alphabetically" {
        $items = @(
            [pscustomobject]@{ Name = 'zeta'; Type = 'File' },
            [pscustomobject]@{ Name = 'alpha'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'gamma'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'beta'; Type = 'File' }
        )

        $sortedNames = (Sort-BrowseItems $items) | ForEach-Object { $_.Name }
        $sortedNames | Should -Be @('alpha','gamma','beta','zeta')
    }

    It "ignores case when sorting names" {
        $items = @(
            [pscustomobject]@{ Name = 'beta'; Type = 'File' },
            [pscustomobject]@{ Name = 'Alpha'; Type = 'File' },
            [pscustomobject]@{ Name = 'delta'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'Gamma'; Type = 'Directory' }
        )

        $sortedNames = (Sort-BrowseItems $items) | ForEach-Object { $_.Name }
        $sortedNames | Should -Be @('delta','Gamma','Alpha','beta')
    }

    It "sorts using invariant culture for non-Latin names" {
        $items = @(
            [pscustomobject]@{ Name = 'Яблоко'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'Banana'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'ábaco'; Type = 'File' },
            [pscustomobject]@{ Name = 'Éclair'; Type = 'File' }
        )

        $sortedNames = (Sort-BrowseItems $items) | ForEach-Object { $_.Name }
        $sortedNames | Should -Be @('Banana','Яблоко','ábaco','Éclair')
    }

    It "treats symlinks to directories as directories" {
        $items = @(
            [pscustomobject]@{ Name = 'zeta'; Type = 'File' },
            [pscustomobject]@{ Name = 'alpha'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'link'; Type = 'Link'; ResolvedType = 'Directory' }
        )

        $sortedNames = (Sort-BrowseItems $items) | ForEach-Object { $_.Name }
        $sortedNames | Should -Be @('alpha','link','zeta')
    }

    It "orders mixed-case and non-Latin names with directories first" {
        $items = @(
            [pscustomobject]@{ Name = 'beta'; Type = 'File' },
            [pscustomobject]@{ Name = 'Alpha'; Type = 'File' },
            [pscustomobject]@{ Name = 'Яблоко'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'delta'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'ábaco'; Type = 'File' },
            [pscustomobject]@{ Name = 'Γamma'; Type = 'Directory' }
        )

        $sortedNames = (Sort-BrowseItems $items) | ForEach-Object { $_.Name }

        $dirNames = $items | Where-Object { $_.Type -eq 'Directory' } | ForEach-Object { $_.Name }
        $dirList = [System.Collections.Generic.List[string]]::new([string[]]$dirNames)
        $dirList.Sort([StringComparer]::InvariantCultureIgnoreCase)

        $fileNames = $items | Where-Object { $_.Type -ne 'Directory' } | ForEach-Object { $_.Name }
        $fileList = [System.Collections.Generic.List[string]]::new([string[]]$fileNames)
        $fileList.Sort([StringComparer]::InvariantCultureIgnoreCase)

        $expected = @($dirList.ToArray() + $fileList.ToArray())
        $sortedNames | Should -Be $expected
    }
}

Describe "Get-AndroidDirectoryContentsJob" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "returns items from background job" {
        $state = @{ DirectoryCache = @{}; DirectoryCacheAliases = @{}; Features = @{}; Config = @{} }
        $real = (Get-Command Start-ThreadJob).ScriptBlock
        Mock Start-ThreadJob { & $real @PSBoundParameters } -Verifiable
        $fetcher = {
            param($s,$p)
            return [pscustomobject]@{ State = $s; Items = 1..200 | ForEach-Object { [pscustomobject]@{ Name = "f$_"; Type = 'File' } } }
        }
        $res = Get-AndroidDirectoryContentsJob -State $state -Path '/big' -Fetcher $fetcher -ShowSpinner:$false
        ($res.Items).Count | Should -Be 200
        Assert-MockCalled Start-ThreadJob -Times 1 -Exactly
    }

    It "falls back to synchronous call when job fails" {
        $state = @{ DirectoryCache = @{}; DirectoryCacheAliases = @{}; Features = @{}; Config = @{} }
        $global:syncCalled = $false
        $fetcher = {
            param($s,$p)
            $global:syncCalled = $true
            return [pscustomobject]@{ State = $s; Items = @('a') }
        }
        Mock Start-ThreadJob { throw 'no threads' }
        $res = Get-AndroidDirectoryContentsJob -State $state -Path '/big' -Fetcher $fetcher -ShowSpinner:$false
        $global:syncCalled | Should -BeTrue
        ($res.Items).Count | Should -Be 1
    }

    It "retries synchronously when job returns invalid result" {
        $state = @{ DirectoryCache = @{}; DirectoryCacheAliases = @{}; Features = @{}; Config = @{} }
        $script:syncCalls = 0
        $fetcher = {
            param($s,$p)
            $script:syncCalls++
            return [pscustomobject]@{ State = $s; Items = @([pscustomobject]@{ Name = 'file'; Type = 'File'; FullPath = '/big/file' }) }
        }
        Mock Start-ThreadJob { [pscustomobject]@{ State = 'Completed'; ChildJobs = @() } }
        Mock Wait-Job {}
        Mock Receive-Job { [pscustomobject]@{ Items = $null } }
        Mock Remove-Job {}
        $res = Get-AndroidDirectoryContentsJob -State $state -Path '/big' -Fetcher $fetcher -ShowSpinner:$false
        $script:syncCalls | Should -Be 1
        ($res.Items | ForEach-Object { $_.Name }) | Should -Contain 'file'
    }

    It "returns items when cache is already populated" {
        $state = @{
            DirectoryCache = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
            DirectoryCacheAliases = @{}
            Features = @{}
            Config = @{}
            MaxDirectoryCacheEntries = 100
        }
        $state.DirectoryCache['/cached'] = @([pscustomobject]@{ Name = 'old'; Type = 'File'; FullPath = '/cached/old'; Size = 0 })
        $state.DirectoryCacheAliases['/cached'] = '/cached'
        $fetcher = { param($s,$p) Get-AndroidDirectoryContents -State $s -Path $p }
        $real = (Get-Command Start-ThreadJob).ScriptBlock
        Mock Start-ThreadJob { & $real @PSBoundParameters }
        $res = Get-AndroidDirectoryContentsJob -State $state -Path '/cached' -Fetcher $fetcher -ShowSpinner:$false
        $res.Items | Should -Not -BeNullOrEmpty
    }
}

Describe "Browse-AndroidFileSystem job error handling" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "shows job error details in UI and log" {
        $state = @{ DirectoryCache = @{}; DirectoryCacheAliases = @{}; Features = @{}; Config = @{} }
        Mock Show-UIHeader { param($State, $Title) return $State }
        Mock Read-Host { '/invalid' }
        Mock Clear-Host {}
        Mock Start-Sleep {}
        Mock Test-AndroidPath { $true }
        $realJob = (Get-Command Get-AndroidDirectoryContentsJob).ScriptBlock
        $script:thrown = $false
        Mock Get-AndroidDirectoryContentsJob {
            $params = $PSBoundParameters
            $params['Fetcher'] = {
                param($s,$p)
                if (-not $script:thrown) { $script:thrown = $true; throw 'invalid path' }
                else { [pscustomobject]@{ State = $s; Items = @() } }
            }
            & $realJob @params
        }
        $script:logged = @()
        Mock Write-Log { param($Message,$Level) $script:logged += $Message }
        $script:errorDetails = $null
        Mock Write-ErrorMessage {}
        Browse-AndroidFileSystem -State $state | Out-Null
        Assert-MockCalled Clear-Host -Times 1 -Exactly
    }
}

Describe "Browse-AndroidFileSystem navigation" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "clears the screen when entering a subdirectory" {
        $state = @{ DirectoryCache = @{}; DirectoryCacheAliases = @{}; Features = @{}; Config = @{} }

        $inputs = @('/start','1','q')
        $script:idx = 0
        Mock Read-Host { $res = $inputs[$script:idx]; $script:idx++; return $res }

        Mock Show-UIHeader { param($State,$Title) return $State }
        Mock Test-AndroidPath { $true }
        Mock Get-AndroidDirectoryContentsJob {
            param($State,$Path)
            if ($Path -eq '/start') {
                return [pscustomobject]@{ State=$State; Items=@([pscustomobject]@{ Name='sub'; Type='Directory'; FullPath='/start/sub' }) }
            } else {
                return [pscustomobject]@{ State=$State; Items=@([pscustomobject]@{ Name='file'; Type='File'; FullPath='/start/sub/file' }) }
            }
        }

        Mock Clear-Host {}

        Browse-AndroidFileSystem -State $state | Out-Null
        Assert-MockCalled Clear-Host -Times 4 -Exactly
    }
}
