# wayfire-pi.sh

A terminal UI tool for adding — and safely removing — Wayfire compositor eye-candy on Raspberry Pi OS (Trixie). Pick a tier from plain and stock to full glass-and-wobbly-windows, save/restore your own look-and-feel presets, or nuke it all back to standard Pi OS if something goes wrong.

Built and tested on real Pi hardware (Zero 2W through Pi 5), with a strong bias toward not leaving your desktop in a broken state — every change is guarded, logged, and reversible.

![Bash](https://img.shields.io/badge/bash-5.x-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Raspberry%20Pi%20OS-Trixie-C51A4A?logo=raspberrypi&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## What this actually does

Pi OS Trixie ships with `labwc`, a lightweight Wayland window manager, and no compositor effects of any kind — no blur, no shadows, no transparency. `wayfire-pi.sh` is a menu-driven installer/configurator that switches your login session over to [Wayfire](https://github.com/WayfireWM/wayfire) (a Wayland compositor with a proper effects/plugin stack) and applies a curated, GPU-budget-aware set of visual effects on top of it — glass panel and titlebars, blur, shadows, animations, and at the top end wobbly windows and a rotating desktop cube.

You pick a **tier** based on how much GPU headroom your Pi has, and the script handles installing packages, building the one plugin that isn't packaged (`pixdecor`, for shadows/decorations), writing all the config files in the right places, and switching your login session — all from a `dialog`/`whiptail` text UI, no desktop session required to run it.

Everything it changes can be undone: a one-time snapshot of your system is taken automatically the first time you apply any tier, and a single menu option restores your Pi to exactly the state it was in before you ever ran this script.

## ⚠️ Before you run this

- **Trixie only.** This script assumes Raspberry Pi OS Trixie's default desktop stack (`labwc`, `wf-panel-pi`, LightDM + AccountsService session handling). Running it on Bookworm or any earlier release **will damage your desktop** — the config file layout and session handling it depends on don't match.
- **Run as your normal user, not root.** The script calls `sudo` itself for the specific steps that need it (package installs, session files) and will refuse to run under `sudo ./wayfire-pi.sh`.
- **Reboots are sometimes required.** Switching login sessions doesn't take effect until your next login/reboot — the script tells you when and offers to do it for you.

## Requirements

- Raspberry Pi OS **Trixie**, any supported Pi model
- `dialog` or `whiptail` (the script will tell you which to install if neither is present):
  ```bash
  sudo apt-get install dialog
  ```
- A user account with `sudo` access
- An internet connection (for package installs and building `pixdecor` on first run)

Everything else — Wayfire, `wf-shell`, `wcm`, the icon theme, the `pixdecor` build toolchain, `swaync`, `swayosd` — is installed automatically by the script the first time it's needed.

## Usage

```bash
git clone https://github.com/<your-username>/wayfire-pi.git
cd wayfire-pi
chmod +x wayfire-pi.sh
./wayfire-pi.sh
```

You'll get a one-time detection screen (Pi model, RAM, suggested tier), then the main menu:

```
1) Apply the suggested level
2) Apply minimal effects (Pi OS)
3) Ludicrous mode — apply everything
4) Help, my desktop is borked — back to standard Pi OS
5) Backup this look and feel
6) Apply a previously saved look and feel
```

The script detects your Pi model and RAM and recommends a tier automatically, but you're always free to pick any of the three directly.

## Modes

### 1. Minimal effects
Strips Wayfire out of the picture entirely — no compositor effects layer at all.
- Standard `labwc` (stock Pi OS window manager), no Wayfire
- Standard Pi OS panel and Pi menu
- Adwaita-dark GTK appearance with stock PiXtrix icons
- swaync (system notifications UI)
- Translucent title bars only — window *content* stays fully opaque
- No blur, no rounded corners, no glass
- Wayfire itself is left installed (just not the active session) so switching up to Average/Ludicrous later is instant

### 2. Average (recommended level)
The "suggested" tier, auto-picked based on detected Pi model/RAM. Switches the login session to Wayfire and turns on:
- MacTahoe GTK glass theme (falls back to Adwaita-dark + translucent titlebars if MacTahoe isn't available)
- `blur` plugin (kawase, 4 degrade / 3 iterations / 2 offset — lighter weight)
- Window alpha ~0.78 for glass look, snapping to fully opaque on fullscreen
- Window shadows if `wayfire-plugin-winshadows` is installed (radius 35, no glow)
- Open/close animations: zoom in, fade out

### 3. Ludicrous mode
Everything Average has, turned up, plus the extra eye-candy plugins:
- `wobbly`, `cube`, `fisheye`, `wrot` plugins enabled
- Heavier blur (kawase, 2 degrade / 5 iterations / 3 offset)
- Deeper shadows with glow enabled (radius 55)
- Close animation swapped from fade → fire
- Wobbly windows, rotate-cube desktop switching, fisheye zoom
- Intended for beefier Pis (Pi 5 with ≥4GB RAM) — heaviest on GPU

## Backups and reverting

`wayfire-pi.sh` keeps **two separate snapshot mechanisms**. They look similar but do different jobs — worth knowing the difference before you rely on either.

### The pristine snapshot — your undo button
- Automatic, invisible, and only ever taken **once** — the very first time you apply any tier — guarded by a marker file so it can't be overwritten
- Captures exactly what your system looked like *before wayfire-pi ever touched it*, including config files that didn't exist yet (so a revert deletes them again rather than leaving stray empty files)
- Restored by menu option **4, "Help, my desktop is borked — back to standard Pi OS"**
- Confirms with you first, then purges the Wayfire packages, reinstalls Pi OS's stock desktop packages, restores your original session config, and reboots

### Saved looks — your checkpoints
- Manual and repeatable — create as many as you like, under any name, via menu option **5, "Backup this look and feel"**
- Captures your *current, mid-session* config — whatever tier and tweaks you're on right now, including your panel/GTK theming and wallpaper — not the original pre-script state
- Restored via menu option **6, "Apply a previously saved look and feel"**, which lists everything you've saved
- Use this to hop between configs you've built and liked, without reverting all the way back to stock Pi OS

In short: the pristine snapshot gets you back to *before wayfire-pi existed on your system*; saved looks are checkpoints of configs *you* built while using it.

## Key bindings

| Effect | Keybind | Tier |
|---|---|---|
| Alpha (window transparency) | `Super` `Alt` + scroll | Average, Ludicrous |
| Wrot (rotate window) | `Ctrl` `Super` + right-click drag | Ludicrous only |
| Wrot 3D rotate | `Super` `Shift` + right-click drag | Ludicrous only |
| Wrot reset rotation | `Super` `R` | Ludicrous only |
| Cube (desktop cube) | `Super` `C` | Ludicrous only |

### Plugins enabled but using Wayfire's stock defaults

These are enabled in every tier's `plugins =` line (or added for winshadows/blur/wobbly/fisheye tiers), but this script doesn't set custom `activate =` binds for them — whatever's compiled into your Wayfire install or `wcm` defaults applies:

| Plugin | Typical default bind |
|---|---|
| `expo` | `Super` `E` |
| `scale` | `Super` `Tab` (Exposé-style window overview) |
| `switcher` / `fast-switcher` | `Alt` `Tab` |
| `grid` | `Super` + arrow keys (snap to grid positions) |
| `zoom` | `Super` + scroll |
| `vswitch` | `Ctrl` `Alt` + arrow keys (switch virtual desktops) |
| `move` / `resize` | `Alt` + left/right click drag |
| `fisheye` *(Ludicrous only)* | no default bind — toggle via `wcm` |

You can always customise any binding yourself in `wcm` (Wayfire Config Manager) once a Wayfire tier is active.

## Troubleshooting

- **Desktop looks broken / won't log in properly** → run the script again and pick option 4, "Help, my desktop is borked." It's designed for exactly this.
- **Neither `dialog` nor `whiptail` found** → `sudo apt-get install dialog`, then re-run.
- **First run to Average/Ludicrous is slow** → the script is compiling `pixdecor` from source the first time, since it isn't packaged for Pi OS. Subsequent runs are fast.
- **Script exits with "aborted (exit ...) at line ..."** → this is the script's own error trap; it means a command failed partway through rather than dying silently. Check `/tmp/wayfire-pi-*-build.log` for build-step failures, or open an issue with the reported line number.

## License

MIT — see [LICENSE](LICENSE).
