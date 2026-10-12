# SpoofMyDevice Scripts

Host helper scripts for [BuSung-dev/SpoofMyDevice](https://github.com/BuSung-dev/SpoofMyDevice)'s Import Personal AVD Profile feature.

These scripts extract hardware identifiers, build properties, and screen metrics from an Android source device or emulator via ADB. The extracted configuration can be transmitted directly to an active SpoofMyDevice instance via an Android broadcast or exported locally as a JSON file.

## Prerequisites

- Android Debug Bridge (`adb`) installed and present on system `PATH`.
- USB debugging enabled and authorized on all connected devices.

## How to Run

### Windows

Execute via Command Prompt or PowerShell:

```cmd
extract_profile.bat
```

To pipe the output JSON directly into a file:

```cmd
extract_profile.bat > profile.json
```

### Linux / macOS

Make the script executable and run it:

```bash
chmod +x extract_profile.sh
./extract_profile.sh
```

To pipe the output JSON directly into a file:

```bash
./extract_profile.sh > profile.json
```

## How It Works

1. **Receiver Discovery:** The script queries connected ADB devices for up to 90 seconds to locate an active SpoofMyDevice broadcast receiver (`com.spoofmydevice.ACTION_SEND_CONFIG`).
2. **Source Selection:** Identifies connected devices excluding the receiver. If multiple source devices are attached, the user is prompted to select one by index.
3. **Property Extraction:** Gathers hardware, vendor, and build parameters (`ro.*`, `gsm.*`, timezone) along with display resolution and density metrics using `getprop`, `wm size`, and `wm density`.
4. **Profile Generation & Delivery:**
   - Constructs a structured JSON configuration payload.
   - If an active receiver is present, dispatches the payload directly to the device via `am broadcast`.
   - If no broadcast receiver is active or broadcast fails, prompts the user to save `output.json` directly to the host machine.

To generate the JSON file directly on the host machine without wireless/USB transmission, run the script without an active broadcast listener running in SpoofMyDevice.

## Common Errors

- **`adb is not installed or is not on PATH`**  
  The ADB binary was not found. Install Android SDK Platform-Tools and verify that `adb` executes in your terminal.
- **`No active registered receiver detected within 90 seconds`**  
  SpoofMyDevice is not open, the broadcast listener is inactive, or the target device is disconnected/unauthorized. The script will fall back to local file export if prompted.
- **`Multiple devices have active registered receivers`**  
  More than one connected device is actively listening for the configuration broadcast. Keep the listener open on only one device.
- **`No authorized source device connected besides the receiver device`**  
  No secondary device was detected to pull properties from. Connect the source device and confirm the USB debugging authorization dialog.
- **`ADB timed out` / Shell communication failure**  
  An ADB command hung or failed to respond. Check cable connections, verify device authorization status with `adb devices`, or restart the daemon with `adb kill-server`.
