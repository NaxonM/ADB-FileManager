# ADB File Manager - PowerShell Script
# A feature-rich tool for managing files on Android devices via ADB.

# Load required assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Global State and Configuration ---
$script:LogFile = "ADB_Operations_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:DeviceStatus = @{
    IsConnected = $false
    DeviceName  = "No Device"
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

    # Using Start-Process to get more reliable exit codes and output handling
    $process = Start-Process adb -ArgumentList $Command -Wait -NoNewWindow -PassThru -RedirectStandardOutput "temp_stdout.txt" -RedirectStandardError "temp_stderr.txt"
    $exitCode = $process.ExitCode
    $stdout = Get-Content "temp_stdout.txt" -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content "temp_stderr.txt" -Raw -ErrorAction SilentlyContinue
    Remove-Item "temp_stdout.txt", "temp_stderr.txt" -ErrorAction SilentlyContinue

    $success = ($exitCode -eq 0)
    $output = if ($success) { $stdout } else { $stderr }

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
        Output  = $output
    }
}

# Function to run a transfer with a progress indicator
function Invoke-AdbTransferWithProgress {
    param(
        [string]$Activity,
        [scriptblock]$AdbCommand,
        [string]$DestinationFileForPull, # Only for pull operations to check file size
        [long]$TotalSizeForPull          # Only for pull operations
    )

    $job = Start-Job -ScriptBlock $AdbCommand
    $spinner = @('|', '/', '-', '\')
    $spinnerIndex = 0

    while ($job.State -eq 'Running') {
        if ($DestinationFileForPull -and (Test-Path $DestinationFileForPull) -and $TotalSizeForPull -gt 0) {
            # Detailed progress for PULL
            $currentSize = (Get-Item $DestinationFileForPull).Length
            $percent = [math]::Round(($currentSize / $TotalSizeForPull) * 100)
            $status = "Pulling: {0:N2} MB / {1:N2} MB" -f ($currentSize / 1MB), ($TotalSizeForPull / 1MB)
            Write-Progress -Activity $Activity -Status $status -PercentComplete $percent
        }
        else {
            # Spinner for PUSH or when size is unknown
            $status = "Transferring... $($spinner[$spinnerIndex])"
            Write-Progress -Activity $Activity -Status $status
            $spinnerIndex = ($spinnerIndex + 1) % $spinner.Length
        }
        Start-Sleep -Milliseconds 150
    }

    Write-Progress -Activity $Activity -Completed
    $result = Receive-Job $job
    $success = $job.JobStateInfo.State -eq 'Completed' # Check job state for success
    Remove-Job $job

    return [PSCustomObject]@{
        Success = $success
        Output  = $result
    }
}


# Function to update the global device status
function Update-DeviceStatus {
    $result = Invoke-AdbCommand "devices"
    if ($result.Success -and ($result.Output | Select-String -Pattern "`tdevice$")) {
        $script:DeviceStatus.IsConnected = $true
        # Get serial number and device name
        $deviceInfo = $result.Output -split '\r?\n' | Where-Object { $_ -match "`tdevice$" } | Select-Object -First 1
        $script:DeviceStatus.SerialNumber = ($deviceInfo -split "`t")[0]
        $deviceNameResult = Invoke-AdbCommand "-s $($script:DeviceStatus.SerialNumber) shell getprop ro.product.model"
        if ($deviceNameResult.Success) {
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
    Write-Host "║                     Enhanced Edition                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # Status Bar
    Update-DeviceStatus
    $statusText = "🔌 Status: "
    if ($script:DeviceStatus.IsConnected) {
        Write-Host "$statusText $($script:DeviceStatus.DeviceName) ($($script:DeviceStatus.SerialNumber)) - Connected" -ForegroundColor Green
    }
    else {
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
    # Handle both LF and CRLF line endings
    $lines = $result.Output -split '\r?\n' | Where-Object { $_ -and $_ -notlike 'total *' -and $_ -notlike '*No such file or directory*' }

    foreach ($line in $lines) {
        # Parsing ls -la output. This is complex and might need adjustments for different Android versions.
        $parts = $line -split '\s+', 9
        if ($parts.Count -lt 6) { continue } # Skip malformed lines

        $permissions = $parts[0]
        $type = if ($permissions.StartsWith('d')) { "Directory" } elseif ($permissions.StartsWith('l')) { "Link" } else { "File" }
        
        # Find the date/time part to reliably get the name
        $nameIndex = -1
        for ($i = 5; $i -lt $parts.Length; $i++) {
            if ($parts[$i] -match '^\d{2}:\d{2}$') { # Matches HH:mm
                $nameIndex = $i + 1
                break
            }
        }

        if ($nameIndex -eq -1 -or $nameIndex -ge $parts.Length) { continue } # Could not find name

        $name = $parts[$nameIndex..($parts.Length -1)] -join ' '

        if ($name -eq "." -or $name -eq "..") { continue }
        
        # Handle symlinks where name is 'link -> target'
        $name = ($name -split ' -> ')[0]

        # Rejoin path, handling root case
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
        $selectedItem = $displayItems | Select-Object Name, Type | Out-GridView -Title "Browse: $currentPath" -OutputMode Single

        if (-not $selectedItem) { continue }

        $fullSelectedItem = $displayItems | Where-Object { $_.Name -eq $selectedItem.Name -and $_.Type -eq $selectedItem.Type } | Select-Object -First 1

        switch ($fullSelectedItem.Name) {
            "<- Back to Main Menu" { return }
            ".. (Go Up)" {
                if ($currentPath -ne "/") {
                    $parentPath = $currentPath.TrimEnd('/') | Split-Path -Parent
                    $currentPath = if ([string]::IsNullOrEmpty($parentPath) -or $parentPath -eq '\') { "/" } else { $parentPath }
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

    # Loop until user chooses to go back
    while ($true) {
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
                # Rename can change the item path, so we need to update it
                $newItem = Rename-AndroidItem -ItemPath $Item.FullPath
                if ($newItem) { $Item = $newItem } # Update the item if rename was successful
                Read-Host "Press Enter to continue"
            }
            "4" {
                Remove-AndroidItem -ItemPath $Item.FullPath
                Read-Host "Press Enter to continue"
                return # Item is deleted, so we must exit the action menu
            }
            "5" {
                Copy-AndroidItem -SourcePath $Item.FullPath
                Read-Host "Press Enter to continue"
            }
            "6" {
                Move-AndroidItem -SourcePath $Item.FullPath
                Read-Host "Press Enter to continue"
                return # Item is moved, so we must exit the action menu
            }
            "7" { return }
            default {
                Write-Host "Invalid choice." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            }
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
    if ($folderBrowser.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq 'OK') {
        return $folderBrowser.SelectedPath
    }
    return $null
}

# Function to pull files from Android
function Pull-FilesFromAndroid {
    param(
        [string]$Path,
        [switch]$Move
    )
    Write-Host "📥 PULL FILES FROM ANDROID" -ForegroundColor Magenta
    
    $sourcePath = if ($Path) { $Path } else { Read-Host -Prompt 'Enter source path on Android (e.g., /sdcard/Download/)' }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { $sourcePath = "/sdcard/Download/" }

    # Check if the source is a directory or a file
    $sourceIsDirResult = Invoke-AdbCommand "shell ls -ld ""$sourcePath"""
    $isDir = $sourceIsDirResult.Success -and $sourceIsDirResult.Output.StartsWith('d')

    $itemsToPull = @()
    if ($isDir) {
        $items = Get-AndroidDirectoryContents $sourcePath
        if ($items.Count -eq 0) { Write-Host "Directory is empty or inaccessible." -ForegroundColor Yellow; return }
        $itemsToPull = $items | Where-Object { $_.Type -ne 'Directory' } | Out-GridView -Title "Select files to pull" -OutputMode Multiple
    } else {
        # It's a single file
        $itemName = Split-Path $sourcePath -Leaf
        $itemsToPull += [PSCustomObject]@{ Name = $itemName; FullPath = $sourcePath }
    }
    
    if ($itemsToPull.Count -eq 0) { Write-Host "No files selected." -ForegroundColor Yellow; return }

    $destinationFolder = Show-FolderPicker "Select destination folder on PC"
    if (-not $destinationFolder) { return }

    $successCount = 0
    $failureCount = 0

    foreach ($item in $itemsToPull) {
        $sourceItemSafe = """$($item.FullPath)"""
        $destFileSafe = Join-Path $destinationFolder $item.Name
        
        # Get file size for progress bar
        $sizeResult = Invoke-AdbCommand "shell stat -c %s ""$($item.FullPath)"""
        [long]$totalSize = 0
        if ($sizeResult.Success) { $totalSize = [long]$sizeResult.Output }

        $adbCommand = {
            param($source, $dest)
            adb pull $source $dest
        }

        $result = Invoke-AdbTransferWithProgress -Activity "Pulling $($item.Name)" -AdbCommand $adbCommand -ArgumentList $sourceItemSafe, $destFileSafe -DestinationFileForPull $destFileSafe -TotalSizeForPull $totalSize

        if ($result.Success) {
            $successCount++
            if ($Move) {
                Write-Host "   - Removing source file..." -NoNewline
                $deleteResult = Invoke-AdbCommand "shell rm `"$($item.FullPath)`""
                if ($deleteResult.Success) { Write-Host " ✅" -ForegroundColor Green }
                else { Write-Host " ❌" -ForegroundColor Red }
            }
        } else {
            $failureCount++
            Write-Host "`n❌ Failed to pull $($item.Name). Error: $($result.Output)" -ForegroundColor Red
        }
    }
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# Function to push files to Android
function Push-FilesToAndroid {
    param([switch]$Move)
    Write-Host "📤 PUSH FILES TO ANDROID" -ForegroundColor Magenta
    
    $sourceFiles = Show-OpenFilePicker -Title "Select files to push" -MultiSelect
    if (-not $sourceFiles) { Write-Host "❌ No files selected." -ForegroundColor Red; return }

    $destinationPath = Read-Host -Prompt 'Enter destination path on Android (e.g., /sdcard/Download/)'
    if ([string]::IsNullOrWhiteSpace($destinationPath)) { $destinationPath = "/sdcard/Download/" }

    $successCount = 0
    $failureCount = 0

    foreach ($file in $sourceFiles) {
        $fileInfo = Get-Item $file
        $sourceFileSafe = """$($fileInfo.FullName)"""
        $destPathSafe = """$destinationPath"""
        
        $adbCommand = {
            param($source, $dest)
            adb push $source $dest
        }

        $result = Invoke-AdbTransferWithProgress -Activity "Pushing $($fileInfo.Name)" -AdbCommand $adbCommand -ArgumentList $sourceFileSafe, $destPathSafe

        if ($result.Success) {
            $successCount++
            if ($Move) {
                Write-Host "   - Removing source file..." -NoNewline
                Remove-Item -Path $fileInfo.FullName -Force -ErrorAction SilentlyContinue
                Write-Host " ✅" -ForegroundColor Green
            }
        } else {
            $failureCount++
            Write-Host "`n❌ Failed to push $($fileInfo.Name). Error: $($result.Output)" -ForegroundColor Red
        }
    }
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# Function to copy an item on Android
function Copy-AndroidItem {
    param([string]$SourcePath)

    $destinationPath = Read-Host "Enter the destination directory"
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

    $destinationPath = Read-Host "Enter the destination path (can be a new name in the same directory)"
    if ([string]::IsNullOrWhiteSpace($destinationPath)) {
        Write-Host "❌ Invalid destination path." -ForegroundColor Red
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
    $confirmation = Read-Host "Are you sure you want to permanently delete '$itemName'? This cannot be undone. [y/N]"
    if ($confirmation -ne 'y') {
        Write-Host "Deletion cancelled." -ForegroundColor Yellow
        return
    }

    # Use 'rm -rf' for directories and 'rm' for files
    $command = "shell rm -rf ""$ItemPath""" # Added -f to force deletion
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

    $originalItem = Get-AndroidDirectoryContents (Split-Path $ItemPath -Parent) | Where-Object { $_.FullPath -eq $ItemPath }
    $itemName = Split-Path $ItemPath -Leaf
    $newName = Read-Host "Enter the new name for '$itemName'"
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName.Contains('/') -or $newName.Contains('\')) {
        Write-Host "❌ Invalid name. Name cannot be empty or contain slashes." -ForegroundColor Red
        return $null
    }

    $parentPath = Split-Path $ItemPath -Parent
    $newItemPath = if ($parentPath -eq "/") { "/$newName" } else { "$parentPath/$newName" }

    $command = "shell mv ""$ItemPath"" ""$newItemPath"""
    $result = Invoke-AdbCommand $command

    if ($result.Success) {
        Write-Host "✅ Successfully renamed to '$newName'." -ForegroundColor Green
        # Return the new item object so the caller can update its state
        return [PSCustomObject]@{
            Name     = $newName
            FullPath = $newItemPath
            Type     = $originalItem.Type # Assume type stays the same
            Permissions = $originalItem.Permissions
        }
    } else {
        Write-Host "❌ Failed to rename. Error: $($result.Output)" -ForegroundColor Red
        return $null
    }
}

# Function to install an APK file
function Install-AndroidPackage {
    Write-Host "📦 INSTALL ANDROID PACKAGE (APK)" -ForegroundColor Magenta

    $apkPaths = Show-OpenFilePicker -Title "Select APK file(s) to install" -MultiSelect
    if (-not $apkPaths) { return }

    foreach ($apkPath in $apkPaths) {
        Write-Host "Installing '$apkPath'..." -ForegroundColor Yellow
        $result = Invoke-AdbCommand "install -r `"$apkPath`"" # Added -r to allow reinstall/update

        if ($result.Success -and $result.Output -match "Success") {
            Write-Host "✅ Successfully installed package." -ForegroundColor Green
        } else {
            Write-Host "❌ Failed to install package. Error: $($result.Output)" -ForegroundColor Red
        }
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

# Function to show file picker dialog
function Show-OpenFilePicker {
    param(
        [string]$Title = "Select a file",
        [switch]$MultiSelect
    )
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = $Title
    $fileDialog.Filter = "All files (*.*)|*.*|APK files (*.apk)|*.apk"
    $fileDialog.Multiselect = $MultiSelect
    if ($fileDialog.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq 'OK') {
        return $fileDialog.FileNames
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
    $result = Invoke-AdbCommand "shell mkdir -p `"$folderPath`""

    if ($result.Success) {
        Write-Host "✅ Successfully created folder: $folderPath" -ForegroundColor Green
        Write-Log "Successfully created folder $folderPath" "INFO"
    } else {
        Write-Host "❌ Failed to create folder. Error: $($result.Output)" -ForegroundColor Red
        # The error is already logged by Invoke-AdbCommand
    }
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
                    Remove-AndroidItem -ItemPath $itemPath
                }
            }
            "6" {
                $itemPath = Read-Host "Enter the full path of the item to rename"
                if (-not [string]::IsNullOrWhiteSpace($itemPath)) {
                    Rename-AndroidItem -ItemPath $itemPath
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
        
        if ($choice -in "1", "2", "4", "5", "6", "7", "8", "9") {
            Write-Host "`nPress Enter to return to the menu..." -ForegroundColor Yellow
            Read-Host | Out-Null
        }
    } while ($true)
}

# Start the application
Start-ADBTool
