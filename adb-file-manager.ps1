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

# Script parameters
param(
    [ValidateSet('INFO','DEBUG','WARN','ERROR')]
    [string]$LogLevel = 'INFO',
    [switch]$NoGui,
    [switch]$WhatIf,
    [switch]$JsonLog
)

# Detect platform and PowerShell edition at runtime
$PSMajorVersion = $PSVersionTable.PSVersion.Major
$script:IsPSCore = $PSMajorVersion -ge 6
Set-Variable -Name IsWindows -Scope Script -Value ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) -Force

# Load GUI assemblies when running on Windows PowerShell (Desktop edition)
$script:CanUseGui = $false
if (-not $NoGui -and $script:IsWindows -and $PSVersionTable.PSEdition -eq 'Desktop') {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:CanUseGui = $true
    } catch {
        Write-Log "Failed to load GUI assemblies. Falling back to text prompts." "WARN"
    }
}

# Capture the full path to the adb executable at startup
try {
    $script:AdbPath = (Get-Command adb -ErrorAction Stop).Source
} catch {
    $script:AdbPath = $null
}

# --- Global State and Configuration ---
$script:CurrentLogLevel = $LogLevel
$script:LogLevelPriority = @{
    DEBUG = 1
    INFO  = 2
    WARN  = 3
    ERROR = 4
}
$script:LogFile = "ADB_Operations_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:JsonLogFile = [System.IO.Path]::ChangeExtension($script:LogFile, 'json')

# Encapsulated application state that will be threaded through functions.
$script:State = @{
    DeviceStatus = @{
        IsConnected  = $false
        DeviceName   = "No Device"
        SerialNumber = ""
    }
    # Cache for directory listings to speed up browsing. Key = Path, Value = Directory Contents
    # Use an ordered, case-sensitive dictionary so entries can be removed in least-recently-used order.
    DirectoryCache = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    # Map of originally requested paths to their canonical cache keys
    DirectoryCacheAliases = @{}
    # Maximum number of entries to keep in the directory cache
    MaxDirectoryCacheEntries = 100
    # Timestamp for the last device status check to prevent excessive ADB calls.
    LastStatusUpdateTime = [DateTime]::MinValue;
    # Information about host and device capabilities
    Features = @{
        ADBVersion         = ''
        SupportsDuSb       = $false
        Checked            = $false
        SupportsStatC      = $null
        WarnedStatFallback = $false
    }
    Config = @{
        DefaultTimeoutMs             = 120000
        SafeRoot                     = '/sdcard'
        VerboseLists                 = $false
        LargeDeleteConfirmThresholdMB = 100
        AllowUnsafeOps               = $false
        EnableJsonLog                = $JsonLog.IsPresent
        WhatIf                       = $WhatIf.IsPresent
    }
}

# --- Core ADB and Logging Functions ---

# Function to write to the log file
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','DEBUG','WARN','ERROR')]
        [string]$Level = "INFO",
        [switch]$SanitizePaths
    )

    if ($SanitizePaths) {
        $Message = [regex]::Replace($Message, '((?:[A-Za-z]:)?[\\/][^\s"'']*)', {
            param($m)
            $path = $m.Value
            if ($path.Contains('/')) {
                $sep = '/'
            } else {
                $sep = '\\'
            }
            [string[]]$parts = $path -split '[\\/]+'
            for ($i = 1; $i -lt $parts.Length - 1; $i++) {
                $parts[$i] = '***'
            }
            return ($parts -join $sep)
        })
    }

    if ($script:LogLevelPriority[$Level] -lt $script:LogLevelPriority[$script:CurrentLogLevel]) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        "" | Out-File -FilePath $script:LogFile -Encoding utf8
    }
    Add-Content -Path $script:LogFile -Value $logEntry -Encoding utf8
    if ($script:State.Config.EnableJsonLog) {
        $jsonObj = @{ timestamp = $timestamp; level = $Level; message = $Message }
        $jsonLine = $jsonObj | ConvertTo-Json -Compress
        Add-Content -Path $script:JsonLogFile -Value $jsonLine -Encoding utf8
    }
}

# Writes a formatted error message to the console.
function Write-ErrorMessage {
    param(
        [string]$Operation,
        [string]$Item = "",
        [string]$Details = "",
        [switch]$NoNewline
    )
    $message = "❌ $Operation"
    if ($Item) { $message += " '$Item'" }
    if ($Details) { $message += ". $Details" }
    Write-Host $message -ForegroundColor Red -NoNewline:$NoNewline
}

# Returns the path to the ADB executable, caching the result for reuse.
function Get-AdbExe {
    if ($script:AdbPath) { return $script:AdbPath }
    try {
        $cmd = Get-Command adb -ErrorAction Stop
        $script:AdbPath = $cmd.Source
        return $script:AdbPath
    } catch {
        return 'adb'
    }
}

# Centralized function to execute simple ADB commands and get their direct output.
function Invoke-AdbCommand {
    param(
        [hashtable]$State = $script:State,
        [string[]]$Arguments,
        [switch]$HideOutput,
        [switch]$NoSerial,
        [int]$TimeoutMs = $State.Config.DefaultTimeoutMs,
        [switch]$RawOutput,
        [bool]$MergeStdErrOnSuccess = $true
    )
    $argList = @()
    if ($State.DeviceStatus.SerialNumber -and -not $NoSerial) {
        $argList += '-s'
        $argList += $State.DeviceStatus.SerialNumber
    }
    if ($Arguments) { $argList += $Arguments }
    $adbExe = Get-AdbExe
    Write-Log ("Executing ADB Command: {0} {1}" -f $adbExe, ($argList -join ' ')) "DEBUG" -SanitizePaths

    $destructive = $false
    if ($Arguments) {
        $cmd = $Arguments[0]
        if ($cmd -in @('push','pull')) { $destructive = $true }
        elseif ($cmd -eq 'shell' -and $Arguments.Count -gt 1 -and $Arguments[1] -in @('rm','mv','cp')) { $destructive = $true }
    }
    if ($State.Config.WhatIf -and $destructive) {
        Write-Host "[WhatIf] $adbExe $($argList -join ' ')" -ForegroundColor Yellow
        Write-Log ("[WhatIf] {0} {1}" -f $adbExe, ($argList -join ' ')) 'INFO' -SanitizePaths
        if ($RawOutput) {
            return [PSCustomObject]@{ Success = $true; StdOut = ''; StdErr = ''; ExitCode = 0; State = $State }
        }
        return [PSCustomObject]@{ Success = $true; Output = ''; State = $State }
    }

    $stdout = ''
    $stderr = ''
    $exitCode = 1
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($adbExe)
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            foreach ($arg in $argList) { $null = $psi.ArgumentList.Add($arg) }
        }
        else {
            # PowerShell 5.1: build argument string manually
            $psi.Arguments = ($argList | ForEach-Object { [char]34 + $_ + [char]34 }) -join ' '
        }

        $process = [System.Diagnostics.Process]::Start($psi)

        if (-not $process.WaitForExit($TimeoutMs)) {
            Write-Log "ADB command timed out after $TimeoutMs ms. Killing process." "ERROR"
            try { $process.Kill() } catch { }
            $process.WaitForExit()
            $stdout = ''
            $stderr = "ADB command timed out after $TimeoutMs ms."
            $exitCode = -1
        }
        else {
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $exitCode = $process.ExitCode
        }
    }
    finally {
        if ($process) { $process.Dispose() }
    }

    $success = ($exitCode -eq 0)

    if ($RawOutput) {
        if ($success -and $MergeStdErrOnSuccess) {
            $stdout = ($stdout, $stderr | Where-Object { $_ }) -join "`n"
            $stderr = ''
        }
        if (-not $success) {
            Write-Log "ADB command failed with exit code $exitCode. Error: $stderr" "ERROR" -SanitizePaths
            if ($stderr -match "device not found|device offline|no devices/emulators found") {
                Write-Log "Device disconnection detected from command error. Forcing status refresh." "WARN"
                $State.DeviceStatus.IsConnected = $false
                $State.DeviceStatus.DeviceName   = "No Device"
                $State.DeviceStatus.SerialNumber = ""
                $State.LastStatusUpdateTime = [DateTime]::MinValue
                $State.DirectoryCache.Clear()
                Write-Log "Directory cache cleared due to device loss." "WARN"
                $State.Features.Checked = $false
                $State.Features.SupportsDuSb = $false
            }
        }
        if ($HideOutput) { return [PSCustomObject]@{ Success = $success; StdOut = ''; StdErr = ''; ExitCode = $exitCode; State = $State } }
        return [PSCustomObject]@{ Success = $success; StdOut = $stdout.TrimEnd(); StdErr = $stderr.TrimEnd(); ExitCode = $exitCode; State = $State }
    }

    # Some successful commands (like pull) write to stderr, so we combine them on success.
    $output = if ($success -and $MergeStdErrOnSuccess) { ($stdout, $stderr | Where-Object { $_ }) -join "`n" } else { if ($success) { $stdout } else { $stderr } }

    if (-not $success) {
        Write-Log "ADB command failed with exit code $exitCode. Error: $output" "ERROR" -SanitizePaths
        # Smart Status Check: If a command fails, check if it's due to a disconnection.
        # This makes the script instantly aware of a disconnected device without constant polling.
        if ($output -match "device not found|device offline|no devices/emulators found") {
            Write-Log "Device disconnection detected from command error. Forcing status refresh." "WARN"
            $State.DeviceStatus.IsConnected = $false
            $State.DeviceStatus.DeviceName   = "No Device"
            $State.DeviceStatus.SerialNumber = ""
            # By resetting the timestamp, we force Update-DeviceStatus to do a full check next time it's called.
            $State.LastStatusUpdateTime = [DateTime]::MinValue
            # Purge any cached directory entries since they're now invalid without a device.
            $State.DirectoryCache.Clear()
            Write-Log "Directory cache cleared due to device loss." "WARN"
            $State.Features.Checked = $false
            $State.Features.SupportsDuSb = $false
        }
    }

    if ($HideOutput) {
        return [PSCustomObject]@{ Success = $success; Output  = ""; State = $State }
    }

    return [PSCustomObject]@{ Success = $success; Output  = $output.Trim(); State = $State }
}

