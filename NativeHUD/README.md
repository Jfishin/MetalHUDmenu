# Mac stats library

`libMHUDStats.dylib` adds live Mac readings (CPU/GPU usage and clocks, ANE usage, temperatures, fans, power, memory, thermal pressure) as rows in Apple's own Metal HUD. It draws nothing itself; Apple's HUD renders the rows.

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
  `cpuusage cpuclock cputemp cpupower gpuusage gpuclock gputemp gpupower aneusage mempressure swap free inactive systempower thermal fans`
  An empty or missing list shows nothing. Changes apply within a second. The list lives only in `mhud_stats.mm`; the app reads it through the exported `mhud_catalog()` (`token\tlabel\tgroup` lines).
- MetalHUDmenu also loads the library and calls `mhud_publisher_start()`. Each game's helper posts `com.Jfishin.MetalHUDmenu.stats.client` every second; while those arrive, the app samples with its own preferences and publishes the rows as notify states (`…stats.<token>` = row count, `…stats.<token>.<n>` = status and value, `…stats.stamp` = time). A game uses published rows that are at most 3 s old and otherwise samples itself. This is what makes sandboxed games work: the App Sandbox blocks AppleSMC, IOReport and other apps' preferences, but allows reading notify state and posting notifications. `MHUD_SYSTEM_ELEMENTS` always samples in-process.
- Clocks: IOReport `CPU Complex Performance States` (`V<i>P<j>` → table index i) and `GPU Performance States` (`P<i>`), weighted by residency, with tables from the `pmgr` IORegistry entry (`voltage-states1-sram` E-cores, `voltage-states5-sram` P-cores, `voltage-states9` GPU; values ≥ 1e8 are Hz, smaller ones kHz). A state outside its table shows Unavailable rather than a guess.
- Memory pressure: `100 - kern.memorystatus_level` (the free percentage `memory_pressure` prints) plus `kern.memorystatus_vm_pressure_level` (1 Normal, 2 Warning, 4 Critical), as Activity Monitor uses. Free RAM is `free_count` pages from `HOST_VM_INFO64`; free + inactive adds `inactive_count` pages.
- Status is spelled out in text ("21% Normal") as well as colored, so the State Reporters fallback, which is sorted and white, still reads well.
- Temperatures: AppleSMC `flt` keys, ignoring implausible values and the exact 40.0 that power-gated clusters report. CPU is the hottest of the chip's per-core keys, the same sensors and value TG Pro shows as its hottest core (verified on M4 Max: `Te05 Te0S Tp01 Tp09 Tp0H Tp0P Tp0X Tp1j Tp1t Tp1z Tp25 Tp2B`); chips without a verified list use the mean of `Tp*`/`Te*`, because a max there picks hotspot keys 5-25 C hotter. GPU is the hottest `Tg*` key. (M3 places some sensors in `Tf*` keys, not yet read.)
- ANE usage: the highest share of time any PMP `*Floor` channel named `ANE…` spends above its lowest step (`VMIN`, `F1`). Energy Model `ANE` reads 0 on macOS 27 even under load.
- `systemStatsEnabled` is the independent master switch (missing means true for migration). False skips sampling and clears the active state. False at process startup also skips reporter environment additions and registration. The library remains mapped; macOS 27 exposes no reporter unregister API.
- macOS 27 and later: draws rows through Apple's private custom-metric API, `MTLHUDService` (`insertMetric:after:name:unit:nameColor:valueColor:visualType:options:`, `updateLabelMetric:label:`, `updateMetricColor:nameColor:valueColor:`, `removeMetric:`; colors are `0xAABBGGRR`), the API D3DMetal and DXMT use. Rows appear flush and in catalog order under "Custom Metrics"; only temperatures and memory/thermal pressure are colored. That section needs the HUD's `client` element, which the library adds to `MTL_HUD_EXTRA_ELEMENTS` (so translation layers' own custom rows can show there too). The class, the exact method signature, the other selectors and the `client` element are checked once, two seconds after Apple's HUD loads.
- Fallback: if any of those checks fail, it reports through the public `SRStateReporter` API (domain `Mac Stats`) instead, with `statereporter` and `Mac Stats` added to `MTL_HUD_EXTRA_ELEMENTS` / `MTL_HUD_STATE_REPORTER_DOMAINS`. Those rows are white, indented under "Mac Stats", and sorted by label, which is why labels share a group prefix.
- macOS 26: uses the private `_CADeveloperHUDProperties` label calls that DXMT uses. Every call is checked first, so a missing method does nothing. Not yet tested on a macOS 26 machine.
- Apps that only accept libraries signed by their own developer can't load it.

## Steam wrapper

`mhud-run` adds the library to the game it starts and keeps Steam's own overlay libraries (Steam's copy survives in `STEAM_DYLD_INSERT_LIBRARIES`). Steam passes `.app` games as a bundle path, which the wrapper opens with `open --env`.

## Debugging

- `MHUD_DEBUG=1` prints when sampling starts and each sample to stderr, marked `published` or `local`.
- `MHUD_SYSTEM_ELEMENTS=cpuusage,fans` overrides the preference list (handy for testing outside the app).
- `MHUD_STATE_REPORTER=1` forces the State Reporters fallback, to check it after a macOS update. Debug output says `custom-metrics` or `state-reporter` per sample.

## Other launch connections

General app pins use `NSWorkspace.OpenConfiguration.environment`; executable pins use `Process.environment`. Both pass explicit current HUD settings and preserve existing injection lists without shell parsing. Other launchers (Steam, Heroic) run `mhud-run` from the launch option the person pastes in. Wine runtime connections add a weak `@loader_path/MHUD.dylib` dependency to hash-verified `winemac.so` files with sufficient zero header padding; the sibling link resolves to the stable installed helper. See the main README for signing and restoration limitations.
