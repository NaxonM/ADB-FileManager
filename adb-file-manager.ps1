# ADB File Manager - PowerShell Script
# A feature-rich tool for managing files on Android devices via ADB.
# Version 3.6 - By Gemini
#
# Key Features & Improvements:
# - NEW in v3.6: Major Performance Boost!
#   - The device status check is now cached for 15 seconds.
#   - This eliminates redundant 'adb' commands during rapid directory navigation,
#     making the file browser significantly faster and more responsive.
# - FIX in v3.5: Path Canonicalization to correctly handle symbolic links.
# - FIX in v3.5: Array Handling to fix "Invalid selection" bug.
# - FIX in v3.4: Robust Progress Bar to prevent crashes.
# - FIX in v3.3: Robust Path Handling and Caching Logic.
# - Directory Content Caching, Optimized Transfers, ETR & Progress Bar, Confirmation Screen.

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
# Cache for directory listings to speed up browsing. Key = Path, Value = Directory Contents
$script:DirectoryCache = @{}
# --- FIX (v3.6) ---
# Timestamp for the last device status check to prevent excessive ADB calls.
$script:LastStatusUpdateTime = [DateTime]::MinValue

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

# Centralized function to execute simple ADB commands and get their direct output.
function Invoke-AdbCommand {
    param(
        [string]$Command,
        [switch]$HideOutput
    )
    Write-Log "Executing ADB Command: adb $Command" "DEBUG"

    # Using temporary files for stdout/stderr is more robust for capturing all output
    $process = Start-Process adb -ArgumentList $Command -Wait -NoNewWindow -PassThru -RedirectStandardOutput "temp_stdout.txt" -RedirectStandardError "temp_stderr.txt"
    $exitCode = $process.ExitCode
    
    $stdout = Get-Content "temp_stdout.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $stderr = Get-Content "temp_stderr.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Remove-Item "temp_stdout.txt", "temp_stderr.txt" -ErrorAction SilentlyContinue

    $success = ($exitCode -eq 0)
    # Some successful commands (like pull) write to stderr, so we combine them on success.
    $output = if ($success) { ($stdout, $stderr | Where-Object { $_ }) -join "`n" } else { $stderr }

    if (-not $success) {
        Write-Log "ADB command failed with exit code $exitCode. Error: $output" "ERROR"
    }

    if ($HideOutput) {
        return [PSCustomObject]@{ Success = $success; Output  = "" }
    }

    return [PSCustomObject]@{ Success = $success; Output  = $output.Trim() }
}

# --- FIX (v3.6) ---
# OPTIMIZED to only run expensive ADB commands periodically.
function Update-DeviceStatus {
    # If a device is connected and we checked less than 15 seconds ago, skip the check.
    if ($script:DeviceStatus.IsConnected -and ((Get-Date) - $script:LastStatusUpdateTime).TotalSeconds -lt 15) {
        return
    }

    Write-Log "Performing full device status check." "DEBUG"
    $result = Invoke-AdbCommand "devices"
    $firstDeviceLine = $result.Output -split '\r?\n' | Where-Object { $_ -match '\s+device$' } | Select-Object -First 1

    if ($firstDeviceLine) {
        $serialNumber = ($firstDeviceLine -split '\s+')[0]
        $script:DeviceStatus.IsConnected = $true
        $script:DeviceStatus.SerialNumber = $serialNumber.Trim()
        
        $deviceNameResult = Invoke-AdbCommand "-s $serialNumber shell getprop ro.product.model"
        if ($deviceNameResult.Success -and -not [string]::IsNullOrWhiteSpace($deviceNameResult.Output)) {
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
    # Update the timestamp after a full check.
    $script:LastStatusUpdateTime = (Get-Date)
}

# --- Caching Functions ---

# Invalidates the cache for a specific directory path.
function Invalidate-DirectoryCache {
    param([string]$DirectoryPath)

    # Normalize path to use forward slashes and no trailing slash for consistency
    $normalizedPath = $DirectoryPath.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrEmpty($normalizedPath)) { $normalizedPath = "/" }

    if ($script:DirectoryCache.ContainsKey($normalizedPath)) {
        Write-Log "CACHE INVALIDATION: Removing '$normalizedPath' from cache." "INFO"
        $script:DirectoryCache.Remove($normalizedPath)
    }
}

# Gets the parent of an item and invalidates its cache.
function Invalidate-ParentCache {
     param([string]$ItemPath)
     # Normalize to forward slashes and remove any trailing slash
    $normalizedItemPath = $ItemPath.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrEmpty($normalizedItemPath) -or $normalizedItemPath -eq "/") { return }

    $lastSlashIndex = $normalizedItemPath.LastIndexOf('/')
    # If no slash or it's the only character, the parent is root.
    if ($lastSlashIndex -le 0) {
        Invalidate-DirectoryCache -DirectoryPath "/"
    } else {
        $parentPath = $normalizedItemPath.Substring(0, $lastSlashIndex)
        Invalidate-DirectoryCache -DirectoryPath $parentPath
    }
}

