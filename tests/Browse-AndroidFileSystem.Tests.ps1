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
