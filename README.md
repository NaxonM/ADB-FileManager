# ADB File Manager for PowerShell

<div align="center"><img src="https://raw.githubusercontent.com/NaxonM/ADB-FileManager/main/screenshot.png" width="750"></div>

<p align="center">
  A powerful, efficient, and user-friendly command-line interface for managing files on your Android device, built with PowerShell.
</p>

---

## Why Use ADB File Manager?

Tired of the clunky `adb push` and `adb pull` commands? This ADB File Manager enhances your workflow with a rich, interactive terminal experience. It's designed for both power users and those who want a safer, more intuitive way to handle file transfers and management without ever leaving the console.

It's faster, smarter, and provides far more feedback than standard ADB commands.

## Core Features

* **💻 Interactive File Browser**: Navigate your device's filesystem with ease. The intuitive interface allows you to browse directories, select items, and perform actions without typing complex paths.
* **🚀 Efficient & Optimized Transfers**:
    * **Blazing Fast Pulls**: A detailed progress bar shows transfer speed, ETA, percentage, and total size.
    * **Optimized Size Calculation**: Calculates the total size of multiple folders in a single, efficient ADB command, making transfer confirmations significantly faster.
    * **Move Operations**: Transfer files and folders from your device and automatically delete the source, all in one go.
* **⚡ Performance & Reliability**:
    * **Smart Caching**: Directory contents are cached to make browsing incredibly fast and responsive. A manual refresh option gives you full control.
    * **Intelligent Status Detection**: The script instantly detects if a device is disconnected during an operation, providing immediate feedback without constant, slow polling.
* **🗂️ On-Device File Management**:
    * Create new folders.
    * Rename files and folders.
    * Delete items with a safety confirmation prompt.
* **✨ User-Friendly Interface**:
    * **GUI/Console Pickers**: On Windows PowerShell, uses familiar Windows dialogs for selecting local files and folders. When running on PowerShell Core (6+), falls back to console prompts for cross-platform compatibility.
    * **Clean UI**: A polished and clean header shows the connected device status at all times.
* **Detailed Logging**: All major operations are logged to a timestamped file for easy debugging. Supports log levels (`INFO`, `DEBUG`, `ERROR`) with optional path sanitization.

## Prerequisites

1.  **PowerShell 5.1 or PowerShell Core 6+**: Windows PowerShell provides GUI dialogs, while PowerShell Core is fully supported with console prompts. Comes standard with Windows 10 and later.
2.  **Android SDK Platform Tools (ADB)**: The script requires ADB. If `adb` is not found in your `PATH` at startup, it will automatically download and install the latest platform-tools to a user directory and append it to your `PATH`.

## Getting Started

1.  **Enable USB Debugging**: On your Android device, go to `Settings` > `About phone`, tap `Build number` seven times to enable Developer Options. Then, go to `Developer options` and enable `USB debugging`.
2.  **Connect Your Device**: Connect your Android device to your PC with a USB cable. Authorize the connection on your device if prompted.
3.  **Run the Script**:
    * Download the `adb-file-manager.ps1` script.
    * Open a PowerShell terminal.
    * If this is your first time running a local script, you may need to set the execution policy. Run PowerShell as Administrator and execute:
        ```powershell
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
        ```
    * Navigate to the directory where you saved the script and run it:
        ```powershell
        .\adb-file-manager.ps1
        ```

    * On first run, if ADB isn't installed, the script will download it. After installation, reopen PowerShell or rerun the script.

    * To include debug-level output, run the script with the `-LogLevel DEBUG` parameter.
        ```
4.  **Use the Menu**: The script will guide you through the available options. The most powerful features are in the **Browse Device Filesystem** menu.

## Disclaimer

This script executes powerful ADB commands, including file deletion. While it includes safeguards like confirmation prompts, you are responsible for the actions you perform. Always double-check paths and be careful when deleting files. The author is not responsible for any data loss.
