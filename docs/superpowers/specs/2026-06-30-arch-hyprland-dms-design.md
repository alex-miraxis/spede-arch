# spede-arch — Design Spec

**Date:** 2026-06-30
**Status:** Verified draft (8-agent adversarial verification applied — see §15 changelog)
**Author:** Brainstormed with Claude Code

A from-scratch (no Omarchy) bare-metal installer + dotfiles repo for an **Arch Linux + Hyprland + DankMaterialShell** desktop, with a macOS-style keyboard feel.

---

## 1. Goal & non-goals

**Goal:** A git repo cloned from the live Arch ISO that performs a full bare-metal install of an encrypted, snapshot-capable Arch system running a Hyprland + DankMaterialShell (DMS) desktop, configured for macOS keyboard muscle memory, and symlinks a set of dotfiles.

**Non-goals:**
- Not based on Omarchy or any distro layer — we own every choice.
- Not using the upstream `DankInstall` bootstrapper — DMS is installed the documented manual way so the whole setup lives in this repo.
- Not a laptop build — no battery/brightness/touchpad/power-profile layer (desktop, AMD GPU).

## 2. Target machine (decided)

| Property | Value |
|---|---|
| Form factor | Desktop |
| GPU | AMD (mesa + vulkan-radeon; pure Wayland — **no** `xf86-video-amdgpu`) |
| AUR helper | `yay` (bootstrapped from `yay-bin` as the non-root user) |
| Bootloader | GRUB (required for `grub-btrfs` snapshot menu) |
| Filesystem | Btrfs (snapper layout) on **LUKS2 full-disk encryption** |
| Snapshots | snapper + snap-pac + grub-btrfs (+ grub-btrfs-overlayfs hook) |
| Login | greetd + `greetd-dms-greeter-git` (DANK greeter — greetd-based, **not** SDDM) |
| Seat management | **systemd-logind** (no seatd) |
| Locale | `en_US.UTF-8` primary, `el_GR.UTF-8` also generated |
| Timezone | `Europe/Athens` (+ `hwclock --systohc`, systemd-timesyncd) |
| Keyboard | XKB `us,gr` (no IME), toggle on **Ctrl+Space** (`grp:ctrl_space_toggle` — caveat §8); Caps Lock untouched |

## 3. Install flow

From the official Arch ISO:

```
boot ISO → iwctl (connect wifi) → reflector (refresh mirrors) → pacman -Sy git
→ git clone <repo> → cd spede-arch → ./install.sh
```

### Two-phase architecture

- **Phase A — `install.sh`** (runs once, from the live ISO): preflight → interactive disk selection (loud destructive-wipe confirm) → partition (GPT: FAT32 ESP + LUKS2 partition) → `cryptsetup luksFormat` **with PBKDF2** → Btrfs subvolumes → `pacstrap` the full base set → `genfstab` → copy repo into the new system → `arch-chroot` → run Phase B.
- **Phase B — `setup.sh`** (runs in chroot, **re-runnable** on the booted system): locale/timezone/users/sudoers → mkinitcpio (udev/encrypt + overlayfs) → GRUB (cryptodisk + keyfile) → snapper + grub-btrfs → desktop (Hyprland + DMS) → greeter → input layer (xremap + XKB) → apps → yay + AUR → services → dotfiles (stow) → post-install (Claude Code, Codex). Every mutating step is guarded for idempotency.

Interactive prompts (Phase A): target disk, hostname, username, passwords. Hardcoded: timezone, locale.

## 4. Repo structure

```
spede-arch/
├── install.sh              # Phase A entry (live ISO)
├── setup.sh                # Phase B entry (re-runnable)
├── lib/00-preflight … 13-postinstall  (numbered, sourced steps)
├── packages/{pacman.txt, aur.txt}
├── dotfiles/               # GNU stow packages (one dir per app)
│   ├── hypr/.config/hypr/…
│   ├── ghostty/.config/ghostty/config
│   ├── dms/.config/DankMaterialShell/…
│   ├── xremap/.config/xremap/config.yml
│   ├── zsh/{.zshrc,.p10k.zsh}   # mirrored from the user's Mac; PATH includes ~/.local/bin
│   ├── nvim/.config/nvim   # LazyVim starter
│   └── zed/.config/zed/settings.json
├── wallpapers/
└── README.md
```

