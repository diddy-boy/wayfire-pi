#!/usr/bin/env bash
set -Eeuo pipefail

# This desktop configurator is design to run on Trixie ONLY
# Do not run on Pi OS Bookworm
# Otherwise this will damage your desktop

# Safety net: print where and why if anything ever kills the script
# unexpectedly, instead of dying silently (lesson learned the hard way
# building the previous labwc/wf-panel-pi version of this tool).
trap 'echo "wayfire-pi.sh: aborted (exit $?) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

WAYFIRE_PI_VERSION="0.1.0"

# Cache for the authoritative "is wayfire still in apt?" check, so a run
# only ever fires one `apt-get update` (and one possible sudo prompt) for
# this, no matter how many times ensure_wayfire_installed is called.
WAYFIRE_REPO_CHECKED=""
WAYFIRE_REPO_AVAILABLE=""

WAYFIRE_PI_HOME="${HOME}/.config/wayfire-pi"
LOOKS_DIR="${WAYFIRE_PI_HOME}/looks"
PRISTINE_DIR="${WAYFIRE_PI_HOME}/pristine"
STATE_FILE="${WAYFIRE_PI_HOME}/state"

WAYFIRE_CFG_DIR="${HOME}/.config"
WAYFIRE_INI="${WAYFIRE_CFG_DIR}/wayfire.ini"

# wf-panel (wf-shell) reads its panel/dock/background config from here —
# entirely separate file from wayfire.ini itself. Absent = wf-panel just
# falls back to its own built-in defaults (menu left, volume/network/clock
# right), which is the "before" state this file changes.
WF_SHELL_INI="${WAYFIRE_CFG_DIR}/wf-shell.ini"

# wf-panel-pi's config lives in a SUBDIRECTORY — ~/.config/wf-panel-pi/
# wf-panel-pi.ini — confirmed straight from the project's own README.
# ~/.config/wf-panel-pi.ini (a flat file, no subdirectory) was the wrong
# path used everywhere in this script previously, silently ignored the
# entire time regardless of what was in it. `background_color` is also
# confirmed DEAD — it's wrapped in `#if 0`/`#endif` in the actual
# panel.cpp source (a C preprocessor block meaning "don't compile
# this"), so it could never have worked either, wrong path or not.
# `css_path` is the real, live mechanism for panel appearance — see
# write_wf_panel_pi_glass below. `position`, `autohide`, and `layer`
# are all confirmed real/live options (defined in wf-autohide-window.cpp,
# a different source file, which is why they were easy to miss).
WF_PANEL_PI_DIR="${WAYFIRE_CFG_DIR}/wf-panel-pi"
WF_PANEL_PI_INI="${WF_PANEL_PI_DIR}/wf-panel-pi.ini"
WF_PANEL_PI_CSS="${WF_PANEL_PI_DIR}/panel-glass.css"

# labwc's own config dir — used by Minimal/Minimal Plus (no Wayfire).
LABWC_CFG_DIR="${HOME}/.config/labwc"
LABWC_RC="${LABWC_CFG_DIR}/rc.xml"
LABWC_AUTOSTART="${LABWC_CFG_DIR}/autostart"
LABWC_THEMERC_OVERRIDE="${LABWC_CFG_DIR}/themerc-override"

LIGHTDM_CONF="/etc/lightdm/lightdm.conf"

# Modern LightDM (what Pi OS Trixie ships) doesn't just read
# lightdm.conf's autologin-session/user-session fresh every boot — once
# you've actually logged into a session, it remembers it per-user here,
# and THAT takes priority over lightdm.conf on the next boot. Confirmed
# by hand: without also touching this file, switching lightdm.conf back
# to the Pi OS session isn't enough — the Pi still boots into Wayfire.
ACCOUNTSSERVICE_USER_FILE="/var/lib/AccountsService/users/$(id -un)"

UI_BIN=""

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

bootstrap_ui() {
    if command -v dialog >/dev/null 2>&1; then
        UI_BIN="dialog"
        return 0
    fi
    if command -v whiptail >/dev/null 2>&1; then
        UI_BIN="whiptail"
        return 0
    fi
    echo "Neither 'dialog' nor 'whiptail' is installed. Install one and try again:" >&2
    echo "  sudo apt-get install dialog" >&2
    exit 1
}

ui() {
    "$UI_BIN" "$@"
}

# write_wf_panel_pi_glass <r> <g> <b> <a> — the ONE place panel
# translucency gets configured, used by both Minimal and Average/
# Ludicrous so there's no risk of the two drifting apart again.
# Writes a small CSS file targeting the panel window by its actual GTK
# widget name (window->set_name("PanelToplevel") in panel.cpp — hence
# the #PanelToplevel selector), then points wf-panel-pi.ini's
# css_path at it. This is the real, confirmed-live mechanism —
# background_color is dead code, see the comment on WF_PANEL_PI_INI
# above for the full story.
write_wf_panel_pi_glass() {
    local r="$1" g="$2" b="$3" a="$4"
    mkdir -p "$WF_PANEL_PI_DIR"

    cat > "$WF_PANEL_PI_CSS" <<EOF
#PanelToplevel {
    background-color: rgba(${r}, ${g}, ${b}, ${a});
}

/* Necessary but not sufficient on its own: child containers (the
   left/right/center widget boxes) paint their own opaque background
   from the active GTK theme, right on top of the rule above, unless
   explicitly told not to. */
#PanelToplevel * {
    background-color: transparent;
    background-image: none;
}
EOF

    cat > "$WF_PANEL_PI_INI" <<EOF
[panel]
autohide = false
position = top
css_path = ${WF_PANEL_PI_CSS}
widgets_left = smenu spacing4 window-list
widgets_right = tray power ejecter updater spacing2 bluetooth spacing2 netman spacing2 volumepulse spacing2 clock spacing2 batt spacing2 cputemp cpu
clock_format = %e %a %H:%M
battery_status = 1
EOF
}

# install_power_menu_shortcuts — standard XDG .desktop entries for
# Shutdown / Restart / Log Out under ~/.local/share/applications, which
# every spec-compliant menu (including smenu) picks up automatically.
# Plain `systemctl poweroff`/`reboot`, no sudo — confirmed working
# directly on hardware. (An earlier version of this routed through sudo
# on a polkit-agent theory; that turned out to be wrong in practice —
# most likely GUI-launched sudo has no terminal/askpass to satisfy even
# a passwordless rule cleanly, whereas plain systemctl just works here.)
install_power_menu_shortcuts() {
    local apps_dir="${HOME}/.local/share/applications"
    mkdir -p "$apps_dir"

    cat > "${apps_dir}/wayfire-pi-shutdown.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Shutdown
Comment=Power off the Pi
Exec=systemctl poweroff
Icon=system-shutdown
Categories=System;
EOF

    cat > "${apps_dir}/wayfire-pi-restart.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Restart
Comment=Reboot the Pi
Exec=systemctl reboot
Icon=system-reboot
Categories=System;
EOF

    cat > "${apps_dir}/wayfire-pi-logout.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Log Out
Comment=End the current desktop session
Exec=loginctl terminate-user $(id -un)
Icon=system-log-out
Categories=System;
EOF
}

# ---------------------------------------------------------------------------
# State helpers — every read is guarded against "key not found" (a grep
# with no match exits 1, which under pipefail + set -e is fatal unless
# explicitly guarded) and every write treats an existing-but-empty file
# the same as a missing one (GNU sed's line-addressed inserts are a
# silent no-op on a truly empty file).
# ---------------------------------------------------------------------------

get_state() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

set_state() {
    local key="$1" value="$2"
    mkdir -p "$WAYFIRE_PI_HOME"
    if [[ ! -s "$STATE_FILE" ]]; then
        printf '%s=%s\n' "$key" "$value" > "$STATE_FILE"
        return 0
    fi
    if grep -q "^${key}=" "$STATE_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Pi model / RAM detection and tier recommendation
# ---------------------------------------------------------------------------

detect_pi_model() {
    if [[ -r /proc/device-tree/model ]]; then
        tr -d '\0' < /proc/device-tree/model 2>/dev/null || true
    fi
}

detect_ram_mb() {
    awk '/^MemTotal:/ { print int($2/1024); exit }' /proc/meminfo 2>/dev/null || true
}

recommend_tier() {
    local model ram tier
    model=$(detect_pi_model)
    ram=$(detect_ram_mb)
    ram="${ram:-0}"

    case "$model" in
        *"Raspberry Pi 5"*)
            if (( ram >= 4096 )); then
                tier="ludicrous"
            else
                tier="recommended"
            fi
            ;;
        *"Raspberry Pi 4"*)
            if (( ram >= 4096 )); then
                tier="recommended"
            else
                tier="minimal"
            fi
            ;;
        *"Raspberry Pi 400"*)
            tier="recommended"
            ;;
        *"Zero 2"*)
            tier="minimal"
            ;;
        *"Raspberry Pi 3"*|*"Zero"*)
            tier="minimal"
            ;;
        *)
            tier="recommended"
            ;;
    esac

    # Future-proofing: don't recommend a Wayfire tier we probably can't
    # deliver. Cheap/no-sudo check only — this is just for the menu
    # hint, the real gate is ensure_wayfire_installed at apply time.
    # Minimal Plus (enhanced labwc, no Wayfire) is the soft landing here
    # rather than dropping straight to bare Minimal.
    if [[ "$tier" != "minimal" ]] && ! wayfire_installed && ! wayfire_likely_available; then
        tier="minimal_plus"
    fi

    echo "$tier"
}