# Starts an ADB process with redirected output, returning the process handle.
function Start-AdbProcess {
    param(
        [hashtable]$State = $script:State,
        [string[]]$Arguments,
        [string]$StdOutPath,
        [string]$StdErrPath,
        [switch]$NoSerial
    )
    $argList = @()
    if ($State.DeviceStatus.SerialNumber -and -not $NoSerial) {
        $argList += '-s'
        $argList += $State.DeviceStatus.SerialNumber
    }
    if ($Arguments) { $argList += $Arguments }
    $adbExe = Get-AdbExe
    return Start-Process -FilePath $adbExe -ArgumentList $argList -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath -PassThru -NoNewWindow
}

# Validates ADB version and required device features.
function Test-AdbFeatures {
    param([hashtable]$State)

    # Always determine the ADB version
    $versionResult = Invoke-AdbCommand -State $State -Arguments @('version')
    $State = $versionResult.State
    if ($versionResult.Success -and $versionResult.Output -match 'Android Debug Bridge version\s+(?<ver>[0-9\.]+)') {
        $State.Features.ADBVersion = $Matches.ver
        try {
            $current = [version]$Matches.ver
            $required = [version]'1.0.41'
            if ($current -lt $required) {
                Write-Host "⚠️  Warning: ADB version $current is older than required $required. Some features may not work." -ForegroundColor Yellow
            }
        } catch {
            Write-Log "Failed to parse ADB version '$($Matches.ver)'" "WARN"
        }
    } else {
        Write-Log "Unable to determine ADB version from output: $($versionResult.Output)" "WARN"
    }

    # Only test device-specific features if a device is connected
    if ($State.DeviceStatus.IsConnected) {
        $duResult = Invoke-AdbCommand -State $State -Arguments @('shell','du','-sb','/data/local/tmp')
        $State = $duResult.State
        if ($duResult.Success -and $duResult.Output -match '^[0-9]+') {
            $State.Features.SupportsDuSb = $true
        } else {
            $State.Features.SupportsDuSb = $false
            Write-Host "⚠️  Warning: Your device does not support 'du -sb'. Directory size calculations may be slower or unavailable." -ForegroundColor Yellow
        }
        $State.Features.Checked = $true
    }

    return $State
}

# --- Device and Caching Functions ---

# OPTIMIZED to only run expensive ADB commands periodically.
function Update-DeviceStatus {
    param([hashtable]$State)

    # If a device is connected and we checked less than 15 seconds ago, skip the check.
    if ($State.DeviceStatus.IsConnected -and ((Get-Date) - $State.LastStatusUpdateTime).TotalSeconds -lt 15) {
        return [pscustomobject]@{
            State = $State
            Devices = @()
            ConnectionChanged = $false
            NeedsSelection = $false
        }
    }

    $prevConnected = $State.DeviceStatus.IsConnected
    $prevSerial = $State.DeviceStatus.SerialNumber

    Write-Log "Performing full device status check." "DEBUG"
    $startResult = Invoke-AdbCommand -State $State -Arguments @('start-server') -NoSerial
    $State = $startResult.State
    $result = Invoke-AdbCommand -State $State -Arguments @('devices','-l') -NoSerial
    $State = $result.State
    $deviceInfos = @(
        $result.Output -split '\r?\n' |
        Where-Object { $_ -notmatch '^(List of devices attached|\* daemon)' -and $_.Trim() } |
        ForEach-Object {
            $parts = $_ -split '\s+'
            if ($parts.Length -ge 2) {
                $serial = $parts[0].Trim()
                $status = $parts[1].Trim()
                $modelToken = $parts | Where-Object { $_ -like 'model:*' } | Select-Object -First 1
                $model = if ($modelToken) { $modelToken -replace '^model:' } else { $null }
                [pscustomobject]@{Serial=$serial; Status=$status; Model=$model}
            }
        } |
        Where-Object { $_.Status -eq 'device' }
    )

    $needsSelection = $false

    if ($deviceInfos.Count -gt 0) {
        $serialNumber = $null
        $selectedDevice = $null
        if ($State.DeviceStatus.SerialNumber -and ($deviceInfos.Serial -contains $State.DeviceStatus.SerialNumber)) {
            $serialNumber = $State.DeviceStatus.SerialNumber
            $selectedDevice = $deviceInfos | Where-Object { $_.Serial -eq $serialNumber } | Select-Object -First 1
        } elseif ($deviceInfos.Count -eq 1) {
            $selectedDevice = $deviceInfos[0]
            $serialNumber = $selectedDevice.Serial
        } else {
            $needsSelection = $true
        }

        if (-not $needsSelection) {
            $State.DeviceStatus.IsConnected = $true
            $State.DeviceStatus.SerialNumber = $serialNumber

            if ($selectedDevice.Model) {
                $State.DeviceStatus.DeviceName = $selectedDevice.Model
            } else {
                $deviceNameResult = Invoke-AdbCommand -State $State -Arguments @('shell', 'getprop', 'ro.product.model')
                $State = $deviceNameResult.State
                if ($deviceNameResult.Success -and -not [string]::IsNullOrWhiteSpace($deviceNameResult.Output)) {
                    $State.DeviceStatus.DeviceName = $deviceNameResult.Output.Trim()
                } else {
                    $State.DeviceStatus.DeviceName = "Unknown Device"
                }
            }
            Write-Log "Device connected: $($State.DeviceStatus.DeviceName) ($($State.DeviceStatus.SerialNumber))" "INFO"
            if (-not $State.Features.Checked) {
                $State = Test-AdbFeatures -State $State
            }
        } else {
            $State.DeviceStatus.IsConnected = $false
            $State.DeviceStatus.DeviceName = "No Device"
            $State.DeviceStatus.SerialNumber = ""
            Write-Log "Multiple devices detected. Awaiting user selection." "INFO"
        }
    } else {
        $State.DeviceStatus.IsConnected = $false
        $State.DeviceStatus.DeviceName = "No Device"
        $State.DeviceStatus.SerialNumber = ""
        Write-Log "No device connected." "INFO"
        $State.Features.Checked = $false
        $State.Features.SupportsDuSb = $false
    }

    # Update the timestamp after a full check.
    $State.LastStatusUpdateTime = (Get-Date)
    $connectionChanged = ($prevConnected -ne $State.DeviceStatus.IsConnected) -or ($prevSerial -ne $State.DeviceStatus.SerialNumber)

    return [pscustomobject]@{
        State = $State
        Devices = $deviceInfos
        ConnectionChanged = $connectionChanged
        NeedsSelection = $needsSelection
    }
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
    param(
        [hashtable]$State,
        [string]$DirectoryPath
    )

    # Always normalize the path before interacting with the cache.
    $cacheKey = ConvertTo-AndroidPath $DirectoryPath
    $canonicalKey = if ($State.DirectoryCacheAliases.Contains($cacheKey)) {
        $State.DirectoryCacheAliases[$cacheKey]
    } else {
        $cacheKey
    }

    if ($State.DirectoryCache.Contains($canonicalKey)) {
        Write-Log "CACHE INVALIDATION: Removing '$canonicalKey' from cache." "INFO" -SanitizePaths
        $State.DirectoryCache.Remove($canonicalKey)
    }

    if ($State.DirectoryCacheAliases.Contains($cacheKey)) {
        $State.DirectoryCacheAliases.Remove($cacheKey) | Out-Null
    }
    foreach ($alias in @($State.DirectoryCacheAliases.Keys)) {
        if ($State.DirectoryCacheAliases[$alias] -eq $canonicalKey) {
            $State.DirectoryCacheAliases.Remove($alias) | Out-Null
        }
    }
    return $State
}

# Gets the parent of an item and invalidates its cache.
function Invalidate-ParentCache {
     param(
        [hashtable]$State,
        [string]$ItemPath
    )
    if (-not (Test-AndroidPath $ItemPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $State
    }
     # Normalize to forward slashes and remove any trailing slash
    $normalizedItemPath = ConvertTo-AndroidPath $ItemPath
    if ($normalizedItemPath -eq "/") { return $State }

    $lastSlashIndex = $normalizedItemPath.LastIndexOf('/')
    # If no slash or it's the only character, the parent is root.
    if ($lastSlashIndex -le 0) {
        $State = Invalidate-DirectoryCache -State $State -DirectoryPath "/"
    } else {
        $parentPath = $normalizedItemPath.Substring(0, $lastSlashIndex)
        $State = Invalidate-DirectoryCache -State $State -DirectoryPath $parentPath
    }
    return $State
}

# Adds an entry to a cache and enforces a maximum number of entries.
# When the limit is exceeded, the least-recently-used entry is removed.
function Add-ToCacheWithLimit {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Cache,
        [string]$Key,
        $Value,
        [int]$MaxEntries,
        [hashtable]$Aliases
    )

    # If the key already exists, remove it so re-adding moves it to the end
    if ($Cache.Contains($Key)) {
        $Cache.Remove($Key)
    }

    $Cache[$Key] = $Value

    while ($Cache.Count -gt $MaxEntries) {
        $oldestKey = ($Cache.Keys)[0]
        $Cache.Remove($oldestKey)
        if ($Aliases) {
            foreach ($alias in @($Aliases.Keys)) {
                if ($Aliases[$alias] -eq $oldestKey) {
                    $Aliases.Remove($alias) | Out-Null
                }
            }
        }
        Write-Log "CACHE LIMIT EXCEEDED: Removed least recently used entry '$oldestKey'." "DEBUG" -SanitizePaths
    }
}

