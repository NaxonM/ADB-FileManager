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
        Mock Get-AndroidDirectoryContentsJob {
            $params = $PSBoundParameters
            $params['Fetcher'] = { param($s,$p) throw 'invalid path' }
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
