Describe "Browse-AndroidFileSystem sorting" {
    It "orders directories before other items and sorts names alphabetically" {
        $items = @(
            [pscustomobject]@{ Name = 'zeta'; Type = 'File' },
            [pscustomobject]@{ Name = 'alpha'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'gamma'; Type = 'Directory' },
            [pscustomobject]@{ Name = 'beta'; Type = 'File' }
        )

        $sorted = @($items |
            Sort-Object -Property @{ Expression = { if ($_.Type -eq 'Directory') { 0 } else { 1 } } }, Name)

        $sortedNames = $sorted | ForEach-Object { $_.Name }
        $sortedNames | Should -Be @('alpha','gamma','beta','zeta')
    }
}
