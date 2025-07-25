# ADB File Transfer Tool - PowerShell Script
# Provides a graphical and interactive interface for Android file operations

# Load required assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global variables
$script:LogFile = "ADB_Operations_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Function to write to log file
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $logEntry
}

# Function to check if ADB is available and device is connected
function Test-ADBConnection {
    Write-Host "🔍 Checking ADB connection..." -ForegroundColor Cyan
    try {
        if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
            Write-Host "❌ ADB not found in PATH. Please install Android SDK Platform Tools and restart the terminal." -ForegroundColor Red
            return $false
        }
        if (-not (& adb devices | Select-String -Pattern "device$")) {
            Write-Host "❌ No Android device connected. Please connect your device and enable USB debugging." -ForegroundColor Red
            return $false
        }
        Write-Host "✅ Device connected successfully!" -ForegroundColor Green
        Write-Log "Device connected successfully" "INFO"
        return $true
    }
    catch {
        Write-Host "❌ Error checking ADB connection: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "Error checking ADB connection: $($_.Exception.Message)" "ERROR"
        return $false
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

# Function to get files from a folder for selection
function Get-FilesFromFolder {
    param(
        [string]$FolderPath
    )
    $files = Get-ChildItem -Path $FolderPath -File | Select-Object Name, Length, LastWriteTime, FullName
    if ($files.Count -eq 0) {
        Write-Host "⚠️ No files found in the selected folder." -ForegroundColor Yellow
        return @()
    }
    return $files | Out-GridView -Title "Select files to transfer" -OutputMode Multiple
}

# Function to push files to Android
function Push-FilesToAndroid {
    Write-Host "📤 PUSH FILES TO ANDROID" -ForegroundColor Magenta
    Write-Host "=" * 40 -ForegroundColor Magenta
    
    $sourceFolder = Show-FolderPicker "Select source folder on your PC"
    if (-not $sourceFolder) { Write-Host "❌ No folder selected." -ForegroundColor Red; return }
    Write-Host "📁 Source folder: $sourceFolder" -ForegroundColor Cyan

    $pushChoice = Read-Host -Prompt "Push the [E]ntire folder or [S]elect specific files from it?"
    
    $destinationPath = Read-Host -Prompt "Enter destination path on Android (e.g., /sdcard/Download/)"
    if ([string]::IsNullOrWhiteSpace($destinationPath)) { $destinationPath = "/sdcard/Download/" }
    
    if ($pushChoice -ieq 'E') {
        Write-Host "🚀 Pushing entire folder to $destinationPath... (This may take a while)" -ForegroundColor Green
        $result = & adb push "$sourceFolder" "$destinationPath" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Successfully pushed folder '$sourceFolder'." -ForegroundColor Green
            Write-Log "Successfully pushed folder '$sourceFolder' to $destinationPath" "INFO"
        } else {
            Write-Host "❌ Failed to push folder: $result" -ForegroundColor Red
            Write-Log "Failed to push folder '$sourceFolder': $result" "ERROR"
        }
    } else {
        $selectedFiles = Get-FilesFromFolder $sourceFolder
        if ($selectedFiles.Count -eq 0) { return }
        
        Write-Host "🚀 Starting file transfer to $destinationPath..." -ForegroundColor Green
        $successCount = 0; $failureCount = 0; $i = 0; $total = $selectedFiles.Count
        
        foreach ($file in $selectedFiles) {
            $i++
            Write-Progress -Activity "Pushing Files" -Status "($i/$total) Pushing $($file.Name)" -PercentComplete (($i / $total) * 100)
            
            $result = & adb push "$($file.FullName)" "$destinationPath" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $successCount++; Write-Log "Successfully pushed $($file.Name) to $destinationPath" "INFO"
            } else {
                $failureCount++; Write-Log "Failed to push $($file.Name): $result" "ERROR"
            }
        }
        Write-Progress -Activity "Pushing Files" -Completed
        Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
    }
}