# Splits an array into chunks of a specified maximum size.
function Split-IntoChunks {
    param(
        [object[]]$Items,
        [int]$ChunkSize
    )
    if (-not $Items) { return @() }
    for ($i = 0; $i -lt $Items.Count; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize - 1, $Items.Count - 1)
        ,(@($Items[$i..$end]))
    }
}

# Validates Android paths to prevent command injection
function Test-AndroidPath {
    param([string]$Path)
    if (-not $Path) { return $true }

    foreach ($ch in $Path.ToCharArray()) {
        if ($ch -eq "'") {
            Write-ErrorMessage -Operation "Path contains single quote"
            return $false
        }
        elseif ($ch -eq '`') {
            Write-ErrorMessage -Operation "Path contains backtick" -Item "``"
            return $false
        }
        elseif ($ch -eq '$') {
            Write-ErrorMessage -Operation "Path contains dollar sign"
            return $false
        }
        else {
            $code = [int][char]$ch
            if ($code -lt 32 -or $code -eq 127) {
                $hex = "0x{0:X2}" -f $code
                Write-ErrorMessage -Operation "Path contains control character" -Item $hex
                return $false
            }
        }
    }
    return $true
}

function Test-IsSafePath {
    param(
        [hashtable]$State,
        [string]$Path,
        [switch]$Force
    )
    if ($Path -like "$($State.Config.SafeRoot)*") { return $true }
    if ($Force -or $State.Config.AllowUnsafeOps) { return $true }
    Write-ErrorMessage -Operation "Operation blocked" -Item $Path -Details "outside safe root"
    return $false
}

function Test-AndroidItemIsDirectory {
    param(
        [hashtable]$State,
        [string]$Path
    )
    if (-not (Test-AndroidPath $Path)) {
        return [PSCustomObject]@{ State = $State; IsDirectory = $false; Success = $false }
    }

    if ($null -eq $State.Features.SupportsStatC) {
        $probe = Invoke-AdbCommand -State $State -Arguments @('shell','stat','-c','%F','/')
        $State = $probe.State
        $State.Features.SupportsStatC = $probe.Success
        if (-not $probe.Success -and -not $State.Features.WarnedStatFallback) {
            Write-Log "Device does not support 'stat -c'; falling back to parsing 'ls -ld' output." "WARN"
            $State.Features.WarnedStatFallback = $true
        }
    }

    if ($State.Features.SupportsStatC) {
        $res = Invoke-AdbCommand -State $State -Arguments @('shell','stat','-c','%F', "'$Path'")
        $State = $res.State
        if ($res.Success) {
            return [PSCustomObject]@{ State = $State; IsDirectory = ($res.Output.Trim() -eq 'directory'); Success = $true }
        }
    } else {
        $res = Invoke-AdbCommand -State $State -Arguments @('shell','ls','-ld', "'$Path'")
        $State = $res.State
        if ($res.Success -and $res.Output) {
            return [PSCustomObject]@{ State = $State; IsDirectory = $res.Output.StartsWith('d'); Success = $true }
        }
    }
    return [PSCustomObject]@{ State = $State; IsDirectory = $false; Success = $false }
}

# Validates numeric selection strings (e.g., "1,3,5" or "1-3") or 'all'
function Test-ValidSelection {
    param(
        [string]$Selection,
        [int]$Max
    )

    if ([string]::IsNullOrWhiteSpace($Selection)) { return $null }
    $sel = $Selection.Trim().ToLower()
    if ($sel -eq 'all') { return 0..($Max - 1) }

    $indices = @()
    foreach ($part in $sel.Split(',')) {
        $p = $part.Trim()
        if ($p -match '^(\d+)-(\d+)$') {
            $start = [int]$Matches[1]
            $end   = [int]$Matches[2]
            if ($start -lt 1 -or $end -gt $Max -or $start -gt $end) { return $null }
            $indices += ($start-1)..($end-1)
        } elseif ($p -match '^\d+$') {
            $num = [int]$p
            if ($num -lt 1 -or $num -gt $Max) { return $null }
            $indices += ($num-1)
        } else {
            return $null
        }
    }
    if ($indices.Count -eq 0) { return $null }
    return ($indices | Sort-Object -Unique)
}

# --- UI and Utility Functions ---

function Show-UIHeader {
    param(
        [hashtable]$State,
        [string]$Title = "ADB FILE MANAGER",
        [string]$SubTitle,
        [switch]$ShowDeviceList
    )
    Clear-Host
    $width = 62
    $innerWidth = $width - 2
    $border = "═" * $innerWidth
    $blank = " " * $innerWidth
    Write-Host "╔$border╗" -ForegroundColor Cyan
    Write-Host "║$blank║" -ForegroundColor Cyan

    $titlePadding = [math]::Max(0, [math]::Floor(($innerWidth - $Title.Length) / 2))
    $titleLine = "║" + (" " * $titlePadding) + $Title
    $titleLine += " " * [math]::Max(0, $innerWidth - $Title.Length - $titlePadding) + "║"
    Write-Host $titleLine -ForegroundColor White

    if ($SubTitle) {
        $subtitlePadding = [math]::Max(0, [math]::Floor(($innerWidth - $SubTitle.Length) / 2))
        $subLine = "║" + (" " * $subtitlePadding) + $SubTitle
        $subLine += " " * [math]::Max(0, $innerWidth - $SubTitle.Length - $subtitlePadding) + "║"
        Write-Host $subLine -ForegroundColor Gray
    }

    Write-Host "║$blank║" -ForegroundColor Cyan
    Write-Host "╚$border╝" -ForegroundColor Cyan

    $updateResult = Update-DeviceStatus -State $State
    $State = $updateResult.State

    if (($updateResult.ConnectionChanged -or $ShowDeviceList) -and $updateResult.Devices.Count -gt 0) {
        Write-Host "`nAvailable devices:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $updateResult.Devices.Count; $i++) {
            $info = $updateResult.Devices[$i]
            $statusLabel = if ($info.Status -eq 'device') { 'Online' } else { 'Offline' }
            $displayName = if ($info.Model) { $info.Model } else { $info.Serial }
            Write-Host "  $($i + 1). $displayName ($statusLabel) - $($info.Serial)"
        }

        if ($updateResult.NeedsSelection -or $ShowDeviceList) {
            $selection = Read-Host "➡️  Enter the number of the device to use"
            $choice = 0
            if (-not [int]::TryParse($selection, [ref]$choice) -or $choice -lt 1 -or $choice -gt $updateResult.Devices.Count) {
                $choice = 1
            }
            $selected = $updateResult.Devices[$choice - 1]
            $State.DeviceStatus.SerialNumber = $selected.Serial
            $updateResult = Update-DeviceStatus -State $State
            $State = $updateResult.State
        }
    }

    $statusText = "🔌 Status: "
    if ($State.DeviceStatus.IsConnected) {
        Write-Host "$statusText $($State.DeviceStatus.DeviceName) ($($State.DeviceStatus.SerialNumber))" -ForegroundColor Green
    } else {
        Write-ErrorMessage -Operation "Status" -Item "Disconnected" -Details "Please connect a device."
    }
    Write-Host ("─" * $width) -ForegroundColor Gray
    return $State
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
        [datetime]$StartTime,
        [switch]$ShowCancelMessage
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
    if ($ShowCancelMessage) { $progressLine += " | Press Esc or Q to cancel" }
    Write-Host $progressLine -NoNewline
}

# Clears the current console line to prevent leftover progress text.
function Clear-ProgressLine {
    Write-Host "`r" + (' ' * 80) + "`r" -NoNewline
}

# Parses the last line of an adb stderr log to extract percent or speed info.
function Get-AdbStderrProgress {
    param([string]$StderrPath)
    try {
        if (Test-Path -LiteralPath $StderrPath) {
            $line = Get-Content -LiteralPath $StderrPath -ErrorAction SilentlyContinue -Tail 1
            if ($line) {
                $line = $line.Trim()
                if ($line -match '(?<pct>\d+)%.*?(?<speed>\d+(?:\.\d+)?\s*(?:[KMG]?B/s))') {
                    return "$($Matches.pct)% $($Matches.speed)".Trim()
                } elseif ($line -match '(?<pct>\d+)%') {
                    return "$($Matches.pct)%"
                } elseif ($line -match '(?<speed>\d+(?:\.\d+)?\s*(?:[KMG]?B/s))') {
                    return $Matches.speed
                }
            }
        }
    } catch { }
    return $null
}


# Starts a background job using Start-ThreadJob on PowerShell 7+, falling back to Start-Job otherwise.
function Start-PortableJob {
    param(
        [ScriptBlock]$ScriptBlock,
        [object[]]$ArgumentList
    )
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    } else {
        return Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }
}

# --- File and Directory Size Calculation ---

# Gets the size of multiple Android items (files/dirs) using an optimized single command for directories.
function Get-AndroidItemsSize {
    param(
        [hashtable]$State,
        [array]$Items
    )
    $totalSize = 0L
    $itemSizes = @{}
    $dirsToQuery = @()
    $failedSizeCalc = $false

    # Separate files and directories. Files already have their size from the 'ls' command.
    foreach ($item in $Items) {
        if (-not (Test-AndroidPath $item.FullPath)) {
            Write-Log "Skipping item with unsafe path: $($item.FullPath)" "WARN" -SanitizePaths
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
        $sizeResult = Invoke-AdbCommand -State $State -Arguments (@('shell','du','-sb') + $dirsToQuery)
        $State = $sizeResult.State
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
                         Write-Log "Could not match DU output path '$path' to any selected item." "WARN" -SanitizePaths
                    }
                }
            }
        }
    }
    
    # Ensure every item has an entry in the hashtable, even if size calculation failed (defaults to 0).
    foreach($item in $Items) {
        if (-not $itemSizes.ContainsKey($item.FullPath)) {
            $itemSizes[$item.FullPath] = 0L
            Write-Log "Could not determine size for '$($item.FullPath)'. Defaulting to 0." "WARN" -SanitizePaths
            if ($item.Type -eq 'Directory') { $failedSizeCalc = $true }
        }
    }

    if ($failedSizeCalc) {
        Write-Host "⚠️  Warning: Unable to determine size for one or more directories. They have been set to 0." -ForegroundColor Yellow
    }

    return [PSCustomObject]@{ State = $State; TotalSize = $totalSize; ItemSizes = $itemSizes }
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
                $sum = 0L
                foreach ($f in [System.IO.Directory]::EnumerateFiles($path, '*', [System.IO.SearchOption]::AllDirectories)) {
                    try { $sum += ([System.IO.FileInfo]::new($f)).Length } catch { }
                }
                return $sum
            }
            $job = Start-PortableJob -ScriptBlock $sb -ArgumentList $ItemPath
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
        Write-Log "Could not get size for local item: $ItemPath. Error: $_" "WARN" -SanitizePaths
        return 0
    }
}

