Describe "Get-AndroidDirectoryContents" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager.ps1" }

    It "returns files, directories, and links" {
        $state = @{ 
            DirectoryCache = @{}
            DirectoryCacheAliases = @{ '/data' = '/data' }
            Features = @{ SupportsStatC = $true }
            Config = @{ VerboseLists = $false }
            MaxDirectoryCacheEntries = 100
        }
        Mock Invoke-AdbCommand {
            param($State, $Arguments)
            return [pscustomobject]@{ Success = $true; Output = "directory|0|/data/subdir`nregular file|12|/data/file.txt`nsymbolic link|0|/data/link"; State = $State }
        } -ParameterFilter { $Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'find' }
        $res = Get-AndroidDirectoryContents -State $state -Path '/data'
        $names = $res.Items | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Type }
        $names | Should -Be @('file.txt:File','link:Link','subdir:Directory')
    }
}
