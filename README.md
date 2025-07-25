# ADB File Manager (Enhanced PowerShell Edition)

This PowerShell script provides a powerful, user-friendly command-line interface for managing files on an Android device via ADB (Android Debug Bridge). It's designed to be a significant improvement over the standard `adb push` and `adb pull` commands, with a focus on usability, safety, and a rich feature set.

## Features

*   **Interactive File Browser:** Navigate your Android device's file system with a user-friendly grid view.
*   **Device Status Bar:** Always know if your device is connected and see its model name at a glance.
*   **Robust File Operations:**
    *   **Push/Pull:** Transfer files and folders between your PC and Android device with detailed progress bars, including transfer speed and ETA for pull operations.
    *   **Move:** Move files between your PC and Android device (push/pull + delete).
    *   **Copy/Move (Intra-device):** Copy and move files and folders within your Android device's storage.
    *   **Delete:** Remove files and folders with a confirmation prompt to prevent accidents.
    *   **Rename:** Rename files and folders directly on the device.
    *   **Create Directory:** Make new folders on your device or on your local PC.
*   **App Management:**
    *   **Install APK:** Easily install Android packages (APKs) from your PC.
    *   **List Apps:** Get a list of all installed applications on your device.
*   **Comprehensive Logging:** All operations are logged to a timestamped file for easy debugging.
*   **Error Handling:** Centralized error handling provides clear feedback.
*   **Support for Special Characters:** Handles file and folder names with spaces.

## Prerequisites

*   **PowerShell:** The script is designed to run in a PowerShell environment.
*   **Android SDK Platform Tools (ADB):** You must have `adb.exe` in your system's PATH. You can download the platform tools from the official [Android developer website](https://developer.android.com/studio/releases/platform-tools).

## How to Use

1.  **Save the Script:** Save the `adb-file-manager.ps1` script to a location on your computer.
2.  **Enable USB Debugging:** On your Android device, enable Developer Options and then enable USB Debugging.
3.  **Connect Your Device:** Connect your Android device to your PC via a USB cable.
4.  **Run the Script:**
    *   Open a PowerShell terminal.
    *   Navigate to the directory where you saved the script.
    *   Run the script by typing: `.\adb-file-manager.ps1`

5.  **Use the Menu:** The script will present you with a menu of options. Simply type the number corresponding to the action you want to perform and press Enter. The most powerful features are in the interactive file browser (option 3).

## Disclaimer

This script executes powerful ADB commands, including file deletion. While it includes safeguards like confirmation prompts, you are responsible for the actions you perform. Always double-check paths and be careful when deleting files.