# --- Core File Operations ---

function Get-AndroidDirectoryContents {
    param(
        [hashtable]$State,
        [string]$Path
    )
    # Normalize path for cache key consistency
    $cacheKey = ConvertTo-AndroidPath $Path
    if (-not (Test-AndroidPath $cacheKey)) {
        Write-ErrorMessage -Operation "Invalid path"
        return [PSCustomObject]@{ State = $State; Items = @() }
    }

    if ($State.DirectoryCacheAliases.Contains($cacheKey)) {
        $listPath = $State.DirectoryCacheAliases[$cacheKey]
    } else {
        # Canonicalize the path to resolve symbolic links before listing contents.
        $canonicalResult = Invoke-AdbCommand -State $State -Arguments @('shell','readlink','-f', "'$cacheKey'")
        $State = $canonicalResult.State
        if (-not ($canonicalResult.Success -and -not [string]::IsNullOrWhiteSpace($canonicalResult.Output))) {
            $canonicalResult = Invoke-AdbCommand -State $State -Arguments @('shell','realpath', "'$cacheKey'")
            $State = $canonicalResult.State
        }
        $listPath = if ($canonicalResult.Success -and -not [string]::IsNullOrWhiteSpace($canonicalResult.Output)) {
            $canonicalResult.Output.Trim()
        } else {
            $cacheKey
        }
    }

    if (-not (Test-AndroidPath $listPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return [PSCustomObject]@{ State = $State; Items = @() }
    }

    $canonicalKey = ConvertTo-AndroidPath $listPath
    $State.DirectoryCacheAliases[$cacheKey]  = $canonicalKey
    $State.DirectoryCacheAliases[$canonicalKey] = $canonicalKey

    # Check cache using the canonical key
    if ($State.DirectoryCache.Contains($canonicalKey)) {
        Write-Log "CACHE HIT: Returning cached contents for '$canonicalKey' (requested as '$cacheKey')." "DEBUG" -SanitizePaths
        $cached = $State.DirectoryCache[$canonicalKey]
        # Update order to reflect recent use
        $State.DirectoryCache.Remove($canonicalKey)
        $State.DirectoryCache[$canonicalKey] = $cached
        return [PSCustomObject]@{ State = $State; Items = $cached }
    }
    Write-Log "CACHE MISS: Fetching contents for '$canonicalKey' from device (requested as '$cacheKey')." "DEBUG" -SanitizePaths

    # Determine how to batch query metadata for directory contents in one command.
    if ($null -eq $State.Features.SupportsStatC) {
        $probe = Invoke-AdbCommand -State $State -Arguments @('shell','stat','-c','%F|%s|%n','/')
        $State = $probe.State
        $State.Features.SupportsStatC = $probe.Success
        if (-not $probe.Success -and -not $State.Features.WarnedStatFallback) {
            Write-Log "Device does not support 'stat -c'; falling back to parsing 'ls -ld' output." "WARN"
            $State.Features.WarnedStatFallback = $true
        }
    }

    $cmdArgs = @('shell','find', "'$listPath'", '-maxdepth','1','-mindepth','1')
    if ($State.Features.SupportsStatC) {
        $cmdArgs += @('-exec','stat','-c','%F|%s|%n','{}','+')
    } else {
        $cmdArgs += @('-exec','ls','-ld','{}','+')
    }
    $result = Invoke-AdbCommand -State $State -Arguments $cmdArgs
    $State = $result.State

    if (-not $result.Success) {
        Write-Host ""
        Write-ErrorMessage -Operation "Failed to list directory" -Item $Path -Details $result.Output
        return [PSCustomObject]@{ State = $State; Items = @() }
    }

    $items = @()
    $lines = $result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($line in $lines) {
        if ($State.Features.SupportsStatC) {
            if ($line -match '^(?<type>.+)\|(?<size>\d+)\|(?<path>.+)$') {
                $path = $Matches.path.Trim()
                $name = $path.Substring($path.LastIndexOf('/') + 1)
                $aliasPath = if ($cacheKey.EndsWith('/')) { "$cacheKey$name" } else { "$cacheKey/$name" }
                if (-not (Test-AndroidPath $aliasPath)) { continue }
                $type = switch -regex ($Matches.type) {
                    '^directory$'    { 'Directory' }
                    '^regular file$' { 'File' }
                    '^symbolic link.*$' { 'Link' }
                    default { 'Other' }
                }
                $size = if ($type -eq 'File') { [long]$Matches.size } else { 0L }
                $items += [PSCustomObject]@{
                    Name        = $name
                    Type        = $type
                    Permissions = ''
                    FullPath    = $aliasPath
                    Size        = $size
                }
                $State.DirectoryCacheAliases[$aliasPath] = $path
                $State.DirectoryCacheAliases[$path] = $path
            }
        } else {
            if ($line -match '^(?<perm>.).{9}\s+\d+\s+\S+(?:\s+\S+)?\s+(?<size>\d+)\s+\S+\s+\S+\s+\S+\s+(?<rest>.+)$') {
                $path = ($Matches.rest -split '\s->\s')[0].Trim()
                $name = $path.Substring($path.LastIndexOf('/') + 1)
                $aliasPath = if ($cacheKey.EndsWith('/')) { "$cacheKey$name" } else { "$cacheKey/$name" }
                if (-not (Test-AndroidPath $aliasPath)) { continue }
                $type = switch ($Matches.perm) {
                    'd' { 'Directory' }
                    'l' { 'Link' }
                    '-' { 'File' }
                    default { 'Other' }
                }
                $size = if ($type -eq 'File') { [long]$Matches.size } else { 0L }
                $items += [PSCustomObject]@{
                    Name        = $name
                    Type        = $type
                    Permissions = ''
                    FullPath    = $aliasPath
                    Size        = $size
                }
                $State.DirectoryCacheAliases[$aliasPath] = $path
                $State.DirectoryCacheAliases[$path] = $path
            }
        }
    }

    $chunkSize = 50

    # Resolve any items not yet confirmed as directories using additional checks
    $unverifiedItems = $items | Where-Object { $_.Type -notin 'Directory','Link','File' }
    if ($unverifiedItems.Count -gt 0) {
        $unverifiedMap = @{}
        foreach ($item in $unverifiedItems) { $unverifiedMap[$item.FullPath] = $item }
        foreach ($chunk in Split-IntoChunks -Items $unverifiedMap.Keys -ChunkSize $chunkSize) {
            $lsArgs  = @('shell','ls','-p','-d') + ($chunk | ForEach-Object { "'$_'" })
            $lsProbe = Invoke-AdbCommand -State $State -Arguments $lsArgs
            $State   = $lsProbe.State
            if ($lsProbe.Success) {
                $lines = $lsProbe.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                foreach ($line in $lines) {
                    $pathOut = $line.Trim()
                    $isDir = $pathOut.EndsWith('/')
                    $resolved = if ($isDir) { $pathOut.TrimEnd('/') } else { $pathOut }
                    if ($unverifiedMap.ContainsKey($resolved)) {
                        $unverifiedMap[$resolved].Type = if ($isDir) { 'Directory' } else { 'File' }
                    }
                }
            }
        }
    }

    # Store the fresh result in the cache using the canonical path as the key
    Add-ToCacheWithLimit -Cache $State.DirectoryCache -Key $canonicalKey -Value $items -MaxEntries $State.MaxDirectoryCacheEntries -Aliases $State.DirectoryCacheAliases
    return [PSCustomObject]@{ State = $State; Items = $items }
}

function Select-PullItems {
    param(
        [hashtable]$State,
        [string]$Path
    )
    $sourcePath = if ($Path) { $Path } else { Read-Host "➡️  Enter source path on Android to pull from (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { Write-Host "🟡 Action cancelled."; return $null }
    if (-not (Test-AndroidPath $sourcePath)) { Write-ErrorMessage -Operation "Invalid path"; return $null }

    $dirCheck = Test-AndroidItemIsDirectory -State $State -Path $sourcePath
    $State  = $dirCheck.State
    $isDir  = $dirCheck.Success -and $dirCheck.IsDirectory

    $itemsToPull = @()
    if ($isDir) {
        $res = Get-AndroidDirectoryContents -State $State -Path $sourcePath
        $State = $res.State
        $allItems = @($res.Items)
        if ($allItems.Count -eq 0) { Write-Host "🟡 Directory is empty or inaccessible." -ForegroundColor Yellow; return $null }

        Write-Host "`nItems available in '$($sourcePath)':" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allItems.Count; $i++) {
            $icon = Get-ItemEmoji -Name $allItems[$i].Name -Type $allItems[$i].Type
            Write-Host (" [{0,2}] {1} {2}" -f ($i+1), $icon, $allItems[$i].Name)
        }
        $selectionStr = Read-Host "`n➡️  Enter item numbers to pull (e.g., 1-3,5 or 'all')"
        $selectedIndices = Test-ValidSelection -Selection $selectionStr -Max $allItems.Count
        if (-not $selectedIndices) { Write-Host "🟡 No items selected." -ForegroundColor Yellow; return $null }
        $itemsToPull = $selectedIndices | ForEach-Object { $allItems[$_] }
    } else {
        $sizeResult = Invoke-AdbCommand -State $State -Arguments @('shell','stat','-c','%s', "'$sourcePath'")
        $State = $sizeResult.State
        $fileSize = if ($sizeResult.Success -and $sizeResult.Output -match '^\d+$') { [long]$sizeResult.Output } else { 0L }
        $itemName = $sourcePath.Split('/')[-1]
        $itemsToPull += [PSCustomObject]@{ Name = $itemName; FullPath = $sourcePath; Type = 'File'; Size = $fileSize }
    }

    if ($itemsToPull.Count -eq 0) { Write-Host "🟡 No items selected." -ForegroundColor Yellow; return $null }

    $destinationFolder = Show-FolderPicker "Select destination folder on PC"
    if (-not $destinationFolder) { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return $null }
    if (-not (Test-Path -LiteralPath $destinationFolder)) { Write-ErrorMessage -Operation "Invalid path"; return $null }
    $destinationFolder = [IO.Path]::GetFullPath($destinationFolder)

    return [PSCustomObject]@{
        State       = $State
        Items       = $itemsToPull
        Destination = $destinationFolder
        SourcePath  = $sourcePath
        IsDirectory = $isDir
    }
}

function Confirm-PullTransfer {
    param(
        [hashtable]$State,
        [array]$Items,
        [string]$SourcePath,
        [string]$Destination,
        [string]$ActionVerb,
        [bool]$IsDirectory
    )
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline

    $sizeInfo = Get-AndroidItemsSize -State $State -Items $Items
    $State = $sizeInfo.State
    $totalSize = $sizeInfo.TotalSize
    $itemSizes = $sizeInfo.ItemSizes

    Write-Host "`r" + (" " * 50) + "`r"
    Write-Host "You are about to $ActionVerb $($Items.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    $fromLocation = if ($IsDirectory) { $SourcePath } else { $SourcePath.Substring(0, $SourcePath.LastIndexOf('/')) }
    Write-Host "From (Android): $fromLocation" -ForegroundColor Yellow
    Write-Host "To   (PC)    : $Destination" -ForegroundColor Yellow
    $confirm = Read-Host "➡️  Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host "🟡 Action cancelled." -ForegroundColor Yellow; return $null }

    if     ($totalSize -ge 1GB)  { $updateInterval = 500 }
    elseif ($totalSize -ge 100MB) { $updateInterval = 250 }
    else                          { $updateInterval = 100 }

    return [PSCustomObject]@{
        State          = $State
        ItemSizes      = $itemSizes
        TotalSize      = $totalSize
        UpdateInterval = $updateInterval
    }
}

function Execute-PullTransfer {
    param(
        [hashtable]$State,
        [array]$Items,
        [hashtable]$ItemSizes,
        [string]$Destination,
        [switch]$Move,
        [int]$UpdateInterval
    )
    $successCount = 0; $failureCount = 0; [long]$cumulativeBytesTransferred = 0
    $overallStartTime = Get-Date

    foreach ($item in $Items) {
        if (-not (Test-AndroidPath $item.FullPath)) {
            Write-ErrorMessage -Operation "Skipping" -Item $item.Name -Details "Invalid path"
            continue
        }
        $sourceItem = $item.FullPath
        $destPathOnPC = Join-Path $Destination $item.Name
        $itemTotalSize = $ItemSizes[$item.FullPath]

        if ($State.Config.WhatIf) {
            Write-Host "[WhatIf] Would pull $sourceItem to $destPathOnPC" -ForegroundColor Yellow
            $successCount++
            continue
        }

        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-AdbProcess -State $State -Arguments @('pull', $sourceItem, $destPathOnPC) -StdOutPath $stdoutFile -StdErrPath $stderrFile

        Write-Host "Press Esc or Q to cancel..." -ForegroundColor Yellow

        $itemStartTime = Get-Date
        Write-Host ""

        $lastReportedSize = 0L
        $lastWriteTime   = [DateTime]::MinValue
        $cancelled = $false
        if ($itemTotalSize -gt 0) {
            while (-not $proc.HasExited) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true).Key
                        if ($key -eq [ConsoleKey]::Escape -or $key -eq [ConsoleKey]::Q) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $cancelled = $true
                            break
                        }
                    }
                } catch {
                    # Input may be redirected; ignore key checks
                }
                $currentSize = $lastReportedSize
                if (Test-Path -LiteralPath $destPathOnPC) {
                    try {
                        $itemInfo = Get-Item -LiteralPath $destPathOnPC -ErrorAction Stop
                        if ($itemInfo.PSIsContainer) {
                            if ($itemInfo.LastWriteTime -gt $lastWriteTime) {
                                $currentSize      = Get-LocalItemSize -ItemPath $destPathOnPC
                                $lastReportedSize = $currentSize
                                $lastWriteTime    = $itemInfo.LastWriteTime
                            }
                        } else {
                            if ($itemInfo.Length -gt $lastReportedSize) {
                                $currentSize      = Get-LocalItemSize -ItemPath $destPathOnPC
                                $lastReportedSize = $currentSize
                            }
                        }
                    } catch { }
                }
                Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $currentSize -TotalValue $itemTotalSize -StartTime $itemStartTime -ShowCancelMessage
                Start-Sleep -Milliseconds $UpdateInterval
            }
            if ($cancelled) {
                $proc.WaitForExit() | Out-Null
                Clear-ProgressLine
                Write-Host "⛔ Cancelled pulling $($item.Name)" -ForegroundColor Yellow
                $failureCount++
                Remove-Item -LiteralPath $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
                continue
            }
            $proc.WaitForExit()
            $finalSize = Get-LocalItemSize -ItemPath $destPathOnPC
            if ($finalSize -lt $lastReportedSize) { $finalSize = $lastReportedSize }
            Show-InlineProgress -Activity "Pulling $($item.Name)" -CurrentValue $finalSize -TotalValue $itemTotalSize -StartTime $itemStartTime -ShowCancelMessage
            Clear-ProgressLine
        } else {
            $spinner = @('|','/','-','\\')
            $spinIndex = 0
            while (-not $proc.HasExited) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true).Key
                        if ($key -eq [ConsoleKey]::Escape -or $key -eq [ConsoleKey]::Q) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $cancelled = $true
                            break
                        }
                    }
                } catch {
                    # Input may be redirected; ignore key checks
                }
                $statusText = Get-AdbStderrProgress -StderrPath $stderrFile
                if ($statusText) {
                    Write-Host -NoNewline ("`r{0} Pulling {1}... {2} (Press Esc or Q to cancel)" -f $spinner[$spinIndex % $spinner.Length], $item.Name, $statusText)
                } else {
                    Write-Host -NoNewline ("`r{0} Pulling {1}... (Press Esc or Q to cancel)" -f $spinner[$spinIndex % $spinner.Length], $item.Name)
                }
                $spinIndex++
                Start-Sleep -Milliseconds $UpdateInterval
            }
            if ($cancelled) {
                $proc.WaitForExit() | Out-Null
                Clear-ProgressLine
                Write-Host "⛔ Cancelled pulling $($item.Name)" -ForegroundColor Yellow
                $failureCount++
                Remove-Item -LiteralPath $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
                Write-Host ""
                continue
            }
            $proc.WaitForExit()
            Clear-ProgressLine
            Write-Host "Pulling $($item.Name)... done"
            $finalSize = Get-LocalItemSize -ItemPath $destPathOnPC
        }

        $proc.WaitForExit()
        $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
        $resultOutput = ($stdout,$stderr | Where-Object { $_ }) -join "`n"
        $success = ($proc.ExitCode -eq 0 -and $resultOutput -notmatch 'No such file or directory|error:')

        if ($success) {
            $successCount++
            $cumulativeBytesTransferred += $finalSize
            Write-Host "✅ Pulled $($item.Name)" -ForegroundColor Green
            Write-Host $resultOutput.Trim() -ForegroundColor Gray

            if ($Move) {
                $canDelete = $false
                if ($item.Type -eq 'Directory') {
                    if ($State.Features.SupportsDuSb) {
                        $remoteSizeRes = Invoke-AdbCommand -State $State -Arguments @('shell','du','-sb', "'$sourceItem'")
                        $State = $remoteSizeRes.State
                        if ($remoteSizeRes.Success -and $remoteSizeRes.Output -match '^(\d+)') {
                            if ([long]$Matches[1] -eq $finalSize) { $canDelete = $true }
                        }
                    } else {
                        $remoteCountRes = Invoke-AdbCommand -State $State -Arguments @('shell','sh','-c', "find '$sourceItem' -maxdepth 1 -mindepth 1 | wc -l")
                        $State = $remoteCountRes.State
                        if ($remoteCountRes.Success -and $remoteCountRes.Output -match '^(\d+)') {
                            $remoteCount = [int]$Matches[1]
                            $localCount = (Get-ChildItem -LiteralPath $destPathOnPC -Force | Measure-Object).Count
                            if ($remoteCount -eq $localCount) { $canDelete = $true }
                        }
                    }
                } else {
                    $remoteSizeRes = Invoke-AdbCommand -State $State -Arguments @('shell','stat','-c','%s', "'$sourceItem'")
                    $State = $remoteSizeRes.State
                    if ($remoteSizeRes.Success -and $remoteSizeRes.Output -match '^\d+$') {
                        if ([long]$remoteSizeRes.Output -eq $finalSize) { $canDelete = $true }
                    }
                }
                if ($canDelete -and (Test-IsSafePath -State $State -Path $sourceItem)) {
                    Write-Host "   - Removing source item..." -NoNewline
                    $deleteResult = Invoke-AdbCommand -State $State -Arguments @('shell','rm','-rf', "'$sourceItem'")
                    $State = $deleteResult.State
                    if ($deleteResult.Success) {
                        Write-Host " ✅" -ForegroundColor Green
                        $State = Invalidate-ParentCache -State $State -ItemPath $sourceItem
                    } else {
                        Write-Host " " -NoNewline
                        Write-ErrorMessage -Operation "(Failed to delete)" -NoNewline
                    }
                } else {
                    Write-Host "   - Skipping source delete; verification failed." -ForegroundColor Yellow
                }
            }
        } else {
            $failureCount++
            Write-ErrorMessage -Operation "FAILED to pull" -Item $item.Name -Details $resultOutput
        }

    }
    $overallTimeTaken = ((Get-Date) - $overallStartTime).TotalSeconds
    return [PSCustomObject]@{
        State          = $State
        SuccessCount   = $successCount
        FailureCount   = $failureCount
        CumulativeBytes = $cumulativeBytesTransferred
        TimeTaken      = $overallTimeTaken
    }
}