tier_label() {
    case "$1" in
        minimal) echo "Minimal" ;;
        minimal_plus) echo "Minimal Plus" ;;
        recommended) echo "Average" ;;
        ludicrous) echo "Ludicrous mode" ;;
        *) echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Wayfire / wf-shell install
# ---------------------------------------------------------------------------

wayfire_installed() {
    command -v wayfire >/dev/null 2>&1
}

wf_panel_installed() {
    command -v wf-panel >/dev/null 2>&1 || command -v wf-shell >/dev/null 2>&1
}

winshadows_available() {
    apt-cache show wayfire-plugin-winshadows >/dev/null 2>&1
}

# Cheap, no-sudo, no-network probe against whatever's already in apt's
# local cache. Good enough for menu hints/recommendations — it can be
# stale, but it never blocks or prompts for a password just to draw a
# menu. The authoritative check is wayfire_available_in_repos() below.
wayfire_likely_available() {
    apt-cache show wayfire >/dev/null 2>&1
}

# Authoritative check: forces a fresh `apt-get update` then asks apt
# directly whether it has an installation candidate for wayfire. This is
# the check that actually decides whether we attempt install_wayfire.
#
# Raspberry Pi OS has been signalling that Wayfire won't be carried
# forward indefinitely, so at some point this will correctly come back
# "no" on an up-to-date Trixie system — that's expected, not a bug, and
# is exactly the case Minimal mode (stock labwc) exists to cover.
#
# Cached per run (see WAYFIRE_REPO_CHECKED above) so repeated calls don't
# re-run apt-get update.
wayfire_available_in_repos() {
    if [[ -n "$WAYFIRE_REPO_CHECKED" ]]; then
        [[ "$WAYFIRE_REPO_AVAILABLE" == "yes" ]]
        return
    fi
    WAYFIRE_REPO_CHECKED="yes"

    sudo apt-get update -qq >/dev/null 2>&1 || true

    if apt-cache policy wayfire 2>/dev/null | grep -q '^  Candidate: (none)'; then
        WAYFIRE_REPO_AVAILABLE="no"
    elif apt-cache show wayfire >/dev/null 2>&1; then
        WAYFIRE_REPO_AVAILABLE="yes"
    else
        WAYFIRE_REPO_AVAILABLE="no"
    fi

    [[ "$WAYFIRE_REPO_AVAILABLE" == "yes" ]]
}

install_wayfire() {
    local pkgs=(wayfire wf-shell wcm papirus-icon-theme git)
    if winshadows_available; then
        pkgs+=(wayfire-plugin-winshadows)
    fi

    ui --title "wayfire-pi" --infobox "Installing Wayfire and friends — this can take a few minutes on first run..." 6 60
    sleep 1

    if ! sudo apt-get update -qq; then
        ui --title "wayfire-pi" --msgbox "apt-get update failed. Check your network connection and try again." 8 60
        return 1
    fi
    if ! sudo apt-get install -y "${pkgs[@]}"; then
        ui --title "wayfire-pi" --msgbox "Installing ${pkgs[*]} failed. Check the terminal output above for details." 9 60
        return 1
    fi
    return 0
}

# Returns:
#   0 — wayfire (+ wf-shell) is installed and ready to use
#   1 — not installed, and the user declined, or the install attempt failed
#   2 — not installed, and it's no longer available from apt at all
ensure_wayfire_installed() {
    if wayfire_installed && wf_panel_installed; then
        return 0
    fi

    if ! wayfire_available_in_repos; then
        ui --title "wayfire-pi" --msgbox \
"Wayfire is no longer available from apt on this system.

Raspberry Pi OS has dropped Wayfire from its repositories, so Average and \
Ludicrous mode can't be installed here. wayfire-pi.sh deliberately doesn't \
fall back to fetching it from Debian or upstream instead — mixing package \
sources like that is a fast road to dependency hell and library-version \
clashes.

Minimal mode (stock labwc, no Wayfire) doesn't depend on Wayfire at all \
and will keep working. Check the wayfire-pi GitHub/Hackaday page for any \
future updates." \
            18 70
        return 2
    fi

    if ! ui --title "wayfire-pi" --yesno "Wayfire isn't installed yet.\n\nInstall wayfire + wf-shell now? This uses sudo apt-get and needs a network connection." 10 60; then
        return 1
    fi
    install_wayfire
}

# ---------------------------------------------------------------------------
# wayfire.ini generation
# ---------------------------------------------------------------------------

backup_pristine_once() {
    [[ -f "${PRISTINE_DIR}/.snapshot-complete" ]] && return 0
    mkdir -p "$PRISTINE_DIR"
    if [[ -f "$WAYFIRE_INI" ]]; then
        cp -a "$WAYFIRE_INI" "${PRISTINE_DIR}/wayfire.ini.orig"
        echo "existed" > "${PRISTINE_DIR}/wayfire.ini.state"
    else
        echo "absent" > "${PRISTINE_DIR}/wayfire.ini.state"
    fi
    if [[ -f "$WF_SHELL_INI" ]]; then
        cp -a "$WF_SHELL_INI" "${PRISTINE_DIR}/wf-shell.ini.orig"
        echo "existed" > "${PRISTINE_DIR}/wf-shell.ini.state"
    else
        echo "absent" > "${PRISTINE_DIR}/wf-shell.ini.state"
    fi
    if [[ -f "$LIGHTDM_CONF" ]]; then
        sudo cp -a "$LIGHTDM_CONF" "${PRISTINE_DIR}/lightdm.conf.orig"
        sudo chown "$(id -u)":"$(id -g)" "${PRISTINE_DIR}/lightdm.conf.orig"
    fi
    if [[ -f "$ACCOUNTSSERVICE_USER_FILE" ]]; then
        sudo cp -a "$ACCOUNTSSERVICE_USER_FILE" "${PRISTINE_DIR}/accountsservice.orig"
        sudo chown "$(id -u)":"$(id -g)" "${PRISTINE_DIR}/accountsservice.orig"
        echo "existed" > "${PRISTINE_DIR}/accountsservice.state"
    else
        echo "absent" > "${PRISTINE_DIR}/accountsservice.state"
    fi
    touch "${PRISTINE_DIR}/.snapshot-complete"
}

