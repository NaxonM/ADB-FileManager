Describe "Sort-BrowseItems" {
    BeforeAll {
        function Add-Type { param([Parameter(ValueFromRemainingArguments=$true)]$Args) }
        $scriptPath = "$PSScriptRoot/../adb-file-manager-V2.ps1"
        $raw = Get-Content $scriptPath -Raw
        $raw = $raw -replace 'Start-ADBTool\s*$',''
        Invoke-Expression $raw
    }

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

    It "places symlinks after directories even if they resolve to directories" {
        $items = @(
            [pscustomobject]@{ Name = 'zeta'; Type = 'File' },
            [pscustomobject]@{ Name = 'alpha'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'link'; Type = 'Link'; ResolvedType = 'Directory' },
            [pscustomobject]@{ Name = 'gamma'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'beta'; Type = 'File' }
        )

        $sortedNames = (Sort-BrowseItems $items) | ForEach-Object { $_.Name }
        $sortedNames | Should -Be @('alpha','gamma','beta','link','zeta')
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

Describe "Get-FileEmoji" {
    BeforeAll {
        function Add-Type { param([Parameter(ValueFromRemainingArguments=$true)]$Args) }
        $scriptPath = "$PSScriptRoot/../adb-file-manager-V2.ps1"
        $raw = Get-Content $scriptPath -Raw
        $raw = $raw -replace 'Start-ADBTool\s*$',''
        Invoke-Expression $raw
    }

    It "returns the correct emoji for known and unknown extensions" {
        $cases = @{
            'picture.png' = '🖼️'
            'clip.mkv'    = '🎞️'
            'track.flac'  = '🎵'
            'manual.pdf'  = '📕'
            'package.apk' = '🤖'
            'archive.tar' = '📦'
            'note.xyz'    = '📄'
        }

        foreach ($name in $cases.Keys) {
            Get-FileEmoji -FileName $name | Should -Be $cases[$name]
        }
    }
}
