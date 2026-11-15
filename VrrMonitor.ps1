[CmdletBinding()]
param(
    [ValidateSet("Watch", "Log")]
    [string]$Mode = "Watch",

    [string]$ConfigPath = (Join-Path $PSScriptRoot "vrr-monitor.config.json")
)

$ErrorActionPreference = "Stop"

# Load user configuration.
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$displayId = [uint32]$config.DisplayId
$windowSeconds = [double]$config.WindowSeconds
$updateIntervalMs = [int]$config.UpdateIntervalMs
$pollIntervalMs = [int]$config.PollIntervalMs
$startupDelaySeconds = [int]$config.StartupDelaySeconds

if ($windowSeconds -le 0 -or $updateIntervalMs -lt 100 -or $pollIntervalMs -lt 0) {
    throw "Invalid config: WindowSeconds must be positive, UpdateIntervalMs at least 100, and PollIntervalMs nonnegative."
}

# Compile the embedded NVAPI wrapper once per PowerShell session.
if ($null -eq ("NvApiVrrMonitorPortable" -as [type])) {
    $source = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

public static class NvApiVrrMonitorPortable
{
    private const uint InitializeId = 0x0150E828;
    private const uint AdaptiveSyncId = 0xB73D1EE9;
    private const uint VrrInfoId = 0xDF8FDA57;
    private const uint LoadLibrarySearchSystem32 = 0x00000800;

    // Load NVAPI only from the Windows System32 directory. This avoids
    // resolving nvapi64.dll from the script or current working directory.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(
        string fileName, IntPtr fileHandle, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi,
        ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr GetProcAddress(
        IntPtr module, string procedureName);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr NvApiQueryInterface(uint id);

    private static IntPtr nvapiModule = IntPtr.Zero;
    private static NvApiQueryInterface queryInterface;

    private static IntPtr QueryInterface(uint id)
    {
        return queryInterface(id);
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvInitialize();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvGetAdaptiveSyncData(
        uint displayId, ref AdaptiveSyncData data);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvGetVrrInfo(
        uint displayId, ref VrrInfo data);

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct AdaptiveSyncData
    {
        public uint version;
        public uint maxFrameInterval;
        public uint flags;
        public uint lastFlipRefreshCount;
        public ulong lastFlipTimeStamp;
        public uint reserved0;
        public uint reserved1;
        public uint reserved2;
        public uint reserved3;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct VrrInfo
    {
        public uint version;
        public uint flags;
        public uint reserved0;
        public uint reserved1;
        public uint reserved2;
        public uint reserved3;
    }

    public class Sample
    {
        public int AdaptiveStatus { get; set; }
        public int VrrStatus { get; set; }
        public uint VrrFlags { get; set; }
        public uint MaxFrameInterval { get; set; }
        public uint AdaptiveFlags { get; set; }
        public uint LastFlipRefreshCount { get; set; }
        public ulong LastFlipTimeStamp { get; set; }
    }

    private static NvGetAdaptiveSyncData getAdaptive;
    private static NvGetVrrInfo getVrr;
    private static bool initialized;

    public static int Initialize()
    {
        if (initialized) return 0;

        if (IntPtr.Size != 8)
            throw new Exception("This monitor requires 64-bit PowerShell to load nvapi64.dll.");

        if (nvapiModule == IntPtr.Zero)
        {
            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string nvapiPath = Path.Combine(systemDirectory, "nvapi64.dll");
            nvapiModule = LoadLibraryEx(
                nvapiPath, IntPtr.Zero, LoadLibrarySearchSystem32);

            if (nvapiModule == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error,
                    "Could not load the NVIDIA NVAPI library from System32: " + nvapiPath);
            }

            IntPtr queryPtr = GetProcAddress(nvapiModule, "nvapi_QueryInterface");
            if (queryPtr == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error,
                    "nvapi_QueryInterface was not found in the System32 NVAPI library.");
            }

            queryInterface = (NvApiQueryInterface)Marshal.GetDelegateForFunctionPointer(
                queryPtr, typeof(NvApiQueryInterface));
        }

        IntPtr initPtr = QueryInterface(InitializeId);
        if (initPtr == IntPtr.Zero)
            throw new Exception("NvAPI_Initialize not found.");

        NvInitialize init =
            (NvInitialize)Marshal.GetDelegateForFunctionPointer(
                initPtr, typeof(NvInitialize));

        int status = init();
        if (status != 0) return status;

        IntPtr adaptivePtr = QueryInterface(AdaptiveSyncId);
        IntPtr vrrPtr = QueryInterface(VrrInfoId);

        if (adaptivePtr == IntPtr.Zero)
            throw new Exception("AdaptiveSync API not found.");

        if (vrrPtr == IntPtr.Zero)
            throw new Exception("VRR Info API not found.");

        getAdaptive =
            (NvGetAdaptiveSyncData)Marshal.GetDelegateForFunctionPointer(
                adaptivePtr, typeof(NvGetAdaptiveSyncData));

        getVrr =
            (NvGetVrrInfo)Marshal.GetDelegateForFunctionPointer(
                vrrPtr, typeof(NvGetVrrInfo));

        initialized = true;
        return 0;
    }

    public static Sample Read(uint displayId)
    {
        if (!initialized)
            throw new Exception("Call Initialize() first.");

        AdaptiveSyncData adaptive = new AdaptiveSyncData();
        adaptive.version =
            (uint)Marshal.SizeOf(typeof(AdaptiveSyncData)) | (1u << 16);

        VrrInfo vrr = new VrrInfo();
        vrr.version =
            (uint)Marshal.SizeOf(typeof(VrrInfo)) | (1u << 16);

        int adaptiveStatus = getAdaptive(displayId, ref adaptive);
        int vrrStatus = getVrr(displayId, ref vrr);

        return new Sample
        {
            AdaptiveStatus = adaptiveStatus,
            VrrStatus = vrrStatus,
            VrrFlags = vrr.flags,
            MaxFrameInterval = adaptive.maxFrameInterval,
            AdaptiveFlags = adaptive.flags,
            LastFlipRefreshCount = adaptive.lastFlipRefreshCount,
            LastFlipTimeStamp = adaptive.lastFlipTimeStamp
        };
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

# Initialize NVAPI and check the selected display.
$initStatus = [NvApiVrrMonitorPortable]::Initialize()
if ($initStatus -ne 0) {
    throw "NVAPI initialization failed with status $initStatus."
}

$initial = [NvApiVrrMonitorPortable]::Read($displayId)
if ($initial.VrrStatus -ne 0 -and $initial.AdaptiveStatus -ne 0) {
    throw "Both NVAPI reads failed. Check DisplayId in the config file."
}

$intervals = [System.Collections.Generic.List[object]]::new()
$logRows = [System.Collections.Generic.List[object]]::new()

$lastTimestamp = [uint64]0
$lastFlipAt = $null
$timer = $null

function Get-Median {
    param([double[]]$Values)

    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count

    if (($n % 2) -eq 1) {
        return [double]$sorted[[int][math]::Floor($n / 2)]
    }

    $middle = [int]($n / 2)
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-VrrState {
    param($Sample)

    if ($Sample.VrrStatus -ne 0) {
        return "VRR STATUS UNKNOWN"
    }

    $enabled = (($Sample.VrrFlags -band 0x01) -ne 0)
    $possible = (($Sample.VrrFlags -band 0x02) -ne 0)
    $requested = (($Sample.VrrFlags -band 0x04) -ne 0)
    $displayMode = (($Sample.VrrFlags -band 0x10) -ne 0)

    if ($enabled -and $requested -and $displayMode) {
        return "VRR ENGAGED"
    }
    if ($requested -and $enabled) {
        return "VRR REQUESTED; DISPLAY FLAG OFF"
    }
    if ($displayMode -and -not $requested) {
        return "DISPLAY VRR FLAG SET; NOT REQUESTED"
    }
    if ($possible) {
        return "VRR AVAILABLE; NOT ENGAGED"
    }
    return "VRR NOT AVAILABLE / INACTIVE"
}

Write-Host ""
Write-Host "Display ID: $displayId"
Write-Host "Mode: $Mode"
Write-Host "Switch to your game. Monitoring starts in $startupDelaySeconds seconds..."
Start-Sleep -Seconds $startupDelaySeconds

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$nextDisplay = 0.0
$latestSample = $initial
$logBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.LogFile)
$logPath = Join-Path $PSScriptRoot (
    "{0}-{1}.csv" -f $logBase, (Get-Date -Format "yyyyMMdd-HHmmss")
)

try {
    while ($true) {
        $sample = [NvApiVrrMonitorPortable]::Read($displayId)
        $now = $timer.Elapsed.TotalSeconds
        $latestSample = $sample

        # Record a new flip timestamp. FlipCount is treated as the number
        # of refreshes represented by that flip interval; this is an estimate.
        if ($sample.AdaptiveStatus -eq 0 -and
            $sample.LastFlipTimeStamp -ne 0) {

            if ($lastTimestamp -ne 0) {
                if ($sample.LastFlipTimeStamp -gt $lastTimestamp) {
                    $dtMs = ($now - $lastFlipAt) * 1000.0
                    $refreshCount = [double]$sample.LastFlipRefreshCount

                    if ($dtMs -gt 0 -and $dtMs -lt 1000 -and $refreshCount -gt 0) {
                        $estimatedHz = (1000.0 * $refreshCount) / $dtMs

                        $intervals.Add([pscustomobject]@{
                            At = $now
                            Hz = $estimatedHz
                            Refreshes = $refreshCount
                            IntervalMs = $dtMs
                        })
                    }
                }
                elseif ($sample.LastFlipTimeStamp -lt $lastTimestamp) {
                    # Timestamp reset/wrap: discard the current rate window.
                    $intervals.Clear()
                }
            }

            $lastTimestamp = $sample.LastFlipTimeStamp
            $lastFlipAt = $now
        }

        # Keep only the configured rolling window.
        while ($intervals.Count -gt 0 -and
               $intervals[0].At -lt ($now - $windowSeconds)) {
            $intervals.RemoveAt(0)
        }

        if ($now -ge $nextDisplay) {
            $state = Get-VrrState -Sample $sample

            $enabled = (($sample.VrrFlags -band 0x01) -ne 0)
            $requested = (($sample.VrrFlags -band 0x04) -ne 0)
            $displayMode = (($sample.VrrFlags -band 0x10) -ne 0)

            $meanHz = $null
            $medianHz = $null

            if ($intervals.Count -gt 0) {
                $totalRefreshes = (
                    $intervals | Measure-Object -Property Refreshes -Sum
                ).Sum
                $totalMs = (
                    $intervals | Measure-Object -Property IntervalMs -Sum
                ).Sum

                if ($totalMs -gt 0) {
                    $meanHz = 1000.0 * $totalRefreshes / $totalMs
                }

                $rates = [double[]]@($intervals | ForEach-Object { [double]$_.Hz })
                $medianHz = Get-Median -Values $rates
            }

            $flipAgeMs = $null
            if ($null -ne $lastFlipAt) {
                $flipAgeMs = ($now - $lastFlipAt) * 1000.0
            }

            if ($null -ne $meanHz) {
                $rateText = "Avg {0:N1} Hz / Median {1:N1} Hz" -f $meanHz, $medianHz
            }
            else {
                $rateText = "Rate: waiting for flip data"
            }

            if ($null -ne $flipAgeMs) {
                $ageText = "Last flip {0:N0} ms ago" -f $flipAgeMs
            }
            else {
                $ageText = "No flip data yet"
            }

            $line = "{0} | {1} | {2} | Enabled={3} Requested={4} DisplayMode={5}" -f `
                $state, $rateText, $ageText, $enabled, $requested, $displayMode

            if ($Mode -eq "Watch") {
                # Clear and redraw instead of writing carriage-return-only lines.
                # This avoids wrapped/stale text after resizing the terminal.
                Clear-Host
                Write-Host $line
                Write-Host ""
                Write-Host "Ctrl+C to stop. Five-second rolling window. Rate is an estimate."
            }
            else {
                # Log mode intentionally writes a complete newline-terminated line.
                $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                Write-Host "[$stamp] $line"

                $meanLog = $null
                $medianLog = $null
                $flipAgeLog = $null

                if ($null -ne $meanHz) { $meanLog = [math]::Round($meanHz, 2) }
                if ($null -ne $medianHz) { $medianLog = [math]::Round($medianHz, 2) }
                if ($null -ne $flipAgeMs) { $flipAgeLog = [math]::Round($flipAgeMs, 1) }

                $logRows.Add([pscustomobject]@{
                    LocalTime = $stamp
                    ElapsedSeconds = [math]::Round($now, 3)
                    VrrState = $state
                    VrrFlagsHex = ('0x{0:X2}' -f $sample.VrrFlags)
                    Enabled = $enabled
                    Requested = $requested
                    DisplayMode = $displayMode
                    MeanHz = $meanLog
                    MedianHz = $medianLog
                    FlipAgeMs = $flipAgeLog
                    FlipCount = $sample.LastFlipRefreshCount
                    AdaptiveStatus = $sample.AdaptiveStatus
                    VrrStatus = $sample.VrrStatus
                })
            }

            $nextDisplay = $now + ($updateIntervalMs / 1000.0)
        }

        if ($pollIntervalMs -gt 0) {
            Start-Sleep -Milliseconds $pollIntervalMs
        }
    }
}
finally {
    if ($null -ne $timer) { $timer.Stop() }

    if ($Mode -eq "Log" -and $logRows.Count -gt 0) {
        $logRows | Export-Csv -LiteralPath $logPath -NoTypeInformation
        Write-Host ""
        Write-Host "Saved $($logRows.Count) log records to:"
        Write-Host $logPath
    }
    elseif ($Mode -eq "Log") {
        Write-Host "No log records were collected."
    }

    if ($Mode -eq "Watch") {
        Write-Host ""
        Write-Host "Monitoring stopped."
    }
}
