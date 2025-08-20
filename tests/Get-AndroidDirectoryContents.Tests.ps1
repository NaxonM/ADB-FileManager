Describe "Get-AndroidDirectoryContents" {
    BeforeAll {
        function Add-Type { param([Parameter(ValueFromRemainingArguments=$true)]$Args) }
        $scriptPath = "$PSScriptRoot/../adb-file-manager-V2.ps1"
        $raw = Get-Content $scriptPath -Raw
        $raw = $raw -replace 'Start-ADBTool\s*$',''
        Invoke-Expression $raw
    }

    BeforeEach { $script:DirectoryCache.Clear() }

    It "orders directories before files case-insensitively" {
        $lsOut = @(
            "-rw-r--r-- 1 root root 0 1700000000 zeta.txt",
            "drwxr-xr-x 2 root root 0 1700000000 Alpha",
            "drwxr-xr-x 2 root root 0 1700000000 gamma",
            "-rw-r--r-- 1 root root 0 1700000000 beta.txt"
        ) -join "`n"

        Mock Invoke-AdbCommand { [pscustomobject]@{ Success = $true; Output = $lsOut } } -Verifiable

        $items = Get-AndroidDirectoryContents -Path '/data'
        ($items | ForEach-Object { $_.Name }) | Should -Be @('Alpha','gamma','beta.txt','zeta.txt')
    }

    It "caches the sorted results for subsequent calls" {
        $lsOut = "drwxr-xr-x 2 root root 0 1700000000 subdir"
        Mock Invoke-AdbCommand { [pscustomobject]@{ Success = $true; Output = $lsOut } } -Verifiable

        $first = Get-AndroidDirectoryContents -Path '/data'
        $second = Get-AndroidDirectoryContents -Path '/data'

        Assert-MockCalled Invoke-AdbCommand -Times 1
        ($second | ForEach-Object { $_.Name }) | Should -Be @('subdir')
    }

    It "assigns icons based on file extension" {
        $lsOut = @(
            "-rw-r--r-- 1 root root 0 1700000000 photo.jpg",
            "-rw-r--r-- 1 root root 0 1700000000 movie.mp4",
            "-rw-r--r-- 1 root root 0 1700000000 song.mp3",
            "-rw-r--r-- 1 root root 0 1700000000 doc.pdf",
            "-rw-r--r-- 1 root root 0 1700000000 app.apk",
            "-rw-r--r-- 1 root root 0 1700000000 archive.zip",
            "-rw-r--r-- 1 root root 0 1700000000 unknown.xyz"
        ) -join "`n"

        Mock Invoke-AdbCommand { [pscustomobject]@{ Success = $true; Output = $lsOut } } -Verifiable

        $items = Get-AndroidDirectoryContents -Path '/data'
        $lookup = $items | Group-Object -Property Name -AsHashTable -AsString
        $lookup['photo.jpg'].Icon   | Should -Be '🖼️'
        $lookup['movie.mp4'].Icon   | Should -Be '🎞️'
        $lookup['song.mp3'].Icon    | Should -Be '🎵'
        $lookup['doc.pdf'].Icon     | Should -Be '📕'
        $lookup['app.apk'].Icon     | Should -Be '🤖'
        $lookup['archive.zip'].Icon | Should -Be '📦'
        $lookup['unknown.xyz'].Icon | Should -Be '📄'
    }
}

