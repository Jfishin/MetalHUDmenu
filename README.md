# MetalHUDmenu

![App Screenshot](pic.png)

A tiny macOS utility that configures Apple’s **Metal Performance HUD** system-wide. Toggle the HUD, pick elements (FPS, GPU time, memory, etc.), set opacity/scale, and place it on screen—without having to triple-click the HUD in-game.

---

## Features
- Enable/disable the Metal HUD
- Choose elements (e.g., FPS, GPU time, memory, thermal)
- Adjust **opacity** and **scale**
- Set **alignment** (top/center/bottom, left/center/right)
- “Set & forget” for all apps (newly launched apps inherit the settings)

## Requirements
- macOS 26 (Tahoe)

## Install
- Download the release `.zip`, extract, then:
  -  Right-click the app → **Open** → Error message will pop up, allow through System Settings > Privacy and security and hit allow at the bottom. 
## Usage
1. Open **MetalHUDmenu**.
2. Toggle **Enable Metal HUD**.
3. Pick HUD **Elements**, set **Opacity** and **Scale**.
4. Choose **Alignment**.
5. Click **Apply**

**Tip: HUD settings are applied via environment variables and affect **newly launched** processes.** Games started through the Mac Stats launch option, a pin, or a patched app always use your last **Apply**, even if their launcher (Steam, Heroic) was opened before it; other apps opened from a launcher that was already running keep the settings it started with until you restart that launcher.

## Mac Stats (beta)

Adds live Mac readings to the HUD in games: CPU/GPU usage and clocks, Neural Engine (ANE) usage, CPU/GPU temperature, fan speed, power, memory, memory pressure and thermal pressure.

1. Open the **Mac Stats** tab, turn on **Enable Mac Stats**, and tick the stats you want. Games with the helper already loaded update within a second.
2. Get the helper into the game one of three ways (all in the **Games** tab):
   - **Launch Option:** copy it and paste it into the game's launch options in your launcher. Steam: right-click the game → Properties → Launch Options (`"…/mhud-run" %command%`). Heroic and similar launchers: paste the wrapper path into the game's wrapper command.
   - **Pinned Apps:** pin a standalone app with **Pin App…**, or drop it on the menu bar icon or into the menu. Choose **Load Mac Stats on Launch…** in its menu so it loads Mac Stats however it is opened, or launch it from the pin each time.
   - **NotProton / CrossOver / other Wine:** connect the Wine runtime once (below).
3. Launch the game with the HUD on. On macOS 27 your stats appear in the HUD's **Custom Metrics** section, lined up with Apple's rows. Temperatures turn yellow at 65 °C and red at 85 °C, and memory and thermal pressure show their level in color; everything else stays white. If a macOS update changes that private HUD feature, the stats fall back to **State Reporters → Mac Stats** (white, indented) until MetalHUDmenu is updated.

