<#
.SYNOPSIS
    A feature-rich PowerShell script for managing files on Android devices using ADB.

.DESCRIPTION
    ADB File Manager provides a comprehensive, user-friendly command-line interface
    for browsing, transferring, and managing files and directories on an Android device.

    It is designed for efficiency and reliability, incorporating features like content
    caching, optimized bulk transfers, and a real-time status checker that intelligently
    detects device disconnections.

.FEATURES
    - Interactive File Browser: Navigate the device filesystem, with options to create,
      rename, and delete files/folders.
    - Optimized Transfers: Efficiently pull/push multiple items at once. Directory sizes
      are calculated in a single, optimized command to speed up confirmations.
    - Smart Status & Caching: A 15-second device status cache minimizes redundant ADB
      calls, making browsing significantly faster. The script also intelligently detects
      disconnections from command errors for instant feedback.
    - Detailed Progress Bar: Monitor 'pull' operations with a detailed progress bar
      showing speed, percentage, ETR, and total size.
    - GUI Pickers: Uses familiar Windows dialogs for selecting local files and folders.
    - Robust Error Handling: Built to handle common ADB errors and pathing issues gracefully.
    - Logging: All major operations are logged to a timestamped file for easy debugging.

.VERSION
    4.2.0
#>

#Requires -Version 5.1

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

    try {
        # Using temporary files for stdout/stderr is more robust for capturing all output
        $process = Start-Process adb -ArgumentList $Command -Wait -NoNewWindow -PassThru -RedirectStandardOutput "temp_stdout.txt" -RedirectStandardError "temp_stderr.txt"
        $exitCode = $process.ExitCode

        $stdout = Get-Content "temp_stdout.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $stderr = Get-Content "temp_stderr.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item "temp_stdout.txt", "temp_stderr.txt" -ErrorAction SilentlyContinue
    }

    $success = ($exitCode -eq 0)
    # Some successful commands (like pull) write to stderr, so we combine them on success.
    $output = if ($success) { ($stdout, $stderr | Where-Object { $_ }) -join "`n" } else { $stderr }

    if (-not $success) {
        Write-Log "ADB command failed with exit code $exitCode. Error: $output" "ERROR"
        # Smart Status Check: If a command fails, check if it's due to a disconnection.
        # This makes the script instantly aware of a disconnected device without constant polling.
        if ($output -match "device not found|device offline|no devices/emulators found") {
            Write-Log "Device disconnection detected from command error. Forcing status refresh." "WARN"
            $script:DeviceStatus.IsConnected = $false
            $script:DeviceStatus.DeviceName   = "No Device"
            $script:DeviceStatus.SerialNumber = ""
            # By resetting the timestamp, we force Update-DeviceStatus to do a full check next time it's called.
            $script:LastStatusUpdateTime = [DateTime]::MinValue
            # Purge any cached directory entries since they're now invalid without a device.
            $script:DirectoryCache.Clear()
            Write-Log "Directory cache cleared due to device loss." "WARN"
        }
    }

    if ($HideOutput) {
        return [PSCustomObject]@{ Success = $success; Output  = "" }
    }

    return [PSCustomObject]@{ Success = $success; Output  = $output.Trim() }
}

# --- Device and Caching Functions ---

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

# Converts a path to Android-friendly format.
function ConvertTo-AndroidPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return "/" }
    $converted = $Path.Replace('\\', '/').TrimEnd('/')
    if ([string]::IsNullOrEmpty($converted)) { $converted = "/" }
    return $converted
}

# Invalidates the cache for a specific directory path.
function Invalidate-DirectoryCache {
    param([string]$DirectoryPath)

    # Always normalize the path before interacting with the cache.
    $cacheKey = ConvertTo-AndroidPath $DirectoryPath

    if ($script:DirectoryCache.ContainsKey($cacheKey)) {
        Write-Log "CACHE INVALIDATION: Removing '$cacheKey' from cache." "INFO"
        $script:DirectoryCache.Remove($cacheKey)
    }
}