# Function to list Android directory contents with correct character encoding
function Get-AndroidDirectoryContents {
    param([string]$Path)
    
    $oldEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $result = & adb shell "ls -p ""$Path""" 2>&1
    [Console]::OutputEncoding = $oldEncoding
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Failed to list directory: $result" -ForegroundColor Red
        return @()
    }
    
    $items = @()
    $lines = $result -split '\r?\n' | Where-Object { $_ }

    foreach ($line in $lines) {
        $name = $line.Trim()
        $type = if ($name.EndsWith('/')) { "Directory" } else { "File" }
        $name = $name.TrimEnd('/')
        
        if ($name -ne "." -and $name -ne "..") {
            $items += [PSCustomObject]@{
                Name     = $name
                Type     = $type
                FullPath = "$Path/$name".Replace("//", "/")
            }
        }
    }
    return $items
}

# Function to pull files from Android
function Pull-FilesFromAndroid {
    Write-Host "📥 PULL FILES FROM ANDROID" -ForegroundColor Magenta
    Write-Host "=" * 40 -ForegroundColor Magenta
    
    $sourcePath = Read-Host -Prompt "Enter source path on Android (e.g., /sdcard/Download/)"
    if (-not $sourcePath) { $sourcePath = "/sdcard/Download/" }

    & adb shell "test -d ""$sourcePath""" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $pullChoice = Read-Host -Prompt "Path is a directory. Pull the [E]ntire directory or [S]elect specific items from inside?"
        if ($pullChoice -ieq 'E') {
            $destinationFolder = Show-FolderPicker "Select a destination folder on your PC"
            if (-not $destinationFolder) { Write-Host "❌ No destination folder selected." -ForegroundColor Red; return }

            $createSubfolderChoice = Read-Host -Prompt "Create a subfolder named '$(Split-Path $sourcePath -Leaf)' in the destination? [Y]es/[N]o"
            $finalDest = if ($createSubfolderChoice -ieq 'Y') {
                $dest = Join-Path -Path $destinationFolder -ChildPath (Split-Path $sourcePath -Leaf)
                if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory | Out-Null }
                $dest
            } else {
                $destinationFolder
            }

            Write-Host "🚀 Pulling entire folder to $finalDest... (This may take a while)" -ForegroundColor Green
            $result = & adb pull "$sourcePath" "$finalDest" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✅ Successfully pulled folder." -ForegroundColor Green
                Write-Log "Successfully pulled folder $sourcePath to $finalDest" "INFO"
            } else {
                Write-Host "❌ Failed to pull folder: $result" -ForegroundColor Red
                # CORRECTED LINE
                Write-Log "Failed to pull folder ${sourcePath}: $result" "ERROR"
            }
            return
        }
    }

    $items = Get-AndroidDirectoryContents $sourcePath
    if ($items.Count -eq 0) { Write-Host "❌ No items found or path is not a directory." -ForegroundColor Red; return }

    $selectedItems = $items | Out-GridView -Title "Select files/folders to pull" -OutputMode Multiple
    if ($selectedItems.Count -eq 0) { Write-Host "❌ No items selected." -ForegroundColor Red; return }
    
    $destinationFolder = Show-FolderPicker "Select destination folder on PC"
    if (-not $destinationFolder) { Write-Host "❌ No destination folder selected." -ForegroundColor Red; return }

    $successCount = 0; $failureCount = 0; $i = 0; $total = $selectedItems.Count
    foreach ($item in $selectedItems) {
        $i++
        Write-Progress -Activity "Pulling Items" -Status "($i/$total) Pulling $($item.Name)" -PercentComplete (($i / $total) * 100)
        
        $pullSource = $item.FullPath
        $pullDest = $destinationFolder

        if ($item.Type -eq 'Directory') {
            $pullDest = Join-Path -Path $destinationFolder -ChildPath $item.Name
            if (-not (Test-Path $pullDest)) {
                New-Item -Path $pullDest -ItemType Directory | Out-Null
            }
            $pullSource += "/."
        }

        $result = & adb pull "$pullSource" "$pullDest" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $successCount++; Write-Log "Successfully pulled $($item.Name) from $($item.FullPath)" "INFO"
        } else {
            $failureCount++; Write-Log "Failed to pull $($item.Name): $result" "ERROR"
        }
    }
    Write-Progress -Activity "Pulling Items" -Completed
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}

