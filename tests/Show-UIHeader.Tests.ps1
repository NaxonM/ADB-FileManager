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
            }
        }

        $script:writes = @()
        Mock Write-Host { param($Object, $ForegroundColor) $script:writes += ,$Object }

        Show-UIHeader -State $state -SubTitle 'MAIN MENU' | Out-Null

        $statusLines = $writes | Where-Object { $_ -match '🔌 Status:' }
        $statusLines.Count | Should -Be 1
        $statusLines[0].Trim() | Should -Be '🔌 Status: Test (ABC123)'
        $statusLines[0][0] | Should -Be ' '

        ($writes | Where-Object { $_ -match 'Available devices:' }) | Should -BeNullOrEmpty
    }

    It "shows device list without status line when requested" {
        $state = @{ DeviceStatus = @{ IsConnected = $false; DeviceName = ''; SerialNumber = '' }; LastStatusUpdateTime = [DateTime]::MinValue }

        Mock Clear-Host {}
        $call = 0
        Mock Update-DeviceStatus {
            param($State)
            $call++
            if ($call -eq 1) {
                return [pscustomobject]@{
                    State = $state
                    Devices = @([pscustomobject]@{ Serial='ABC'; Status='device'; Model='Test' })
                    ConnectionChanged = $false
                    NeedsSelection = $false
                }
            } else {
                $state.DeviceStatus = @{ IsConnected = $true; DeviceName = 'Test'; SerialNumber = 'ABC' }
                return [pscustomobject]@{
                    State = $state
                    Devices = @()
                    ConnectionChanged = $false
                    NeedsSelection = $false
                }
            }
        }
        Mock Read-Host { '1' }

        $script:writes = @()
        Mock Write-Host { param($Object, $ForegroundColor) $script:writes += ,$Object }

        Show-UIHeader -State $state -ShowDeviceList | Out-Null

        ($writes | Where-Object { $_ -match 'Available devices:' }).Count | Should -Be 1
        ($writes | Where-Object { $_ -match '🔌 Status:' }) | Should -BeNullOrEmpty
    }
}