find_wayfire_session_name() {
    local f
    for f in /usr/share/wayland-sessions/wayfire.desktop /usr/share/wayland-sessions/*[Ww]ayfire*.desktop; do
        if [[ -f "$f" ]]; then
            basename "$f" .desktop
            return 0
        fi
    done
    return 1
}

find_pios_session_name() {
    local f
    for f in /usr/share/wayland-sessions/*.desktop; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f" .desktop)
        [[ "$base" == *[Ww]ayfire* ]] && continue
        echo "$base"
        return 0
    done
    return 1
}

ensure_autologin_user() {
    local user="$1"
    if sudo grep -q '^autologin-user=' "$LIGHTDM_CONF" 2>/dev/null; then
        sudo sed -i "s|^autologin-user=.*|autologin-user=${user}|" "$LIGHTDM_CONF"
    elif sudo grep -q '^#autologin-user=' "$LIGHTDM_CONF" 2>/dev/null; then
        sudo sed -i "s|^#autologin-user=.*|autologin-user=${user}|" "$LIGHTDM_CONF"
    fi
    if sudo grep -q '^autologin-user-timeout=' "$LIGHTDM_CONF" 2>/dev/null; then
        sudo sed -i "s|^autologin-user-timeout=.*|autologin-user-timeout=0|" "$LIGHTDM_CONF"
    elif sudo grep -q '^#autologin-user-timeout=' "$LIGHTDM_CONF" 2>/dev/null; then
        sudo sed -i "s|^#autologin-user-timeout=.*|autologin-user-timeout=0|" "$LIGHTDM_CONF"
    fi
}

get_lightdm_session() {
    [[ -f "$LIGHTDM_CONF" ]] || return 0
    grep -m1 '^autologin-session=' "$LIGHTDM_CONF" 2>/dev/null | cut -d= -f2- || true
}

set_lightdm_session() {
    local session="$1"
    sudo sed -i \
        -e "s|^autologin-session=.*|autologin-session=${session}|" \
        -e "s|^user-session=.*|user-session=${session}|" \
        "$LIGHTDM_CONF"
}

restore_lightdm_session() {
    [[ -f "${PRISTINE_DIR}/lightdm.conf.orig" ]] || return 0
    sudo cp -a "${PRISTINE_DIR}/lightdm.conf.orig" "$LIGHTDM_CONF"
}

set_accountsservice_session() {
    local session="$1"
    sudo mkdir -p "$(dirname "$ACCOUNTSSERVICE_USER_FILE")"
    if [[ ! -f "$ACCOUNTSSERVICE_USER_FILE" ]]; then
        printf '[User]\n' | sudo tee "$ACCOUNTSSERVICE_USER_FILE" >/dev/null
    fi
    if sudo grep -q '^Session=' "$ACCOUNTSSERVICE_USER_FILE" 2>/dev/null; then
        sudo sed -i "s|^Session=.*|Session=${session}|" "$ACCOUNTSSERVICE_USER_FILE"
    else
        printf 'Session=%s\n' "$session" | sudo tee -a "$ACCOUNTSSERVICE_USER_FILE" >/dev/null
    fi
    if sudo grep -q '^XSession=' "$ACCOUNTSSERVICE_USER_FILE" 2>/dev/null; then
        sudo sed -i "s|^XSession=.*|XSession=${session}|" "$ACCOUNTSSERVICE_USER_FILE"
    else
        printf 'XSession=%s\n' "$session" | sudo tee -a "$ACCOUNTSSERVICE_USER_FILE" >/dev/null
    fi
}

restore_accountsservice_session() {
    local state
    state=$(cat "${PRISTINE_DIR}/accountsservice.state" 2>/dev/null || echo "absent")
    if [[ "$state" == "existed" ]]; then
        sudo cp -a "${PRISTINE_DIR}/accountsservice.orig" "$ACCOUNTSSERVICE_USER_FILE"
    else
        sudo rm -f "$ACCOUNTSSERVICE_USER_FILE"
    fi
}

build_wayfire_ini() {
    local tier="$1"

    local plugins="alpha animate autostart command expo fast-switcher grid idle move oswitch place resize scale switcher vswitch window-rules wm-actions zoom gtk-shell wayfire-shell"

    local have_winshadows="no"
    dpkg -s wayfire-plugin-winshadows >/dev/null 2>&1 && have_winshadows="yes"

    plugins="${plugins} decoration"

    [[ "$have_winshadows" == "yes" ]] && \
        plugins="${plugins} winshadows"

    if [[ "$tier" == "recommended" || "$tier" == "ludicrous" ]]; then
        plugins="${plugins} blur"
    fi

    if [[ "$tier" == "ludicrous" ]]; then
        plugins="${plugins} wobbly cube fisheye wrot"
    fi

    mkdir -p "$WAYFIRE_CFG_DIR"

    {
        echo "[core]"
        echo "plugins = ${plugins}"
        echo "preferred_decoration_mode = server"
        echo ""

        echo "[input]"
        echo "click_method = default"
        echo "tap_to_click = true"
        echo "tap_and_drag = true"
        echo "scroll_method = two_finger"
        echo "natural_scroll = false"
        echo ""

        echo "[window-rules]"

        if [[ "$tier" == "recommended" ]]; then
            echo "glass_windows = on created if type is \"toplevel\" then set alpha 0.78"
            echo "glass_fullscreen = on fullscreened if type is \"toplevel\" then set alpha 1.0"
            echo "glass_unfullscreen = on unfullscreened if type is \"toplevel\" then set alpha 0.78"
        else
            # Nudged up from 0.80 for titlebar text readability (per
            # request) — kept modest rather than pushing it close to
            # 0.86, which is confirmed to cross back into "not visibly
            # different from opaque" territory on this same mechanism.
            echo "glass_windows = on created if type is \"toplevel\" then set alpha 0.90"
            echo "glass_fullscreen = on fullscreened if type is \"toplevel\" then set alpha 1.0"
            echo "glass_unfullscreen = on unfullscreened if type is \"toplevel\" then set alpha 0.90"
        fi

        echo ""

        echo "[decoration]"
        echo "title_height = 28"
        echo "border_size = 1"
        echo "active_color = 0.12 0.12 0.18 0.82"
        echo "inactive_color = 0.12 0.12 0.18 0.42"
        echo ""

        if [[ "$have_winshadows" == "yes" ]]; then
            echo "[winshadows]"

            case "$tier" in
                recommended)
                    echo "shadow_radius = 35"
                    echo "glow_enabled = false"
                    ;;
                ludicrous)
                    echo "shadow_radius = 55"
                    echo "glow_enabled = true"
                    ;;
            esac

            echo ""
        fi

        if [[ "$tier" == "recommended" || "$tier" == "ludicrous" ]]; then
            echo "[blur]"

            if [[ "$tier" == "ludicrous" ]]; then
                echo "method = kawase"
                echo "kawase_degrade = 2"
                echo "kawase_iterations = 5"
                echo "kawase_offset = 3"
            else
                echo "method = kawase"
                echo "kawase_degrade = 4"
                echo "kawase_iterations = 3"
                echo "kawase_offset = 2"
            fi

            echo ""
        fi

        echo "[alpha]"
        echo "min_value = 0.50"
        echo "modifier = <super> <alt>"
        echo ""

        echo "[animate]"
        echo "duration = 300"

        if [[ "$tier" == "ludicrous" ]]; then
            echo "open_animation = zoom"
            echo "close_animation = fire"
        else
            echo "open_animation = zoom"
            echo "close_animation = fade"
        fi

        echo ""

        if [[ "$tier" == "ludicrous" ]]; then

            echo "[wobbly]"
            echo "friction = 3.0"
            echo "spring_k = 8.0"
            echo "grid_resolution = 12"
            echo ""

            echo "[wrot]"
            echo "activate = <ctrl> <super> BTN_RIGHT"
            echo "activate_3d = <super> <shift> BTN_RIGHT"
            echo "reset = <super> KEY_R"
            echo ""

            echo "[cube]"
            echo "activate = <super> KEY_C"
            echo ""
        fi

        echo "[autostart]"

        if command -v wf-panel-pi >/dev/null 2>&1; then
            echo "panel = wf-panel-pi"
        else
            echo "panel = wf-panel"
        fi

        if command -v pcmanfm >/dev/null 2>&1; then
            ensure_pcmanfm_desktop_icons
            echo "background = env GDK_BACKEND=wayland pcmanfm --desktop --profile=LXDE-pi"
        fi

    } > "$WAYFIRE_INI"

    if command -v wf-panel-pi >/dev/null 2>&1; then
        if [[ "$tier" == "ludicrous" ]]; then
            write_wf_panel_pi_glass 20 20 30 0.48
        else
            write_wf_panel_pi_glass 20 20 30 0.58
        fi
    fi
}

build_wf_shell_ini() {
    # This is the plain-upstream-wf-panel config — apply_tier only calls
    # this when wf-panel-pi ISN'T installed (see the
    # `[[ "$(command -v wf-panel-pi)" ]] || build_wf_shell_ini` guard
    # there), so the wf-panel-pi check below is currently always false
    # in practice and menu_widget always ends up "menu". Left in as a
    # belt-and-braces guard in case this function is ever called from
    # somewhere else in future. "smenu" — wf-panel-pi's Raspberry-branded
    # start menu widget that bundles a Shutdown entry (confirmed straight
    # from Pi OS's own default wf-panel-pi.ini, which uses "... clock
    # smenu ...") — doesn't exist on plain wf-panel anyway, hence the
    # fallback. "menu" is wf-shell's generic, unbranded XDG app list — no
    # Shutdown/Reboot/Logout on it, which is what
    # install_power_menu_shortcuts' .desktop entries exist to cover.
    local menu_widget="menu"
    command -v wf-panel-pi >/dev/null 2>&1 && menu_widget="smenu"

    {
        echo "[panel]"
        echo "widgets_left = ${menu_widget} spacing4 window-list"
        echo "widgets_center = none"
        echo "widgets_right = tray notifications volume network battery clock"
        echo ""
        echo "clock_format = %e %a %H:%M"
        echo ""
        echo "battery_status = 1"
    } > "$WF_SHELL_INI"
}

GTK3_CFG_DIR="${HOME}/.config/gtk-3.0"
GTK4_CFG_DIR="${HOME}/.config/gtk-4.0"

# "LXDE-pi" is Pi OS's own pcmanfm profile name, where its desktop icon
# settings (and wallpaper) actually live — e.g.
# ~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf. `pcmanfm --desktop` with
# no --profile falls back to a profile literally called "default", which
# is a brand new, empty profile with none of that. That mismatch — not
# anything disabled on purpose — is why the Trash bin and any existing
# desktop shortcut were vanishing under Wayfire.
PCMANFM_DESKTOP_DIR="${HOME}/.config/pcmanfm/LXDE-pi"
GTK3_CSS="${GTK3_CFG_DIR}/gtk.css"
GTK4_CSS="${GTK4_CFG_DIR}/gtk.css"
GTK3_SETTINGS="${GTK3_CFG_DIR}/settings.ini"
GTK4_SETTINGS="${GTK4_CFG_DIR}/settings.ini"

# ensure_pcmanfm_desktop_icons — makes sure the Trash bin is switched on
# for the LXDE-pi desktop profile. If a real config already exists (from
# Pi OS itself, or a previous run of this script) it's left otherwise
# untouched — wallpaper and any existing desktop shortcut carry over as-is.
# Only if there's no config at all yet (e.g. a brand new Wayfire-only
# install that's never had the config created) does this writes a fresh
# minimal one.
ensure_pcmanfm_desktop_icons() {
    command -v pcmanfm >/dev/null 2>&1 || return 0
    mkdir -p "$PCMANFM_DESKTOP_DIR"
    local conf="${PCMANFM_DESKTOP_DIR}/desktop-items-0.conf"

    if [[ -f "$conf" ]]; then
        if grep -q "^show_trash=" "$conf"; then
            sed -i "s|^show_trash=.*|show_trash=1|" "$conf"
        else
            printf 'show_trash=1\n' >> "$conf"
        fi
        return 0
    fi

    cat > "$conf" <<EOF
[*]
show_trash=1
show_mounts=1
EOF
}

whitesur_installed() {
    [[ -d "${HOME}/.local/share/icons/WhiteSur" || -d "${HOME}/.icons/WhiteSur" || -d "/usr/share/icons/WhiteSur" ]]
}

install_glass_icon_theme() {
    whitesur_installed && return 0
    command -v git >/dev/null 2>&1 || return 1

    local clone_dir result
    clone_dir=$(mktemp -d)
    if (
        set -e
        cd "$clone_dir"
        git clone --depth=1 https://github.com/vinceliuice/WhiteSur-icon-theme.git
        cd WhiteSur-icon-theme
        ./install.sh -a
    ) >/tmp/wayfire-pi-whitesur-install.log 2>&1; then
        result=0
    else
        result=1
    fi
    rm -rf "$clone_dir"
    return "$result"
}

ensure_mactahoe_gtk_theme() {
    local found
    found=$(find "$HOME/.themes" -maxdepth 1 -iname 'MacTahoe*[Dd]ark*' -type d 2>/dev/null | head -n1)
    if [[ -n "$found" ]]; then
        basename "$found"
        return 0
    fi

    # >/dev/tty here is deliberate: this function's real return value is
    # its own stdout (captured by the caller via $(...)), and whiptail's
    # drawing has to be kept off that same stream or it gets mashed
    # together with the theme name — which is exactly what was producing
    # garbled settings.ini lines like "MacTahoe-Dark-hdpi" with no key.
    ui --title "wayfire-pi" --infobox "Installing the MacTahoe GTK theme (dark, translucent)...\n\nDownloads and builds — can take a few minutes on first run." 7 66 >/dev/tty 2>&1 || true

    sudo apt-get install -y sassc libglib2.0-dev libxml2-utils >>/tmp/wayfire-pi-mactahoe-build.log 2>&1 || true

    local build_dir result=0
    build_dir=$(mktemp -d)
    (
        set -e
        cd "$build_dir"
        git clone --depth=1 https://github.com/vinceliuice/MacTahoe-gtk-theme.git
        cd MacTahoe-gtk-theme
        sudo ./install.sh -d "$HOME/.themes" -c dark -o normal -t default -a normal --silent-mode
    ) >>/tmp/wayfire-pi-mactahoe-build.log 2>&1 || result=1
    rm -rf "$build_dir"
    sudo chown -R "$(id -u):$(id -g)" "$HOME/.themes" 2>/dev/null || true
    [[ "$result" == "0" ]] || return 1

    found=$(find "$HOME/.themes" -maxdepth 1 -iname 'MacTahoe*[Dd]ark*' -type d 2>/dev/null | head -n1)
    [[ -n "$found" ]] || return 1
    basename "$found"
    return 0
}

ensure_mactahoe_icon_theme() {
    local found
    found=$(find "$HOME/.local/share/icons" -maxdepth 1 -iname 'MacTahoe*' -type d 2>/dev/null | head -n1)
    if [[ -n "$found" ]]; then
        basename "$found"
        return 0
    fi

    # See the matching comment in ensure_mactahoe_gtk_theme above — same
    # reason: keep whiptail's drawing off the stdout this function's
    # caller captures as the real return value.
    ui --title "wayfire-pi" --infobox "Installing the MacTahoe icon theme..." 6 55 >/dev/tty 2>&1 || true

    local build_dir result=0
    build_dir=$(mktemp -d)
    (
        set -e
        cd "$build_dir"
        git clone --depth=1 https://github.com/vinceliuice/MacTahoe-icon-theme.git
        cd MacTahoe-icon-theme
        ./install.sh -t default
    ) >>/tmp/wayfire-pi-mactahoe-build.log 2>&1 || result=1
    rm -rf "$build_dir"
    [[ "$result" == "0" ]] || return 1

    found=$(find "$HOME/.local/share/icons" -maxdepth 1 -iname 'MacTahoe*' -type d 2>/dev/null | head -n1)
    [[ -n "$found" ]] || return 1
    basename "$found"
    return 0
}

write_gtk_glass_theme() {
    mkdir -p "$GTK3_CFG_DIR" "$GTK4_CFG_DIR"

    local gtk_theme=""
    local icon_theme=""
    local result="fallback"

    if gtk_theme=$(ensure_mactahoe_gtk_theme) && \
       icon_theme=$(ensure_mactahoe_icon_theme); then
        result="mactahoe"
    else
        gtk_theme="Adwaita-dark"
        icon_theme="Papirus-Dark"

        if install_glass_icon_theme; then
            icon_theme="WhiteSur"
        fi
    fi

    # Defensive backstop: whatever ensure_mactahoe_* returned should
    # already be a single clean theme-directory name, but strip any
    # stray \r and collapse to the last non-empty line/token regardless
    # — cheap insurance against another stdout-leak like the one that
    # produced garbled, key-less lines in settings.ini before the
    # >/dev/tty fix above.
    gtk_theme=$(tr -d '\r' <<<"$gtk_theme" | awk 'NF{v=$NF} END{print v}')
    icon_theme=$(tr -d '\r' <<<"$icon_theme" | awk 'NF{v=$NF} END{print v}')

    cat > "$GTK3_SETTINGS" <<EOF
[Settings]
gtk-theme-name = ${gtk_theme}
gtk-icon-theme-name = ${icon_theme}
gtk-application-prefer-dark-theme = 1
EOF

    cat > "$GTK4_SETTINGS" <<EOF
[Settings]
gtk-theme-name = ${gtk_theme}
gtk-icon-theme-name = ${icon_theme}
gtk-application-prefer-dark-theme = 1
EOF

    local CSS_PAYLOAD='
/* Global palette defaults */
@define-color theme_fg_color #f3f3f3;
@define-color theme_text_color #f3f3f3;

/* Default translucent dark windows & menus */
window,
window.background,
.background {
    background-color: rgba(24, 24, 37, 0.72);
    background-image: none;
    color: #f3f3f3;
}

headerbar,
.titlebar,
headerbar label,
.titlebar label {
    background-color: rgba(20, 20, 30, 0.55);
    background-image: none;
    border: none;
    box-shadow: none;
    color: #ffffff;
}

button,
button label {
    background-color: rgba(255, 255, 255, 0.075);
    background-image: none;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 9px;
    box-shadow: none;
    color: #ffffff;
}

button:hover,
button:hover label {
    background-color: rgba(203, 166, 247, 0.22);
    border-color: rgba(203, 166, 247, 0.38);
    color: #ffffff;
}

button:active,
button:checked,
button:active label,
button:checked label {
    background-color: rgba(203, 166, 247, 0.30);
    color: #ffffff;
}

menu,
menu.background,
.menu {
    background-color: rgba(24, 24, 37, 0.85);
    background-image: none;
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 12px;
    padding: 6px;
    box-shadow: 0 12px 35px rgba(0, 0, 0, 0.45);
    color: #ffffff;
}

menu menuitem,
.menu menuitem,
menuitem,
menu menuitem label,
.menu menuitem label,
menuitem label {
    background-color: transparent;
    background-image: none;
    border-radius: 7px;
    color: #f3f3f3;
}

menu menuitem:hover,
menu menuitem:selected,
.menu menuitem:hover,
menuitem:hover,
menu menuitem:hover label,
menu menuitem:selected label,
.menu menuitem:hover label,
menuitem:hover label {
    background-color: rgba(203, 166, 247, 0.28);
    color: #ffffff;
}

popover,
popover.background,
popover > contents,
popover.background > contents,
popover label {
    background-color: rgba(24, 24, 37, 0.85);
    background-image: none;
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 12px;
    box-shadow: 0 12px 35px rgba(0, 0, 0, 0.40);
    color: #ffffff;
}

entry,
entry:focus,
searchentry {
    background-color: rgba(10, 10, 18, 0.55);
    background-image: none;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px;
    color: #ffffff;
}

/* File manager (PCManFM) & treeview content overrides for light views */
.view,
iconview,
treeview,
treeview.view,
list,
listview,
.side-pane,
FmMainWin .view,
FmMainWin treeview {
    background-color: rgba(255, 255, 255, 0.88);
    color: #1e1e2e;
}

.view label,
iconview label,
treeview label,
.side-pane label,
FmMainWin label {
    color: #1e1e2e;
}

/* Selected item state in light file view */
.view:selected,
iconview:selected,
treeview:selected,
.side-pane:selected {
    background-color: rgba(203, 166, 247, 0.40);
    color: #ffffff;
}

.view:selected label,
iconview:selected label,
treeview:selected label,
.side-pane:selected label {
    color: #ffffff;
}

tooltip,
tooltip.background,
tooltip label {
    background-color: rgba(20, 20, 30, 0.88);
    background-image: none;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px;
    color: #ffffff;
}

#PanelToplevel *,
panel-window *,
.raspberry-pi-panel *,
wf-panel-pi *,
.wf-panel * {
    background-image: none;
    color: #ffffff;
}
'

    printf '%s\n' "$CSS_PAYLOAD" > "$GTK3_CSS"
    printf '%s\n' "$CSS_PAYLOAD" > "$GTK4_CSS"

    # Force live settings updates across standard schemas
    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface icon-theme "$icon_theme" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme "$gtk_theme" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true
    fi

    echo "$result"
}