## 5. Disk & boot architecture (corrected)

> **Why this section is the most dangerous:** a default LUKS2 container uses Argon2id at 1 GiB memory cost. GRUB 2.14 nominally supports Argon2id but **fails on bare-metal UEFI** (GRUB's 4 GiB EFI heap cap) — producing a *false* "invalid passphrase" on a correct password, or an OOM loading the kernel. Verified first-boot breaker.

- **Partitioning (GPT):** FAT32 ESP (~1 GiB, the only plaintext partition) at `/efi`; one LUKS2 partition for everything else. **`/boot` lives inside the encrypted Btrfs root** (enables single-passphrase + snapshotting of `/boot`).
- **LUKS2 format (GRUB-safe slot):**
  ```
  cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000000 --hash sha256 /dev/<part>
  ```
  PBKDF2/sha256 is the deterministic, GRUB-readable choice. (Alternative: capped Argon2id `--pbkdf-memory 131072`; PBKDF2 is recommended for an unattended installer.) **Never** LUKS1.
- **Btrfs subvolumes (top-level):** `@`→`/`, `@home`→`/home`, **`@snapshots`→`/.snapshots` as a SEPARATE subvolume** (not nested in `@`, or a rollback wipes all snapshots), `@var_log`, `@var_cache`, `@var_tmp`. Mount `noatime,compress=zstd`.
- **mkinitcpio (`udev`/`encrypt` style — NOT systemd, because `grub-btrfs-overlayfs` is incompatible with the systemd hook):**
  ```
  MODULES=(amdgpu)
  FILES=(/crypto_keyfile.bin)
  HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck grub-btrfs-overlayfs)
  ```
  `encrypt` before `filesystems`; `grub-btrfs-overlayfs` LAST (or snapshot boots are read-only).
- **Single passphrase:** binary keyfile added as an extra LUKS keyslot, embedded in initramfs via `FILES=`, referenced by `cryptkey=rootfs:/crypto_keyfile.bin`. Safe because `/boot`/initramfs are inside the LUKS container — GRUB unlocks once via the typed passphrase; the keyfile only suppresses the *second* (kernel-stage) prompt.
- **GRUB:**
  ```
  GRUB_ENABLE_CRYPTODISK=y
  GRUB_CMDLINE_LINUX="cryptdevice=UUID=<LUKS-UUID>:cryptroot root=/dev/mapper/cryptroot cryptkey=rootfs:/crypto_keyfile.bin"
  GRUB_PRELOAD_MODULES="part_gpt cryptodisk luks2 gcry_sha256 gcry_pbkdf2 btrfs"
  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --recheck
  grub-mkconfig -o /boot/grub/grub.cfg
  ```
- **Snapshots:** snapper root config (with the standard "delete snapper's nested `.snapshots`, mount `@snapshots` there" dance), `snap-pac` (auto pre/post pacman snapshots), enable `snapper-timeline.timer`, `snapper-cleanup.timer`, **`grub-btrfs.path`** (regenerates the snapshot submenu). `amd-ucode` (auto-detected by grub-mkconfig). `inotify-tools` for grub-btrfsd.

## 6. Desktop stack (corrected)

- **Hyprland** + **DankMaterialShell (DMS)**. DMS (Quickshell + Go) replaces waybar, swaylock, swayidle, mako, fuzzel, **and the polkit agent** — so we do **NOT** install `hyprpaper`, `hyprlock`, `hypridle`, or `hyprpolkitagent` (DMS provides wallpaper, lock, idle, polkit; duplicates conflict).
- **DMS sourcing (corrected):** `quickshell`, `matugen`, `dgop` are now in the **official `extra` repo** (`pacman`, *not* AUR — the bare AUR names don't exist). The shell itself is **`dms-shell-git` (AUR)** for a repo-only install *(build-time check: if `dms-shell` is confirmed in `extra`, prefer it; the stable build otherwise lives in DankLinux's third-party repo which we avoid)*. `accountsservice` is pulled automatically.
- **Launch:** `exec-once = dms run` in `hyprland.conf` (not `qs -c dms`; don't also enable a DMS systemd unit or it runs twice). Generate starter config with `dms setup`.
- **Glue still required** (DMS does NOT replace these): `xdg-desktop-portal` + `xdg-desktop-portal-hyprland` + `xdg-desktop-portal-gtk` (file pickers/screenshare), `qt6-wayland` (or Qt apps crash), `polkit` (framework), `wl-clipboard`, `cliphist`, screenshot tools (grim/slurp/hyprshot/satty), `xdg-user-dirs`.
- **Login:** `greetd` + `greetd-dms-greeter-git`. greetd `config.toml` `[default_session]` runs `dms-greeter --command hyprland -C /etc/greetd/hypr.conf`; run `dms greeter enable && dms greeter sync` (adds user to `greeter` group, sets ACLs); **reboot after sync** or the greeter can't read the theme. Known first-boot failure (GH #494 "stuck on boot") is a Qt-Wayland-plugin/permissions issue → ensure `qt6-wayland` + cursor libs, and test `dms-greeter` from a TTY before enabling greetd at boot.
- **Theming (corrected — Kvantum DROPPED):** DMS themes Qt **and** GTK apps itself via matugen (it writes the qt6ct color scheme + `gtk.css`). Layering a static Catppuccin-Kvantum theme would *fight* DMS. So: install `adw-gtk-theme` + `qt6ct` (DMS's theming targets), **no Kvantum/catppuccin-kvantum**. DMS applies **Catppuccin Mocha (built-in selectable theme)** by default; **matugen dynamic (wallpaper-derived) theming is a toggle** (`Cmd+Shift+Y` / Settings). `QT_QPA_PLATFORMTHEME` set per DMS docs (qt6ct or gtk3 passthrough). hyprpaper dropped — DMS owns the wallpaper (`dms ipc call wallpaper set`), which is what makes matugen work.

## 7. Input architecture — the macOS-feel layer (corrected)

```
physical keys ─▶ xremap (EVIOCGRAB → uinput; Hyprland window-class aware; exact_match:true)
                   │  Super+letter → Ctrl+letter   (GUI apps; Ghostty excluded)
                   │  Super+digit  → Ctrl+digit     (browser tabs)
                   │  Super+arrow  → Home/End/etc.  (macOS line nav)
                   │  Super+Shift+{T,V} → Ctrl+Shift+{T,V}  (reopen-tab / paste-plain)
                   ▼
                 Hyprland  (Super+Enter/Space/Q/Shift…, Super+Ctrl+…, Alt+digit)
                   ▼
                 focused app
```

- **`$mod = SUPER` (Cmd)** drives Hyprland. **`xremap` from `xremap-hypr-bin` (AUR, built with the `hypr` feature)** runs as a `systemd --user` service with `--watch` (or `exec-once` from Hyprland so it inherits `HYPRLAND_INSTANCE_SIGNATURE`). Requires a udev rule + `input` group:
  ```
  /etc/udev/rules.d/99-input.rules:
    KERNEL=="uinput", GROUP="input", TAG+="uaccess", MODE:="0660", OPTIONS+="static_node=uinput"
  gpasswd -a $USER input ; modprobe uinput (+ /etc/modules-load.d/uinput.conf)
  ```
- **`exact_match: true` is mandatory.** Without it, `Super+Shift+F/B/Y` and `Super+Shift+3/4/5` get swallowed (loose matching rewrites them as `Ctrl+Shift+…` and Hyprland never sees the bind).
- **xremap `keymap`** (GUI apps; `application: { not: [/com.mitchellh.ghostty/] }`): `Super+{a,c,v,x,z,s,f,t,w,r,n,l,p}` → `Ctrl+…`; `Super+{1..9}` → `Ctrl+{1..9}`; **explicit** `Super+Shift+t→Ctrl+Shift+t`, `Super+Shift+v→Ctrl+Shift+v`; **macOS line-nav** `Super+Left→Home`, `Super+Right→End`, `Super+Up→Ctrl+Home`, `Super+Down→Ctrl+End`, and `Super+Shift+arrows→Shift+Home/End/Ctrl+Shift+Home/End`.
- **Ghostty** is excluded by class `com.mitchellh.ghostty` and gets native macOS binds (§8), so `Cmd+C`=copy and `Ctrl+C`=SIGINT.
- **Never** put `Super+Enter/Space/Q`, any `Super+Shift+*` WM bind, or any `Super+Ctrl+*` into xremap — those pass through to Hyprland untouched.

### Three-tier modifier model

| Modifier | Role |
|---|---|
| **Cmd** (Super) | App shortcuts (→Ctrl) + line-nav + launching apps + close window |
| **Cmd+Ctrl** | Window control — focus, move, fullscreen, lock (`Cmd+Ctrl+F`/`Cmd+Ctrl+Q` are the real macOS shortcuts) |
| **Option** (Alt) | Spaces / workspaces (xremap never touches Alt) |

## 8. Keybindings (final)

### App shortcuts — xremap Super→Ctrl for GUI apps (Ghostty excluded)

| Press | App gets | Press | App gets |
|---|---|---|---|
| Cmd+C/V/X | Copy/Paste/Cut | Cmd+T/W | New tab / Close tab |
| Cmd+Z / Shift+Z | Undo / Redo | Cmd+N/R | New window / Reload |
| Cmd+A/S/F | Select-all/Save/Find | Cmd+L/P | Address bar / Print |
| Cmd+1–9 | Browser tab 1–9 | Cmd+←/→ | Line start/end |
| Cmd+↑/↓ | Doc top/bottom | Cmd+Shift+←/→ | Select to line bounds |
| Cmd+Shift+T | Reopen closed tab | Cmd+Shift+V | Paste without formatting |

### Ghostty (terminal) — native binds (corrected syntax)

```
keybind = performable:super+c=copy_to_clipboard
keybind = super+v=paste_from_clipboard
keybind = super+t=new_tab
keybind = super+w=close_surface
keybind = super+d=new_split:right
keybind = super+equal=increase_font_size:1
keybind = super+minus=decrease_font_size:1
# optional: confirm-close-surface = false
```

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

**Accepted tradeoffs:** `Cmd+Shift+F` (Dolphin) shadows editor "find-in-files"; `Cmd+Shift+B` shadows "toggle bookmarks bar."

**⚠ Ctrl+Space caveat (your call at review):** macOS-authentic, but it shadows Ctrl+Space autocomplete in editors (Zed/Emacs). We avoid the worse IME-grab problem by using plain XKB `us,gr` (no fcitx5/ibus). Alternative toggles if you'd rather: `grp:alt_shift_toggle` or `grp:caps_toggle`. **Kept as Ctrl+Space per your explicit choice.**

## 9. Packages (verified sources)

**Pacstrap base (Phase A, into the target):** `base base-devel linux linux-firmware amd-ucode btrfs-progs cryptsetup grub efibootmgr grub-btrfs snapper snap-pac inotify-tools networkmanager sudo git vim reflector pacman-contrib zsh stow`. *(NetworkManager in pacstrap is non-negotiable — without it the rebooted system has no network.)* Consider `linux-lts` as a fallback kernel.

**Official `extra` (pacman):** hyprland, quickshell, matugen, dgop, accountsservice, greetd, xdg-desktop-portal(+-hyprland,+-gtk), polkit, qt6-wayland, qt5-wayland, qt6ct, adw-gtk-theme, wl-clipboard, cliphist, brightnessctl, mesa, vulkan-radeon, libva-mesa-driver, vulkan-icd-loader, xdg-user-dirs, pipewire, pipewire-pulse, pipewire-alsa, wireplumber, bluez, bluez-utils, cups, system-config-printer, gutenprint, foomatic-db, avahi, nss-mdns, ufw, ghostty, dolphin, ark, kio-extras, kdegraphics-thumbnailers, ffmpegthumbs, vlc, vlc-plugins-all, zed, neovim, ripgrep, fd, **openai-codex**, telegram-desktop, **bitwarden, bitwarden-cli**, grim, slurp, satty, noto-fonts, noto-fonts-cjk, noto-fonts-emoji, ttf-jetbrains-mono-nerd, ttf-meslo-nerd (p10k), inter-font, ttf-inter, ... + Manrope (AUR `ttf-manrope` if not in repo).

**AUR (`yay`, after key imports):** `dms-shell-git`, `greetd-dms-greeter-git`, `xremap-hypr-bin`, `helium-browser-bin` ⚠PGP, `1password` + `1password-cli` ⚠PGP, `zapzap` (WhatsApp), `slack-desktop`, `hyprshot`, Manrope font.

**External installers (Phase B, as the user):**
- Claude Code: `curl -fsSL https://claude.ai/install.sh | bash` → `~/.local/bin/claude` (no npm; ensure `~/.local/bin` on PATH).
- Codex: `pacman -S openai-codex` (now official — *no AUR*).
- Notion: Helium PWA `.desktop` (`helium --app=https://www.notion.so`); no official Linux app.
- LazyVim: `git clone https://github.com/LazyVim/starter ~/.config/nvim && rm -rf ~/.config/nvim/.git` (needs ripgrep + fd).

**Mandatory PGP key imports (as the building user, before yay):**
```
# Helium (required since 0.7.7.2):
gpg --keyserver keyserver.ubuntu.com --recv-keys BE677C1989D35EAB2C5F26C9351601AD01D6378E
# 1Password (AgileBits):
gpg --keyserver keyserver.ubuntu.com --recv-keys 3FEF9748469ADBE15DA7CA80AC2D62742012EA22
```

## 10. Services, theming & system (verified)

- **AUR bootstrap:** as the non-root user — `git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si` (makepkg refuses root). Set `/etc/makepkg.conf` `MAKEFLAGS="-j$(nproc)"`.
- **Audio:** `systemctl --user enable --now pipewire pipewire-pulse wireplumber`. Ensure pulseaudio is NOT installed.
- **Bluetooth:** `systemctl enable --now bluetooth.service`; DMS provides the applet (no blueman).
- **Printing:** `systemctl enable --now cups.socket` (socket-activated) + `avahi-daemon.service`; nsswitch hosts line `... mdns_minimal [NOTFOUND=return] resolve ... dns`; `ufw allow 5353/udp`.
- **Network:** `systemctl enable --now NetworkManager.service`.
- **Firewall:** `ufw default deny incoming; ufw default allow outgoing; ufw allow 5353/udp; ufw enable`.
- **Time/locale:** `ln -sf /usr/share/zoneinfo/Europe/Athens /etc/localtime; hwclock --systohc`; enable `systemd-timesyncd`; `locale-gen` for en_US.UTF-8 + el_GR.UTF-8; `LANG=en_US.UTF-8`.
- **sudo:** `usermod -aG wheel $USER` + `/etc/sudoers.d/10-wheel` drop-in (idempotent).
- **Hyprland env:** `XDG_CURRENT_DESKTOP=Hyprland`, `XDG_SESSION_TYPE=wayland`, `QT_QPA_PLATFORM="wayland;xcb"`, `QT_QPA_PLATFORMTHEME` per DMS. AMD needs no special GBM/NVIDIA vars.

## 11. Dotfiles (with corrected ordering)

GNU **stow**, one package per app. **Ordering matters:** install oh-my-zsh with `RUNZSH=no KEEP_ZSHRC=yes`, `chsh -s /usr/bin/zsh`, **then** stow — otherwise omz clobbers the stowed `.zshrc`. stow aborts on pre-existing regular files, so Phase B backs up/clears conflicts (or uses `stow --adopt`/`--restow`). The user's real `.zshrc` + `.p10k.zsh` are mirrored from their Mac; the `.zshrc` puts `~/.local/bin` on PATH (for Claude Code).

## 12. Phase B idempotency

`pacman -S --needed`; `systemctl enable` is idempotent; wrap `useradd`/`gpasswd` in `id`/`getent` checks; `stow --restow`; guard `dms greeter sync` and key imports against re-runs. So `setup.sh` can be re-run safely to repair/update.

## 13. Risks & mitigations (verified)

1. **LUKS2/GRUB Argon2id → rescue shell / false bad-password.** → PBKDF2 GRUB slot + `GRUB_ENABLE_CRYPTODISK=y` + preload modules. Test on the *real* board (VMs often pass where hardware fails).
2. **systemd initramfs hook breaks grub-btrfs-overlayfs (silent read-only rollback).** → use `udev`/`encrypt` + overlayfs LAST.
3. **`@snapshots` nested in `@` → rollback destroys snapshots.** → separate top-level subvolume; verify with `btrfs subvolume list /`.
4. **PGP-gated AUR (Helium, 1Password) fail unattended.** → import keys first; 1Password key periodically expires (re-`recv-keys`).
5. **dms-greeter first-boot stall (Qt/permissions).** → qt6-wayland + cursor libs; reboot after `dms greeter sync`; TTY-test first; no other DM enabled.
6. **No NetworkManager in pacstrap → no net after reboot** (then all AUR/CLI installers fail).
7. **xremap user service may miss `HYPRLAND_INSTANCE_SIGNATURE`** (Ghostty exclude silently fails → terminal copy breaks). → launch via `exec-once` or import env into the user manager.
8. **Theming double-up:** Kvantum + DMS auto-theme fight. → Kvantum dropped.

## 14. Open items defaulted (correct if wrong)

- Repo name `spede-arch` · WhatsApp = `zapzap` (Wayland fallback if glitchy) · Notion = Helium PWA · theme toggle `Cmd+Shift+Y` · clipboard history `Cmd+Ctrl+V` · Ctrl+Space layout toggle kept (editor-autocomplete caveat) · `dms-shell-git` from AUR unless `dms-shell` confirmed in `extra` at build time.

## 15. Verification changelog (what the 8-agent pass changed)

- **Disk:** PBKDF2 (not "GRUB can't do Argon2id" — it can, but it breaks); exact hooks/keyfile/GRUB modules; `@snapshots` separate; `grub-btrfs.path` + overlayfs hook; udev-not-systemd initramfs.
- **DMS:** quickshell/matugen/dgop are `extra` not AUR; shell = `dms-shell-git`; `exec-once = dms run`; drop hyprpaper/hyprlock/hypridle/hyprpolkitagent; greeter command + sync + reboot; Kvantum dropped (DMS themes Qt/GTK).
- **Input:** `exact_match: true`; added `Super+Shift+T/V` and `Super+arrow` line-nav entries; xremap udev/group/service; Ghostty class confirmed.
- **Ghostty:** `new_split:right`, `increase_font_size:1`, `super+equal`; only `super+c` performable.
- **Apps:** Codex/Zed/Bitwarden now official `extra`; Helium + 1Password PGP keys; VLC plugins; Dolphin thumbnailers; LazyVim deps; Claude Code native installer path.
- **Services:** pipewire `--user` units; `cups.socket`; qt6-wayland for portals; ufw 5353/udp; nsswitch mDNS.
- **Completeness:** live-ISO bootstrap + full pacstrap set; AMD mesa/vulkan userspace; systemd-logind for seat; yay-bin bootstrap; idempotency + stow ordering; enable-all-services checklist.
