Describe "Get-AndroidDirectoryContents" {
    BeforeAll { . "$PSScriptRoot/../adb-file-manager-V2.ps1" }

    BeforeEach { $script:DirectoryCache.Clear() }

    It "orders directories before files case-insensitively" {
        $lsOut = @(
            "-rw-r--r-- 1 root root 0 1700000000 zeta.txt",
            "drwxr-xr-x 2 root root 0 1700000000 Alpha/",
            "drwxr-xr-x 2 root root 0 1700000000 gamma/",
            "-rw-r--r-- 1 root root 0 1700000000 beta.txt"
        ) -join "`n"

        Mock Invoke-AdbCommand { [pscustomobject]@{ Success = $true; Output = $lsOut } } -Verifiable

        $items = Get-AndroidDirectoryContents -Path '/data'
        ($items | ForEach-Object { $_.Name }) | Should -Be @('Alpha','gamma','beta.txt','zeta.txt')
    }

    It "caches the sorted results for subsequent calls" {
        $lsOut = "drwxr-xr-x 2 root root 0 1700000000 subdir/"
        Mock Invoke-AdbCommand { [pscustomobject]@{ Success = $true; Output = $lsOut } } -Verifiable

        $first = Get-AndroidDirectoryContents -Path '/data'
        $second = Get-AndroidDirectoryContents -Path '/data'

        Assert-MockCalled Invoke-AdbCommand -Times 1
        ($second | ForEach-Object { $_.Name }) | Should -Be @('subdir')
    }
}