# remove_glass_theme_files — actually deletes the MacTahoe/WhiteSur theme
# and icon directories this script downloaded into the user's own
# locations (~/.themes, ~/.local/share/icons, ~/.icons). reset_gtk_theme
# below only clears settings.ini's *reference* to whichever one was
# active — it was never removing the pack itself, in any version of this
# script so far. That's the gap: not a wrong-order bug so much as a
# missing step. Called first, before reset_gtk_theme, so there's nothing
# left on disk for anything (a stale gsettings/dconf value, an
# icon-theme.cache, a not-yet-restarted process) to still resolve to.
#
# Deliberately does NOT touch /usr/share/icons/WhiteSur — that path is
# system-wide, would need root, and may not even be this script's doing.
remove_glass_theme_files() {
    rm -rf "$HOME"/.themes/MacTahoe*[Dd]ark* 2>/dev/null || true
    rm -rf "$HOME"/.local/share/icons/MacTahoe* 2>/dev/null || true
    rm -rf "$HOME"/.local/share/icons/WhiteSur* 2>/dev/null || true
    rm -rf "$HOME"/.icons/WhiteSur* 2>/dev/null || true
}

reset_gtk_theme() {
    rm -f "$GTK3_CSS" "$GTK4_CSS"

    for settings in "$GTK3_SETTINGS" "$GTK4_SETTINGS"; do
        [[ -f "$settings" ]] || continue

        # write_gtk_glass_theme writes "key = value" (spaces either side of
        # the =). These patterns previously assumed a bare "key=value" with
        # no space, which never matched anything it actually wrote — so
        # revert_to_pios was silently leaving gtk-icon-theme-name (and
        # gtk-theme-name) pointed at MacTahoe/WhiteSur instead of clearing
        # them. [[:space:]]* makes it match either form.
        sed -i \
            -e '/^gtk-theme-name[[:space:]]*=/d' \
            -e '/^gtk-icon-theme-name[[:space:]]*=/d' \
            -e '/^gtk-application-prefer-dark-theme[[:space:]]*=/d' \
            "$settings"
    done

    if command -v gsettings >/dev/null 2>&1; then
        # PiXflat was Bookworm's default icon/GTK theme name. Trixie ships
        # a new one called PiXtrix instead — confirmed via `ls
        # /usr/share/icons/` on a live Trixie box, which has PiXtrix but
        # no PiXflat at all. Setting a theme name that doesn't exist on
        # disk doesn't error, it just makes GTK fall back through the
        # inheritance chain to something generic — which is what was
        # actually still being seen after every MacTahoe file had already
        # been removed.
        gsettings set org.gnome.desktop.interface icon-theme "PiXtrix" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme "PiXtrix" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme "default" 2>/dev/null || true
    fi
}