# --- UI and Utility Functions ---

function Show-UIHeader {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    🤖 ADB FILE MANAGER                     ║" -ForegroundColor Cyan
    Write-Host "║                 v3.6 with Performance Boost                ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    Update-DeviceStatus
    $statusText = "🔌 Status: "
    if ($script:DeviceStatus.IsConnected) {
        Write-Host "$statusText $($script:DeviceStatus.DeviceName) ($($script:DeviceStatus.SerialNumber))" -ForegroundColor Green
    } else {
        Write-Host "$statusText Disconnected - Please connect a device." -ForegroundColor Red
    }
    Write-Host "═" * 62 -ForegroundColor Gray
}

function Format-Bytes {
    param([long]$bytes)
    if ($bytes -lt 0) { return "0 B" }
    $units = @("B", "KB", "MB", "GB", "TB")
    $index = 0
    $value = [double]$bytes
    while ($value -ge 1024 -and $index -lt ($units.Length - 1)) {
        $value /= 1024
        $index++
    }
    return "{0:N2} {1}" -f $value, $units[$index]
}

function Show-InlineProgress {
    param(
        [string]$Activity,
        [long]$CurrentValue,
        [long]$TotalValue,
        [datetime]$StartTime
    )
    if ($TotalValue -le 0) {
        $percent = 0
    } else {
        $percent = [math]::Round(($CurrentValue / $TotalValue) * 100)
    }
    
    $elapsed = (Get-Date) - $StartTime
    $speed = if ($elapsed.TotalSeconds -gt 0.5) { $CurrentValue / $elapsed.TotalSeconds } else { 0 }
    
    $etrSeconds = if ($speed -gt 0 -and $CurrentValue -lt $TotalValue) { 
        ($TotalValue - $CurrentValue) / $speed 
    } else { 
        0 
    }
    
    $barWidth = 25
    
    $displayPercent = $percent
    $cappedPercent = $percent
    if ($cappedPercent -gt 100) { $cappedPercent = 100 }
    if ($cappedPercent -lt 0) { $cappedPercent = 0 }

    $completedWidth = [math]::Floor($barWidth * $cappedPercent / 100)
    $remainingWidth = $barWidth - $completedWidth
    if ($remainingWidth -lt 0) { $remainingWidth = 0 }
    
    $remainingSpaces = $remainingWidth - 1
    if ($remainingSpaces -lt 0) { $remainingSpaces = 0 }
    $progressBar = ("=" * $completedWidth) + ">" + (" " * $remainingSpaces)

    if ($completedWidth -ge $barWidth) {
        $progressBar = "=" * $barWidth
    }

    $speedText = "$(Format-Bytes $speed)/s"
    $sizeText = "{0} / {1}" -f (Format-Bytes $CurrentValue), (Format-Bytes $TotalValue)
    $etrText = if ($etrSeconds -gt 0 -and $etrSeconds -lt 86400) { [timespan]::FromSeconds($etrSeconds).ToString("hh\:mm\:ss") } else { "--:--:--" }

    $progressLine = "`r{0,-20} [{1}] {2,3}% | {3,22} | {4,12} | ETR: {5}" -f $Activity.Substring(0, [System.Math]::Min($Activity.Length, 20)), $progressBar, $displayPercent, $sizeText, $speedText, $etrText
    Write-Host $progressLine -NoNewline
}


