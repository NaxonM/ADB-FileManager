Describe "Show-UIHeader" {
    BeforeAll {
        . "$PSScriptRoot/../adb-file-manager.ps1"
    }

    It "renders a single centered status line when a device is connected" {
        $state = @{
            DeviceStatus = @{ IsConnected = $true; DeviceName = 'Test'; SerialNumber = 'ABC123' }
            LastStatusUpdateTime = [DateTime]::MinValue
        }

        Mock Clear-Host {}
        Mock Update-DeviceStatus {
            param($State)
            return [pscustomobject]@{
                State = $state
                Devices = @()
                ConnectionChanged = $false
                NeedsSelection = $false
                StatusText = '🔌 Status: Test (ABC123)'
            }
        }

        $script:writes = @()
        Mock Write-Host { param($Object, $ForegroundColor) $script:writes += ,$Object }

        Show-UIHeader -State $state -SubTitle 'MAIN MENU' | Out-Null

        $statusLines = $writes | Where-Object { $_ -match '🔌 Status:' }
        $statusLines.Count | Should -Be 1
        $statusText = '🔌 Status: Test (ABC123)'
        $statusLines[0].Trim() | Should -Be $statusText
        $statusLines[0][0] | Should -Be ' '

        ($writes | Where-Object { $_ -match 'Available devices:' }) | Should -BeNullOrEmpty
    }
}
