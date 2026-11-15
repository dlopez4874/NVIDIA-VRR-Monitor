# NVIDIA VRR Monitor

A lightweight, console-based NVIDIA Variable Refresh Rate (VRR) and refresh-rate monitor for Windows.

## Why this exists

OLED monitor owners may be accustomed to keeping a monitor's on-screen display (OSD) or a software monitoring overlay visible while gaming to check the current refresh rate and VRR behavior. But a persistent overlay on the OLED itself is not always desirable.

**NVIDIA VRR Monitor moves that monitoring view into a separate PowerShell window.** Keep the console on a second display, or bring it up when needed, and check whether NVIDIA reports VRR as enabled/requested/in its VRR display mode—along with an approximate refresh-rate estimate—without placing an overlay over the game on the OLED display.

This is a focused monitoring utility, not a replacement for every feature in a monitor's hardware OSD. It reports NVIDIA driver/API state and an experimental refresh-rate estimate; it does not read the panel's internal timing controller or measure every aspect of display performance.

## Features

- Reads NVIDIA VRR state through NVAPI.
- Reports the separate `enabled`, `requested`, and `display in VRR mode` flags.
- Estimates refresh rate using NVAPI AdaptiveSync flip timestamp and refresh-count data.
- Provides a compact live **Watch** mode and a newline-based **Log** mode.
- Exports Log-mode samples to a timestamped CSV file.
- Uses a JSON configuration file for the target display and sampling behavior.
- Loads `nvapi64.dll` from the Windows System32 directory using `LoadLibraryEx` with `LOAD_LIBRARY_SEARCH_SYSTEM32`.
- Does not require administrator privileges or install a background service.

## Requirements

- Windows 10 or Windows 11, 64-bit.
- 64-bit Windows PowerShell 5.1 (the primary tested environment).
- An NVIDIA GPU and installed NVIDIA display driver that exposes the NVAPI functions used by this tool.
- `nvapi64.dll` available in the Windows System32 directory.

PowerShell 7 may work, but has not yet been independently validated. Compatibility can vary with NVIDIA driver versions and NVAPI interface changes.

## Quick start

1. Download or clone this repository.
2. Copy `vrr-monitor.config.example.json` to `vrr-monitor.config.json`.
3. Edit `DisplayId` to the NVAPI display ID for the monitor you want to monitor. This is **not necessarily the same as the Windows display number**. The example value `0` is a placeholder and must be replaced.
4. Open a 64-bit PowerShell window in the project directory.
5. Run the monitor:

   ```powershell
   .\VrrMonitor.ps1
   ```

The default **Watch** mode redraws a compact status view. To collect a console history and CSV log instead:

```powershell
.\VrrMonitor.ps1 -Mode Log
```

Press `Ctrl+C` to stop either mode. Log mode writes a timestamped CSV beside the script, so separate runs do not overwrite one another.

### If PowerShell blocks script execution

Avoid changing the machine-wide execution policy just to run this utility. If you have reviewed the script and trust the copy you are running, you can temporarily allow scripts in the current PowerShell process:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\VrrMonitor.ps1
```

That setting applies only to the current PowerShell process and goes away when that PowerShell session closes. Execution policy is not a security boundary; only run scripts you trust.

## Configuration

The example configuration is:

```json
{
  "DisplayId": 0,
  "WindowSeconds": 5,
  "UpdateIntervalMs": 500,
  "PollIntervalMs": 1,
  "StartupDelaySeconds": 3,
  "LogFile": "vrr-monitor-log"
}
```

| Setting | Meaning |
|---|---|
| `DisplayId` | NVAPI display ID for the target monitor. Replace the example `0` with the correct ID. |
| `WindowSeconds` | Rolling time window used for the refresh-rate estimate. |
| `UpdateIntervalMs` | How often the console display is refreshed. |
| `PollIntervalMs` | Delay between NVAPI polls. A value of `1` is the current suggested starting point. |
| `StartupDelaySeconds` | Delay before sampling begins, allowing time to switch focus to the game. |
| `LogFile` | Base name used for timestamped CSV log files. |

The script expects `vrr-monitor.config.json` in its directory by default. You can supply another configuration path with `-ConfigPath`:

```powershell
.\VrrMonitor.ps1 -ConfigPath .\my-monitor.json
```

## Understanding the output

- **VRR ENGAGED**: the NVAPI `enabled`, `requested`, and `display in VRR mode` flags are all set.
- **VRR REQUESTED; DISPLAY FLAG OFF**: enabled and requested are set, but the display-in-VRR-mode flag is not.
- **DISPLAY VRR FLAG SET; NOT REQUESTED**: the display-mode flag is set while the requested flag is not.
- **VRR AVAILABLE; NOT ENGAGED**: the driver reports VRR as possible, but the engaged conditions are not all met.
- **VRR NOT AVAILABLE / INACTIVE**: the available flag is not set.
- **VRR STATUS UNKNOWN**: the VRR info API call failed.

### About the refresh-rate estimate

The displayed average and median are **estimates**, not direct measurements from the panel's timing controller. They are calculated from the observed interval between NVAPI flip timestamp changes and the associated `LastFlipRefreshCount` value. The interpretation and cadence may vary with driver behavior, display mode, application presentation behavior, and sampling conditions.

Treat the VRR state flags as the primary signal. A game pause, static frame, focus change, or other presentation behavior can affect flip updates; a stale flip timestamp by itself does not prove that VRR has stopped working.

## Security and implementation notes

- The embedded C# wrapper loads the NVAPI library from the full System32 path using `LoadLibraryEx` and `LOAD_LIBRARY_SEARCH_SYSTEM32`, rather than relying on the script or current working directory for DLL resolution.
- The script checks that it is running in a 64-bit PowerShell process.
- The monitor does not request elevation and should be run as a standard user.
- The script does not download or execute remote code.

## Compatibility and testing

This project uses NVAPI function IDs and structure layouts that are driver-facing interfaces. NVIDIA may change or restrict these interfaces in future drivers. The initial development and gaming-stability testing was performed on one Windows/NVIDIA/OLED setup; broader GPU, monitor, and driver compatibility is not yet established.

If you test it on another setup, please include your Windows version, PowerShell version, GPU, NVIDIA driver version, monitor model, and any relevant output when reporting an issue. Do not include personal configuration files or logs containing information you do not want to share.

## License

This project is licensed under the BSD 3-Clause License. See [LICENSE](LICENSE).
