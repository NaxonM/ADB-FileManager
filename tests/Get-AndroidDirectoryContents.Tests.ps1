Describe "Get-AndroidDirectoryContents" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "parses ls output and returns correct item types" {
        $state = @{
            DirectoryCache = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{ SupportsLsTimeStyle = $true }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }

        $lsOut = @(
            'drwxr-xr-x 2 root root 0 1700000000 subdir/',
            '-rw-r--r-- 1 root root 12 1700000000 file.txt',
            'lrwxrwxrwx 1 root root 4 1700000000 link -> /target'
        ) -join "`n"

        Mock Invoke-AdbCommand {
            param($State,$Arguments)
            return [pscustomobject]@{ Success = $true; Output = $lsOut; State = $State }
        } -Verifiable -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments -contains '--time-style=+%s' }

        $res = Get-AndroidDirectoryContents -State $state -Path '/data'
        $names = $res.Items | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Type }
        $names | Should -Be @('file.txt:File','link:Link','subdir:Directory')
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments -contains '--time-style=+%s' } -Times 1
    }

    It "returns cached results on subsequent calls" {
        $state = @{
            DirectoryCache = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{ SupportsLsTimeStyle = $true }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }

        $lsOut = 'drwxr-xr-x 2 root root 0 1700000000 subdir/'

        Mock Invoke-AdbCommand {
            param($State,$Arguments)
            return [pscustomobject]@{ Success = $true; Output = $lsOut; State = $State }
        } -Verifiable -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments -contains '--time-style=+%s' }

        $res1 = Get-AndroidDirectoryContents -State $state -Path '/data'
        $res2 = Get-AndroidDirectoryContents -State $res1.State -Path '/data'
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments -contains '--time-style=+%s' } -Times 1
        ($res2.Items | ForEach-Object { $_.Name }) | Should -Contain 'subdir'
    }

    It "falls back when --time-style is unsupported" {
        $state = @{
            DirectoryCache = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{ SupportsLsTimeStyle = $false }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }

        $lsOut = @(
            'drwxr-xr-x 2 root root 0 Jan 1 2024 subdir/',
            '-rw-r--r-- 1 root root 12 Jan 1 2024 file.txt'
        ) -join "`n"

        Mock Invoke-AdbCommand {
            param($State,$Arguments)
            return [pscustomobject]@{ Success = $true; Output = $lsOut; State = $State }
        } -Verifiable -ParameterFilter { $Arguments[1] -eq 'ls' -and -not ($Arguments -contains '--time-style=+%s') }

        $res = Get-AndroidDirectoryContents -State $state -Path '/data'
        $names = $res.Items | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Type }
        $names | Should -Be @('file.txt:File','subdir:Directory')
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[1] -eq 'ls' -and -not ($Arguments -contains '--time-style=+%s') } -Times 1
        ($res.Items | Where-Object Name -eq 'file.txt').Timestamp | Should -BeGreaterThan 0
    }
}