function Show-PullSummary {
    param(
        [int]$SuccessCount,
        [int]$FailureCount,
        [long]$CumulativeBytes,
        [double]$TimeTaken
    )
    Write-Host "`n📊 TRANSFER SUMMARY" -ForegroundColor Cyan
    Write-Host "   - ✅ $SuccessCount Successful, ❌ $FailureCount Failed"
    Write-Host "   - Total Transferred: $(Format-Bytes $CumulativeBytes)"
    Write-Host "   - Time Taken: $([math]::Round($TimeTaken, 2)) seconds"
}

function Pull-FilesFromAndroid {
    param(
        [hashtable]$State,
        [string]$Path,
        [switch]$Move
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PULL" }
    Write-Host "`n📥 $actionVerb FROM ANDROID" -ForegroundColor Magenta

    $selection = Select-PullItems -State $State -Path $Path
    if (-not $selection) { return $State }
    $State = $selection.State

    $confirmation = Confirm-PullTransfer -State $State -Items $selection.Items -SourcePath $selection.SourcePath -Destination $selection.Destination -ActionVerb $actionVerb -IsDirectory:$selection.IsDirectory
    if (-not $confirmation) { return $State }
    $State = $confirmation.State

    $result = Execute-PullTransfer -State $State -Items $selection.Items -ItemSizes $confirmation.ItemSizes -Destination $selection.Destination -Move:$Move -UpdateInterval $confirmation.UpdateInterval
    $State = $result.State

    Show-PullSummary -SuccessCount $result.SuccessCount -FailureCount $result.FailureCount -CumulativeBytes $result.CumulativeBytes -TimeTaken $result.TimeTaken
    return $State
}
 
function Select-PushItems {
    param([string]$DestinationPath)
    $uploadType = Read-Host "What do you want to upload? (F)iles or a (D)irectory?"

    $sourceItems = @()
    switch ($uploadType.ToLower()) {
        'f' { $sourceItems = Show-OpenFilePicker -Title "Select files to push" -MultiSelect }
        'd' {
            $selectedFolder = Show-FolderPicker -Description "Select a folder to push"
            if ($selectedFolder) { $sourceItems += $selectedFolder }
        }
        default { Write-ErrorMessage -Operation "Invalid selection"; return $null }
    }

    if ($sourceItems.Count -eq 0) { Write-Host "🟡 No items selected." -ForegroundColor Yellow; return $null }

    $destPathFinal = if (-not [string]::IsNullOrWhiteSpace($DestinationPath)) { $DestinationPath }
        else { Read-Host "➡️  Enter destination path on Android (e.g., /sdcard/Download/)" }
    if ([string]::IsNullOrWhiteSpace($destPathFinal)) { Write-Host "🟡 Action cancelled."; return $null }
    if (-not (Test-AndroidPath $destPathFinal)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $null
    }

    return [PSCustomObject]@{
        Items       = $sourceItems
        Destination = $destPathFinal
    }
}

function Confirm-PushTransfer {
    param(
        [array]$Items,
        [string]$Destination,
        [string]$ActionVerb
    )
    Write-Host "`n✨ CONFIRMATION" -ForegroundColor Cyan
    Write-Host "Calculating total size... Please wait." -NoNewline
    [long]$totalSize = 0
    $itemSizes = @{}
    foreach ($item in $Items) {
        $size = Get-LocalItemSize -ItemPath $item -ShowStatus
        $itemSizes[$item] = $size
        $totalSize += $size
    }
    Write-Host "`r" + (" " * 50) + "`r"
    Write-Host "You are about to $ActionVerb $($Items.Count) item(s) with a total size of $(Format-Bytes $totalSize)."
    Write-Host "From (PC)    : $(Split-Path $Items[0] -Parent)" -ForegroundColor Yellow
    Write-Host "To   (Android): $Destination" -ForegroundColor Yellow
    Write-Host "NOTE: Progress may be approximate if the device lacks 'du -sb'." -ForegroundColor DarkGray
    $confirm = Read-Host "➡️  Press Enter to begin, or type 'n' to cancel"
    if ($confirm -eq 'n') { Write-Host " Action cancelled." -ForegroundColor Yellow; return $null }
    if     ($totalSize -ge 1GB)  { $updateInterval = 500 }
    elseif ($totalSize -ge 100MB) { $updateInterval = 250 }
    else                          { $updateInterval = 100 }
    return [PSCustomObject]@{
        ItemSizes      = $itemSizes
        TotalSize      = $totalSize
        UpdateInterval = $updateInterval
    }
}

function Execute-PushTransfer {
    param(
        [hashtable]$State,
        [array]$Items,
        [hashtable]$ItemSizes,
        [string]$Destination,
        [switch]$Move,
        [int]$UpdateInterval
    )
    $successCount = 0; $failureCount = 0
    foreach ($item in $Items) {
        if (-not (Test-AndroidPath $Destination)) {
            Write-ErrorMessage -Operation "Invalid path"
            $failureCount++
            continue
        }
        $itemInfo = Get-Item -LiteralPath $item
        $sourceItem = $itemInfo.FullName
        $destPath = $Destination

        if ($State.Config.WhatIf) {
            Write-Host "[WhatIf] Would push $sourceItem to $destPath" -ForegroundColor Yellow
            $successCount++
            continue
        }

        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-AdbProcess -State $State -Arguments @('push', $sourceItem, $destPath) -StdOutPath $stdoutFile -StdErrPath $stderrFile

        Write-Host "Press Esc or Q to cancel..." -ForegroundColor Yellow

        $itemTotalSize = $ItemSizes[$item]
        $destItemPath = if ($Destination.TrimEnd('/') -eq '') { '/' + $itemInfo.Name } else { ($Destination.TrimEnd('/')) + '/' + $itemInfo.Name }
        $itemStartTime = Get-Date
        Write-Host ""
        $cancelled = $false
        if ($State.Features.SupportsDuSb) {
            $lastReportedSize = 0L
            while (-not $proc.HasExited) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true).Key
                        if ($key -eq [ConsoleKey]::Escape -or $key -eq [ConsoleKey]::Q) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $cancelled = $true
                            break
                        }
                    }
                } catch {
                    # Ignore key checks when input is not interactive
                }
                $currentSize = $lastReportedSize
                $sizeResult = Invoke-AdbCommand -State $State -Arguments @('shell','du','-sb', "'$destItemPath'")
                $State = $sizeResult.State
                if ($sizeResult.Success -and $sizeResult.Output -match '^(\d+)') {
                    $currentSize = [long]$Matches[1]
                    $lastReportedSize = $currentSize
                }
                Show-InlineProgress -Activity "Pushing $($itemInfo.Name)" -CurrentValue $currentSize -TotalValue $itemTotalSize -StartTime $itemStartTime -ShowCancelMessage
                Start-Sleep -Milliseconds $UpdateInterval
            }
            if ($cancelled) {
                $proc.WaitForExit() | Out-Null
                Clear-ProgressLine
                Write-Host "⛔ Cancelled pushing $($itemInfo.Name)" -ForegroundColor Yellow
                $failureCount++
                Remove-Item -LiteralPath $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
                continue
            }
            $finalSizeResult = Invoke-AdbCommand -State $State -Arguments @('shell','du','-sb', "'$destItemPath'")
            $State = $finalSizeResult.State
            $finalSize = if ($finalSizeResult.Success -and $finalSizeResult.Output -match '^(\d+)') { [long]$Matches[1] } else { $lastReportedSize }
            Show-InlineProgress -Activity "Pushing $($itemInfo.Name)" -CurrentValue $finalSize -TotalValue $itemTotalSize -StartTime $itemStartTime -ShowCancelMessage
            Clear-ProgressLine
        } else {
            $spinner = @('|','/','-','\\')
            $spinIndex = 0
            while (-not $proc.HasExited) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true).Key
                        if ($key -eq [ConsoleKey]::Escape -or $key -eq [ConsoleKey]::Q) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $cancelled = $true
                            break
                        }
                    }
                } catch {
                    # Ignore key checks when input is not interactive
                }
                $statusText = Get-AdbStderrProgress -StderrPath $stderrFile
                if ($statusText) {
                    Write-Host -NoNewline ("`r{0} Pushing {1}... {2} (Press Esc or Q to cancel)" -f $spinner[$spinIndex % $spinner.Length], $itemInfo.Name, $statusText)
                } else {
                    Write-Host -NoNewline ("`r{0} Pushing {1}... (Press Esc or Q to cancel)" -f $spinner[$spinIndex % $spinner.Length], $itemInfo.Name)
                }
                $spinIndex++
                Start-Sleep -Milliseconds $UpdateInterval
            }
            if ($cancelled) {
                $proc.WaitForExit() | Out-Null
                Clear-ProgressLine
                Write-Host "⛔ Cancelled pushing $($itemInfo.Name)" -ForegroundColor Yellow
                $failureCount++
                Remove-Item -LiteralPath $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
                Write-Host ""  # ensure newline if spinner was active
                continue
            }
            Clear-ProgressLine
            Write-Host "Pushing $($itemInfo.Name)... done"
        }

        $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
        $combinedOutput = ($stdout,$stderr | Where-Object { $_ }) -join "`n"
        $success = ($proc.ExitCode -eq 0 -and $combinedOutput -notmatch 'error:')

        if ($success) {
            $successCount++
            Write-Host "✅ Pushed $($itemInfo.Name)" -ForegroundColor Green
            Write-Host $combinedOutput -ForegroundColor Gray

            $State = Invalidate-DirectoryCache -State $State -DirectoryPath $Destination

            if ($Move) {
                $canDelete = $false
                if ($itemInfo.PSIsContainer) {
                    if ($State.Features.SupportsDuSb) {
                        $remoteSizeRes = Invoke-AdbCommand -State $State -Arguments @('shell','du','-sb', "'$destItemPath'")
                        $State = $remoteSizeRes.State
                        if ($remoteSizeRes.Success -and $remoteSizeRes.Output -match '^(\d+)') {
                            $localSize = Get-LocalItemSize -ItemPath $itemInfo.FullName
                            if ([long]$Matches[1] -eq $localSize) { $canDelete = $true }
                        }
                    } else {
                        $remoteCountRes = Invoke-AdbCommand -State $State -Arguments @('shell','sh','-c', "find '$destItemPath' -maxdepth 1 -mindepth 1 | wc -l")
                        $State = $remoteCountRes.State
                        if ($remoteCountRes.Success -and $remoteCountRes.Output -match '^(\d+)') {
                            $remoteCount = [int]$Matches[1]
                            $localCount = (Get-ChildItem -LiteralPath $itemInfo.FullName -Force | Measure-Object).Count
                            if ($remoteCount -eq $localCount) { $canDelete = $true }
                        }
                    }
                } else {
                    $remoteSizeRes = Invoke-AdbCommand -State $State -Arguments @('shell','stat','-c','%s', "'$destItemPath'")
                    $State = $remoteSizeRes.State
                    if ($remoteSizeRes.Success -and $remoteSizeRes.Output -match '^\d+$') {
                        if ([long]$remoteSizeRes.Output -eq $itemInfo.Length) { $canDelete = $true }
                    }
                }
                if ($canDelete) {
                    Write-Host "   - Removing source item..." -NoNewline
                    try {
                        Remove-Item -LiteralPath $itemInfo.FullName -Force -Recurse -ErrorAction Stop
                        Write-Host " ✅" -ForegroundColor Green
                    } catch {
                        Write-Host " " -NoNewline
                        Write-ErrorMessage -Operation "(Failed to delete)" -NoNewline
                    }
                } else {
                    Write-Host "   - Skipping source delete; verification failed." -ForegroundColor Yellow
                }
            }
        } else {
            $failureCount++
            Write-ErrorMessage -Operation "FAILED to push" -Item $itemInfo.Name -Details $combinedOutput
        }

    }
    return [PSCustomObject]@{
        State        = $State
        SuccessCount = $successCount
        FailureCount = $failureCount
    }
}

