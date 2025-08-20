Describe "Execute-PushTransfer" {
    BeforeAll {
        function Invalidate-DirectoryCache { param($State,$DirectoryPath) return $State }
        function Show-InlineProgress {}
        function Execute-PushTransfer {
            param(
                [hashtable]$State,
                [string[]]$Items,
                [hashtable]$ItemSizes,
                [string]$Destination
            )

            $successCount = 0; $failureCount = 0
            foreach ($item in $Items) {
                $itemStart = Get-Date
                $nonProgress = @()
                & adb push -p $item $Destination 2>&1 | ForEach-Object {
                    $line = $_.ToString()
                    if ($line -match '\[(?:\s*)(\d+)%\]\s*(\d+)/(\d+)') {
                        Show-InlineProgress -Activity "Pushing $(Split-Path $item -Leaf)" -CurrentValue ([int64]$matches[2]) -TotalValue ([int64]$matches[3]) -StartTime $itemStart
                    } elseif ($line -match '\[(?:\s*)(\d+)%\]\s*(\d+)') {
                        Show-InlineProgress -Activity "Pushing $(Split-Path $item -Leaf)" -CurrentValue ([int64]$matches[2]) -TotalValue ([int64]$ItemSizes[$item]) -StartTime $itemStart
                    } elseif ($line -match '(\d+)/(\d+)') {
                        Show-InlineProgress -Activity "Pushing $(Split-Path $item -Leaf)" -CurrentValue ([int64]$matches[1]) -TotalValue ([int64]$matches[2]) -StartTime $itemStart
                    } else {
                        $nonProgress += $line
                    }
                }
                Show-InlineProgress -Activity "Pushing $(Split-Path $item -Leaf)" -CurrentValue $ItemSizes[$item] -TotalValue $ItemSizes[$item] -StartTime $itemStart
                Write-Host ""
                $resultOutput = ($nonProgress -join "`n").Trim()
                if ($LASTEXITCODE -eq 0) {
                    $successCount++
                    if ($resultOutput) { $resultOutput -split "`n" | ForEach-Object { Write-Host $_ } }
                    $State = Invalidate-DirectoryCache $State $Destination
                } else {
                    $failureCount++
                    if ($resultOutput) { $resultOutput -split "`n" | ForEach-Object { Write-Host $_ } }
                }
            }
            [pscustomobject]@{ SuccessCount = $successCount; FailureCount = $failureCount; State = $State }
        }
    }

    It "treats a 0 exit code as success even if stderr has content" {
        $tempFile = New-TemporaryFile
        Set-Content -LiteralPath $tempFile -Value "data"

        $state = @{
            Config = @{ WhatIf = $false }
            Features = @{ SupportsDuSb = $false }
            DirectoryCache = @{}
            DirectoryCacheAliases = @{}
            DeviceStatus = @{ SerialNumber = 'ABC' }
        }

        function adb {
            param($cmd,$flag,$src,$dest)
            Write-Output "1 file pushed"
            Write-Error "error: ignored"
            $global:LASTEXITCODE = 0
        }

        $script:writes = @()
        Mock Write-Host { param($Object) $script:writes += $Object }

        $result = Execute-PushTransfer -State $state -Items @($tempFile) -ItemSizes @{$tempFile = (Get-Item $tempFile).Length} -Destination '/sdcard'

        $result.SuccessCount | Should -Be 1
        $result.FailureCount | Should -Be 0
        $script:writes | Should -Contain '1 file pushed'
        $script:writes | Should -Contain 'error: ignored'
    }

    It "invokes Show-InlineProgress when progress lines are emitted" {
        $tempFile = New-TemporaryFile
        Set-Content -LiteralPath $tempFile -Value "data"

        $state = @{
            Config = @{ WhatIf = $false }
            Features = @{ SupportsDuSb = $false }
            DirectoryCache = @{}
            DirectoryCacheAliases = @{}
            DeviceStatus = @{ SerialNumber = 'ABC' }
        }

        function adb {
            param($cmd,$flag,$src,$dest)
            $lines = "[ 10%] 1/10","[ 50%] 5/10","[100%] 10/10","1 file pushed"
            foreach ($l in $lines) { Write-Output $l }
            $global:LASTEXITCODE = 0
        }

        $script:calls = @()
        Mock Show-InlineProgress {
            param($Activity,$CurrentValue,$TotalValue,$StartTime)
            $script:calls += "${CurrentValue}/${TotalValue}"
        }

        Execute-PushTransfer -State $state -Items @($tempFile) -ItemSizes @{$tempFile = 10} -Destination '/sdcard'

        $script:calls | Should -Contain '1/10'
        $script:calls | Should -Contain '5/10'
        $script:calls | Should -Contain '10/10'
    }

    It "streams progress incrementally" {
        $tempFile = New-TemporaryFile
        Set-Content -LiteralPath $tempFile -Value "data"

        $state = @{
            Config = @{ WhatIf = $false }
            Features = @{ SupportsDuSb = $false }
            DirectoryCache = @{}
            DirectoryCacheAliases = @{}
            DeviceStatus = @{ SerialNumber = 'ABC' }
        }

        function adb {
            param($cmd,$flag,$src,$dest)
            $lines = "[ 10%] 1/10","[ 50%] 5/10","[100%] 10/10","1 file pushed"
            foreach ($l in $lines) {
                Write-Output $l
                Start-Sleep -Milliseconds 50
            }
            $global:LASTEXITCODE = 0
        }

        $script:times = @()
        Mock Show-InlineProgress {
            param($Activity,$CurrentValue,$TotalValue,$StartTime)
            $script:times += Get-Date
        }

        Execute-PushTransfer -State $state -Items @($tempFile) -ItemSizes @{$tempFile = 10} -Destination '/sdcard'

        $script:times.Count | Should -BeGreaterOrEqual 3
        ($script:times[1] -gt $script:times[0]) | Should -BeTrue
        ($script:times[2] -gt $script:times[1]) | Should -BeTrue
    }
}

