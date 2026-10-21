# Mac stats library

`libMHUDStats.dylib` adds live Mac readings (CPU/GPU usage, temperatures, fans, power, memory, thermal pressure) as rows in Apple's own Metal HUD. It draws nothing itself; Apple's HUD renders the rows.

## Files

| File | Purpose |
| --- | --- |
| `mhud_stats.mm` | The library: samples once per second and reports to the HUD. |
| `stats/` | Stat readers (host CPU ticks, IOReport, AppleSMC, VM stats). |
| `mhud-run` | Launch wrapper used by Steam launch options (`"<path>/mhud-run" %command%`). |
| `build.sh` | Builds the universal library and copies the wrapper. Xcode runs it as the "Build Mac Stats Library" phase. |

## How the app ships it

Xcode builds both files into the app's `Resources`. On launch, MetalHUDmenu copies them to a fixed location so launch options keep working if the app moves:

```
~/Library/Application Support/MetalHUDmenu/libMHUDStats.dylib
~/Library/Application Support/MetalHUDmenu/mhud-run
```

## Library behavior

- Universal binary: arm64 and x86_64 (Rosetta). Deployment target macOS 26.
- Needs no environment variables. Once loaded in a process, it stays idle until Apple's `libMTLHud.dylib` loads, then samples once per second on its own queue.
- Stat selection is read live from MetalHUDmenu's preferences: domain `com.Jfishin.MetalHUDmenu`, key `systemStats`, an array of these tokens:
  `cpuusage gpuusage cputemp gputemp fans systempower cpupower gpupower swap free inactive thermal`
  An empty or missing list shows nothing. Changes apply within a second.
- macOS 27 and later: reports through the public `SRStateReporter` API (domain `Mac Stats`). It adds `statereporter` to `MTL_HUD_EXTRA_ELEMENTS` and `Mac Stats` to `MTL_HUD_STATE_REPORTER_DOMAINS` for its own process, on top of the user's HUD rows. Apple's HUD sorts the rows by label.
- macOS 26: uses the private `_CADeveloperHUDProperties` label calls that DXMT uses. Every call is checked first, so a missing method does nothing. Not yet tested on a macOS 26 machine.
- Apps that only accept libraries signed by their own developer can't load it.

## Steam wrapper

`mhud-run` adds the library to the game it starts and keeps Steam's own overlay libraries (Steam's copy survives in `STEAM_DYLD_INSERT_LIBRARIES`). Steam passes `.app` games as a bundle path, which the wrapper opens with `open --env`.

## Debugging

- `MHUD_DEBUG=1` prints when sampling starts and each sample to stderr.
- `MHUD_SYSTEM_ELEMENTS=cpuusage,fans` overrides the preference list (handy for testing outside the app).