# Gets the parent of an item and invalidates its cache.
function Invalidate-ParentCache {
     param([string]$ItemPath)
    if (-not (Test-AndroidPath $ItemPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }
     # Normalize to forward slashes and remove any trailing slash
    $normalizedItemPath = ConvertTo-AndroidPath $ItemPath
    if ($normalizedItemPath -eq "/") { return }

    $lastSlashIndex = $normalizedItemPath.LastIndexOf('/')
    # If no slash or it's the only character, the parent is root.
    if ($lastSlashIndex -le 0) {
        Invalidate-DirectoryCache -DirectoryPath "/"
    } else {
        $parentPath = $normalizedItemPath.Substring(0, $lastSlashIndex)
        Invalidate-DirectoryCache -DirectoryPath $parentPath
    }
}

# Validates Android paths to prevent command injection
function Test-AndroidPath {
    param([string]$Path)
    $invalidChars = @(
        [char]38,  # &
        [char]124, # |
        [char]96,  # `
        [char]36,  # $
        [char]40,  # (
        [char]41,  # )
        [char]39   # '
    )
    foreach ($ch in $invalidChars) {
        if ($Path -and $Path.Contains($ch)) {
            Write-Host "❌ Path contains invalid character '$ch'." -ForegroundColor Red
            return $false
        }
    }
    return $true
}

# --- UI and Utility Functions ---

function Show-UIHeader {
    param(
        [string]$Title = "ADB FILE MANAGER",
        [string]$SubTitle
    )
    Clear-Host
    $width = 62
    Write-Host ("╔" + ("═" * ($width - 2)) + "╗") -ForegroundColor Cyan
    Write-Host ("║" + (" " * ($width - 2)) + "║") -ForegroundColor Cyan
    $titlePadding = [math]::Floor(($width - 2 - $Title.Length) / 2)
    Write-Host ("║" + (" " * $titlePadding) + $Title + (" " * ($width - 2 - $Title.Length - $titlePadding)) + "║") -ForegroundColor White
    if ($SubTitle) {
        $subtitlePadding = [math]::Floor(($width - 2 - $SubTitle.Length) / 2)
        Write-Host ("║" + (" " * $subtitlePadding) + $SubTitle + (" " * ($width - 2 - $SubTitle.Length - $subtitlePadding)) + "║") -ForegroundColor Gray
    }
    Write-Host ("║" + (" " * ($width - 2)) + "║") -ForegroundColor Cyan
    Write-Host ("╚" + ("═" * ($width - 2)) + "╝") -ForegroundColor Cyan
    
    Update-DeviceStatus
    $statusText = "🔌 Status: "
    if ($script:DeviceStatus.IsConnected) {
        Write-Host "$statusText $($script:DeviceStatus.DeviceName) ($($script:DeviceStatus.SerialNumber))" -ForegroundColor Green
    } else {
        Write-Host "$statusText Disconnected - Please connect a device." -ForegroundColor Red
    }
    Write-Host ("─" * $width) -ForegroundColor Gray
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
    
    # FIX: Replaced [System.Math]::Clamp for better PowerShell compatibility.
    $cappedPercent = $percent
    if ($cappedPercent -gt 100) { $cappedPercent = 100 }
    if ($cappedPercent -lt 0) { $cappedPercent = 0 }

    $completedWidth = [math]::Floor($barWidth * $cappedPercent / 100)
    $remainingWidth = $barWidth - $completedWidth
    
    $progressBarChar = "■"
    $progressBar = ($progressBarChar * $completedWidth) + ("-" * $remainingWidth)

    $speedText = "$(Format-Bytes $speed)/s"
    $sizeText = "{0} / {1}" -f (Format-Bytes $CurrentValue), (Format-Bytes $TotalValue)
    $etrText = if ($etrSeconds -gt 0 -and $etrSeconds -lt 86400) { [timespan]::FromSeconds($etrSeconds).ToString("hh\:mm\:ss") } else { "--:--:--" }

    $activityString = $Activity.PadRight(20).Substring(0, 20)
    $progressLine = "`r{0} [{1}] {2,3}% | {3,22} | {4,12} | ETR: {5}" -f $activityString, $progressBar, $displayPercent, $sizeText, $speedText, $etrText
    Write-Host $progressLine -NoNewline
}


# --- File and Directory Size Calculation ---

# Gets the size of multiple Android items (files/dirs) using an optimized single command for directories.
function Get-AndroidItemsSize {
    param(
        [array]$Items
    )
    $totalSize = 0L
    $itemSizes = @{}
    $dirsToQuery = @()

    # Separate files and directories. Files already have their size from the 'ls' command.
    foreach ($item in $Items) {
        if (-not (Test-AndroidPath $item.FullPath)) {
            Write-Log "Skipping item with unsafe path: $($item.FullPath)" "WARN"
            continue
        }
        if ($item.Type -eq 'Directory') {
            # Quote path for the shell command to handle spaces etc.
            $dirsToQuery += "'$($item.FullPath)'"
        } else {
            $itemSizes[$item.FullPath] = $item.Size
            $totalSize += $item.Size
        }
    }


    # If there are directories, query their sizes in one single, efficient command.
    if ($dirsToQuery.Count -gt 0) {
        $pathsString = $dirsToQuery -join " "
        $sizeResult = Invoke-AdbCommand "shell du -sb $pathsString"
        if ($sizeResult.Success -and $sizeResult.Output) {
            # The output lines look like: 5120	/sdcard/Download
            $lines = $sizeResult.Output -split '\r?\n'
            foreach ($line in $lines) {
                if ($line -match '^(?<size>\d+)\s+(?<path>.+)$') {
                    $path = $Matches.path.Trim()
                    $size = [long]$Matches.size
                    
                    # Find the original item to ensure the key matches our expected FullPath format
                    $originalItem = $Items | Where-Object { $_.FullPath -eq $path }
                    if ($originalItem) {
                        $itemSizes[$originalItem.FullPath] = $size
                        $totalSize += $size
                    } else {
                         Write-Log "Could not match DU output path '$path' to any selected item." "WARN"
                    }
                }
            }
        }
    }
    
    # Ensure every item has an entry in the hashtable, even if size calculation failed (defaults to 0).
    foreach($item in $Items) {
        if (-not $itemSizes.ContainsKey($item.FullPath)) {
            $itemSizes[$item.FullPath] = 0L
            Write-Log "Could not determine size for '$($item.FullPath)'. Defaulting to 0." "WARN"
        }
    }

    return [PSCustomObject]@{ TotalSize = $totalSize; ItemSizes = $itemSizes }
}

function Get-LocalItemSize {
    param(
        [string]$ItemPath,
        [switch]$ShowStatus
    )
    try {
        if (-not (Test-Path -LiteralPath $ItemPath)) { return 0 }
        $item = Get-Item -LiteralPath $ItemPath -ErrorAction Stop
        if ($item.PSIsContainer) {
            $sb = {
                param($path)
                (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            }
            $job = Start-Job -ScriptBlock $sb -ArgumentList $ItemPath
            if ($ShowStatus) {
                $spinner = @('|','/','-','\')
                $spinnerIndex = 0
                while ($job.State -eq 'Running') {
                    $status = "Calculating size for '$ItemPath'... $($spinner[$spinnerIndex])"
                    Write-Host "`r$status" -NoNewline
                    $spinnerIndex = ($spinnerIndex + 1) % $spinner.Length
                    Start-Sleep -Milliseconds 150
                }
                Write-Host "`rCalculating size for '$ItemPath'... done" -NoNewline
                Write-Host ""
            } else {
                Wait-Job $job | Out-Null
            }
            $size = Receive-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force | Out-Null
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
    $cacheKey = ConvertTo-AndroidPath $Path
    if (-not (Test-AndroidPath $cacheKey)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return @()
    }

    # Check cache first using the normalized key
    if ($script:DirectoryCache.ContainsKey($cacheKey)) {
        Write-Log "CACHE HIT: Returning cached contents for '$cacheKey'." "DEBUG"
        return $script:DirectoryCache[$cacheKey]
    }
    Write-Log "CACHE MISS: Fetching contents for '$cacheKey' from device." "DEBUG"

    # Canonicalize the path to resolve symbolic links before listing contents.
    $canonicalResult = Invoke-AdbCommand "shell readlink -f '$cacheKey'"
    $listPath = if ($canonicalResult.Success -and -not [string]::IsNullOrWhiteSpace($canonicalResult.Output)) { 
        $canonicalResult.Output.Trim()
    } else { 
        $cacheKey
    }
    if (-not (Test-AndroidPath $listPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return @()
    }
    Write-Log "Canonical path for listing: '$listPath' (from '$cacheKey')" "DEBUG"

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
            
            if ($name -in ".", "..") { continue }
            
            $size = 0L
            if ($type -eq 'File' -and -not [string]::IsNullOrEmpty($Matches.size)) {
                $size = [long]$Matches.size
            }
            
            # Always join with the original path for user context, not the canonical one
            $fullPath = if ($cacheKey.EndsWith('/')) { "$cacheKey$name" } else { "$cacheKey/$name" }
            if (-not (Test-AndroidPath $fullPath)) {
                Write-Log "Skipping item with unsafe path: $fullPath" "WARN"
                continue
            }

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
    $script:DirectoryCache[$cacheKey] = $items
    return $items
}

function Pull-FilesFromAndroid {
    param(
        [string]$Path,
        [switch]$Move
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PULL" }
    Write-Host "`n📥 $actionVerb FROM ANDROID" -ForegroundColor Magenta
    
    $sourcePath = if ($Path) { $Path } else { Read-Host "➡️  Enter source path on Android to pull from (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { Write-Host "🟡 Action cancelled."; return }
    if (-not (Test-AndroidPath $sourcePath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }


    # Use single quotes for shell path
    $sourceIsDirResult = Invoke-AdbCommand "shell ls -ld '$sourcePath'"
    $isDir = $sourceIsDirResult.Success -and $sourceIsDirResult.Output.StartsWith('d')

    $itemsToPull = @()
    if ($isDir) {
        # Cast to array to prevent errors when a directory has only one item.
        $allItems = @(Get-AndroidDirectoryContents $sourcePath)
        if ($allItems.Count -eq 0) { Write-Host "🟡 Directory is empty or inaccessible." -ForegroundColor Yellow; return }
        
        Write-Host "`nItems available in '$($sourcePath)':" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allItems.Count; $i++) {
            $icon = switch ($allItems[$i].Type) {
                "Directory" { "📁" }
                "File"      { "📄" }
                default     { "🔗" }
            }
            Write-Host (" [{0,2}] {1} {2}" -f ($i+1), $icon, $allItems[$i].Name)
        }
        $selectionStr = Read-Host "`n➡️  Enter item numbers to pull (e.g., 1,3,5 or 'all')"
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

    # --- Confirmation Wizard with OPTIMIZED Size Calculation ---
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline

    # New optimized way to get sizes for all selected items at once.
    $sizeInfo = Get-AndroidItemsSize -Items $itemsToPull
    $totalSize = $sizeInfo.TotalSize
    $itemSizes = $sizeInfo.ItemSizes
    
    Write-Host "`r" + (" " * 50) + "`r" # Clear the "Calculating..." line
    Write-Host "You are about to $actionVerb $($itemsToPull.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    $fromLocation = if ($isDir) { $sourcePath } else { $sourcePath.Substring(0, $sourcePath.LastIndexOf('/')) }
    Write-Host "From (Android): $fromLocation" -ForegroundColor Yellow
    Write-Host "To   (PC)    : $destinationFolder" -ForegroundColor Yellow
    $confirm = Read-Host "➡️  Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }
    $successCount = 0; $failureCount = 0; [long]$cumulativeBytesTransferred = 0
    $overallStartTime = Get-Date
    # Determine progress update interval based on total transfer size
    $updateInterval = switch ($totalSize) {
        { $_ -ge 1GB } { 500 }
        { $_ -ge 100MB } { 250 }
        default { 100 }
    }

    foreach ($item in $itemsToPull) {
        if (-not (Test-AndroidPath $item.FullPath)) {
            Write-Host "❌ Skipping '$($item.Name)' due to invalid path." -ForegroundColor Red
            continue
        }
        $sourceItemSafe = """$($item.FullPath)"""
        $destPathOnPC = Join-Path $destinationFolder $item.Name
        $itemTotalSize = $itemSizes[$item.FullPath]
        
        # Pipe to Out-String to prevent PowerShell from formatting stderr as an error object
        $adbCommand = { param($source, $dest) adb pull $source $dest 2>&1 | Out-String }
        $job = Start-Job -ScriptBlock $adbCommand -ArgumentList @($sourceItemSafe, $destinationFolder)

        $itemStartTime = Get-Date
        Write-Host ""

        $lastReportedSize = 0L
        $lastWriteTime   = [DateTime]::MinValue

        $jobStart = Get-Date
        $startTimeout = [TimeSpan]::FromSeconds(5)
        if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
            while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
                if ($job.State -eq 'NotStarted') {
                    if ((Get-Date) - $jobStart -gt $startTimeout) { break }
                } else {
                    $currentSize = $lastReportedSize
                    if (Test-Path -LiteralPath $destPathOnPC) {
                        try {
                            $itemInfo = Get-Item -LiteralPath $destPathOnPC -ErrorAction Stop
                            if ($itemInfo.PSIsContainer) {
                                if ($itemInfo.LastWriteTime -gt $lastWriteTime) {
                                    $currentSize     = Get-LocalItemSize -ItemPath $destPathOnPC
                                    $lastReportedSize = $currentSize
                                    $lastWriteTime    = $itemInfo.LastWriteTime
                                }
                            } else {
                                if ($itemInfo.Length -gt $lastReportedSize) {
                                    $currentSize      = Get-LocalItemSize -ItemPath $destPathOnPC
                                    $lastReportedSize = $currentSize
                                }
                            }
                        } catch {
                            # If we can't access the item yet, keep last reported size
                        }
                    }
                    Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $currentSize -TotalValue $itemTotalSize -StartTime $itemStartTime
                }
                Start-Sleep -Milliseconds $updateInterval
            }
        }

        $finalSize = Get-LocalItemSize -ItemPath $destPathOnPC
        if ($finalSize -lt $lastReportedSize) { $finalSize = $lastReportedSize }
        Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $finalSize -TotalValue $itemTotalSize -StartTime $itemStartTime
        Write-Host ""

        $resultOutput = Receive-Job $job
        $success = ($job.JobStateInfo.State -eq 'Completed' -and $resultOutput -notmatch 'No such file or directory|error:')
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
    else { Read-Host "➡️  Enter destination path on Android (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($destPathFinal)) { Write-Host "🟡 Action cancelled."; return }
    if (-not (Test-AndroidPath $destPathFinal)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }


    # --- Confirmation Wizard with Size Calculation ---
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline
    [long]$totalSize = 0
    foreach ($item in $sourceItems) {
        $totalSize += Get-LocalItemSize -ItemPath $item -ShowStatus
    }
    Write-Host "`r" + (" " * 50) + "`r"
    Write-Host "You are about to $actionVerb $($sourceItems.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    Write-Host "From (PC)    : $(Split-Path $sourceItems[0] -Parent)" -ForegroundColor Yellow
    Write-Host "To   (Android): $destPathFinal" -ForegroundColor Yellow
    Write-Host "NOTE: ADB push does not support a detailed progress bar." -ForegroundColor DarkGray
    $confirm = Read-Host "➡️  Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return }

    $successCount = 0; $failureCount = 0
    foreach ($item in $sourceItems) {
        $itemInfo = Get-Item -LiteralPath $item
        $sourceItemSafe = """$($itemInfo.FullName)"""
        $destPathSafe = """$destPathFinal"""
        
        # Pipe to Out-String to prevent PowerShell from formatting stderr as an error object
        $adbCommand = { 
        param($source, $dest) 
        # Wrap in cmd /c to make stderr redirection more robust against PowerShell's error formatting
        cmd.exe /c "adb push `"$source`" `"$dest`" 2>&1" | Out-String 
                       }
        $job = Start-Job -ScriptBlock $adbCommand -ArgumentList @($sourceItemSafe, $destPathSafe)

        $spinner = @('|', '/', '-', '\')
        $spinnerIndex = 0
        Write-Host ""
        $jobStart = Get-Date
        $startTimeout = [TimeSpan]::FromSeconds(5)
        $status = ""
        if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
            while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
                if ($job.State -eq 'NotStarted') {
                    if ((Get-Date) - $jobStart -gt $startTimeout) { break }
                } else {
                    $status = "Pushing $($itemInfo.Name)... $($spinner[$spinnerIndex])"
                    Write-Host "`r$status" -NoNewline
                    $spinnerIndex = ($spinnerIndex + 1) % $spinner.Length
                }
                Start-Sleep -Milliseconds 150
            }
        }
        Write-Host "`r" + (" " * ($status.Length + 5)) + "`r"

        $resultOutput = Receive-Job $job
        $success = ($job.JobStateInfo.State -eq 'Completed' -and $resultOutput -notmatch 'error:')
        Remove-Job $job

        if ($success) {
            $successCount++
            Write-Host "✅ Pushed $($itemInfo.Name)" -ForegroundColor Green
            Write-Host ($resultOutput | Out-String).Trim() -ForegroundColor Gray

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
    $currentPath = Read-Host "➡️  Enter starting path (default: /sdcard/)"
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "/sdcard/" }
    if (-not (Test-AndroidPath $currentPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }


    do {
        Show-UIHeader -Title "FILE BROWSER"
        Write-Host "📁 Browsing: $currentPath" -ForegroundColor White -BackgroundColor DarkCyan
        Write-Host ("─" * 62) -ForegroundColor Gray

        # Cast the result to an array to prevent errors when a directory has only one item.
        $items = @(Get-AndroidDirectoryContents $currentPath)
        
        Write-Host " [ 0] .. (Go Up)" -ForegroundColor Yellow
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            $icon = switch ($item.Type) {
                "Directory" { "📁" }
                "File"      { "📄" }
                default     { "🔗" }
            }
            $color = switch ($item.Type) {
                "Directory" { "Cyan" }
                "Link"      { "Yellow" }
                default     { "White" }
            }
            Write-Host (" [{0,2}] {1} {2}" -f ($i + 1), $icon, $item.Name) -ForegroundColor $color
        }
        
        Write-Host ("─" * 62) -ForegroundColor Gray
        Write-Host "Actions: (c)reate, (p)ull, (u)pload, (r)efresh, (q)uit to menu" -ForegroundColor Gray
        $choice = Read-Host "`n➡️  Enter number to browse, or select an action"

        switch ($choice) {
            "q" { return }
            "c" { New-AndroidFolder -ParentPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "p" { Pull-FilesFromAndroid -Path $currentPath; Read-Host "`nPress Enter to continue..." }
            "u" { Push-FilesToAndroid -DestinationPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "r" {
                Write-Host "`n🔄 Refreshing directory..." -ForegroundColor Yellow
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
                    # Allow browsing into directories and links
                    if ($selectedItem.Type -in "Directory", "Link") {
                        if (Test-AndroidPath $selectedItem.FullPath) {
                            $currentPath = $selectedItem.FullPath
                        } else {
                            Write-Host "❌ Invalid path." -ForegroundColor Red
                            Start-Sleep -Seconds 1
                        }
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
    $folderName = Read-Host "➡️  Enter name for the new folder"
    if ([string]::IsNullOrWhiteSpace($folderName)) { Write-Host "🟡 Action cancelled: No name provided." -ForegroundColor Yellow; return }
    $fullPath = if ($ParentPath.EndsWith('/')) { "$ParentPath$folderName" } else { "$ParentPath/$folderName" }
    if (-not (Test-AndroidPath $fullPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }
    # Use single quotes for shell path
    $result = Invoke-AdbCommand "shell mkdir -p '$fullPath'"
    if ($result.Success) {
        Write-Host "✅ Successfully created folder: $fullPath" -ForegroundColor Green
        Invalidate-ParentCache -ItemPath $fullPath
    } 
    else { Write-Host "❌ Failed to create folder. Error: $($result.Output)" -ForegroundColor Red }
}

function Show-ItemActionMenu {
    param($Item)
    while ($true) {
        Show-UIHeader -Title "ITEM ACTIONS"
        Write-Host "Selected Item: $($Item.FullPath)" -ForegroundColor White -BackgroundColor DarkMagenta
        Write-Host "---------------------------------"
        Write-Host " 1. Pull to PC (Copy)"
        Write-Host " 2. Move to PC (Pull + Delete)"
        Write-Host " 3. Rename (on device)"
        Write-Host " 4. Delete (on device)"
        Write-Host " 5. Back to browser"
        $action = Read-Host "`n➡️  Enter your choice (1-5)"
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
    if (-not (Test-AndroidPath $ItemPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }
    $itemName = $ItemPath.Split('/')[-1]
    $confirmation = Read-Host "❓ Are you sure you want to PERMANENTLY DELETE '$itemName'? [y/N]"
    if ($confirmation.ToLower() -ne 'y') { Write-Host "🟡 Deletion cancelled." -ForegroundColor Yellow; return }
    # Use single quotes for shell path
    $result = Invoke-AdbCommand "shell rm -rf '$ItemPath'"
    if ($result.Success) {
        Write-Host "✅ Successfully deleted '$itemName'." -ForegroundColor Green
        Invalidate-ParentCache -ItemPath $ItemPath
    } 
    else { Write-Host "❌ Failed to delete '$itemName'. Error: $($result.Output)" -ForegroundColor Red }
}

function Rename-AndroidItem {
    param([string]$ItemPath)
    if (-not (Test-AndroidPath $ItemPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }
    $itemName = $ItemPath.Split('/')[-1]
    $newName = Read-Host "➡️  Enter the new name for '$itemName'"
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName.Contains('/') -or $newName.Contains('\')) {
        Write-Host "❌ Invalid name." -ForegroundColor Red; return
    }
    $parentPath = $ItemPath.Substring(0, $ItemPath.LastIndexOf('/'))
    $newItemPath = if ([string]::IsNullOrEmpty($parentPath)) { "/$newName" } else { "$parentPath/$newName" }
    if (-not (Test-AndroidPath $newItemPath)) {
        Write-Host "❌ Invalid path." -ForegroundColor Red
        return
    }

    # Use single quotes for shell path
    $result = Invoke-AdbCommand "shell mv '$ItemPath' '$newItemPath'"
    if ($result.Success) {
        Write-Host "✅ Successfully renamed to '$newName'." -ForegroundColor Green
        # Invalidate the old item's parent directory to refresh the browser view
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
        Show-UIHeader -SubTitle "MAIN MENU"

        if (-not $script:DeviceStatus.IsConnected) {
            Write-Host "`n⚠️ No device connected. Please connect a device and ensure it's recognized by ADB." -ForegroundColor Yellow
            Write-Host "   Trying to reconnect in 5 seconds..."
            # Force a full status update on the next loop after sleeping
            $script:LastStatusUpdateTime = [DateTime]::MinValue
            Start-Sleep -Seconds 5
            continue
        }

        Write-Host ""
        Write-Host " 1. Browse Device Filesystem (Interactive Push/Pull/Manage)"
        Write-Host " 2. Quick Push (from PC to a specified device path)"
        Write-Host " 3. Quick Pull (from a specified device path to PC)"
        Write-Host ""
        Write-Host " Q. Exit"
        Write-Host ""

        $choice = Read-Host "➡️  Enter your choice"

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

    Write-Log "ADB File Manager v4.2.0 Started" "INFO"
    Show-MainMenu
    Write-Host "`n👋 Thank you for using the ADB File Manager!" -ForegroundColor Green
}

# Start the application
Start-ADBTool