# Translucent title bars AND right-click/desktop menus for Minimal mode
# (stock labwc, no Wayfire). Writes labwc's own themerc-override for
# the title bars/native menus, plus a GTK CSS override so PCManFM's
# desktop right-click menu matches.
#
# labwc has no compositor-level window/view opacity (open feature
# request, not implemented as of writing), so this only affects title
# bar and menu chrome, which labwc itself composites — window content
# stays fully opaque. There's a known labwc rendering bug where
# rounded title-bar corners show visible seams once opacity drops
# much below here — confirmed on labwc's own tracker at 70%, clean
# at 95%. 60/30 sits deliberately close to that line for a visibly
# translucent look; if corner artifacts appear, nudge both values up
# in increments of 5-10 rather than jumping straight back to 75/40.
#
# Colour matches the #1e1e2e navy already used for Wayfire's window
# decoration in Average/Ludicrous, for visual consistency across tiers.
build_labwc_themerc_override() {
    local labwc_cfg_dir="${HOME}/.config/labwc"
    local gtk3_cfg_dir="${HOME}/.config/gtk-3.0"
    local gtk4_cfg_dir="${HOME}/.config/gtk-4.0"
    mkdir -p "$labwc_cfg_dir" "$gtk3_cfg_dir" "$gtk4_cfg_dir"

    # 0. Adwaita-dark widget theme (menus, buttons, window content) —
    # Minimal keeps standard PiXtrix icons (set by reset_gtk_theme,
    # called just before this), but pairs the translucent title
    # bars/menus below with a dark widget theme rather than the default
    # light one, so the two don't clash.
    cat > "$GTK3_SETTINGS" <<EOF
[Settings]
gtk-theme-name = Adwaita-dark
gtk-application-prefer-dark-theme = 1
EOF
    cat > "$GTK4_SETTINGS" <<EOF
[Settings]
gtk-theme-name = Adwaita-dark
gtk-application-prefer-dark-theme = 1
EOF
    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface gtk-theme "Adwaita-dark" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true
    fi

    # 1. Title bars & native labwc menus (#1e1e2e with 60% and 30% alpha)
    #
    # labwc's own defaults for title text and button icons are BLACK
    # (window.active.label.text.color / window.active.button.unpressed.
    # image.color both default to #000000) — fine against Pi OS's stock
    # light titlebar, invisible against the dark translucent one set
    # below. Same story for labwc's native menu item text
    # (menu.items.text.color, also #000000 by default) against the dark
    # menu background just below it. All four get the same light
    # Catppuccin-Mocha "text" colour (#cdd6f4) used nowhere else in this
    # theme yet, so it's free to reuse without clashing.
    {
        echo "window.active.title.bg.color: #1e1e2e 60"
        echo "window.inactive.title.bg.color: #1e1e2e 30"
        echo "window.active.label.text.color: #cdd6f4"
        echo "window.inactive.label.text.color: #cdd6f4 70"
        echo "window.active.button.unpressed.image.color: #cdd6f4"
        echo "window.inactive.button.unpressed.image.color: #cdd6f4 70"
        echo "menu.items.bg.color: #1e1e2e 60"
        echo "menu.items.text.color: #cdd6f4"
        echo "menu.items.active.text.color: #cdd6f4"
        echo "menu.title.bg.color: #1e1e2e 60"
    } > "${labwc_cfg_dir}/themerc-override"

    # 2. GTK Menu translucency for PCManFM desktop right-click menus
    cat > "${gtk3_cfg_dir}/gtk.css" <<EOF
menu,
.menu,
menu.background,
window.popup menu {
    background-color: rgba(30, 30, 46, 0.60) !important;
    background-image: none !important;
}

menu menuitem,
.menu menuitem {
    background-color: transparent !important;
}

menu menuitem:hover,
.menu menuitem:hover {
    background-color: rgba(203, 166, 247, 0.28) !important;
}
EOF
}

# Clean, minimal rc.xml so labwc retains default server-side window drop
# shadows, and (via <default/> below) all of labwc's own compiled-in
# keybinds — Alt-Tab, window move/resize, etc. When swayosd-client is
# present, this also rebinds the volume/brightness/mic-mute XF86 keys so
# they trigger swayosd's on-screen display instead of labwc's silent
# built-in amixer/brightnessctl defaults. <default/> MUST stay in —
# without it, adding a <keyboard> block at all *replaces* every
# compiled-in keybind rather than adding to them.
build_labwc_minimal_rc() {
    local labwc_cfg_dir="${HOME}/.config/labwc"
    mkdir -p "$labwc_cfg_dir"

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<labwc_config>'

        if command -v swayosd-client >/dev/null 2>&1; then
            echo '  <keyboard>'
            echo '    <default />'
            echo '    <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="swayosd-client --output-volume raise"/></keybind>'
            echo '    <keybind key="XF86AudioLowerVolume"><action name="Execute" command="swayosd-client --output-volume lower"/></keybind>'
            echo '    <keybind key="XF86AudioMute"><action name="Execute" command="swayosd-client --output-volume mute-toggle"/></keybind>'
            echo '    <keybind key="XF86AudioMicMute"><action name="Execute" command="swayosd-client --input-volume mute-toggle"/></keybind>'
            echo '    <keybind key="XF86MonBrightnessUp"><action name="Execute" command="swayosd-client --brightness raise"/></keybind>'
            echo '    <keybind key="XF86MonBrightnessDown"><action name="Execute" command="swayosd-client --brightness lower"/></keybind>'
            echo '  </keyboard>'
        fi

        echo '  <theme>'
        echo '    <name>Pix</name>'
        echo '  </theme>'
        echo '</labwc_config>'
    } > "${labwc_cfg_dir}/rc.xml"
}

# build_labwc_autostart — starts swaync (notification daemon) and
# swayosd-server (volume/brightness OSD daemon) in the background for
# Minimal mode, on top of Pi OS's own system autostart.
#
# Two separate gotchas here, both confirmed the hard way:
#
# 1. labwc uses the FIRST autostart file it finds — $XDG_CONFIG_HOME
#    (~/.config/labwc/autostart), THEN /etc/xdg/labwc/autostart — and
#    does NOT merge the two. Pi OS's system autostart at
#    /etc/xdg/labwc/autostart is what actually starts the real panel
#    (wf-panel-pi), desktop icons (pcmanfm-pi), output config (kanshi),
#    and any other XDG autostart apps. A user-level autostart file
#    containing only our own lines doesn't add to that — it silently
#    REPLACES it, which is why the panel/desktop icons/wallpaper
#    vanished and Minimal mode booted to a black screen with just a
#    cursor even though labwc, swaync, and swayosd-server were all
#    running fine. Fix: copy Pi OS's system autostart content in
#    first, then append our own lines after it.
#
# 2. labwc runs this file top-to-bottom as a plain shell script and
#    won't get to whatever comes after a given line until that line
#    returns — so EVERY long-running process in here MUST end in a
#    trailing '&', or the rest of the file never runs either. (This
#    was the FIRST black-screen cause hit here, before gotcha #1
#    above was found.)
PIOS_LABWC_SYSTEM_AUTOSTART="/etc/xdg/labwc/autostart"

