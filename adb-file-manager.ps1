# ADB File Manager - PowerShell Script
# A feature-rich tool for managing files on Android devices via ADB.

# Load required assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Global State and Configuration ---
$script:LogFile = "ADB_Operations_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:DeviceStatus = @{
    IsConnected = $false
    DeviceName = "No Device"
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

    $result = & adb $Command 2>&1
    $exitCode = $LASTEXITCODE

    $success = ($exitCode -eq 0)

    if (-not $success) {
        Write-Log "ADB command failed with exit code $exitCode. Error: $result" "ERROR"
    }

    if ($HideOutput) {
        return [PSCustomObject]@{
            Success = $success
            Output = "" # Hide output if requested
        }
    }

    return [PSCustomObject]@{
        Success = $success
        Output = $result
    }
}

# Function to update the global device status
function Update-DeviceStatus {
    $result = Invoke-AdbCommand "devices"
    if ($result.Success -and ($result.Output | Select-String -Pattern "device$")) {
        $script:DeviceStatus.IsConnected = $true
        # Get serial number and device name
        $deviceInfo = $result.Output | Select-String -Pattern "device$" | Select-Object -First 1
        $script:DeviceStatus.SerialNumber = ($deviceInfo -split "`t")[0]
        $deviceNameResult = Invoke-AdbCommand "shell getprop ro.product.model"
        if ($deviceNameResult.Success) {
            $script:DeviceStatus.DeviceName = $deviceNameResult.Output.Trim()
        } else {
            $script:DeviceStatus.DeviceName = "Unknown Device"
        }
        Write-Log "Device connected: $($script:DeviceStatus.DeviceName) ($($script:DeviceStatus.SerialNumber))" "INFO"
    } else {
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
    Write-Host "║                     Enhanced Edition                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # Status Bar
    Update-DeviceStatus
    $statusText = "🔌 Status: "
    if ($script:DeviceStatus.IsConnected) {
        Write-Host "$statusText $($script:DeviceStatus.DeviceName) - Connected" -ForegroundColor Green
    } else {
        Write-Host "$statusText Disconnected" -ForegroundColor Red
    }
    Write-Host "═" * 62 -ForegroundColor Gray
}


# --- File and Directory Operations ---

# Improved function to list Android directory contents
function Get-AndroidDirectoryContents {
    param([string]$Path)

    # Ensure the path is quoted to handle spaces
    $safePath = """$Path"""
    $result = Invoke-AdbCommand "shell ls -la $safePath"

    if (-not $result.Success) {
        Write-Host "❌ Failed to list directory '$Path'. Error: $($result.Output)" -ForegroundColor Red
        return @()
    }

    $items = @()
    $lines = $result.Output -split '\r?\n' | Where-Object { $_ -and $_ -notlike 'total *' }

    foreach ($line in $lines) {
        # Parsing ls -la output. This is complex and might need adjustments for different Android versions.
        # Example line: drwxr-xr-x 4 root root 4096 2023-10-27 10:00 cache
        $parts = $line -split '\s+', 9
        if ($parts.Count -lt 9) { continue } # Skip malformed lines

        $permissions = $parts[0]
        $type = if ($permissions.StartsWith('d')) { "Directory" } elseif ($permissions.StartsWith('l')) { "Link" } else { "File" }

        # The file name is the last part. It can contain spaces.
        $name = $parts[8].Trim()

        if ($name -eq "." -or $name -eq "..") { continue }

        # Rejoin path, handling root case
        $fullPath = if ($Path -eq "/") { "/$name" } else { "$Path/$name" }

        $items += [PSCustomObject]@{
            Name        = $name
            Type        = $type
            Permissions = $permissions
            Size        = if ($type -eq 'File') { [long]$parts[4] } else { 0 }
            ModifiedDate = [datetime]::ParseExact("$($parts[5]) $($parts[6])", "yyyy-MM-dd HH:mm", $null)
            FullPath    = $fullPath
        }
    }
    return $items
}

# Function to browse Android file system with interactive actions
function Browse-AndroidFileSystem {
    $currentPath = Read-Host -Prompt "Enter starting path (default: /sdcard/)"
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "/sdcard/" }

    do {
        Show-UIHeader
        Write-Host " Browsing: $currentPath" -ForegroundColor Cyan

        $items = Get-AndroidDirectoryContents $currentPath
        if (-not $items) {
             Write-Host "Could not retrieve directory contents. Check path and permissions." -ForegroundColor Yellow
        }

        $navItems = @(
            [PSCustomObject]@{ Name = ".. (Go Up)"; Type = "Navigation"; FullPath = "" },
            [PSCustomObject]@{ Name = "<- Back to Main Menu"; Type = "Navigation"; FullPath = "" }
        )

        $displayItems = $navItems + $items
        $selectedItem = $displayItems | Select-Object Name, Type, Size, ModifiedDate | Out-GridView -Title "Browse: $currentPath" -OutputMode Single

        if (-not $selectedItem) { continue }

        $fullSelectedItem = $displayItems | Where-Object { $_.Name -eq $selectedItem.Name -and $_.Type -eq $selectedItem.Type } | Select-Object -First 1

        switch ($fullSelectedItem.Name) {
            "<- Back to Main Menu" { return }
            ".. (Go Up)" {
                if ($currentPath -ne "/") {
                    $parentPath = $currentPath.TrimEnd('/') | Split-Path -Parent
                    $currentPath = if ([string]::IsNullOrEmpty($parentPath)) { "/" } else { $parentPath }
                }
            }
            default {
                if ($fullSelectedItem.Type -eq "Directory") {
                    $currentPath = $fullSelectedItem.FullPath
                } else {
                    # Item Action Menu
                    Show-ItemActionMenu $fullSelectedItem
                }
            }
        }
    } while ($true)
}

