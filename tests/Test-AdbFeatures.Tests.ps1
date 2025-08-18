Describe "Test-AdbFeatures" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "caches ls time-style support on success" {
        $state = @{
            DirectoryCache = @{}
            DirectoryCacheAliases = @{}
            Features = @{}
            Config = @{}
            DeviceStatus = @{ IsConnected = $true }
        }

        Mock Invoke-AdbCommand {
            param($State,$Arguments,$TimeoutMs,$RawOutput,$SuppressErrors)
            if ($Arguments[0] -eq 'version') {
                return [pscustomobject]@{ Success = $true; Output = 'Android Debug Bridge version 1.0.41'; State = $State }
            }
            elseif ($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'du') {
                return [pscustomobject]@{ Success = $true; Output = '123'; State = $State }
            }
            elseif ($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'sh') {
                return [pscustomobject]@{ Success = $true; StdOut = ''; StdErr = ''; ExitCode = 0; State = $State }
            }
        }

        $state = Test-AdbFeatures -State $state
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'sh' } -Times 1
        $state = Test-AdbFeatures -State $state
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'sh' } -Times 1
        $state.Features.SupportsLsTimeStyle | Should -BeTrue
    }

    It "falls back without error when ls time-style unsupported" {
        $state = @{
            DirectoryCache = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{}
            Config = @{ VerboseLists = $false }
            DeviceStatus = @{ IsConnected = $true }
            MaxDirectoryCacheEntries = 100
        }
        $logs = @()
        Mock Write-Log { param($Message,$Level) $logs += $Level }

        Mock Invoke-AdbCommand {
            param($State,$Arguments,$TimeoutMs,$RawOutput,$SuppressErrors)
            if ($Arguments[0] -eq 'version') {
                return [pscustomobject]@{ Success = $true; Output = 'Android Debug Bridge version 1.0.41'; State = $State }
            }
            elseif ($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'du') {
                return [pscustomobject]@{ Success = $true; Output = '123'; State = $State }
            }
            elseif ($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'sh') {
                return [pscustomobject]@{ Success = $false; StdOut = ''; StdErr = 'bad'; ExitCode = 1; State = $State }
            }
            elseif ($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'ls') {
                return [pscustomobject]@{ Success = $true; Output = 'drwxr-xr-x 2 root root 0 Jan 1 2024 subdir/'; State = $State }
            }
        }

        $state = Test-AdbFeatures -State $state
        $state.Features.SupportsLsTimeStyle | Should -BeFalse
        $logs | Should -Not -Contain 'ERROR'
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'sh' } -Times 1

        $state = Test-AdbFeatures -State $state
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'sh' } -Times 1

        $res = Get-AndroidDirectoryContents -State $state -Path '/data'
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'ls' -and -not ($Arguments -contains '--time-style=+%s') } -Times 1
    }
}
