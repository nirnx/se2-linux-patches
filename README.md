# Space Engineers 2 on Proton: ray tracing / DLSS and "Low Memory" fixes

Unofficial workarounds for two bugs that affect **Space Engineers 2** on Linux with Proton.
Neither Keen Software House nor the Proton, dxvk-nvapi or Wine projects made them or endorse them.

| Bug | Who is affected |
|---|---|
| [Ray tracing and DLSS are greyed out](#1-ray-tracing-and-dlss-are-greyed-out) | NVIDIA RTX cards |
| [False "Low Memory Detected" warning](#2-false-low-memory-detected-warning) | everyone on Proton |

The patcher finds the code to change by byte pattern, not by a list of game versions, so it
should keep working on future builds as long as Keen does not change that code. If the code is
not recognised, it changes nothing.

> The pink screen / loading hang from build 4.0.0.3151 was fixed by Keen in 4.0.0.3165.
> The old workaround is archived at
> [se2-proton-viewinstancing-fix](https://github.com/nirnx/se2-proton-viewinstancing-fix).

## Contents

- [How to use it](#how-to-use-it)
  - [Undo / check](#undo--check)
  - [Manual mode](#manual-mode)
- [1. Ray tracing and DLSS are greyed out](#1-ray-tracing-and-dlss-are-greyed-out)
- [2. False "Low Memory Detected" warning](#2-false-low-memory-detected-warning)
- [Notes](#notes)
- [License](#license)

## How to use it

**1.** Close the game. Open a terminal (on the Steam Deck: Desktop Mode → Konsole) and run:

```sh
curl -fsSL https://raw.githubusercontent.com/nirnx/se2-proton-fixes/main/se2-fix.sh | bash
```

**2.** In Steam, right-click **Space Engineers 2** → **Properties** → **General**, and put this in
**Launch Options**:

```
DOTNET_ReadyToRunExcludeList=VRage.Platform.Windows %command%
```

**3.** For ray tracing / DLSS on NVIDIA: **Properties** → **Compatibility** → select
**GE-Proton 11** (tested with GE-Proton11-11). It ships wine-nvml, which the fix needs. Proton
Experimental 11.0-20261014 does not.

Tested on build 4.0.0.3165 with an RTX 5090 (driver 615.78) and GE-Proton11-11.

### Undo / check

```sh
curl -fsSL https://raw.githubusercontent.com/nirnx/se2-proton-fixes/main/se2-fix.sh | bash -s -- --restore
curl -fsSL https://raw.githubusercontent.com/nirnx/se2-proton-fixes/main/se2-fix.sh | bash -s -- --status
```

### Manual mode

Download [`se2-fix.sh`](se2-fix.sh), read it if you like, and pass the game folder (the
`SpaceEngineers2` folder or its `Game2` subfolder):

```sh
bash se2-fix.sh /path/to/SpaceEngineers2
bash se2-fix.sh --status /path/to/SpaceEngineers2
bash se2-fix.sh --restore /path/to/SpaceEngineers2
```

Without a path, the script finds the game in your Steam libraries (native or Flatpak Steam).
It needs only bash, coreutils and grep.

## 1. Ray tracing and DLSS are greyed out

**Symptom.** On an RTX card, the ray tracing and DLSS options are greyed out. `Render12.log`
says:

```
Adapter 'NVIDIA GeForce RTX 5090' has 0 RTX cores
IsRayTracingSupported = False
```

**Cause.** The game enables ray tracing only when the GPU reports DXR 1.1 **and** NVAPI reports
more than 0 RTX cores. DLSS additionally needs ray tracing support. vkd3d-proton does report
DXR 1.1. The problem is the game's `NvApiWrapper.dll`:

1. It first calls `NvAPI_GPU_GetAllClockFrequencies` with `ClockType = BOOST`.
2. dxvk-nvapi (Proton's NVAPI) only implements `CURRENT` and returns `NVAPI_NOT_SUPPORTED` for
   any other clock type.
3. The wrapper then gives up before it asks for the RTX core count (`NvAPI_GPU_GetGPUInfo`), so
   the game sees 0 cores.

**Fix.** Two bytes in `NvApiWrapper.dll` change the requested clock type from `BOOST` to
`CURRENT`. dxvk-nvapi reads the current clock through NVML, so a Proton with wine-nvml is
needed (GE-Proton). With the fix, the log shows `76 RTX cores`, `IsRayTracingSupported = True`
and `DLSS: NGX runtime probe succeeded`.

The game also uses the clock to estimate the GPU's TFLOPS for its default quality preset. That
estimate now uses the current clock instead of the boost clock.

## 2. False "Low Memory Detected" warning

**Symptom.** The main menu shows "Low Memory Detected", no matter how much RAM and swap you have.
The game log says:

```
Swap configuration: none | pagefile can never reach 40799 MiB (attainable 0 MiB)
```

**Cause.** The warning is about the Windows pagefile, not RAM. The game reads the
`PagingFiles` registry value as `REG_MULTI_SZ` and wants a pagefile that can grow to
8 GB + VRAM. Wine stores that value as a plain `REG_SZ` (`C:\pagefile.sys 27 77`), so the game
finds no pagefile at all. Under Wine there is no pagefile anyway: memory is managed by Linux.

**Fix.** In `VRage.Platform.Windows.dll` the check becomes

```csharp
meetsRequirements = (attainable >= 8 GiB + vram) | CrashReporter.IsRunningWine();
```

On Windows the check is unchanged. `IsRunningWine()` is the game's own Wine detection, which
Keen already uses elsewhere. The patch is the same length as the original IL. To make room, it
drops a `Math.Max(0, vram)` call, which never changes the result.

This assembly ships precompiled (ReadyToRun), so the launch option is **required**. Without it
.NET runs the precompiled code and ignores the patch. It only makes .NET JIT this one assembly.

## Notes

- **Game updates and "Verify integrity of game files" replace the patched files.** Run the
  one-liner again after an update. A backup is only restored if it matches the current game
  build. If the code changed, the script skips that fix and changes nothing.
- To undo everything, run the undo command (or verify the game files in Steam) and remove the
  launch option.
- Once Keen (or dxvk-nvapi) fixes these bugs, stop using the patch. The script reports such a
  fix as "code not recognised".

## License

The script is MIT-licensed (see `LICENSE`). Space Engineers 2 and its files belong to Keen
Software House. This repository contains none of their files.