# Function to show a menu of actions for a selected file/folder
function Show-ItemActionMenu {
    param($Item)

    Clear-Host
    Show-UIHeader
    Write-Host "Selected Item: $($Item.FullPath)" -ForegroundColor Cyan
    Write-Host "---------------------------------"
    Write-Host "Choose an action:"
    Write-Host "1. Pull to PC"
    Write-Host "2. Move to PC (Pull + Delete)"
    Write-Host "3. Rename"
    Write-Host "4. Delete"
    Write-Host "5. Copy (on device)"
    Write-Host "6. Move (on device)"
    Write-Host "7. Back to browser"

    $action = Read-Host "`nEnter your choice (1-7)"
    switch ($action) {
        "1" {
            Pull-FilesFromAndroid -Path $Item.FullPath
            Read-Host "Press Enter to continue"
        }
        "2" {
            Pull-FilesFromAndroid -Path $Item.FullPath -Move
            Read-Host "Press Enter to continue"
        }
        "3" {
            Rename-AndroidItem -ItemPath $Item.FullPath
            Read-Host "Press Enter to continue"
        }
        "4" {
            Remove-AndroidItem -ItemPath $Item.FullPath
            Read-Host "Press Enter to continue"
        }
        "5" {
            Copy-AndroidItem -SourcePath $Item.FullPath
            Read-Host "Press Enter to continue"
        }
        "6" {
            Move-AndroidItem -SourcePath $Item.FullPath
            Read-Host "Press Enter to continue"
        }
        "7" { return }
        default {
            Write-Host "Invalid choice." -ForegroundColor Red
            Read-Host "Press Enter to continue"
        }
    }
}


# Function to show folder picker dialog
function Show-FolderPicker {
    param(
        [string]$Description = "Select a folder"
    )
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    $folderBrowser.ShowNewFolderButton = $true
    if ($folderBrowser.ShowDialog() -eq 'OK') {
        return $folderBrowser.SelectedPath
    }
    return $null
}

# Function to show a detailed transfer progress bar
function Show-TransferProgress {
    param(
        [string]$Activity,
        [string]$SourcePath, # For pull, this is the destination. For push, the source.
        [long]$TotalSize,
        [scriptblock]$AdbCommand,
        [string]$TransferType # 'push' or 'pull'
    )

    $job = Start-Job -ScriptBlock $AdbCommand
    $startTime = Get-Date

    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 250

        if ($TransferType -eq 'pull') {
            $transferred = 0
            if (Test-Path $SourcePath) {
                $transferred = (Get-Item $SourcePath).Length
            }
            $elapsed = (Get-Date) - $startTime
            $speed = if ($elapsed.TotalSeconds -gt 0) { $transferred / $elapsed.TotalSeconds } else { 0 }
            $percent = if ($TotalSize -gt 0) { ($transferred / $TotalSize) * 100 } else { 0 }
            $remaining = if ($speed -gt 0) { ($TotalSize - $transferred) / $speed } else { 0 }
            $status = "Pulled {0:N2} MB of {1:N2} MB ({2:N2} MB/s). ETA: {3:N0}s" -f ($transferred / 1MB), ($TotalSize / 1MB), ($speed / 1MB), $remaining
            Write-Progress -Activity $Activity -Status $status -PercentComplete $percent

        } elseif ($TransferType -eq 'push') {
            # For push, we can't easily check the remote file size.
            # We'll rely on the output of the adb command itself, which sadly doesn't stream percentage for single files well.
            # This will be more of a "spinner" than a detailed progress bar for push.
            $status = "Pushing file... (This may take a while for large files)"
            Write-Progress -Activity $Activity -Status $status
        }
    }

    $result = Receive-Job $job
    Remove-Job $job

    return $result
}