# --- File and Directory Size Calculation ---

function Get-AndroidDirectorySize {
    param([string]$ItemPath)
    # Use single quotes for shell path
    $sizeResult = Invoke-AdbCommand "shell du -sb '$ItemPath'"
    if ($sizeResult.Success -and $sizeResult.Output) {
        $sizeStr = ($sizeResult.Output -split '\s+')[0]
        if ($sizeStr -match '^\d+$') {
            return [long]$sizeStr
        }
    }
    return 0
}

function Get-LocalItemSize {
    param([string]$ItemPath)
    try {
        if (-not (Test-Path -LiteralPath $ItemPath)) { return 0 }
        $item = Get-Item -LiteralPath $ItemPath -ErrorAction Stop
        if ($item.PSIsContainer) {
            $size = (Get-ChildItem -LiteralPath $ItemPath -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            return [long]$size
        } else {
            return $item.Length
        }
    } catch {
        Write-Log "Could not get size for local item: $ItemPath. Error: $_" "WARN"
        return 0
    }
}

# --- Core File Operations ---

function Get-AndroidDirectoryContents {
    param(
        [string]$Path
    )
    # Normalize path for cache key consistency
    $normalizedPath = $Path.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrEmpty($normalizedPath)) { $normalizedPath = "/" }

    # Check cache first
    if ($script:DirectoryCache.ContainsKey($normalizedPath)) {
        Write-Log "CACHE HIT: Returning cached contents for '$normalizedPath'." "DEBUG"
        return $script:DirectoryCache[$normalizedPath]
    }
    Write-Log "CACHE MISS: Fetching contents for '$normalizedPath' from device." "DEBUG"

    # Canonicalize the path to resolve symbolic links before listing contents.
    $canonicalResult = Invoke-AdbCommand "shell readlink -f '$normalizedPath'"
    $listPath = if ($canonicalResult.Success -and -not [string]::IsNullOrWhiteSpace($canonicalResult.Output)) { 
        $canonicalResult.Output.Trim()
    } else { 
        $normalizedPath 
    }
    Write-Log "Canonical path for listing: '$listPath' (from '$normalizedPath')" "DEBUG"

    # Use the canonical path for the 'ls' command.
    $result = Invoke-AdbCommand "shell ls -la '$listPath'"

    if (-not $result.Success) {
        Write-Host "`n❌ Failed to list directory '$Path'." -ForegroundColor Red
        Write-Host "   Error: $($result.Output)" -ForegroundColor Red
        return @()
    }

    $items = @()
    $lines = $result.Output -split '\r?\n' | Where-Object { $_ -and $_ -notlike 'total *' -and $_ -notlike '*No such file or directory*' }

    foreach ($line in $lines) {
        if ($line -match '^(?<perms>[\w-]{10})\s+\d+\s+(?<owner>\S+)\s+(?<group>\S+)\s+(?<size>\d+)?\s+(?<date>\d{4}-\d{2}-\d{2}\s\d{2}:\d{2})\s+(?<name>.+?)(?:\s->\s.*)?$') {
            $name = $Matches.name
            $type = if ($Matches.perms.StartsWith('d')) { "Directory" } elseif ($Matches.perms.StartsWith('l')) { "Link" } else { "File" }
            
            if ($name -eq "." -or $name -eq "..") { continue }
            
            $size = 0L
            if ($type -eq 'File' -and -not [string]::IsNullOrEmpty($Matches.size)) {
                $size = [long]$Matches.size
            }
            
            # Always join with the original path for user context, not the canonical one
            $fullPath = if ($normalizedPath.EndsWith('/')) { "$normalizedPath$name" } else { "$normalizedPath/$name" }

            $items += [PSCustomObject]@{
                Name        = $name.Trim()
                Type        = $type
                Permissions = $Matches.perms
                FullPath    = $fullPath
                Size        = $size
            }
        }
    }
    
    # Store the fresh result in the cache using the original path as the key
    $script:DirectoryCache[$normalizedPath] = $items
    return $items
}

