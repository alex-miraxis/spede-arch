# spede-arch — Design Spec

**Date:** 2026-06-30
**Status:** Draft (technical assumptions under adversarial verification — see §13)
**Author:** Brainstormed with Claude Code

A from-scratch (no Omarchy) bare-metal installer + dotfiles repo for an **Arch Linux + Hyprland + DankMaterialShell** desktop, with a macOS-style keyboard feel.

---

## 1. Goal & non-goals

**Goal:** A git repo cloned from the live Arch ISO that performs a full bare-metal install of an encrypted, snapshot-capable Arch system running a Hyprland + DankMaterialShell (DMS) desktop, configured for macOS keyboard muscle memory, and symlinks a set of dotfiles.

**Non-goals:**
- Not based on Omarchy or any distro layer — we own every choice.
- Not using the upstream `DankInstall` bootstrapper — DMS is installed the documented manual way so the whole setup lives in this repo and is reproducible.
- Not a laptop build — no battery/brightness/touchpad/power-profile layer (desktop, AMD GPU).

## 2. Target machine (decided)

| Property | Value |
|---|---|
| Form factor | Desktop |
| GPU | AMD (iGPU or dGPU) — mesa, native Wayland |
| AUR helper | `yay` |
| Bootloader | GRUB (required for `grub-btrfs` snapshot menu) |
| Filesystem | Btrfs (snapper layout) on **LUKS2 full-disk encryption** |
| Snapshots | snapper + snap-pac + grub-btrfs |
| Login | greetd + `greetd-dms-greeter-git` (DANK's greeter — greetd-based, **not** SDDM) |
| Locale | `en_US.UTF-8` primary, `el_GR.UTF-8` also generated |
| Timezone | `Europe/Athens` |
| Keyboard layouts | `us`, `gr`; toggle on **Ctrl+Space** (`grp:ctrl_space_toggle`); Caps Lock untouched |

## 3. Install flow

On the metal, from the official Arch ISO:

```
boot ISO → iwctl (connect wifi) → pacman -Sy git
→ git clone <repo> → cd spede-arch → ./install.sh
```

### Two-phase architecture

A bare-metal installer is one-shot and destructive, so we split:

- **Phase A — `install.sh`** (runs once, from the live ISO): preflight checks → interactive disk selection (loud destructive-wipe confirmation) → partition → LUKS2 → Btrfs subvolumes → `pacstrap` base + kernel + microcode + NetworkManager → `genfstab` → copy repo into the new system → `arch-chroot` → run Phase B.
- **Phase B — `setup.sh`** (runs inside chroot, and is **re-runnable** on the booted system for repair/update): locale/timezone/users → bootloader (GRUB + cryptodisk + grub-btrfs) → snapper → desktop (Hyprland + DMS) → greeter → apps → AUR → services → input layer → dotfiles (stow) → post-install (Claude Code, Codex).

Interactive prompts (Phase A): target disk, hostname, username, passwords. Hardcoded: timezone, locale.

## 4. Repo structure

```
spede-arch/
├── install.sh              # Phase A entry (live ISO)
├── setup.sh                # Phase B entry (re-runnable)
├── lib/                    # numbered, sourced steps
│   ├── 00-preflight.sh     # UEFI check, internet, disk pick + confirm
│   ├── 01-disk.sh          # partition, LUKS2, btrfs subvols, mount
│   ├── 02-pacstrap.sh      # base, linux, amd-ucode, networkmanager, btrfs-progs…
│   ├── 03-system.sh        # locale, tz, hosts, users, sudoers
│   ├── 04-boot.sh          # mkinitcpio hooks, GRUB + cryptodisk + keyfile, grub-btrfs
│   ├── 05-snapper.sh       # snapper config, snap-pac, timers
│   ├── 06-desktop.sh       # hyprland, DMS stack, portals, polkit
│   ├── 07-greeter.sh       # greetd + dms-greeter, theme sync, ACLs
│   ├── 08-input.sh         # xremap service, XKB layouts, ghostty binds
│   ├── 09-apps.sh          # ghostty, dolphin, vlc, zed, nvim/LazyVim…
│   ├── 10-aur.sh           # yay bootstrap + AUR pkgs (helium, dms, 1password…)
│   ├── 11-services.sh      # pipewire, bluetooth, cups+avahi, NetworkManager, ufw
│   ├── 12-dotfiles.sh      # stow packages
│   └── 13-postinstall.sh   # Claude Code installer, Codex, final touches
├── packages/
│   ├── pacman.txt          # official-repo packages
│   └── aur.txt             # AUR packages
├── dotfiles/               # GNU stow packages (one dir per app)
│   ├── hypr/.config/hypr/…
│   ├── ghostty/.config/ghostty/config
│   ├── dms/.config/…       # DMS config + Catppuccin Mocha theme
│   ├── xremap/.config/xremap/config.yml
│   ├── zsh/{.zshrc,.p10k.zsh}   # mirrored from the user's Mac
│   ├── nvim/.config/nvim   # LazyVim
│   └── zed/.config/zed/settings.json
├── wallpapers/
└── README.md
```

## 5. Disk & boot architecture

- **LUKS2 full-disk encryption** — single passphrase at boot. The container GRUB must read uses a GRUB-compatible KDF (PBKDF2 unless current GRUB confirms Argon2id support — see §13).
- **Btrfs** snapper-friendly subvolume layout: `@` → `/`, `@home` → `/home`, `@snapshots` → `/.snapshots`, plus `@var_log`, `@var_cache`, `@var_tmp` (excluded from snapshots), `@swap` (optional, CoW-disabled) for hibernation if wanted.
- **GRUB** with `GRUB_ENABLE_CRYPTODISK=y`. To avoid a double passphrase prompt (GRUB then kernel), a **keyfile is embedded in the initramfs** (`FILES=` in mkinitcpio + `cryptkey=` on the kernel cmdline). ESP mounted at `/boot` or `/efi` (decided in §13 per the single-vs-separate-/boot tradeoff).
- **mkinitcpio** HOOKS include `encrypt` and `btrfs` in the correct order (confirmed in §13).
- **snapper** root config + **snap-pac** (auto pre/post snapshots on every pacman transaction) + **grub-btrfs** (`grub-btrfsd` watches `/.snapshots` and regenerates the GRUB submenu so you can boot any snapshot). `amd-ucode` microcode.

## 6. Desktop stack

- **Hyprland** (Wayland compositor) + **DankMaterialShell (DMS)** as the shell. DMS (Quickshell + Go) replaces waybar, swaylock, swayidle, mako, fuzzel, and the polkit agent in one process, and provides: top bar, notifications, app launcher, lock screen, idle, **wallpaper management + matugen dynamic theming**, and the bluetooth / audio / network applets.
- DMS installed from AUR the documented manual way (components: quickshell, matugen, dgop, the DMS package, accountsservice — exact names confirmed in §13). **Not** via `DankInstall`.
- **Glue DMS does not provide** that we still install: `xdg-desktop-portal-hyprland` + `xdg-desktop-portal-gtk`, `wl-clipboard`, screenshot tooling (grim/slurp/hyprshot + satty), cliphist (clipboard history).
- **Login:** `greetd` + `greetd-dms-greeter-git`, theme-synced via `dms greeter sync`; greeter group + ACLs configured so the greeter can read the theme.
- **Theme:** Catppuccin Mocha default (DMS ships Catppuccin). DMS manages the wallpaper, so **matugen dynamic (wallpaper-derived) theming is one keybind away** (`Cmd+Shift+Y`). hyprpaper is dropped (would bypass matugen).
- **Qt/GTK consistency:** Dolphin and VLC are Qt — themed to match via kvantum + Catppuccin-kvantum + `qt6ct`/`QT_QPA_PLATFORMTHEME`; GTK apps get the Catppuccin GTK theme. (Exact env vars in §13.)

## 7. Input architecture — the macOS-feel layer

```
physical keys ─▶ xremap (Hyprland window-class aware) ─▶ Hyprland ─▶ focused app
                   │                                       │
   Super+letter → Ctrl+letter for GUI apps;     handles Super+(Enter/Space/Q/Shift…),
   Super+1-9 → Ctrl+1-9 (browser tabs);         Super+Ctrl+… (window control),
   Ghostty EXCLUDED by window class             Alt+digit (workspaces)
```

- **`$mod = SUPER` (the Cmd key)** drives Hyprland.
- **`xremap`** (user systemd service; native Hyprland IPC for window-class detection) translates the macOS app-shortcut set `Super+{C,V,X,Z,Shift+Z,A,S,F,T,W,N,R,L,P}` → `Ctrl+…` and `Super+{1–9}` → `Ctrl+{1–9}` (browser tabs) **for GUI apps**, and **excludes Ghostty** by window class.
- **Ghostty** gets native macOS-style binds (`performable:super+c=copy_to_clipboard`, etc.) so in the terminal `Cmd+C` = copy and `Ctrl+C` = SIGINT.
- **XKB:** layouts `us,gr`; switch on **Ctrl+Space** (`grp:ctrl_space_toggle`). Caps Lock left as-is.

### The three-tier modifier model

| Modifier | Role |
|---|---|
| **Cmd** (Super) | App shortcuts (→Ctrl) + launching apps + close window |
| **Cmd+Ctrl** | Window *control* — focus, move, fullscreen, lock (Cmd+Ctrl+F and Cmd+Ctrl+Q are the real macOS shortcuts) |
| **Option** (Alt) | Spaces / workspaces |

Each tier lives on a distinct modifier, which is *why* the xremap translation never fights the window manager.

## 8. Keybindings (final)

### App shortcuts — xremap translates Super→Ctrl for GUI apps (Ghostty excluded)

| Press | App gets | Press | App gets |
|---|---|---|---|
| Cmd+C / V / X | Copy / Paste / Cut | Cmd+T / W | New tab / Close tab |
| Cmd+Z / Shift+Z | Undo / Redo | Cmd+N / R | New window / Reload |
| Cmd+A / S / F | Select-all / Save / Find | Cmd+L / P | Address bar / Print |
| Cmd+1–9 | Browser tab 1–9 (→Ctrl+1–9) | | |

Kept for apps (not bound in Hyprland): `Cmd+arrows` = line nav, `Cmd+Shift+arrows` = select to line bounds, `Cmd+Shift+T` = reopen closed tab, `Cmd+Shift+V` = paste without formatting.

### Window manager — Hyprland

| Action | Bind | Action | Bind |
|---|---|---|---|
| Terminal (Ghostty) | Cmd+Enter | Close window | Cmd+Q |
| Launcher (DMS) | Cmd+Space | Float toggle | Cmd+Shift+Space |
| Browser (Helium) | Cmd+Shift+B | Power / logout menu | Cmd+Shift+Q |
| Files (Dolphin) | Cmd+Shift+F | Focus ←↑↓→ | Cmd+Ctrl+arrows |
| Fullscreen | Cmd+Ctrl+F | Move window | Cmd+Ctrl+Shift+arrows |
| Lock | Cmd+Ctrl+Q | Clipboard history | Cmd+Ctrl+V |
| Workspace 1–9 | Option+1…9 | Move window → ws | Option+Shift+1…9 |
| Dynamic theme toggle | Cmd+Shift+Y | Screenshots | Cmd+Shift+3 / 4 / 5 |

Screenshots: `Cmd+Shift+3` = full · `Cmd+Shift+4` = region + annotate (satty) · `Cmd+Shift+5` = options.

**Accepted tradeoffs:** `Cmd+Shift+F` (Dolphin) shadows editor "find in files"; `Cmd+Shift+B` shadows browser "toggle bookmarks bar." Both accepted.

## 9. Packages (grouped — exact names finalized by §13 verification)

- **Base/boot:** base, linux, linux-firmware, amd-ucode, btrfs-progs, cryptsetup, grub, efibootmgr, grub-btrfs, snapper, snap-pac, networkmanager, sudo, zsh, git, base-devel.
- **WM/shell:** hyprland, quickshell, matugen, dgop, DMS, accountsservice, greetd, greetd-dms-greeter-git, xdg-desktop-portal-hyprland, xdg-desktop-portal-gtk, polkit, wl-clipboard, qt6-wayland, qt5-wayland.
- **Input:** xremap (Hyprland feature build).
- **Apps:** ghostty, dolphin (+ark, kio-extras), helium-browser-bin ⚠PGP, slack-desktop, vlc, zed, neovim (+LazyVim), telegram-desktop, zapzap (WhatsApp), bitwarden, 1password + 1password-cli ⚠PGP, Notion (Helium PWA).
- **AI CLIs:** Claude Code (official native installer), Codex (AUR native binary) — **no npm**.
- **Shell/theme:** oh-my-zsh, powerlevel10k, kvantum, catppuccin-kvantum, qt6ct, Catppuccin GTK.
- **Fonts:** MesloLGS NF, a Nerd Font set, Inter, Manrope, Noto (+ Greek) + emoji.
- **Extras:** grim, slurp, hyprshot, satty, cliphist, ffmpeg + gstreamer codecs, imv, zathura.

## 10. Services & system

- **Audio:** pipewire + wireplumber + pipewire-pulse + pipewire-alsa (user session).
- **Bluetooth:** bluez + bluez-utils, `bluetooth.service`; applet via DMS.
- **Printing:** cups + drivers (gutenprint/foomatic) + avahi + nss-mdns; `/etc/nsswitch.conf` edited for `.local` mDNS network-printer discovery.
- **Network:** NetworkManager (wifi); DMS network applet.
- **Firewall:** ufw, default-deny incoming.
- **Misc:** systemd-timesyncd, xdg-user-dirs, reflector (mirror ranking).

## 11. Dotfiles

GNU **stow**: each app's config is a stow package; `stow hypr ghostty dms xremap zsh nvim zed …` symlinks them into `$HOME`. Fully reversible. The user's real `.zshrc` + `.p10k.zsh` are mirrored from their Mac. Phase B handles stow conflicts (back up / adopt pre-existing files).

## 12. Risks & mitigations

1. **GRUB + LUKS2 single-passphrase** is the fiddliest piece → correct KDF + initramfs keyfile, verified in §13, tested early.
2. **PGP-gated AUR packages** (Helium, 1Password) → import signing keys before building or the build fails.
3. **dms-greeter first-boot failures** (known "stuck on boot" / "can't login" issues) → follow upstream greeter setup + ACLs exactly; keep a TTY fallback.
4. **Bare-metal install is not idempotent** → Phase A/B split; Phase B re-runnable.
5. **Wifi after reboot** → `networkmanager` must be in the pacstrap set and enabled, or the rebooted system has no network.

## 13. Technical assumptions under verification

An adversarial verification pass (8 parallel researchers, current-2026 Arch practice) is hardening these before implementation:
disk/LUKS/GRUB/snapper correctness · xremap per-app Hyprland remap feasibility + exact YAML · DMS + dms-greeter exact packages & config · Ghostty super-keybind config · AUR app names + PGP steps · full keybind collision audit · services/portals/theming · a completeness critic for first-boot gaps.

Findings are folded back into this spec before the implementation plan is written.

## 14. Open decisions defaulted (correct if wrong)

- Repo name `spede-arch` · WhatsApp = `zapzap` · Notion = Helium PWA · theme toggle on `Cmd+Shift+Y` · clipboard history on `Cmd+Ctrl+V`.
