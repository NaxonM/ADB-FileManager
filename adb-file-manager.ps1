# ADB File Manager - PowerShell Script
# A feature-rich tool for managing files on Android devices via ADB.
# Version 2.7 - Inline progress bar, size calculation, and ETR estimates.

# Load required assemblies for GUI pickers
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Global State and Configuration ---
$script:LogFile = "ADB_Operations_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:DeviceStatus = @{
    IsConnected  = $false
    DeviceName   = "No Device"
    SerialNumber = ""
}

# --- Core ADB and Logging Functions ---

# Function to write to the log file
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $logEntry
}

# Centralized function to execute ADB commands
function Invoke-AdbCommand {
    param(
        [string]$Command,
        [switch]$HideOutput
    )
    Write-Log "Executing ADB Command: adb $Command" "DEBUG"

    # Using Start-Process for better output handling and exit codes.
    $process = Start-Process adb -ArgumentList $Command -Wait -NoNewWindow -PassThru -RedirectStandardOutput "temp_stdout.txt" -RedirectStandardError "temp_stderr.txt"
    $exitCode = $process.ExitCode
    
    # Read temp files using UTF-8 encoding to handle special characters in filenames.
    $stdout = Get-Content "temp_stdout.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $stderr = Get-Content "temp_stderr.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Remove-Item "temp_stdout.txt", "temp_stderr.txt" -ErrorAction SilentlyContinue

    $success = ($exitCode -eq 0)
    
    # On success, adb pull/push writes stats to stderr. We combine them to avoid false errors.
    # On failure, stderr contains the real error.
    $output = if ($success) { ($stdout, $stderr | Where-Object { $_ }) -join "`n" } else { $stderr }

    if (-not $success) {
        Write-Log "ADB command failed with exit code $exitCode. Error: $output" "ERROR"
    }

    if ($HideOutput) {
        return [PSCustomObject]@{
            Success = $success
            Output  = "" # Hide output if requested
        }
    }

    return [PSCustomObject]@{
        Success = $success
        Output  = $output.Trim()
    }
}

# Function to update the global device status
function Update-DeviceStatus {
    $result = Invoke-AdbCommand "devices"
    
    # More robustly parse the device list to find the first connected device.
    $firstDeviceLine = $result.Output -split '\r?\n' | Where-Object { $_ -match '\s+device$' } | Select-Object -First 1

    if ($firstDeviceLine) {
        $serialNumber = ($firstDeviceLine -split '\s+')[0]
        $script:DeviceStatus.IsConnected = $true
        $script:DeviceStatus.SerialNumber = $serialNumber.Trim()
        
        $deviceNameResult = Invoke-AdbCommand "-s $serialNumber shell getprop ro.product.model"
        if ($deviceNameResult.Success -and -not [string]::IsNullOrWhiteSpace($deviceNameResult.Output)) {
            $script:DeviceStatus.DeviceName = $deviceNameResult.Output.Trim()
        }
        else {
            $script:DeviceStatus.DeviceName = "Unknown Device"
        }
        Write-Log "Device connected: $($script:DeviceStatus.DeviceName) ($($script:DeviceStatus.SerialNumber))" "INFO"
    }
    else {
        $script:DeviceStatus.IsConnected = $false
        $script:DeviceStatus.DeviceName = "No Device"
        $script:DeviceStatus.SerialNumber = ""
        Write-Log "No device connected." "INFO"
    }
}

# Function to display the main UI header and status bar
function Show-UIHeader {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    🤖 ADB FILE MANAGER                     ║" -ForegroundColor Cyan
    Write-Host "║                  Enhanced & User-Friendly                  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    Update-DeviceStatus
    $statusText = "🔌 Status: "
    if ($script:DeviceStatus.IsConnected) {
        Write-Host "$statusText $($script:DeviceStatus.DeviceName) ($($script:DeviceStatus.SerialNumber))" -ForegroundColor Green
    }
    else {
        Write-Host "$statusText Disconnected - Please connect a device." -ForegroundColor Red
    }
    Write-Host "═" * 62 -ForegroundColor Gray
}


# --- File and Directory Operations ---

# NEW: Function to format bytes into KB, MB, GB, etc.
function Format-Bytes {
    param([long]$bytes)
    $units = @("B", "KB", "MB", "GB", "TB")
    $index = 0
    $value = $bytes
    while ($value -ge 1024 -and $index -lt ($units.Length - 1)) {
        $value /= 1024
        $index++
    }
    return "{0:N2} {1}" -f $value, $units[$index]
}