# Function to push files to Android with detailed progress
function Push-FilesToAndroid {
    param([switch]$Move)
    Write-Host "📤 PUSH FILES TO ANDROID" -ForegroundColor Magenta
    
    $sourceFolder = Show-FolderPicker "Select source folder on your PC"
    if (-not $sourceFolder) { Write-Host "❌ No folder selected." -ForegroundColor Red; return }

    $destinationPath = Read-Host -Prompt 'Enter destination path on Android (e.g., /sdcard/Download/)'
    if ([string]::IsNullOrWhiteSpace($destinationPath)) { $destinationPath = "/sdcard/Download/" }

    $files = Get-ChildItem -Path $sourceFolder -File | Select-Object Name, FullName, Length
    if ($files.Count -eq 0) {
        Write-Host "⚠️ No files found." -ForegroundColor Yellow
        return
    }
    
    $selectedFiles = $files | Out-GridView -Title "Select files to push" -OutputMode Multiple
    if ($selectedFiles.Count -eq 0) { return }

    $successCount = 0
    $failureCount = 0

    foreach ($file in $selectedFiles) {
        $sourceFileSafe = """$($file.FullName)"""
        $destPathSafe = """$destinationPath"""
        
        $adbCommand = {
            param($source, $dest)
            & adb push $source $dest
        }

        $result = Show-TransferProgress -Activity "Pushing $($file.Name)" -SourcePath $file.FullName -TotalSize $file.Length -AdbCommand $adbCommand -ArgumentList $sourceFileSafe, $destPathSafe -TransferType 'push'

        if ($LASTEXITCODE -eq 0) {
            $successCount++
            if ($Move) {
                Remove-Item -Path $file.FullName -Force
            }
        } else {
            $failureCount++
            Write-Host "`n❌ Failed to push $($file.Name)." -ForegroundColor Red
        }
    }
    Write-Progress -Activity "Pushing Files" -Completed
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# Function to pull files from Android with detailed progress
function Pull-FilesFromAndroid {
    param(
        [string]$Path,
        [switch]$Move
    )
    Write-Host "📥 PULL FILES FROM ANDROID" -ForegroundColor Magenta
    
    $sourcePath = if ($Path) { $Path } else { Read-Host -Prompt 'Enter source path on Android (e.g., /sdcard/Download/)' }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { $sourcePath = "/sdcard/Download/" }

    $items = Get-AndroidDirectoryContents $sourcePath
    if ($items.Count -eq 0) { return }

    $selectedItems = if ($Path) { $items | Where-Object { $_.FullPath -eq $Path } } else { $items | Where-Object { $_.Type -eq 'File' } | Out-GridView -Title "Select files to pull" -OutputMode Multiple }
    if ($selectedItems.Count -eq 0) { return }

    $destinationFolder = Show-FolderPicker "Select destination folder on PC"
    if (-not $destinationFolder) { return }

    $createNewDir = Read-Host "Create a new directory for the pulled files? [y/N]"
    if ($createNewDir -eq 'y') {
        $newDirName = Read-Host "Enter the name for the new directory"
        if (-not [string]::IsNullOrWhiteSpace($newDirName)) {
            $destinationFolder = Join-Path $destinationFolder $newDirName
            New-Item -Path $destinationFolder -ItemType Directory -Force
        }
    }

    $successCount = 0
    $failureCount = 0

    foreach ($item in $selectedItems) {
        $sourceItemSafe = """$($item.FullPath)"""
        $destFileSafe = """$(Join-Path $destinationFolder $item.Name)"""
        
        $adbCommand = {
            param($source, $dest)
            & adb pull $source $dest
        }

        $result = Show-TransferProgress -Activity "Pulling $($item.Name)" -SourcePath $destFileSafe -TotalSize $item.Size -AdbCommand $adbCommand -ArgumentList $sourceItemSafe, $destFileSafe -TransferType 'pull'

        if ($LASTEXITCODE -eq 0) {
            $successCount++
            if ($Move) {
                Invoke-AdbCommand "shell rm `"$($item.FullPath)`""
            }
        } else {
            $failureCount++
            Write-Host "`n❌ Failed to pull $($item.Name)." -ForegroundColor Red
        }
    }
    Write-Progress -Activity "Pulling Items" -Completed
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# Function to copy an item on Android
function Copy-AndroidItem {
    param([string]$SourcePath)

    $destinationPath = Read-Host "Enter the destination path"
    if ([string]::IsNullOrWhiteSpace($destinationPath)) {
        Write-Host "❌ Invalid destination path." -ForegroundColor Red
        return
    }

    $command = "shell cp -r ""$SourcePath"" ""$destinationPath"""
    $result = Invoke-AdbCommand $command

    if ($result.Success) {
        Write-Host "✅ Successfully copied item." -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to copy item. Error: $($result.Output)" -ForegroundColor Red
    }
}

# Function to move an item on Android
function Move-AndroidItem {
    param([string]$SourcePath)

    $destinationPath = Read-Host "Enter the destination path"
    if ([string]::IsNullOrWhiteSpace($destinationPath)) {
        Write-Host "❌ Invalid destination path." -ForegroundColor Red
        return
    }

    $confirmation = Read-Host "Are you sure you want to move this item? [y/N]"
    if ($confirmation -ne 'y') {
        Write-Host "Move cancelled." -ForegroundColor Yellow
        return
    }

    $command = "shell mv ""$SourcePath"" ""$destinationPath"""
    $result = Invoke-AdbCommand $command

    if ($result.Success) {
        Write-Host "✅ Successfully moved item." -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to move item. Error: $($result.Output)" -ForegroundColor Red
    }
}

# Function to create a new directory on the local machine
function New-LocalDirectory {
    $parentFolder = Show-FolderPicker "Select a parent folder"
    if (-not $parentFolder) { return }

    $newDirName = Read-Host "Enter the name for the new directory"
    if ([string]::IsNullOrWhiteSpace($newDirName)) {
        Write-Host "❌ Invalid directory name." -ForegroundColor Red
        return
    }

    $newDirPath = Join-Path $parentFolder $newDirName
    if (Test-Path $newDirPath) {
        Write-Host "❌ Directory already exists." -ForegroundColor Red
        return
    }

    New-Item -Path $newDirPath -ItemType Directory
    Write-Host "✅ Successfully created directory '$newDirPath'." -ForegroundColor Green
}

# Function to remove an item from Android
function Remove-AndroidItem {
    param([string]$ItemPath)

    $itemName = Split-Path $ItemPath -Leaf
    $confirmation = Read-Host "Are you sure you want to permanently delete '$itemName'? [y/N]"
    if ($confirmation -ne 'y') {
        Write-Host "Deletion cancelled." -ForegroundColor Yellow
        return
    }

    # Use 'rm -r' for directories and 'rm' for files
    $command = "shell rm -r ""$ItemPath"""
    $result = Invoke-AdbCommand $command

    if ($result.Success) {
        Write-Host "✅ Successfully deleted '$itemName'." -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to delete '$itemName'. Error: $($result.Output)" -ForegroundColor Red
    }
}

# Function to rename an item on Android
function Rename-AndroidItem {
    param([string]$ItemPath)

    $itemName = Split-Path $ItemPath -Leaf
    $newName = Read-Host "Enter the new name for '$itemName'"
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host "❌ Invalid name." -ForegroundColor Red
        return
    }

    $parentPath = Split-Path $ItemPath -Parent
    $newItemPath = "$parentPath/$newName"

    $command = "shell mv ""$ItemPath"" ""$newItemPath"""
    $result = Invoke-AdbCommand $command

    if ($result.Success) {
        Write-Host "✅ Successfully renamed to '$newName'." -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to rename. Error: $($result.Output)" -ForegroundColor Red
    }
}

# Function to install an APK file
function Install-AndroidPackage {
    Write-Host "📦 INSTALL ANDROID PACKAGE (APK)" -ForegroundColor Magenta

    $apkPath = Show-OpenFilePicker "Select APK file to install"
    if (-not $apkPath) { return }

    Write-Host "Installing '$apkPath'..." -ForegroundColor Yellow
    $result = Invoke-AdbCommand "install `"$apkPath`""

    if ($result.Success -and $result.Output -match "Success") {
        Write-Host "✅ Successfully installed package." -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to install package. Error: $($result.Output)" -ForegroundColor Red
    }
}

# Function to list installed packages
function Get-InstalledApps {
    Write-Host "📋 LIST INSTALLED APPLICATIONS" -ForegroundColor Magenta

    $result = Invoke-AdbCommand "shell pm list packages"
    if (-not $result.Success) {
        Write-Host "❌ Failed to retrieve package list." -ForegroundColor Red
        return
    }

    $packages = $result.Output -split '\r?\n' | ForEach-Object { $_.Replace("package:", "") } | Sort-Object
    $packages | Out-GridView -Title "Installed Applications"
}

function Show-MainMenu {
    Show-UIHeader
    Write-Host "`n📋 MAIN MENU:" -ForegroundColor Green
    Write-Host "1. 📤 Push files to Android"
    Write-Host "2. 📥 Pull files from Android"
    Write-Host "3. 📂 Browse Android file system"
    Write-Host "4. 📁 Create folder on Android"
    Write-Host "5. 🗑️ Remove file/folder on Android"
    Write-Host "6. Rename file/folder on Android"
    Write-Host "7. 📦 Install Android Package (APK)"
    Write-Host "8. 📋 List Installed Apps"
    Write-Host "9. 📁 Create local directory"
    Write-Host "10. 🚪 Exit"
    Write-Host "`n📝 Log file: $script:LogFile" -ForegroundColor Gray
}

# Main execution loop
function Start-ADBTool {
    # Check for ADB on startup
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Write-Host "❌ ADB not found in PATH. Please install Android SDK Platform Tools and restart the terminal." -ForegroundColor Red
        Read-Host "Press Enter to exit."
        return
    }

    Write-Log "ADB File Manager started" "INFO"
    do {
        Show-MainMenu
        $choice = Read-Host -Prompt "`nEnter your choice (1-10)"
        
        # Check connection for relevant choices
        if ($choice -in "1", "2", "3", "4", "5", "6", "7", "8") {
            if (-not $script:DeviceStatus.IsConnected) {
                Write-Host "❌ No Android device connected. Please connect your device and try again." -ForegroundColor Red
                Read-Host "Press Enter to continue..."
                continue
            }
        }
        
        switch ($choice) {
            "1" { Push-FilesToAndroid }
            "2" { Pull-FilesFromAndroid }
            "3" { Browse-AndroidFileSystem }
            "4" { New-AndroidFolder }
            "5" { 
                $itemPath = Read-Host "Enter the full path of the item to remove"
                if (-not [string]::IsNullOrWhiteSpace($itemPath)) {
                    Remove-AndroidItem $itemPath
                }
            }
            "6" {
                $itemPath = Read-Host "Enter the full path of the item to rename"
                if (-not [string]::IsNullOrWhiteSpace($itemPath)) {
                    Rename-AndroidItem $itemPath
                }
            }
            "7" { Install-AndroidPackage }
            "8" { Get-InstalledApps }
            "9" { New-LocalDirectory }
            "10" {
                Write-Host "👋 Thank you for using the tool!" -ForegroundColor Green
                return
            }
            default { Write-Host "❌ Invalid choice." -ForegroundColor Red }
        }
        
        if ($choice -in "1", "2", "3", "4", "5", "6", "7", "8", "9") {
            Write-Host "`nPress Enter to return to the menu..." -ForegroundColor Yellow
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } while ($true)
}

# Function to show file picker dialog
function Show-OpenFilePicker {
    param(
        [string]$Title = "Select a file"
    )
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = $Title
    if ($fileDialog.ShowDialog() -eq 'OK') {
        return $fileDialog.FileName
    }
    return $null
}
# Function to create folder on Android
function New-AndroidFolder {
    Write-Host "📁 CREATE FOLDER ON ANDROID" -ForegroundColor Magenta
    $folderPath = Read-Host -Prompt "Enter full path for new folder (e.g., /sdcard/MyFolder)"
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        Write-Host "❌ No path provided." -ForegroundColor Red; return
    }

    # Using the new centralized function
    $result = Invoke-AdbCommand "shell `"mkdir -p `"$folderPath`"`""

    if ($result.Success) {
        Write-Host "✅ Successfully created folder: $folderPath" -ForegroundColor Green
        Write-Log "Successfully created folder $folderPath" "INFO"
    } else {
        Write-Host "❌ Failed to create folder. Error: $($result.Output)" -ForegroundColor Red
        # The error is already logged by Invoke-AdbCommand
    }
}

# Start the application
Start-ADBTool