# Function to browse Android file system
function Browse-AndroidFileSystem {
    Write-Host "📂 BROWSE ANDROID FILE SYSTEM" -ForegroundColor Magenta
    $currentPath = Read-Host -Prompt "Enter starting path (default: /sdcard/)"
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "/sdcard/" }

    do {
        Write-Host "`n📍 Current path: $currentPath" -ForegroundColor Cyan
        $items = Get-AndroidDirectoryContents $currentPath
        $navItems = @(
            [PSCustomObject]@{ Name = ".. (Go Up)"; Type = "Navigation"; FullPath = "" },
            [PSCustomObject]@{ Name = "Exit Browser"; Type = "Navigation"; FullPath = "" }
        )
        $selectedItem = ($navItems + $items) | Out-GridView -Title "Browse: $currentPath" -OutputMode Single
        
        if (-not $selectedItem -or $selectedItem.Name -eq "Exit Browser") { break }
        
        if ($selectedItem.Name -eq ".. (Go Up)") {
            if ($currentPath -ne "/") { $currentPath = Split-Path $currentPath -Parent }
            if ([string]::IsNullOrEmpty($currentPath)) { $currentPath = "/" }
        } elseif ($selectedItem.Type -eq "Directory") {
            $currentPath = $selectedItem.FullPath
        } else {
            Write-Host "📄 Selected file: $($selectedItem.Name)" -ForegroundColor Green
        }
    } while ($true)
}

# Function to create folder on Android
function New-AndroidFolder {
    Write-Host "📁 CREATE FOLDER ON ANDROID" -ForegroundColor Magenta
    $folderPath = Read-Host -Prompt "Enter full path for new folder (e.g., /sdcard/MyFolder)"
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        Write-Host "❌ No path provided." -ForegroundColor Red; return
    }
    $result = & adb shell "mkdir -p ""$folderPath""" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Successfully created folder: $folderPath" -ForegroundColor Green
        Write-Log "Successfully created folder $folderPath" "INFO"
    } else {
        Write-Host "❌ Failed to create folder: ${result}" -ForegroundColor Red
        # CORRECTED LINE
        Write-Log "Failed to create folder ${folderPath}: $result" "ERROR"
    }
}

# Function to show main menu
function Show-MainMenu {
    Clear-Host
    Write-Host @"
╔══════════════════════════════════════════════════════════════╗
║                    🤖 ADB FILE TRANSFER TOOL                 ║
║                     PowerShell Edition                       ║
╚══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host "`n📋 MAIN MENU:" -ForegroundColor Green
    Write-Host "1. 📤 Push files/folders to Android"
    Write-Host "2. 📥 Pull files/folders from Android"
    Write-Host "3. 📂 Browse Android file system"
    Write-Host "4. 📁 Create folder on Android"
    Write-Host "5. 🚪 Exit"
    Write-Host "`n📝 Log file: $script:LogFile" -ForegroundColor Gray
}

# Main execution loop
function Start-ADBTool {
    Write-Log "ADB File Transfer Tool started" "INFO"
    do {
        Show-MainMenu
        $choice = Read-Host -Prompt "`nEnter your choice (1-5)"
        
        if ($choice -in "1", "2", "3", "4") {
            if (-not (Test-ADBConnection)) {
                Read-Host "Press any key to continue..."; continue
            }
        }
        
        switch ($choice) {
            "1" { Push-FilesToAndroid }
            "2" { Pull-FilesFromAndroid }
            "3" { Browse-AndroidFileSystem }
            "4" { New-AndroidFolder }
            "5" { 
                Write-Host "👋 Thank you for using the tool!" -ForegroundColor Green
                return
            }
            default { Write-Host "❌ Invalid choice." -ForegroundColor Red }
        }
        
        if ($choice -in "1", "2", "3", "4") {
            Write-Host "`nPress any key to return to the menu..." -ForegroundColor Yellow
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } while ($true)
}

# Start the application
Start-ADBTool