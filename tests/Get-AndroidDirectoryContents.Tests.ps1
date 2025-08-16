Describe "Get-AndroidDirectoryContents" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "returns files, directories, and links" {
        $state = @{
            DirectoryCache = @{}
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{ SupportsStatC = $true; SupportsFind = $true }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            return [pscustomobject]@{ Success = $true; Output = "directory|0|/data/subdir`nregular file|12|/data/file.txt`nsymbolic link|0|/data/link"; State = $State }
        } -ParameterFilter { $Arguments[-1] -like 'find*' }
        $res = Get-AndroidDirectoryContents -State $state -Path '/data'
        $names = $res.Items | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Type }
        $names | Should -Be @('file.txt:File','link:Link','subdir:Directory')
    }

    It "keeps results even if find would fail" {
        $state = @{
            DirectoryCache = @{}
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{ SupportsStatC = $true; SupportsFind = $true }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            return [pscustomobject]@{ Success = $false; Output = ""; State = $State }
        } -ParameterFilter { $Arguments[-1] -like 'find*' }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            $out = @('total 0','drwxr-xr-x 2 root root 0 Jan 1 00:00 visible') -join "`n"
            return [pscustomobject]@{ Success = $true; Output = $out; State = $State }
        } -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments[2] -eq '-al' }
        $res = Get-AndroidDirectoryContents -State $state -Path '/data'
        ($res.Items | ForEach-Object { $_.Name }) | Should -Contain 'visible'
    }

    It "falls back to ls when find fails and caches decision" {
        $state = @{
            DirectoryCache = @{}
            DirectoryCacheAliases = @{ '/data' = '/data'; '/other' = '/other' }
            Features = @{ SupportsStatC = $false; SupportsFind = $true }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            return [pscustomobject]@{ Success = $false; Output = ''; State = $State }
        } -ParameterFilter { $Arguments[-1] -like 'find*' }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            $out = @(
                'total 0',
                'drwxr-xr-x 2 root root 0 Jan 1 00:00 subdir',
                '-rw-r--r-- 1 root root 12 Jan 1 00:00 file.txt',
                'd--------- 0 root root 0 Jan 1 00:00 restricted'
            ) -join "`n"
            return [pscustomobject]@{ Success = $true; Output = $out; State = $State }
        } -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments[2] -eq '-al' -and $Arguments[3] -eq "'/data'" }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            $out = @(
                'total 0',
                '-rw-r--r-- 1 root root 5 Jan 1 00:00 other.txt'
            ) -join "`n"
            return [pscustomobject]@{ Success = $true; Output = $out; State = $State }
        } -ParameterFilter { $Arguments[1] -eq 'ls' -and $Arguments[2] -eq '-al' -and $Arguments[3] -eq "'/other'" }

        $res1 = Get-AndroidDirectoryContents -State $state -Path '/data'
        $names1 = $res1.Items | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Type }
        $names1 | Should -Be @('file.txt:File','restricted:Directory','subdir:Directory')
        $res1.State.Features.SupportsFind | Should -BeFalse

        $res2 = Get-AndroidDirectoryContents -State $res1.State -Path '/other'
        $res2.State.Features.SupportsFind | Should -BeFalse
        Assert-MockCalled Invoke-AdbCommand -ParameterFilter { $Arguments[-1] -like 'find*' } -Times 1
    }
}