build_labwc_autostart() {
    local labwc_cfg_dir="${HOME}/.config/labwc"
    mkdir -p "$labwc_cfg_dir"
    local autostart_file="${labwc_cfg_dir}/autostart"

    {
        echo "#!/bin/sh"
        echo "# Managed by wayfire-pi.sh — Minimal tier autostart."
        echo "# Starts with Pi OS's own system autostart (panel, desktop"
        echo "# icons, wallpaper, output config, XDG autostart apps)"
        echo "# verbatim, since labwc reads only the first autostart file"
        echo "# it finds rather than merging user and system ones."
        echo ""

        if [[ -f "$PIOS_LABWC_SYSTEM_AUTOSTART" ]]; then
            cat "$PIOS_LABWC_SYSTEM_AUTOSTART"
        fi

        echo ""
        echo "# --- wayfire-pi.sh additions below ---"

        if command -v swaync >/dev/null 2>&1; then
            echo "swaync &"
        fi

        if command -v swayosd-server >/dev/null 2>&1; then
            echo "swayosd-server &"
        fi
    } > "$autostart_file"

    chmod +x "$autostart_file"
}

# ensure_swaync_swayosd — installs sway-notification-center (swaync) and
# swayosd via apt if either is missing. Both ship in Trixie's own repos,
# no extra apt sources needed. Best-effort: failures are reported but
# don't abort Minimal mode — the tier still applies fine without them,
# just without notifications/OSD, so callers should tolerate a non-zero
# return here rather than let it kill the whole apply_tier run.
ensure_swaync_swayosd() {
    local pkgs=()
    command -v swaync >/dev/null 2>&1 || pkgs+=(sway-notification-center)
    command -v swayosd-server >/dev/null 2>&1 || pkgs+=(swayosd)

    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    ui --title "wayfire-pi" --infobox "Installing ${pkgs[*]}..." 6 60
    sleep 1

    if ! sudo apt-get update -qq; then
        ui --title "wayfire-pi" --msgbox "apt-get update failed, so swaync/swayosd weren't installed. Check your network connection and try again — Minimal mode will still apply without them." 10 60
        return 1
    fi
    if ! sudo apt-get install -y "${pkgs[@]}"; then
        ui --title "wayfire-pi" --msgbox "Installing ${pkgs[*]} failed. Check the terminal output above for details — Minimal mode will still apply without them." 9 60
        return 1
    fi
    return 0
}

apply_tier() {
    local tier="$1"

    # install_power_menu_shortcuts — belt-and-braces fallback for
    # Shutdown/Restart/Log Out. smenu's own built-in Shutdown entry
    # (wired up in write_wf_panel_pi_glass above) should now cover this
    # natively, but these are plain, standard XDG .desktop entries that
    # show up in any spec-compliant app menu regardless of which panel
    # widget ends up rendering the list — so they keep working even if
    # a future Pi OS release renames or drops smenu again. Harmless
    # under Minimal/stock Pi OS too, so it's unconditional here rather
    # than gated to a specific tier.
    install_power_menu_shortcuts

    if [[ "$tier" == "minimal_plus" ]]; then
        ui --title "wayfire-pi" --infobox "Applying Minimal Plus (Enhanced labwc)..." 7 60

        backup_pristine_once

        # 1. Clean configs & set up base labwc autostart/rc.xml
        rm -f "$WAYFIRE_INI" "$WF_SHELL_INI"
        ensure_swaync_swayosd || true
        build_labwc_minimal_rc
        build_labwc_autostart

        # 2. Install MacTahoe / Glass GTK/Icon Themes
        local theme_used
        theme_used=$(write_gtk_glass_theme)

        # 3. Apply translucent titlebars and menus in labwc
        #
        # Alpha here is opacity, not transparency — higher = more solid.
        # These must be LOWER (more see-through) than base Minimal's
        # 60/30 values in build_labwc_themerc_override, or "Plus" ends up
        # looking flatter than plain Minimal instead of glassier.
        local labwc_cfg_dir="${HOME}/.config/labwc"
        mkdir -p "$labwc_cfg_dir"
        cat > "${labwc_cfg_dir}/themerc-override" <<EOF
window.active.title.bg.color: #1e1e2e 40
window.inactive.title.bg.color: #1e1e2e 15
window.active.label.text.color: #cdd6f4
window.inactive.label.text.color: #cdd6f4 70
window.active.button.unpressed.image.color: #cdd6f4
window.inactive.button.unpressed.image.color: #cdd6f4 70
menu.items.bg.color: #1e1e2e 40
menu.items.text.color: #cdd6f4
menu.items.active.text.color: #cdd6f4
menu.title.bg.color: #1e1e2e 40
EOF

        # 4. Glass Panel styling — a bit more transparent than the
        # titlebar/menu values above, since the panel sits over a fixed
        # part of the wallpaper rather than shifting window content.
        write_wf_panel_pi_glass 20 20 30 0.55

        # 5. Make sure the login session points at labwc/Pi OS, not
        # Wayfire — matters if we're switching down from Average/Ludicrous.
        local pios_session
        if pios_session=$(find_pios_session_name); then
            set_lightdm_session "$pios_session"
            set_accountsservice_session "$pios_session"
        else
            restore_lightdm_session
            restore_accountsservice_session
        fi
        if [[ -n "${pios_session:-}" ]]; then
            ensure_autologin_user "$(id -un)"
        fi

        set_state "tier" "minimal_plus"
        set_state "wayfire_active" "off"
        set_state "reboot_needed" "yes"

        if command -v labwc >/dev/null 2>&1; then
            labwc --reconfigure 2>/dev/null || true
        fi

        local theme_msg
        if [[ "$theme_used" == "mactahoe" ]]; then
            theme_msg="MacTahoe GTK theme and matching icons."
        else
            theme_msg="Adwaita-dark GTK theme (MacTahoe wasn't available)."
        fi

        ui --title "wayfire-pi" --msgbox \
"Minimal Plus applied!

Includes:
- ${theme_msg}
- Translucent titlebars & menus
- Translucent wf-panel-pi
- swaync & swayosd support
- No Wayfire required

Note: labwc can only make its own decorations translucent (titlebars, menus, panel) — actual window content stays opaque. Glassy application windows are a Wayfire-only effect; see Average/Ludicrous mode for that.

A reboot or logout/login is required to switch sessions." 20 72

        return 0
    fi

    if [[ "$tier" == "minimal" ]]; then
        ui --title "wayfire-pi" \
           --infobox "Restoring standard Raspberry Pi OS desktop..." 7 60

        backup_pristine_once

        rm -f "$WAYFIRE_INI" "$WF_SHELL_INI"
        rm -rf "$WF_PANEL_PI_DIR"
        rm -f "${HOME}/.config/labwc/rc.xml"

        ensure_swaync_swayosd || true

		build_labwc_minimal_rc
        build_labwc_autostart
        reset_gtk_theme
        build_labwc_themerc_override

        local pios_session
        if pios_session=$(find_pios_session_name); then
            set_lightdm_session "$pios_session"
            set_accountsservice_session "$pios_session"
        else
            restore_lightdm_session
            restore_accountsservice_session
        fi

        if [[ -n "${pios_session:-}" ]]; then
            ensure_autologin_user "$(id -un)"
        fi

        set_state "tier" "minimal"
        set_state "wayfire_active" "off"
        set_state "reboot_needed" "yes"

        if command -v labwc >/dev/null 2>&1; then
            labwc --reconfigure 2>/dev/null || true
        fi

        ui --title "wayfire-pi" \
           --msgbox \
"Standard Pi OS desktop restored.

Minimal mode now means:

- Standard labwc
- Standard Pi OS panel
- Standard Pi OS Pi menu
- Adwaita-dark GTK appearance, standard PiXtrix icons
- swaync (desktop notifications)
- No Wayfire
- No glass effects
- Translucent title bars only (window views stay opaque)
- No custom rounded decorations
- Notifications via swaync, volume/brightness OSD via swayosd

Wayfire remains installed for Average and Ludicrous modes.

A reboot or logout/login is required to switch sessions." \
           18 70

        return 0
    fi

    ui --title "wayfire-pi" --infobox "Working — applying $(tier_label "$tier")...\n\nThis can take a while the first time (installing packages). Later runs are quicker." 8 62

    local wf_rc=0
    ensure_wayfire_installed || wf_rc=$?
    if [[ $wf_rc -eq 2 ]]; then
        if ui --title "wayfire-pi" --yesno "Apply Minimal Plus instead now?\n\n(Enhanced labwc — glass theming, translucent titlebars and panel — no Wayfire required, works on every Trixie system.)" 10 65; then
            apply_tier "minimal_plus"
        fi
        return 1
    elif [[ $wf_rc -ne 0 ]]; then
        return 1
    fi

    backup_pristine_once

    reset_gtk_theme

    local theme_msg=""
    if [[ "$tier" == "recommended" || "$tier" == "ludicrous" ]]; then
        local theme_used
        theme_used=$(write_gtk_glass_theme)
        if [[ "$theme_used" == "mactahoe" ]]; then
            theme_msg="Translucent glass theming is active, using the MacTahoe GTK theme and matching icons."
        else
            theme_msg="Translucent titlebar and dark theming are active (Adwaita-dark)."
        fi
    fi

    build_wayfire_ini "$tier"
    [[ "$(command -v wf-panel-pi)" ]] || build_wf_shell_ini
    set_state "tier" "$tier"
    set_state "wayfire_active" "on"

    local wf_session switch_msg
    if wf_session=$(find_wayfire_session_name); then
        set_lightdm_session "$wf_session"
        set_accountsservice_session "$wf_session"
        switch_msg="Your login session has been switched to Wayfire automatically."
    else
        switch_msg="Couldn't find Wayfire's session file — select 'Wayfire' manually at the login screen."
    fi

    local full_msg="$(tier_label "$tier") effects applied."
    [[ -n "$theme_msg" ]] && full_msg="${full_msg}\n\n${theme_msg}"
    full_msg="${full_msg}\n\n${switch_msg}\n\nReboot (or log out and back in) to see it."
    ui --title "wayfire-pi" --msgbox "$full_msg" 20 70
    set_state "reboot_needed" "yes"
}