# NEW: Function to get the size of an item on the Android device.
function Get-AndroidItemSize {
    param([string]$ItemPath)
    
    # Check if it's a directory
    $isDirResult = Invoke-AdbCommand "shell ls -ld ""$ItemPath"""
    $isDir = $isDirResult.Success -and $isDirResult.Output.StartsWith('d')

    if ($isDir) {
        # Use 'du -sb' which gives total size in bytes ('-s' for summary, '-b' for bytes)
        $sizeResult = Invoke-AdbCommand "shell du -sb ""$ItemPath"""
        if ($sizeResult.Success -and $sizeResult.Output) {
            # Output is like "123456 /sdcard/Download"
            $sizeStr = ($sizeResult.Output -split '\s+')[0]
            if ($sizeStr -match '^\d+$') {
                return [long]$sizeStr
            }
        }
    } else {
        # It's a file, use 'stat'
        $sizeResult = Invoke-AdbCommand "shell stat -c %s ""$ItemPath"""
        if ($sizeResult.Success -and $sizeResult.Output) {
            $sizeStr = $sizeResult.Output.Trim()
             if ($sizeStr -match '^\d+$') {
                return [long]$sizeStr
            }
        }
    }
    return 0 # Return 0 if size couldn't be determined
}

# NEW: Function to get the size of a local item on the PC.
function Get-LocalItemSize {
    param([string]$ItemPath)
    if (-not (Test-Path -LiteralPath $ItemPath)) { return 0 }
    $item = Get-Item -LiteralPath $ItemPath
    if ($item.PSIsContainer) {
        # It's a directory
        return (Get-ChildItem -LiteralPath $ItemPath -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    } else {
        # It's a file
        return $item.Length
    }
}

# NEW: Function to display a detailed, inline progress bar.
function Show-InlineProgress {
    param(
        [string]$Activity,
        [long]$CurrentValue,
        [long]$TotalValue,
        [datetime]$StartTime
    )
    $percent = if ($TotalValue -gt 0) { [math]::Round(($CurrentValue / $TotalValue) * 100) } else { 0 }
    $elapsed = (Get-Date) - $StartTime
    $speed = if ($elapsed.TotalSeconds -gt 0) { $CurrentValue / $elapsed.TotalSeconds } else { 0 }
    $etrSeconds = if ($speed -gt 0) { ($TotalValue - $CurrentValue) / $speed } else { 0 }
    
    $barWidth = 20
    $completedWidth = [math]::Floor($barWidth * $percent / 100)
    $remainingWidth = $barWidth - $completedWidth
    $progressBar = "✅" * $completedWidth + "─" * $remainingWidth

    $speedText = Format-Bytes $speed
    $sizeText = "{0} / {1}" -f (Format-Bytes $CurrentValue), (Format-Bytes $TotalValue)
    $etrText = if ($etrSeconds -gt 0) { [timespan]::FromSeconds($etrSeconds).ToString("hh\:mm\:ss") } else { "--:--:--" }

    $progressLine = "`r{0,-25} [{1}] {2,3}% | {3,20} | {4}/s | ETR: {5}" -f $Activity, $progressBar, $percent, $sizeText, $speedText, $etrText
    Write-Host $progressLine -NoNewline
}

# Improved function to list Android directory contents
function Get-AndroidDirectoryContents {
    param([string]$Path)

    $safePath = """$Path"""
    $result = Invoke-AdbCommand "shell ls -la $safePath"

    if (-not $result.Success) {
        Write-Host "❌ Failed to list directory '$Path'. Error: $($result.Output)" -ForegroundColor Red
        return @()
    }

    $items = @()
    $lines = $result.Output -split '\r?\n' | Where-Object { $_ -and $_ -notlike 'total *' -and $_ -notlike '*No such file or directory*' }

    foreach ($line in $lines) {
        $parts = $line -split '\s+', 9
        if ($parts.Count -lt 6) { continue } 

        $permissions = $parts[0]
        $type = if ($permissions.StartsWith('d')) { "Directory" } elseif ($permissions.StartsWith('l')) { "Link" } else { "File" }
        
        $nameIndex = -1
        for ($i = 5; $i -lt $parts.Length; $i++) {
            if ($parts[$i] -match '^\d{2}:\d{2}$') { $nameIndex = $i + 1; break }
        }

        if ($nameIndex -eq -1 -or $nameIndex -ge $parts.Length) { continue } 

        $name = $parts[$nameIndex..($parts.Length -1)] -join ' '
        if ($name -eq "." -or $name -eq "..") { continue }
        $name = ($name -split ' -> ')[0] # Handle symbolic links
        $fullPath = if ($Path.EndsWith('/')) { "$Path$name" } else { "$Path/$name" }

        $items += [PSCustomObject]@{
            Name        = $name.Trim()
            Type        = $type
            Permissions = $permissions
            FullPath    = $fullPath
        }
    }
    return $items
}

# REFACTORED: Pull function with size calculation and inline progress.
function Pull-FilesFromAndroid {
    param(
        [string]$Path,
        [switch]$Move
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PULL" }
    Write-Host "📥 $actionVerb FROM ANDROID" -ForegroundColor Magenta
    
    $sourcePath = if ($Path) { $Path } else { Read-Host "➡️ Enter source path on Android to pull from (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { Write-Host "🟡 Action cancelled."; return }

    $sourceIsDirResult = Invoke-AdbCommand "shell ls -ld ""$sourcePath"""
    $isDir = $sourceIsDirResult.Success -and $sourceIsDirResult.Output.StartsWith('d')

    $itemsToPull = @()
    if ($isDir) {
        $allItems = Get-AndroidDirectoryContents $sourcePath
        if ($allItems.Count -eq 0) { Write-Host "🟡 Directory is empty or inaccessible." -ForegroundColor Yellow; return }
        
        Write-Host "Items available in '$($sourcePath)':" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allItems.Count; $i++) {
            $icon = if ($allItems[$i].Type -eq "Directory") { "📁" } else { "📄" }
            Write-Host (" [{0,2}] {1} {2}" -f ($i+1), $icon, $allItems[$i].Name)
        }
        $selectionStr = Read-Host "`n➡️ Enter item numbers to pull (e.g., 1,3,5 or 'all')"
        if ($selectionStr -eq 'all') { $itemsToPull = $allItems } 
        elseif ($selectionStr) {
            $selectedIndices = $selectionStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
            $itemsToPull = $selectedIndices | ForEach-Object { if ($_ -lt $allItems.Count) { $allItems[$_] } }
        }
    } else {
        $itemName = Split-Path $sourcePath -Leaf
        $itemType = 'File' # Assume file if not a directory
        $itemsToPull += [PSCustomObject]@{ Name = $itemName; FullPath = $sourcePath; Type = $itemType }
    }
    
    if ($itemsToPull.Count -eq 0) { Write-Host "🟡 No items selected." -ForegroundColor Yellow; return }

    $destinationFolder = Show-FolderPicker "Select destination folder on PC"
    if (-not $destinationFolder) { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }

    # --- Confirmation Wizard with Size Calculation ---
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline
    [long]$totalSize = 0
    foreach ($item in $itemsToPull) {
        $totalSize += Get-AndroidItemSize -ItemPath $item.FullPath
    }
    Write-Host "`r" + (" " * 40) + "`r" # Clear line
    Write-Host "You are about to $actionVerb $($itemsToPull.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    $fromLocation = if ($isDir) { $sourcePath } else { (Split-Path $sourcePath -Parent) }
    Write-Host "From (Android): $fromLocation" -ForegroundColor Yellow
    Write-Host "To   (PC)    : $destinationFolder" -ForegroundColor Yellow
    $confirm = Read-Host "➡️ Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }
    # --- End Confirmation ---

    $successCount = 0; $failureCount = 0
    foreach ($item in $itemsToPull) {
        $sourceItemSafe = """$($item.FullPath)"""
        $destFileSafe = Join-Path $destinationFolder $item.Name
        
        # Start the ADB pull command as a background job
        $adbCommand = { param($source, $dest) adb pull $source $dest 2>&1 }
        $job = Start-Job -ScriptBlock $adbCommand -ArgumentList @($sourceItemSafe, $destinationFolder)
        
        $startTime = Get-Date
        Write-Host "" # Newline for progress bar
        
        # Monitor progress
        while ($job.State -eq 'Running') {
            $currentSize = 0
            if (Test-Path -LiteralPath $destFileSafe) {
                 # For directories, we get the size of the partially created folder on PC
                 $currentSize = Get-LocalItemSize -ItemPath $destFileSafe
            }
            Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $currentSize -TotalValue (Get-AndroidItemSize -ItemPath $item.FullPath) -StartTime $startTime
            Start-Sleep -Milliseconds 200
        }
        
        # Final progress update and cleanup
        Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue (Get-LocalItemSize -ItemPath $destFileSafe) -TotalValue (Get-AndroidItemSize -ItemPath $item.FullPath) -StartTime $startTime
        Write-Host "" # Move to next line after progress is complete

        $resultOutput = Receive-Job $job
        $success = ($job.JobStateInfo.State -eq 'Completed')
        Remove-Job $job
        
        if ($success) {
            $successCount++
            Write-Host "✅ Successfully pulled $($item.Name)" -ForegroundColor Green
            Write-Host ($resultOutput | Out-String).Trim() -ForegroundColor Gray

            if ($Move) {
                Write-Host "   - Removing source item..." -NoNewline
                $deleteResult = Invoke-AdbCommand "shell rm -rf `"$($item.FullPath)`""
                if ($deleteResult.Success) { Write-Host " ✅" -ForegroundColor Green } else { Write-Host " ❌" -ForegroundColor Red }
            }
        } else {
            $failureCount++; Write-Host "`n❌ Failed to pull $($item.Name). Error: $resultOutput" -ForegroundColor Red
        }
    }
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# REFACTORED: Push function with size calculation and inline progress.
function Push-FilesToAndroid {
    param(
        [switch]$Move,
        [string]$DestinationPath
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PUSH" }
    Write-Host "📤 $actionVerb ITEMS TO ANDROID" -ForegroundColor Magenta
    
    $uploadType = Read-Host "What do you want to upload? (F)iles or a (D)irectory?"
    
    $sourceItems = @()
    switch ($uploadType.ToLower()) {
        'f' { $sourceItems = Show-OpenFilePicker -Title "Select files to push" -MultiSelect }
        'd' {
            $selectedFolder = Show-FolderPicker -Description "Select a folder to push"
            if ($selectedFolder) { $sourceItems += $selectedFolder }
        }
        default { Write-Host "❌ Invalid selection." -ForegroundColor Red; return }
    }

    if ($sourceItems.Count -eq 0) { Write-Host "🟡 No items selected." -ForegroundColor Yellow; return }

    $destPathFinal = if (-not [string]::IsNullOrWhiteSpace($DestinationPath)) { $DestinationPath } 
    else { Read-Host "➡️ Enter destination path on Android (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($destPathFinal)) { Write-Host "🟡 Action cancelled."; return }

    # --- Confirmation Wizard with Size Calculation ---
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline
    [long]$totalSize = 0
    foreach ($item in $sourceItems) {
        $totalSize += Get-LocalItemSize -ItemPath $item
    }
    Write-Host "`r" + (" " * 40) + "`r" # Clear line
    Write-Host "You are about to $actionVerb $($sourceItems.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    Write-Host "To (Android): $destPathFinal" -ForegroundColor Yellow
    $confirm = Read-Host "➡️ Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }
    # --- End Confirmation ---

    $successCount = 0; $failureCount = 0
    foreach ($item in $sourceItems) {
        $itemInfo = Get-Item -LiteralPath $item
        $sourceItemSafe = """$($itemInfo.FullName)"""
        $destPathSafe = """$destPathFinal"""
        
        # Start the ADB push command as a background job
        $adbCommand = { param($source, $dest) adb push $source $dest 2>&1 }
        $job = Start-Job -ScriptBlock $adbCommand -ArgumentList @($sourceItemSafe, $destPathSafe)

        # Show a spinner for push, as we can't get detailed progress
        $spinner = @('|', '/', '-', '\')
        $spinnerIndex = 0
        Write-Host "" # Newline for spinner
        while ($job.State -eq 'Running') {
            $status = "Pushing $($itemInfo.Name)... $($spinner[$spinnerIndex])"
            Write-Host "`r$status" -NoNewline
            $spinnerIndex = ($spinnerIndex + 1) % $spinner.Length
            Start-Sleep -Milliseconds 150
        }
        Write-Host "`r" + (" " * 60) + "`r" # Clear the spinner line

        $resultOutput = Receive-Job $job
        $success = ($job.JobStateInfo.State -eq 'Completed')
        Remove-Job $job

        if ($success) {
            $successCount++
            Write-Host "✅ Pushed $($itemInfo.Name)" -ForegroundColor Green
            Write-Host ($resultOutput | Out-String).Trim() -ForegroundColor Gray

            if ($Move) {
                Write-Host "   - Removing source item..." -NoNewline
                Remove-Item -LiteralPath $itemInfo.FullName -Force -Recurse -ErrorAction SilentlyContinue
                Write-Host " ✅" -ForegroundColor Green
            }
        } else {
            $failureCount++; Write-Host "`n❌ Failed to push $($itemInfo.Name). Error: $resultOutput" -ForegroundColor Red
        }
    }
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# --- Other File System Functions (Unchanged) ---

# Function to browse Android file system with integrated push/pull.
function Browse-AndroidFileSystem {
    $currentPath = Read-Host "➡️ Enter starting path (default: /sdcard/)"
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "/sdcard/" }

    do {
        Show-UIHeader
        Write-Host "📁 Browsing: $currentPath" -ForegroundColor White -BackgroundColor DarkCyan
        Write-Host "─" * 62 -ForegroundColor Gray

        $items = Get-AndroidDirectoryContents $currentPath
        if (-not $items) {
             Write-Host "⚠️ Could not retrieve directory contents. Check path and permissions." -ForegroundColor Yellow
        }
        
        Write-Host " [ 0] .. (Go Up)" -ForegroundColor Yellow
        $i = 1
        foreach ($item in $items) {
            $icon = if ($item.Type -eq "Directory") { "📁" } else { "📄" }
            $color = if ($item.Type -eq "Directory") { "Cyan" } else { "White" }
            Write-Host (" [{0,2}] {1} {2}" -f $i, $icon, $item.Name) -ForegroundColor $color
            $i++
        }
        
        $choice = Read-Host "`n➡️ Enter number to browse, (c)reate, (p)ull, (u)pload, or (q)uit to menu"

        switch ($choice) {
            "q" { return }
            "c" { New-AndroidFolder -ParentPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "p" { Pull-FilesFromAndroid -Path $currentPath; Read-Host "`nPress Enter to continue..." }
            "u" { Push-FilesToAndroid -DestinationPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "0" {
                if ($currentPath -ne "/") {
                    $parentPath = $currentPath.TrimEnd('/') | Split-Path -Parent
                    $currentPath = if ([string]::IsNullOrEmpty($parentPath) -or $parentPath -eq '\') { "/" } else { $parentPath }
                }
            }
            default {
                if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $items.Count) {
                    $selectedIndex = [int]$choice - 1
                    $selectedItem = $items[$selectedIndex]
                    if ($selectedItem.Type -eq "Directory") { $currentPath = $selectedItem.FullPath } 
                    else { Show-ItemActionMenu -Item $selectedItem }
                } else {
                    Write-Host "❌ Invalid selection." -ForegroundColor Red; Start-Sleep -Seconds 1
                }
            }
        }
    } while ($true)
}

function New-AndroidFolder {
    param([string]$ParentPath)
    $folderName = Read-Host "➡️ Enter name for the new folder"
    if ([string]::IsNullOrWhiteSpace($folderName)) { Write-Host "🟡 Action cancelled: No name provided." -ForegroundColor Yellow; return }
    $fullPath = if ($ParentPath.EndsWith('/')) { "$ParentPath$folderName" } else { "$ParentPath/$folderName" }
    $result = Invoke-AdbCommand "shell mkdir -p `"$fullPath`""
    if ($result.Success) { Write-Host "✅ Successfully created folder: $fullPath" -ForegroundColor Green } 
    else { Write-Host "❌ Failed to create folder. Error: $($result.Output)" -ForegroundColor Red }
}

function Show-ItemActionMenu {
    param($Item)
    while ($true) {
        Show-UIHeader
        Write-Host "Selected Item: $($Item.FullPath)" -ForegroundColor White -BackgroundColor DarkMagenta
        Write-Host "---------------------------------"
        Write-Host "1. Pull to PC (Copy)"
        Write-Host "2. Move to PC (Pull + Delete)"
        Write-Host "3. Rename (on device)"
        Write-Host "4. Delete (on device)"
        Write-Host "5. Back to browser"
        $action = Read-Host "`n➡️ Enter your choice (1-5)"
        switch ($action) {
            "1" { Pull-FilesFromAndroid -Path $Item.FullPath; Read-Host "`nPress Enter to continue..."; break }
            "2" { Pull-FilesFromAndroid -Path $Item.FullPath -Move; Read-Host "`nPress Enter to continue..."; break }
            "3" {
                $newItem = Rename-AndroidItem -ItemPath $Item.FullPath
                if ($newItem) { $Item = $newItem }
                Read-Host "`nPress Enter to continue..."; break
            }
            "4" { Remove-AndroidItem -ItemPath $Item.FullPath; Read-Host "`nPress Enter to continue..."; return }
            "5" { return }
            default { Write-Host "❌ Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Remove-AndroidItem {
    param([string]$ItemPath)
    $itemName = Split-Path $ItemPath -Leaf
    $confirmation = Read-Host "❓ Are you sure you want to PERMANENTLY DELETE '$itemName'? [y/N]"
    if ($confirmation -ne 'y') { Write-Host "🟡 Deletion cancelled." -ForegroundColor Yellow; return }
    $result = Invoke-AdbCommand "shell rm -rf ""$ItemPath"""
    if ($result.Success) { Write-Host "✅ Successfully deleted '$itemName'." -ForegroundColor Green } 
    else { Write-Host "❌ Failed to delete '$itemName'. Error: $($result.Output)" -ForegroundColor Red }
}

function Rename-AndroidItem {
    param([string]$ItemPath)
    $originalItem = Get-AndroidDirectoryContents (Split-Path $ItemPath -Parent) | Where-Object { $_.FullPath -eq $ItemPath }
    $itemName = Split-Path $ItemPath -Leaf
    $newName = Read-Host "➡️ Enter the new name for '$itemName'"
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName.Contains('/') -or $newName.Contains('\')) {
        Write-Host "❌ Invalid name." -ForegroundColor Red; return $null
    }
    $parentPath = Split-Path $ItemPath -Parent
    $newItemPath = if ($parentPath -eq "/") { "/$newName" } else { "$parentPath/$newName" }
    $result = Invoke-AdbCommand "shell mv ""$ItemPath"" ""$newItemPath"""
    if ($result.Success) {
        Write-Host "✅ Successfully renamed to '$newName'." -ForegroundColor Green
        return [PSCustomObject]@{ Name = $newName; FullPath = $newItemPath; Type = $originalItem.Type; Permissions = $originalItem.Permissions }
    } else {
        Write-Host "❌ Failed to rename. Error: $($result.Output)" -ForegroundColor Red
        return $null
    }
}

function Show-FolderPicker {
    param([string]$Description = "Select a folder")
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    $folderBrowser.ShowNewFolderButton = $true
    if ($folderBrowser.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq 'OK') {
        return $folderBrowser.SelectedPath
    }
    return $null
}

function Show-OpenFilePicker {
    param(
        [string]$Title = "Select a file",
        [string]$Filter = "All files (*.*)|*.*",
        [switch]$MultiSelect
    )
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = $Title
    $fileDialog.Filter = $Filter
    $fileDialog.Multiselect = $MultiSelect
    if ($fileDialog.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq 'OK') {
        return $fileDialog.FileNames
    }
    return $null
}

# --- Main Menu and Execution Flow ---

function Show-MainMenu {
    while ($true) {
        Show-UIHeader

        if (-not $script:DeviceStatus.IsConnected) {
            Write-Host "`n⚠️ No device connected. Please connect a device and ensure it's recognized by ADB." -ForegroundColor Yellow
        }

        Write-Host "`nMAIN MENU" -ForegroundColor Green
        Write-Host "═══ FILE MANAGEMENT ══════════════════════════════════════════"
        Write-Host "1. Browse Device Filesystem (with contextual Push/Pull)"
        Write-Host "2. Quick Push Items (from PC to a specified device path)"
        Write-Host "3. Quick Pull Items (from a specified device path to PC)"
        Write-Host "q. Exit"

        $choice = Read-Host "`n➡️ Enter your choice"

        if ($choice -in '1', '2', '3' -and -not $script:DeviceStatus.IsConnected) {
            Write-Host "`n❌ Cannot perform this action: No device connected." -ForegroundColor Red
            Read-Host "Press Enter to continue"
            continue
        }

        switch ($choice) {
            '1' { Browse-AndroidFileSystem }
            '2' { Push-FilesToAndroid }
            '3' { Pull-FilesFromAndroid }
            'q' { return }
            default { Write-Host "❌ Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
        
        if ($choice -ne '1') {
            Read-Host "`nPress Enter to return to the main menu..."
        }
    }
}

# --- Main execution entry point ---
function Start-ADBTool {
    $OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Write-Host "❌ ADB not found in your system's PATH." -ForegroundColor Red
        Write-Host "Please install Android SDK Platform Tools and ensure the directory is in your PATH environment variable." -ForegroundColor Red
        Read-Host "Press Enter to exit."
        return
    }

    Write-Log "ADB File Manager started" "INFO"
    Show-MainMenu
    Write-Host "`n👋 Thank you for using the ADB File Manager!" -ForegroundColor Green
}

# Start the application
Start-ADBTool