function Show-PushSummary {
    param([int]$SuccessCount, [int]$FailureCount)
    Write-Host "`n📊 TRANSFER SUMMARY: ✅ $SuccessCount Successful, ❌ $FailureCount Failed" -ForegroundColor Cyan
}
 
function Push-FilesToAndroid {
    param(
        [hashtable]$State,
        [switch]$Move,
        [string]$DestinationPath
    )
    $actionVerb = if ($Move) { "MOVE" } else { "PUSH" }
    Write-Host "`n📤 $actionVerb ITEMS TO ANDROID" -ForegroundColor Magenta

    $selection = Select-PushItems -DestinationPath $DestinationPath
    if (-not $selection) { return $State }

    $confirmation = Confirm-PushTransfer -Items $selection.Items -Destination $selection.Destination -ActionVerb $actionVerb
    if (-not $confirmation) { return $State }

    $result = Execute-PushTransfer -State $State -Items $selection.Items -ItemSizes $confirmation.ItemSizes -Destination $selection.Destination -Move:$Move -UpdateInterval $confirmation.UpdateInterval
    $State = $result.State

    Show-PushSummary -SuccessCount $result.SuccessCount -FailureCount $result.FailureCount
    return $State
}

# --- Other File System Functions ---

function Get-ItemEmoji {
    param([string]$Name, [string]$Type)
    if ($Type -eq 'Directory') { return '📁' }
    if ($Type -eq 'Link')      { return '🔗' }
    $ext = [IO.Path]::GetExtension($Name).ToLowerInvariant()
    switch ($ext) {
        { '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp' -contains $_ } { return '🖼️' }
        { '.mp4', '.mkv', '.mov', '.avi' -contains $_ }                 { return '🎞️' }
        { '.mp3', '.flac', '.wav', '.ogg' -contains $_ }                { return '🎵' }
        { '.zip', '.rar', '.7z', '.tar', '.gz' -contains $_ }           { return '🗜️' }
        '.pdf'                                                         { return '📕' }
        { '.txt', '.md', '.log', '.ini', '.json', '.xml' -contains $_ } { return '📝' }
        default                                                         { return '📄' }
    }
}