save_look() {
    local name
    name=$(ui --title "wayfire-pi" --inputbox "Name this look:" 9 50 \
        3>&1 1>&2 2>&3) || return 0
    [[ -n "$name" ]] || return 0
    name=$(tr -c 'A-Za-z0-9_-' '_' <<< "$name")

    ui --title "wayfire-pi" --infobox "Working — saving '${name}'..." 6 50

    local dest="${LOOKS_DIR}/${name}"
    local overwriting=0
    [[ -d "$dest" ]] && overwriting=1
    mkdir -p "$dest"

    [[ -f "$WAYFIRE_INI" ]] && cp -a "$WAYFIRE_INI" "${dest}/wayfire.ini"
    [[ -f "$WF_SHELL_INI" ]] && cp -a "$WF_SHELL_INI" "${dest}/wf-shell.ini"
    [[ -f "$WF_PANEL_PI_INI" ]] && cp -a "$WF_PANEL_PI_INI" "${dest}/wf-panel-pi.ini"
    [[ -f "$WF_PANEL_PI_CSS" ]] && cp -a "$WF_PANEL_PI_CSS" "${dest}/panel-glass.css"
    [[ -f "$GTK3_CSS" ]] && cp -a "$GTK3_CSS" "${dest}/gtk.css"
    [[ -f "$GTK3_SETTINGS" ]] && cp -a "$GTK3_SETTINGS" "${dest}/gtk-settings.ini"

    # labwc side too (Minimal / Minimal Plus have no wayfire.ini at all) —
    # capture whatever's there, skip whatever isn't. Belt-and-braces so
    # one "Backup this look" always grabs the full picture regardless of
    # which tier is currently active.
    [[ -f "$LABWC_RC" ]] && cp -a "$LABWC_RC" "${dest}/labwc-rc.xml"
    [[ -f "$LABWC_AUTOSTART" ]] && cp -a "$LABWC_AUTOSTART" "${dest}/labwc-autostart"
    [[ -f "$LABWC_THEMERC_OVERRIDE" ]] && cp -a "$LABWC_THEMERC_OVERRIDE" "${dest}/labwc-themerc-override"

    # Record which tier this was, purely so restore can put the right
    # label/state back and pick the right session — restore itself
    # still works fine from the files alone if this is missing (older
    # saved looks won't have it).
    get_state "tier" > "${dest}/tier" 2>/dev/null || true

    if [[ -d "$PCMANFM_DESKTOP_DIR" ]]; then
        mkdir -p "${dest}/pcmanfm"
        local f found_any=0
        for f in "$PCMANFM_DESKTOP_DIR"/desktop-items-*.conf; do
            [[ -f "$f" ]] || continue
            cp -a "$f" "${dest}/pcmanfm/"
            found_any=1

            local wp
            wp=$(grep -oP '(?<=^wallpaper=).*' "$f" 2>/dev/null | head -n1) || true
            if [[ -n "$wp" && -f "$wp" ]]; then
                cp -a "$wp" "${dest}/pcmanfm/$(basename "$wp")"
            fi
        done
        [[ "$found_any" == "0" ]] && rmdir "${dest}/pcmanfm" 2>/dev/null || true
    fi

    set_state "last_saved_look" "$name"

    local overwrite_msg=""
    [[ "$overwriting" == "1" ]] && overwrite_msg=" (replaced previous backup)"

    ui --title "wayfire-pi" --msgbox "Saved current look as '${name}'${overwrite_msg}." 12 66
}

list_looks() {
    [[ -d "$LOOKS_DIR" ]] || return 0
    find "$LOOKS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
}

apply_saved_look() {
    local looks
    looks=$(list_looks)
    if [[ -z "$looks" ]]; then
        ui --title "wayfire-pi" --msgbox "No saved looks yet. Use 'Backup this look and feel' first." 8 55
        return 0
    fi

    local menu_args=()
    local n=1
    local name
    while IFS= read -r name; do
        menu_args+=("$n" "$name")
        n=$(( n + 1 ))
    done <<< "$looks"

    local choice
    choice=$(ui --title "wayfire-pi" --menu "Pick a saved look:" 15 55 8 \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0

    local picked="${menu_args[$(( (choice - 1) * 2 + 1 ))]}"
    ui --title "wayfire-pi" --infobox "Working — applying '${picked}'..." 6 55
    local look_dir="${LOOKS_DIR}/${picked}"

    # A saved look is "just files" — restore whatever was captured and
    # skip whatever wasn't. This has to work for a look saved under any
    # of the four tiers (Minimal, Minimal Plus, Average, Ludicrous), so
    # the session decision below has to reflect what was ACTUALLY active
    # at the moment the look was saved — not just whatever files happen
    # to be lying around in the look folder.
    #
    # Primary signal: the "tier" file written by save_look at capture
    # time. Fallback: presence of wayfire.ini, for looks saved by an
    # older version of this script before that file existed.
    local saved_tier="" has_wayfire=0
    [[ -f "${look_dir}/tier" ]] && saved_tier=$(<"${look_dir}/tier")

    case "$saved_tier" in
        recommended|ludicrous) has_wayfire=1 ;;
        minimal|minimal_plus)  has_wayfire=0 ;;
        *)
            # No (or unrecognised) tier metadata — fall back to what's
            # actually in the look folder.
            [[ -f "${look_dir}/wayfire.ini" ]] && has_wayfire=1
            ;;
    esac

    # Belt-and-braces: if the tier says Wayfire but the file itself isn't
    # actually there (a corrupted/incomplete save), don't try to restore
    # a Wayfire config that doesn't exist — treat it as labwc-only.
    if [[ "$has_wayfire" == "1" && ! -f "${look_dir}/wayfire.ini" ]]; then
        has_wayfire=0
    fi

    if [[ "$has_wayfire" == "1" ]]; then
        ensure_wayfire_installed || return 1
    fi

    backup_pristine_once
    reset_gtk_theme

    if [[ "$has_wayfire" == "1" ]]; then
        cp -a "${look_dir}/wayfire.ini" "$WAYFIRE_INI"
        if [[ -f "${look_dir}/wf-shell.ini" ]]; then
            cp -a "${look_dir}/wf-shell.ini" "$WF_SHELL_INI"
        else
            build_wf_shell_ini
        fi
        if [[ -f "${look_dir}/wf-panel-pi.ini" ]]; then
            mkdir -p "$WF_PANEL_PI_DIR"
            cp -a "${look_dir}/wf-panel-pi.ini" "$WF_PANEL_PI_INI"
            [[ -f "${look_dir}/panel-glass.css" ]] && cp -a "${look_dir}/panel-glass.css" "$WF_PANEL_PI_CSS"
        else
            rm -f "$WF_PANEL_PI_INI" "$WF_PANEL_PI_CSS"
        fi
    else
        # No wayfire.ini in this look — clear any stale Wayfire config
        # left over from a previous tier so it can't linger and confuse
        # things if the user ever ends up back in a Wayfire session.
        rm -f "$WAYFIRE_INI" "$WF_SHELL_INI"
        rm -rf "$WF_PANEL_PI_DIR"
    fi

    if [[ -f "${look_dir}/labwc-rc.xml" || -f "${look_dir}/labwc-autostart" || -f "${look_dir}/labwc-themerc-override" ]]; then
        mkdir -p "$LABWC_CFG_DIR"
        [[ -f "${look_dir}/labwc-rc.xml" ]] && cp -a "${look_dir}/labwc-rc.xml" "$LABWC_RC"
        [[ -f "${look_dir}/labwc-autostart" ]] && cp -a "${look_dir}/labwc-autostart" "$LABWC_AUTOSTART"
        if [[ -f "${look_dir}/labwc-themerc-override" ]]; then
            cp -a "${look_dir}/labwc-themerc-override" "$LABWC_THEMERC_OVERRIDE"
        else
            rm -f "$LABWC_THEMERC_OVERRIDE"
        fi
    elif [[ "$has_wayfire" == "1" ]]; then
        # A pure Wayfire look with no labwc files saved — clear any old
        # labwc override so it doesn't bleed into a future manual switch.
        rm -f "$LABWC_RC" "$LABWC_THEMERC_OVERRIDE"
    fi

    [[ -f "${look_dir}/gtk.css" ]] && { mkdir -p "$GTK3_CFG_DIR"; cp -a "${look_dir}/gtk.css" "$GTK3_CSS"; }
    [[ -f "${look_dir}/gtk-settings.ini" ]] && { mkdir -p "$GTK3_CFG_DIR"; cp -a "${look_dir}/gtk-settings.ini" "$GTK3_SETTINGS"; }

    local switch_msg
    if [[ "$has_wayfire" == "1" ]]; then
        set_state "wayfire_active" "on"
        set_state "tier" "${saved_tier:-recommended}"
        local wf_session
        if wf_session=$(find_wayfire_session_name); then
            set_lightdm_session "$wf_session"
            set_accountsservice_session "$wf_session"
            switch_msg="Your login session has been switched to Wayfire automatically."
        else
            switch_msg="Select 'Wayfire' manually at the login screen."
        fi
    else
        set_state "wayfire_active" "off"
        set_state "tier" "${saved_tier:-minimal}"
        local pios_session
        if pios_session=$(find_pios_session_name); then
            set_lightdm_session "$pios_session"
            set_accountsservice_session "$pios_session"
            ensure_autologin_user "$(id -un)"
            switch_msg="Your login session has been switched back to standard Pi OS automatically."
        else
            restore_lightdm_session
            restore_accountsservice_session
            switch_msg="Select the standard Pi OS session manually at the login screen."
        fi
    fi

    if command -v labwc >/dev/null 2>&1; then
        labwc --reconfigure 2>/dev/null || true
    fi

    ui --title "wayfire-pi" --msgbox "Applied saved look '${picked}'.\n\n${switch_msg}" 13 66
    set_state "reboot_needed" "yes"
}

