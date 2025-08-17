Describe "Execute-PushTransfer" {
    BeforeAll {
        . "$PSScriptRoot/../adb-file-manager.ps1"
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
}