function Browse-AndroidFileSystem {
    param([hashtable]$State)
    $State = Show-UIHeader -State $State -Title "FILE BROWSER"
    $currentPath = Read-Host "➡️  Enter starting path (default: /sdcard/)"
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "/sdcard/" }
    if (-not (Test-AndroidPath $currentPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $State
    }

    do {
        $State = Show-UIHeader -State $State -Title "FILE BROWSER"
        Write-Host "📁 Browsing: $currentPath" -ForegroundColor White -BackgroundColor DarkCyan
        Write-Host ("─" * 62) -ForegroundColor Gray

        # Cast the result to an array to prevent errors when a directory has only one item.
        $res = Get-AndroidDirectoryContents -State $State -Path $currentPath
        $State = $res.State
        $items = @($res.Items |
            Sort-Object -Property @{ Expression = { if ($_.Type -eq 'Directory') { 0 } else { 1 } } }, Name)

        Write-Host " [ 0] .. (Go Up)" -ForegroundColor Yellow
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            $icon = Get-ItemEmoji -Name $item.Name -Type $item.Type
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
            "q" { Clear-Host; return $State }
            "c" { $State = New-AndroidFolder -State $State -ParentPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "p" { $State = Pull-FilesFromAndroid -State $State -Path $currentPath; Read-Host "`nPress Enter to continue..." }
            "u" { $State = Push-FilesToAndroid -State $State -DestinationPath $currentPath; Read-Host "`nPress Enter to continue..." }
            "r" {
                Write-Host "`n🔄 Refreshing directory..." -ForegroundColor Yellow
                $State = Invalidate-DirectoryCache -State $State -DirectoryPath $currentPath
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
                    } else {
                        $currentPath = "/"
                    }
                }
            }
            default {
                if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $items.Count) {
                    $selectedIndex = [int]$choice - 1
                    $selectedItem = $items[$selectedIndex]
                    if ($selectedItem.Type -in "Directory", "Link") {
                        if (Test-AndroidPath $selectedItem.FullPath) {
                            $currentPath = $selectedItem.FullPath
                        } else {
                            Write-ErrorMessage -Operation "Invalid path"
                            Start-Sleep -Seconds 1
                        }
                    } else {
                        $State = Show-ItemActionMenu -State $State -Item $selectedItem
                    }
                } else {
                    Write-ErrorMessage -Operation "Invalid selection"
                    Start-Sleep -Seconds 1
                }
            }
        }
    } while ($true)
}