revert_to_pios() {
    if [[ ! -f "${PRISTINE_DIR}/.snapshot-complete" ]]; then
        ui --title "wayfire-pi" --msgbox "Nothing to revert — this tool hasn't changed anything yet." 8 55
        return 0
    fi

    if ! ui --title "wayfire-pi" --yesno "This will restore Pi OS desktop settings, purge Wayfire in the background, and reboot. Continue?" 12 65; then
        return 0
    fi

    ui --title "wayfire-pi" --infobox "Preparing system restore..." 7 55

    # 1. First, only write the persistent display manager session files
    # (Do NOT delete/replace whole GTK theme directories live, as that
    # can crash apps mid-render — that destructive part stays deferred
    # to the background unit below).
    restore_lightdm_session
    restore_accountsservice_session

    local pios_session
    if pios_session=$(find_pios_session_name); then
        set_lightdm_session "$pios_session"
        set_accountsservice_session "$pios_session"
        ensure_autologin_user "$(id -un)"
    fi

    # reset_gtk_theme is safe to run live — apply_tier and
    # apply_saved_look already call it mid-session without issue. It's
    # the ONE thing this function was missing: without it, settings.ini
    # is left pointing at gtk-icon-theme-name=WhiteSur/MacTahoe/Papirus
    # (whichever glass theme was active), and once the background unit
    # below deletes those theme directories, GTK has nothing to resolve
    # that name to and silently falls back to Adwaita ("gnome icons").
    # The Pi start-menu icon and the themed Shutdown/Log Out entries
    # are looked up by icon NAME too, so the same broken fallback is
    # why those disappear from the menu entirely instead of just
    # showing blank icons. reset_gtk_theme both strips the stale
    # settings.ini lines and points gsettings back at PiXtrix, Trixie's
    # real Pi OS default.
    reset_gtk_theme

    # install_power_menu_shortcuts' fallback .desktop entries are only
    # meaningful under Wayfire's smenu — no reason to leave them behind
    # once back on Pi OS's own panel.
    rm -f "${HOME}/.local/share/applications/wayfire-pi-shutdown.desktop" \
          "${HOME}/.local/share/applications/wayfire-pi-restart.desktop" \
          "${HOME}/.local/share/applications/wayfire-pi-logout.desktop"

    set_state "wayfire_active" "off"
    set_state "reboot_needed" "no"

    # Display the message box while the GUI is still completely stable
    ui --title "wayfire-pi" --msgbox "Revert initiated!\n\nThe system is purging Wayfire packages in the background and will reboot into standard Pi OS automatically in a few seconds." 12 65

    # 2. Defer the remaining session-killing actions (theme directory
    # deletion, package purges, labwc/panel cleanup) to the background
    # unit, starting 2 seconds after the user clicks OK. GTK's
    # settings.ini/gsettings state was already reset live, above.
    local user_home="$HOME"
    sudo systemd-run --unit=wayfire-pi-cleanup --on-active=2s bash -c "
        rm -rf '${user_home}/.config/labwc'
        rm -rf '${WF_PANEL_PI_DIR}'
        rm -rf '${WAYFIRE_INI}' '${WF_SHELL_INI}'

        # Clean GTK themes from systemd context
        rm -rf '${user_home}'/.themes/MacTahoe*[Dd]ark* 2>/dev/null || true
        rm -rf '${user_home}'/.local/share/icons/MacTahoe* 2>/dev/null || true
        rm -rf '${user_home}'/.local/share/icons/WhiteSur* 2>/dev/null || true
        rm -rf '${user_home}'/.icons/WhiteSur* 2>/dev/null || true
        rm -f '${user_home}/.config/gtk-3.0/gtk.css' '${user_home}/.config/gtk-4.0/gtk.css'

        apt-get purge -y wayfire wf-shell wcm sway-notification-center swayosd
        apt-get update -qq
        apt-get install --no-install-recommends -y rpd-wayland-core rpd-theme rpd-preferences
        apt-get install --reinstall -y rpd-wayland-core rpd-theme rpd-preferences
        systemctl reboot
    "

    kill -9 $PPID
}

show_intro() {
    local model ram tier
    model=$(detect_pi_model)
    model="${model:-Unknown Raspberry Pi model}"
    ram=$(detect_ram_mb)
    ram="${ram:-unknown}"
    tier=$(recommend_tier)

    ui --title "wayfire-pi v${WAYFIRE_PI_VERSION}" --msgbox \
        "Detected: ${model}\nRAM: ${ram} MB\n\nSuggested level for this board: $(tier_label "$tier")" 12 62
}

main_menu() {
    local current_tier wayfire_active reboot_pending
    current_tier=$(get_state "tier")
    wayfire_active=$(get_state "wayfire_active")
    reboot_pending=$(get_state "reboot_needed")
    local rec
    rec=$(recommend_tier)

    local wayfire_reachable=1
    if ! wayfire_installed && ! wayfire_likely_available; then
        wayfire_reachable=0
    fi

    local banner="" menu_height=18
    if [[ "$reboot_pending" == "yes" ]]; then
        banner="*** REBOOT NEEDED to apply your last change ***\n\n"
        menu_height=20
    fi
    if [[ "$wayfire_reachable" == "0" ]]; then
        banner="${banner}Note: Wayfire doesn't look available from apt right now — Ludicrous mode is hidden below. Minimal and Minimal Plus are unaffected.\n\n"
        menu_height=$(( menu_height + 2 ))
    fi

    # Numbers are what the user sees and picks; "actions" is the parallel
    # list of what each number actually does. Built together so hiding
    # Ludicrous just skips a number rather than risking a mismatch.
    local menu_args=() actions=() n=1

    menu_args+=("$n" "Apply the suggested level ($(tier_label "$rec"))"); actions+=(REC); n=$(( n + 1 ))
    menu_args+=("$n" "Apply Minimal mode (standard Pi OS)"); actions+=(MIN); n=$(( n + 1 ))
    menu_args+=("$n" "Apply Minimal Plus (enhanced labwc, no Wayfire)"); actions+=(MINPLUS); n=$(( n + 1 ))
    if [[ "$wayfire_reachable" == "1" ]]; then
        menu_args+=("$n" "Ludicrous mode — apply everything"); actions+=(LUD); n=$(( n + 1 ))
    fi
    menu_args+=("$n" "Help, my desktop is borked — back to standard Pi OS"); actions+=(REVERT); n=$(( n + 1 ))
    menu_args+=("$n" "Backup this look and feel"); actions+=(BACKUP); n=$(( n + 1 ))
    menu_args+=("$n" "Apply a previously saved look and feel"); actions+=(RESTORE); n=$(( n + 1 ))

    local menu_count=$(( n - 1 ))

    local choice
    choice=$(ui --title "wayfire-pi v${WAYFIRE_PI_VERSION}" --cancel-button "Exit" --menu \
        "${banner}Active: ${wayfire_active:-off}   Level: ${current_tier:+$(tier_label "$current_tier")}\nSuggested level for this board: $(tier_label "$rec")\n\nChoose an option:" \
        "$menu_height" 68 "$menu_count" \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || { handle_menu_exit; exit 0; }

    local action="${actions[$(( choice - 1 ))]}"
    case "$action" in
        REC)     apply_tier "$rec" ;;
        MIN)     apply_tier "minimal" ;;
        MINPLUS) apply_tier "minimal_plus" ;;
        LUD)     apply_tier "ludicrous" ;;
        REVERT)  revert_to_pios ;;
        BACKUP)  save_look ;;
        RESTORE) apply_saved_look ;;
    esac

    main_menu
}

handle_menu_exit() {
    local reboot_pending
    reboot_pending=$(get_state "reboot_needed")
    [[ "$reboot_pending" == "yes" ]] || return 0

    if ui --title "wayfire-pi" --yesno "A reboot is needed for your last change to actually take effect.\n\nReboot now?" 10 60; then
        set_state "reboot_needed" "no"
        ui --title "wayfire-pi" --infobox "Rebooting..." 5 40
        sleep 1
        sudo reboot
    fi
}

main() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        echo "wayfire-pi.sh should be run as your normal user, not root/sudo." >&2
        exit 1
    fi

    mkdir -p "$WAYFIRE_PI_HOME"
    bootstrap_ui

    echo "** Sudo access required to manage login sessions and install software. **"
    if ! sudo -v; then
        echo "This script needs sudo access and couldn't get it. Exiting." >&2
        exit 1
    fi

    show_intro || exit 0
    main_menu
}

main "$@"