function Pull-FilesFromAndroid {
    param(
        [string]$Path,
        [switch]$Move
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PULL" }
    Write-Host "`n📥 $actionVerb FROM ANDROID" -ForegroundColor Magenta
    
    $sourcePath = if ($Path) { $Path } else { Read-Host "➡️ Enter source path on Android to pull from (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { Write-Host "🟡 Action cancelled."; return }

    # Use single quotes for shell path
    $sourceIsDirResult = Invoke-AdbCommand "shell ls -ld '$sourcePath'"
    $isDir = $sourceIsDirResult.Success -and $sourceIsDirResult.Output.StartsWith('d')

    $itemsToPull = @()
    if ($isDir) {
        $allItems = @(Get-AndroidDirectoryContents $sourcePath) # Cast to array
        if ($allItems.Count -eq 0) { Write-Host "🟡 Directory is empty or inaccessible." -ForegroundColor Yellow; return }
        
        Write-Host "`nItems available in '$($sourcePath)':" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allItems.Count; $i++) {
            $icon = if ($allItems[$i].Type -eq "Directory") { "📁" } elseif ($allItems[$i].Type -eq "File") { "📄" } else { "🔗" }
            Write-Host (" [{0,2}] {1} {2}" -f ($i+1), $icon, $allItems[$i].Name)
        }
        $selectionStr = Read-Host "`n➡️ Enter item numbers to pull (e.g., 1,3,5 or 'all')"
        if ($selectionStr -eq 'all') { $itemsToPull = $allItems } 
        elseif ($selectionStr) {
            $selectedIndices = $selectionStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
            $itemsToPull = $selectedIndices | ForEach-Object { if ($_ -ge 0 -and $_ -lt $allItems.Count) { $allItems[$_] } }
        }
    } else {
        # Use single quotes for shell path
        $sizeResult = Invoke-AdbCommand "shell stat -c %s '$sourcePath'"
        $fileSize = if ($sizeResult.Success -and $sizeResult.Output -match '^\d+$') { [long]$sizeResult.Output } else { 0L }
        $itemName = $sourcePath.Split('/')[-1]
        $itemsToPull += [PSCustomObject]@{ Name = $itemName; FullPath = $sourcePath; Type = 'File'; Size = $fileSize }
    }
    
    if ($itemsToPull.Count -eq 0) { Write-Host "🟡 No items selected." -ForegroundColor Yellow; return }

    $destinationFolder = Show-FolderPicker "Select destination folder on PC"
    if (-not $destinationFolder) { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }

    # --- Confirmation Wizard with Size Calculation ---
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline
    [long]$totalSize = 0
    $itemSizes = @{}
    
    foreach ($item in $itemsToPull) {
        $itemSize = 0L
        if ($item.Type -eq 'Directory') {
            $itemSize = Get-AndroidDirectorySize -ItemPath $item.FullPath
        } else {
            $itemSize = $item.Size
        }
        $itemSizes[$item.FullPath] = $itemSize
        $totalSize += $itemSize
    }

    Write-Host "`r" + (" " * 50) + "`r"
    Write-Host "You are about to $actionVerb $($itemsToPull.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    $fromLocation = if ($isDir) { $sourcePath } else { $sourcePath.Substring(0, $sourcePath.LastIndexOf('/')) }
    Write-Host "From (Android): $fromLocation" -ForegroundColor Yellow
    Write-Host "To   (PC)    : $destinationFolder" -ForegroundColor Yellow
    $confirm = Read-Host "➡️ Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }

    $successCount = 0; $failureCount = 0; [long]$cumulativeBytesTransferred = 0
    $overallStartTime = Get-Date

    foreach ($item in $itemsToPull) {
        $sourceItemSafe = """$($item.FullPath)"""
        $destPathOnPC = Join-Path $destinationFolder $item.Name
        $itemTotalSize = $itemSizes[$item.FullPath]
        
        $adbCommand = { param($source, $dest) adb pull $source $dest 2>&1 }
        $job = Start-Job -ScriptBlock $adbCommand -ArgumentList @($sourceItemSafe, $destinationFolder)
        
        $itemStartTime = Get-Date
        Write-Host ""
        
        while ($job.State -eq 'Running') {
            $currentSize = Get-LocalItemSize -ItemPath $destPathOnPC
            Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $currentSize -TotalValue $itemTotalSize -StartTime $itemStartTime
            Start-Sleep -Milliseconds 250
        }
        
        $finalSize = Get-LocalItemSize -ItemPath $destPathOnPC
        Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $finalSize -TotalValue $itemTotalSize -StartTime $itemStartTime
        Write-Host ""

        $resultOutput = Receive-Job $job
        $success = ($job.JobStateInfo.State -eq 'Completed' -and $resultOutput -notmatch 'No such file or directory' -and $resultOutput -notmatch 'error:')
        Remove-Job $job
        
        if ($success) {
            $successCount++
            $cumulativeBytesTransferred += $finalSize
            Write-Host "✅ Pulled $($item.Name)" -ForegroundColor Green
            Write-Host ($resultOutput | Out-String).Trim() -ForegroundColor Gray

            if ($Move) {
                Write-Host "   - Removing source item..." -NoNewline
                # Use single quotes for shell path
                $deleteResult = Invoke-AdbCommand "shell rm -rf '$($item.FullPath)'"
                if ($deleteResult.Success) {
                    Write-Host " ✅" -ForegroundColor Green
                    # Use new cache invalidation
                    Invalidate-ParentCache -ItemPath $item.FullPath
                } else { Write-Host " ❌ (Failed to delete)" -ForegroundColor Red }
            }
        } else {
            $failureCount++; Write-Host "`n❌ FAILED to pull $($item.Name)." -ForegroundColor Red
            Write-Host "   Error: $resultOutput" -ForegroundColor Red
        }
    }
    $overallTimeTaken = ((Get-Date) - $overallStartTime).TotalSeconds
    Write-Host "`n📊 TRANSFER SUMMARY" -ForegroundColor Cyan
    Write-Host "   - ✅ $successCount Successful, ❌ $failureCount Failed"
    Write-Host "   - Total Transferred: $(Format-Bytes $cumulativeBytesTransferred)"
    Write-Host "   - Time Taken: $([math]::Round($overallTimeTaken, 2)) seconds"
}

function Push-FilesToAndroid {
    param(
        [switch]$Move,
        [string]$DestinationPath
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PUSH" }
    Write-Host "`n📤 $actionVerb ITEMS TO ANDROID" -ForegroundColor Magenta
    
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
    Write-Host "`r" + (" " * 50) + "`r"
    Write-Host "You are about to $actionVerb $($sourceItems.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    Write-Host "From (PC)    : $(Split-Path $sourceItems[0] -Parent)" -ForegroundColor Yellow
    Write-Host "To   (Android): $destPathFinal" -ForegroundColor Yellow
    Write-Host "NOTE: ADB push does not support a detailed progress bar." -ForegroundColor DarkGray
    $confirm = Read-Host "➡️ Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }

    $successCount = 0; $failureCount = 0
    foreach ($item in $sourceItems) {
        $itemInfo = Get-Item -LiteralPath $item
        $sourceItemSafe = """$($itemInfo.FullName)"""
        $destPathSafe = """$destPathFinal"""
        
        $adbCommand = { param($source, $dest) adb push $source $dest 2>&1 }
        $job = Start-Job -ScriptBlock $adbCommand -ArgumentList @($sourceItemSafe, $destPathSafe)

        $spinner = @('|', '/', '-', '\')
        $spinnerIndex = 0
        Write-Host ""
        while ($job.State -eq 'Running') {
            $status = "Pushing $($itemInfo.Name)... $($spinner[$spinnerIndex])"
            Write-Host "`r$status" -NoNewline
            $spinnerIndex = ($spinnerIndex + 1) % $spinner.Length
            Start-Sleep -Milliseconds 150
        }
        Write-Host "`r" + (" " * ($status.Length + 5)) + "`r"

        $resultOutput = Receive-Job $job
        $success = ($job.JobStateInfo.State -eq 'Completed' -and $resultOutput -notmatch 'error:')
        Remove-Job $job

        if ($success) {
            $successCount++
            Write-Host "✅ Pushed $($itemInfo.Name)" -ForegroundColor Green
            Write-Host ($resultOutput | Out-String).Trim() -ForegroundColor Gray

            # Use new cache invalidation
            Invalidate-DirectoryCache -DirectoryPath $destPathFinal

            if ($Move) {
                Write-Host "   - Removing source item..." -NoNewline
                try {
                    Remove-Item -LiteralPath $itemInfo.FullName -Force -Recurse -ErrorAction Stop
                    Write-Host " ✅" -ForegroundColor Green
                } catch {
                    Write-Host " ❌ (Failed to delete)" -ForegroundColor Red
                }
            }
        } else {
            $failureCount++; Write-Host "`n❌ FAILED to push $($itemInfo.Name)." -ForegroundColor Red
            Write-Host "   Error: $resultOutput" -ForegroundColor Red
        }
    }
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $successCount Successful, ❌ $failureCount Failed" -ForegroundColor Cyan
}


# --- Other File System Functions ---

function Browse-AndroidFileSystem {
    $currentPath = Read-Host "➡️ Enter starting path (default: /sdcard/)"
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "/sdcard/" }

    do {
        Show-UIHeader
        Write-Host "📁 Browsing: $currentPath" -ForegroundColor White -BackgroundColor DarkCyan
        Write-Host "─" * 62 -ForegroundColor Gray

        # Cast the result to an array to prevent errors when a directory has only one item.
        $items = @(Get-AndroidDirectoryContents $currentPath)
        
        Write-Host " [ 0] .. (Go Up)" -ForegroundColor Yellow
        $i = 1
        foreach ($item in $items) {
            # Added a 'Link' icon for completeness
            $icon = if ($item.Type -eq "Directory") { "📁" } elseif ($item.Type -eq "File") { "📄" } else { "🔗" }
            $color = if ($item.Type -eq "Directory") { "Cyan" } elseif ($item.Type -eq "Link") { "Yellow" } else { "White" }
            Write-Host (" [{0,2}] {1} {2}" -f $i, $icon, $item.Name) -ForegroundColor $color
            $i++
        }
        
        $choice = Read-Host "`n➡️ Enter number to browse, (c)reate, (p)ull, (u)pload, (r)efresh, or (q)uit to menu"

        switch ($choice) {
            "q" { return }
            "c" { New-AndroidFolder -ParentPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "p" { Pull-FilesFromAndroid -Path $currentPath; Read-Host "`nPress Enter to continue..." }
            "u" { Push-FilesToAndroid -DestinationPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "r" {
                Write-Host "`n🔄 Refreshing directory..." -ForegroundColor Yellow
                # Use new cache invalidation
                Invalidate-DirectoryCache -DirectoryPath $currentPath
                Start-Sleep -Seconds 1
            }
            "0" {
                if ($currentPath -ne "/" -and $currentPath -ne "") {
                    $parentPath = $currentPath.TrimEnd('/')
                    $lastSlash = $parentPath.LastIndexOf('/')
                    if ($lastSlash -gt 0) {
                        $currentPath = $parentPath.Substring(0, $lastSlash)
                    } elseif ($lastSlash -eq 0) {
                        $currentPath = "/"
                    } else { # No slash found
                        $currentPath = "/"
                    }
                }
            }
            default {
                if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $items.Count) {
                    $selectedIndex = [int]$choice - 1
                    $selectedItem = $items[$selectedIndex]
                    if ($selectedItem.Type -eq "Directory" -or $selectedItem.Type -eq "Link") { # Allow browsing into links
                        $currentPath = $selectedItem.FullPath 
                    } else { 
                        Show-ItemActionMenu -Item $selectedItem 
                    }
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
    # Use single quotes for shell path
    $result = Invoke-AdbCommand "shell mkdir -p '$fullPath'"
    if ($result.Success) {
        Write-Host "✅ Successfully created folder: $fullPath" -ForegroundColor Green
        # Use new cache invalidation
        Invalidate-ParentCache -ItemPath $fullPath
    } 
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
                Rename-AndroidItem -ItemPath $Item.FullPath
                Read-Host "`nPress Enter to continue..."
                return # Return to browser as item name has changed
            }
            "4" { 
                Remove-AndroidItem -ItemPath $Item.FullPath
                Read-Host "`nPress Enter to continue..."
                return # Return to browser as item is gone
            }
            "5" { return }
            default { Write-Host "❌ Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Remove-AndroidItem {
    param([string]$ItemPath)
    $itemName = $ItemPath.Split('/')[-1]
    $confirmation = Read-Host "❓ Are you sure you want to PERMANENTLY DELETE '$itemName'? [y/N]"
    if ($confirmation.ToLower() -ne 'y') { Write-Host "🟡 Deletion cancelled." -ForegroundColor Yellow; return }
    # Use single quotes for shell path
    $result = Invoke-AdbCommand "shell rm -rf '$ItemPath'"
    if ($result.Success) {
        Write-Host "✅ Successfully deleted '$itemName'." -ForegroundColor Green
        # Use new cache invalidation
        Invalidate-ParentCache -ItemPath $ItemPath
    } 
    else { Write-Host "❌ Failed to delete '$itemName'. Error: $($result.Output)" -ForegroundColor Red }
}

function Rename-AndroidItem {
    param([string]$ItemPath)
    $itemName = $ItemPath.Split('/')[-1]
    $newName = Read-Host "➡️ Enter the new name for '$itemName'"
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName.Contains('/') -or $newName.Contains('\')) {
        Write-Host "❌ Invalid name." -ForegroundColor Red; return
    }
    $parentPath = $ItemPath.Substring(0, $ItemPath.LastIndexOf('/'))
    $newItemPath = if ([string]::IsNullOrEmpty($parentPath)) { "/$newName" } else { "$parentPath/$newName" }

    # Use single quotes for shell path
    $result = Invoke-AdbCommand "shell mv '$ItemPath' '$newItemPath'"
    if ($result.Success) {
        Write-Host "✅ Successfully renamed to '$newName'." -ForegroundColor Green
        # Use new cache invalidation (invalidate the old item's parent directory)
        Invalidate-ParentCache -ItemPath $ItemPath 
    } else {
        Write-Host "❌ Failed to rename. Error: $($result.Output)" -ForegroundColor Red
    }
}

# --- GUI Picker Functions ---

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
            Write-Host "   Trying to reconnect in 5 seconds..."
            # Force a full status update on the next loop after sleeping
            $script:LastStatusUpdateTime = [DateTime]::MinValue
            Start-Sleep -Seconds 5
            continue
        }

        Write-Host "`nMAIN MENU" -ForegroundColor Green
        Write-Host "══════════════════════════════════════════════════════════════"
        Write-Host "1. Browse Device Filesystem (Interactive Push/Pull/Manage)"
        Write-Host "2. Quick Push (from PC to a specified device path)"
        Write-Host "3. Quick Pull (from a specified device path to PC)"
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
        
        if ($choice -in '2','3') {
            Read-Host "`nPress Enter to return to the main menu..."
        }
    }
}

# --- Main execution entry point ---
function Start-ADBTool {
    # Set output encoding to handle special characters correctly
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Write-Host "❌ ADB not found in your system's PATH." -ForegroundColor Red
        Write-Host "Please install Android SDK Platform Tools and add its directory to your system's PATH environment variable." -ForegroundColor Red
        Read-Host "Press Enter to exit."
        return
    }

    Write-Log "ADB File Manager v3.6 Started" "INFO"
    Show-MainMenu
    Write-Host "`n👋 Thank you for using the ADB File Manager!" -ForegroundColor Green
}

# Start the application
Start-ADBTool