function New-AndroidFolder {
    param(
        [hashtable]$State,
        [string]$ParentPath
    )
    $folderName = Read-Host "➡️  Enter name for the new folder"
    if ([string]::IsNullOrWhiteSpace($folderName)) { Write-Host "🟡 Action cancelled: No name provided." -ForegroundColor Yellow; return }
    $fullPath = if ($ParentPath.EndsWith('/')) { "$ParentPath$folderName" } else { "$ParentPath/$folderName" }
    if (-not (Test-AndroidPath $fullPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $State
    }
    # Use single quotes for shell path
    $result = Invoke-AdbCommand -State $State -Arguments @('shell','mkdir','-p', "'$fullPath'")
    $State = $result.State
    if ($result.Success) {
        Write-Host "✅ Successfully created folder: $fullPath" -ForegroundColor Green
        $State = Invalidate-ParentCache -State $State -ItemPath $fullPath
    }
    else { Write-ErrorMessage -Operation "Failed to create folder" -Item $fullPath -Details $result.Output }
    return $State
}

function Show-ItemActionMenu {
    param(
        [hashtable]$State,
        $Item
    )
    while ($true) {
        $State = Show-UIHeader -State $State -Title "ITEM ACTIONS"
        Write-Host "Selected Item: $($Item.FullPath)" -ForegroundColor White -BackgroundColor DarkMagenta
        Write-Host "---------------------------------"
        Write-Host " 1. Pull to PC (Copy)"
        Write-Host " 2. Move to PC (Pull + Delete)"
        Write-Host " 3. Rename (on device)"
        Write-Host " 4. Delete (on device)"
        Write-Host " 5. Back to browser"
        $action = Read-Host "`n➡️  Enter your choice (1-5)"
        switch ($action) {
            "1" { $State = Pull-FilesFromAndroid -State $State -Path $Item.FullPath; Read-Host "`nPress Enter to continue..."; break }
            "2" { $State = Pull-FilesFromAndroid -State $State -Path $Item.FullPath -Move; Read-Host "`nPress Enter to continue..."; break }
            "3" {
                $State = Rename-AndroidItem -State $State -ItemPath $Item.FullPath
                Read-Host "`nPress Enter to continue..."
                Clear-Host
                return $State # Return to browser as item name has changed
            }
            "4" {
                $State = Remove-AndroidItem -State $State -ItemPath $Item.FullPath
                Read-Host "`nPress Enter to continue..."
                Clear-Host
                return $State # Return to browser as item is gone
            }
            "5" { Clear-Host; return $State }
            default { Write-ErrorMessage -Operation "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

function Remove-AndroidItem {
    param(
        [hashtable]$State,
        [string]$ItemPath,
        [switch]$Force
    )
    if (-not (Test-AndroidPath $ItemPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $State
    }
    if (-not (Test-IsSafePath -State $State -Path $ItemPath -Force:$Force)) { return $State }
    $itemName = $ItemPath.Split('/')[-1]
    $typeCheck = Test-AndroidItemIsDirectory -State $State -Path $ItemPath
    $State = $typeCheck.State
    $isDir = $typeCheck.Success -and $typeCheck.IsDirectory

    $requireName = $false
    if ($isDir -and $State.Features.SupportsDuSb) {
        $sizeRes = Invoke-AdbCommand -State $State -Arguments @('shell','du','-sb', "'$ItemPath'")
        $State = $sizeRes.State
        if ($sizeRes.Success -and $sizeRes.Output -match '^(\d+)') {
            $dirSize = [long]$Matches[1]
            if ($dirSize -ge ($State.Config.LargeDeleteConfirmThresholdMB * 1MB)) { $requireName = $true }
        }
    }

    if ($State.Config.WhatIf) {
        Write-Host "[WhatIf] Would delete '$itemName'" -ForegroundColor Yellow
        return $State
    }

    if ($requireName) {
        $typed = Read-Host "Type '$itemName' or DELETE to confirm"
        if ($typed -ne $itemName -and $typed -ne 'DELETE') { Write-Host "🟡 Deletion cancelled." -ForegroundColor Yellow; return $State }
    } else {
        $confirmation = Read-Host "❓ Are you sure you want to PERMANENTLY DELETE '$itemName'? [y/N]"
        if ($confirmation.ToLower() -ne 'y') { Write-Host "🟡 Deletion cancelled." -ForegroundColor Yellow; return $State }
    }

    $result = Invoke-AdbCommand -State $State -Arguments @('shell','rm','-rf', "'$ItemPath'")
    $State = $result.State
    if ($result.Success) {
        Write-Host "✅ Successfully deleted '$itemName'." -ForegroundColor Green
        $State = Invalidate-ParentCache -State $State -ItemPath $ItemPath
    }
    else { Write-ErrorMessage -Operation "Failed to delete" -Item $itemName -Details $result.Output }
    return $State
}

function Rename-AndroidItem {
    param(
        [hashtable]$State,
        [string]$ItemPath,
        [switch]$Force
    )
    if (-not (Test-AndroidPath $ItemPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $State
    }
    if (-not (Test-IsSafePath -State $State -Path $ItemPath -Force:$Force)) { return $State }
    if ($State.Config.WhatIf) {
        Write-Host "[WhatIf] Would rename '$ItemPath'" -ForegroundColor Yellow
        return $State
    }
    $itemName = $ItemPath.Split('/')[-1]
    $newName = Read-Host "➡️  Enter the new name for '$itemName'"
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName.Contains('/') -or $newName.Contains('\')) {
        Write-ErrorMessage -Operation "Invalid name"; return $State
    }
    $parentPath = $ItemPath.Substring(0, $ItemPath.LastIndexOf('/'))
    $newItemPath = if ([string]::IsNullOrEmpty($parentPath)) { "/$newName" } else { "$parentPath/$newName" }
    if (-not (Test-AndroidPath $newItemPath)) {
        Write-ErrorMessage -Operation "Invalid path"
        return $State
    }
    if (-not (Test-IsSafePath -State $State -Path $newItemPath -Force:$Force)) { return $State }

    $result = Invoke-AdbCommand -State $State -Arguments @('shell','mv', "'$ItemPath'", "'$newItemPath'")
    $State = $result.State
    if ($result.Success) {
        Write-Host "✅ Successfully renamed to '$newName'." -ForegroundColor Green
        $State = Invalidate-ParentCache -State $State -ItemPath $ItemPath
    } else {
        Write-ErrorMessage -Operation "Failed to rename" -Item $itemName -Details $result.Output
    }
    return $State
}

# --- GUI Picker Functions ---

function Show-FolderPicker {
    param([string]$Description = "Select a folder")
    if ($script:CanUseGui) {
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = $Description
        $folderBrowser.ShowNewFolderButton = $true
        if ($folderBrowser.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq 'OK') {
            return $folderBrowser.SelectedPath
        }
        return $null
    } else {
        $path = Read-Host "$Description (enter full path)"
        if (Test-Path $path) { return $path } else { return $null }
    }
}

function Show-OpenFilePicker {
    param(
        [string]$Title = "Select a file",
        [string]$Filter = "All files (*.*)|*.*",
        [switch]$MultiSelect
    )
    if ($script:CanUseGui) {
        $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $fileDialog.Title = $Title
        $fileDialog.Filter = $Filter
        $fileDialog.Multiselect = $MultiSelect
        if ($fileDialog.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq 'OK') {
            return $fileDialog.FileNames
        }
        return $null
    } else {
        $prompt = if ($MultiSelect) { "$Title (enter paths separated by commas)" } else { "$Title (enter path)" }
        $input = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($input)) { return $null }
        if ($MultiSelect) {
            return $input.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        } else {
            return $input.Trim()
        }
    }
}

# --- Main Menu and Execution Flow ---

function Show-MainMenu {
    param([hashtable]$State)
    while ($true) {
        $State = Show-UIHeader -State $State -SubTitle "MAIN MENU"

        if (-not $State.DeviceStatus.IsConnected) {
            Write-Host "`n⚠️ No device connected. Please connect a device and ensure it's recognized by ADB." -ForegroundColor Yellow
            Write-Host "   Trying to reconnect in 5 seconds..."
            # Force a full status update on the next loop after sleeping
            $State.LastStatusUpdateTime = [DateTime]::MinValue
            Start-Sleep -Seconds 5
            continue
        }

        Write-Host ""
        Write-Host " 1. Browse Device Filesystem (Interactive Push/Pull/Manage)"
        Write-Host " 2. Quick Push (from PC to a specified device path)"
        Write-Host " 3. Quick Pull (from a specified device path to PC)"
        Write-Host " R. Refresh Device List"
        Write-Host ""
        Write-Host " Q. Exit"
        Write-Host ""

        $choice = Read-Host "➡️  Enter your choice"

        if ($choice -in '1', '2', '3' -and -not $State.DeviceStatus.IsConnected) {
            Write-Host ""
            Write-ErrorMessage -Operation "Cannot perform this action" -Details "No device connected."
            Read-Host "Press Enter to continue"
            continue
        }

        switch ($choice) {
            '1' { $State = Browse-AndroidFileSystem -State $State }
            '2' { $State = Push-FilesToAndroid -State $State }
            '3' { $State = Pull-FilesFromAndroid -State $State }
            'r' {
                $State = Show-UIHeader -State $State -SubTitle "MAIN MENU" -ShowDeviceList
                Read-Host "Press Enter to continue"
                continue
            }
            'q' { return $State }
            default { Write-ErrorMessage -Operation "Invalid choice"; Start-Sleep -Seconds 1 }
        }

        if ($choice -in '2','3') {
            Read-Host "`nPress Enter to return to the main menu..."
        }
    }
}

# --- ADB Setup ---
function Ensure-Adb {
    $existing = Get-Command adb -ErrorAction SilentlyContinue
    if ($existing) {
        $script:AdbPath = $existing.Source
        return $true
    }

    Write-Host "⚠️ ADB not found. Installing Android SDK Platform Tools..." -ForegroundColor Yellow

    $platform = if ($script:IsWindows) { 'windows' } else { 'linux' }
    $url = "https://dl.google.com/android/repository/platform-tools-latest-$platform.zip"
    $installDir = if ($script:IsWindows) {
        Join-Path $env:USERPROFILE 'AppData\Local\Android\platform-tools'
    } else {
        Join-Path $HOME '.android/platform-tools'
    }

    try {
        $tempZip = Join-Path ([IO.Path]::GetTempPath()) 'platform-tools.zip'
        Invoke-WebRequest -Uri $url -OutFile $tempZip
        $parent = Split-Path $installDir -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
        Expand-Archive -Path $tempZip -DestinationPath $parent -Force
        Remove-Item $tempZip -ErrorAction SilentlyContinue

        $existing = [Environment]::GetEnvironmentVariable('PATH','User')
        if ($existing) {
            $pathSep = [IO.Path]::PathSeparator
            if (-not $existing.Split($pathSep) -contains $installDir) {
                [Environment]::SetEnvironmentVariable('PATH', "$existing$pathSep$installDir", 'User')
            }
        } else {
            [Environment]::SetEnvironmentVariable('PATH', $installDir, 'User')
        }

        Write-Host "✅ ADB installed to $installDir" -ForegroundColor Green
        $resolved = Get-Command adb -ErrorAction SilentlyContinue
        if ($resolved) { $script:AdbPath = $resolved.Source }
        return $true
    }
    catch {
        Write-ErrorMessage -Operation "Failed to install ADB" -Details $_
    }

    return $false
}

# --- Main execution entry point ---
function Start-ADBTool {
    # Set output encoding to handle special characters correctly
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Ensure-Adb)) {
        Read-Host "Press Enter to exit."
        return
    }

    Write-Log "ADB File Manager v4.2.0 Started" "INFO"
    $state = $script:State
    $state = Show-MainMenu -State $state
    Write-Host "`n👋 Thank you for using the ADB File Manager!" -ForegroundColor Green
}

# Start the application
Start-ADBTool
