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

**Tip: HUD settings are applied via environment variables and affect **newly launched** processes.**

## Mac Stats (beta)

Adds live Mac readings to the HUD in games: CPU/GPU usage, CPU/GPU temperature, fan speed, power, memory and thermal pressure.

1. Open the **Mac Stats** tab and tick the stats you want. Games that are already running update within a second.
2. Under **Steam**, click **Connect**. MetalHUDmenu adds itself to each installed game's launch options and keeps any options you already had. If Steam is open, it restarts once.
3. Launch a Steam game with the HUD on. Your stats appear under **State Reporters → Mac Stats**.

- When Steam opens and isn't connected, MetalHUDmenu asks once with a notification. Choose **Don't Ask Again** or untick **Ask when Steam opens** to stop it.
- New games are picked up each time Steam quits. Keep **Open at Login** on so this keeps working.
- **Disconnect** removes MetalHUDmenu from every game's launch options. A backup of Steam's config is kept next to it as `localconfig.vdf.metalhudmenu-backup`.
- Native Mac games through Steam are supported today. macOS 27 is recommended; macOS 26 support is experimental.
- Some games refuse outside libraries and won't show stats.



> All created with GPT5. 