- Older versions added the wrapper to every Steam game automatically. If yours did, **Games → Launch Option → Remove** takes it back out of every game (Steam restarts once if open; a backup of Steam's config is kept next to it as `localconfig.vdf.metalhudmenu-backup`).
- macOS 27 is recommended; macOS 26 support is experimental.
- A GOG game from Heroic that quits or crashes a few seconds in (DREDGE does) may be fighting Heroic's GOG Galaxy stand-in, Comet, with or without Mac Stats. Turning off Heroic → Settings → Experimental → Comet support fixes it, at the cost of Galaxy features such as achievements for GOG games.
- **Mac App Store apps are not supported.** Their signatures block outside libraries and can't be changed without breaking the app.
- Some other games refuse outside libraries too; see the pin warning below.
- **Sandboxed apps** (many emulators) can't read the sensors or MetalHUDmenu's settings. Keep MetalHUDmenu open: while a game's HUD is up, the app reads the sensors and hands the numbers to the game.
- **GPU usage** is the share of time the GPU is busy at any speed (the same as mactop). macmon's default view scales that by clock / max clock, and Stats reads a driver value that drops to 0 at light load, so both read much lower while a game keeps the GPU at a low clock. Add **GPU clock** to see that speed.
- **CPU temperature** is the hottest CPU core and **GPU temperature** the hottest GPU cluster, matching TG Pro on an M4 Max. Other chips show the average of the CPU sensors until their core sensors are verified.
- **ANE usage** is estimated from the Neural Engine's memory-bandwidth requests; its energy counter reads 0 on macOS 27. MetalFX upscaling is expected to run on the GPU, so ANE usage near 0 in a MetalFX game is plausible; the row lets you check.

### NotProton, CrossOver and other Wine runtimes

- **NotProton** appears only when its app and a runtime are installed. One runtime folder can serve **both ARM64/FEX and Rosetta**; the folder's `-fex` name does not mean Rosetta is missing.
- **Wine Runtimes → Add…** takes any Wine runtime: a CrossOver or Sikarugir app, a Heroic Wine folder, a Wine folder, or the `winemac.so` inside it. Connect checks the library's layout and that it has room, backs up the originals, and adds the helper to its Wine Mac graphics driver. One connection covers every game and bottle using that runtime; there is no per-bottle setup or environment variable.
- No version list: the patch fits CrossOver 24, 25, 26.2, 26.3 and 27 Preview, NotProton 27, Sikarugir wrappers and Gcenx Wine 11 / Staging builds. A library without room is refused and left unchanged. A runtime update replaces the patched file, so connect again after updating.
- **Restore** puts the original driver files back. Quit affected games first. Standalone backups live under `~/Library/Application Support/MetalHUDmenu/RuntimeBackups`; NotProton backups remain inside its runtime's `.metalhudmenu-backup` folder.
- Modifying a Wine app invalidates its outer resource signature until restored. The app warns before connecting. Only `winemac.so` is re-signed (ad hoc); Wine's loader keeps its signature and entitlements. Every loader checked either isn't hardened (Sikarugir, Gcenx Wine) or is CrossOver's, which already turns off library validation, so the helper loads without loosening anything. Confirmed in game with NotProton and a Sikarugir wrapper.
- A connected runtime also applies your HUD settings: some wrappers set `MTL_HUD_ENABLED=0` themselves (Sikarugir does when its own Metal HUD option is off), and the helper re-applies your last **Apply** as it loads, before Apple's HUD reads it.

### Pinned Apps

- **Games → Pin App…** selects a standalone Mac app or executable. Launch it from the menu-bar popover with the current HUD settings and stats helper. The pin's menu edits its name and literal arguments (one per line), or removes the pin without deleting the game.
- **Load Mac Stats on Launch…** in a pin's menu makes the app load Mac Stats every time it starts, from the Dock, Finder or Spotlight, with no pin launch or environment variable. It adds a weak reference to the helper in spare header space of the app's executable: nothing in the code moves, and a missing helper never stops the app from opening. A launch environment can't do this on its own, because hardened apps drop `DYLD_INSERT_LIBRARIES` and only a launch through the pin sets it.
- Before patching it keeps an APFS clone of the app under `~/Library/Application Support/MetalHUDmenu/LaunchPatches`, then re-signs the app on this Mac (ad hoc). Hardened apps also get `disable-library-validation` so they accept the helper; no DYLD exception is added. A green dot shows it's set. The app no longer carries its developer's signature, and an app update undoes the patch. **Stop Loading Mac Stats** swaps the original back and moves the patched copy to the Trash; it refuses if the app changed since (an update). If macOS blocks the change, allow MetalHUDmenu under Privacy & Security → App Management.
- A grey warning means the app can't be patched: a Mac App Store app (its permissions only work under Apple's signature, so it is never re-signed) or an executable with no spare header space. Launch it from the pin instead.
- Quit an already-running app before launching through its pin. Opening the game normally does not apply the pin's launch environment. Protected apps may reject helper injection; no app-signing protections are disabled.

The Mac Stats master toggle stops reporting without forgetting selected rows. Restart with it off for a clean launch without our reporter; a game started with it off may need restarting after enabling. Removing the Steam launch option does not disable an independently connected Wine runtime or unload a helper from an already-running game.



> All created with GPT5. 
