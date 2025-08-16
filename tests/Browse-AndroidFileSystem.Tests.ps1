Describe "Browse-AndroidFileSystem sorting" {
    BeforeAll {
        function Sort-BrowseItems {
            param([array]$Items)
            $list = [System.Collections.Generic.List[psobject]]::new([psobject[]]$Items)
            $comparison = [System.Comparison[psobject]]{
                param($a, $b)
                $aRank = if ($a.Type -eq 'Directory') { 0 } else { 1 }
                $bRank = if ($b.Type -eq 'Directory') { 0 } else { 1 }
                $rankCompare = $aRank.CompareTo($bRank)
                if ($rankCompare -ne 0) { return $rankCompare }
                return [StringComparer]::InvariantCultureIgnoreCase.Compare($a.Name, $b.Name)
            }
            $list.Sort($comparison)
            return $list
        }
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
}
