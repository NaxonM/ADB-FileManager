function Test-AndroidPath {}
function Start-AdbProcess {}
function Invalidate-DirectoryCache { param($State,$DirectoryPath) return $State }
function Show-InlineProgress {}

function Execute-PushTransfer {
    param(
        [hashtable]$State,
        [string[]]$Items,
        [hashtable]$ItemSizes,
        [string]$Destination,
        [int]$UpdateInterval = 0
    )

    $successCount = 0; $failureCount = 0
    foreach ($item in $Items) {
        $stdoutPath = New-TemporaryFile
        $stderrPath = New-TemporaryFile
        $proc = Start-AdbProcess -State $State -Arguments @('push','-p',$item,$Destination) -StdOutPath $stdoutPath -StdErrPath $stderrPath

        $startTime = Get-Date
        if (Test-Path $stdoutPath) {
            Get-Content -Path $stdoutPath | ForEach-Object {
                $line = $_
                if ($line -match '\[(?:\s*)(\d+)%\]\s*(\d+)/(\d+)') {
                    Show-InlineProgress -Activity "Pushing $(Split-Path $item -Leaf)" -CurrentValue ([int64]$matches[2]) -TotalValue ([int64]$matches[3]) -StartTime $startTime
                } elseif ($line -match '\[(?:\s*)(\d+)%\]\s*(\d+)') {
                    Show-InlineProgress -Activity "Pushing $(Split-Path $item -Leaf)" -CurrentValue ([int64]$matches[2]) -TotalValue ([int64]$ItemSizes[$item]) -StartTime $startTime
                }
            }
        }

        $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { '' }
        Remove-Item $stdoutPath,$stderrPath -ErrorAction SilentlyContinue

        if ($proc.ExitCode -eq 0) {
            $successCount++
            if ($stdout) { Write-Host $stdout }
            if ($stderr) { Write-Host $stderr }
            $State = Invalidate-DirectoryCache $State $Destination
        } else {
            $failureCount++
            if ($stderr) { Write-Host $stderr }
        }
    }
    return [pscustomobject]@{ SuccessCount = $successCount; FailureCount = $failureCount; State = $State }
}

Describe "Execute-PushTransfer" {
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

        Mock Test-AndroidPath { return $true }
        Mock Start-AdbProcess {
            param($State,$Arguments,$StdOutPath,$StdErrPath)
            Set-Content -LiteralPath $StdOutPath -Value "1 file pushed"
            Set-Content -LiteralPath $StdErrPath -Value "error: ignored"
            return [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
        }
        Mock Invalidate-DirectoryCache { param($State,$DirectoryPath) return $State }

        $script:writes = @()
        Mock Write-Host { param($Object) $script:writes += $Object }

        $result = Execute-PushTransfer -State $state -Items @($tempFile) -ItemSizes @{$tempFile = (Get-Item $tempFile).Length} -Destination '/sdcard' -UpdateInterval 0

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

        Mock Test-AndroidPath { return $true }
        Mock Start-AdbProcess {
            param($State,$Arguments,$StdOutPath,$StdErrPath)
            $progress = "[ 10%] 1/10`n[ 50%] 5/10`n[100%] 10/10`n1 file pushed"
            Set-Content -LiteralPath $StdOutPath -Value $progress
            Set-Content -LiteralPath $StdErrPath -Value ""
            return [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
        }
        Mock Invalidate-DirectoryCache { param($State,$DirectoryPath) return $State }

        $calls = @()
        Mock Show-InlineProgress {
            param($Activity,$CurrentValue,$TotalValue,$StartTime)
            $calls += "${CurrentValue}/${TotalValue}"
        }

        Execute-PushTransfer -State $state -Items @($tempFile) -ItemSizes @{$tempFile = 10} -Destination '/sdcard' -UpdateInterval 0

        $calls | Should -Contain '1/10'
        $calls | Should -Contain '5/10'
        $calls | Should -Contain '10/10'
    }
}

