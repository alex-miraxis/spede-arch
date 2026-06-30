# spede-arch — Build Manifest

This is the authoritative ownership map for the installer. Each downstream
agent owns exactly one `lib/NN-*.sh` step file (or a dotfile package) and
codes against the contract in `lib/common.sh`. Honor the spec at
`docs/superpowers/specs/2026-06-30-arch-hyprland-dms-design.md` exactly.

> **⚠️ Runtime testing happens on the Arch box, never on macOS.** This repo is
> authored on macOS, but `install.sh` / `setup.sh` exercise `cryptsetup`,
> `pacstrap`, `arch-chroot`, GRUB, mkinitcpio, snapper, Hyprland and systemd —
> none of which exist or behave correctly on macOS. Shell *syntax* is checked
> here with `shellcheck`; **behavioral** verification (especially the LUKS/GRUB
> first-boot path) MUST be done on the real AMD hardware.

---

## libContract (every `lib/NN-<name>.sh` step file)

1. **No** shebang, **no** `set -euo pipefail`, **no** `IFS=` — `common.sh` owns
   those. Step files are sourced into that context by `install.sh` / `setup.sh`.
2. Define **exactly one** function, `step_<name>`, matching the filename
   (`lib/01-disk.sh` → `step_disk`). No other top-level functions.
3. **Nothing executes at source time.** Pure definitions; zero side effects on
   source. All work runs only when the `step_<name>` function is called.
4. Use **only** the helpers/globals from `common.sh` (see below). Do not
   re-define them.
5. Every mutating action is **idempotent** (`pacman -S --needed`,
   `id`/`getent` guards, `ensure_line`, `stow --restow`, re-run-safe checks).

The full contract comment lives at the top of `lib/common.sh`.

---

## Shared API (defined in `lib/common.sh`)

**Logging (stderr):** `log` `info` `warn` `err` `ok` `die`
**Helpers:** `confirm "prompt"` · `need_cmd name` · `in_chroot` ·
`as_user USER CMD...` · `pkg_install PKGS...` · `aur_install PKGS...` ·
`ensure_line FILE LINE` · `backup_file PATH` · `enable_service NAME` ·
`enable_user_service_global NAME` · `save_config` / `load_config`
**Global defaults:** `TIMEZONE=Europe/Athens` · `LOCALE_PRIMARY=en_US.UTF-8` ·
`LOCALE_EXTRA=el_GR.UTF-8` · `KEYFILE=/crypto_keyfile.bin` · `NEWROOT=/mnt` ·
`REPO_DEST=/root/spede-arch`
**Runtime (persisted to `REPO_DEST/.install-config`):** `TARGET_DISK` ·
`NEW_HOSTNAME` · `NEW_USER`

---

## File-ownership map

| File | Function | Phase | Owns (per spec) |
|---|---|---|---|
| `lib/common.sh` | — | both | shebang/set/IFS, logging, all helpers, globals, config persistence |
| `install.sh` | `main` | A | live-ISO entry; calls preflight→disk→pacstrap; copies repo; arch-chroot→setup.sh |
| `setup.sh` | `main` | B | re-runnable entry; sources lib/03..13; calls steps in order |
| `lib/00-preflight.sh` | `step_preflight` | A | UEFI/root/network checks, `reflector`, interactive disk+hostname+user prompts, `save_config` (§3) |
| `lib/01-disk.sh` | `step_disk` | A | GPT (FAT32 ESP + LUKS2), `luksFormat --pbkdf pbkdf2 …`, keyfile keyslot, Btrfs subvols `@ @home @snapshots @var_log @var_cache @var_tmp`, mount `noatime,compress=zstd` (§5) |
| `lib/02-pacstrap.sh` | `step_pacstrap` | A | `pacstrap` base set from `packages/pacman.txt`, `genfstab` (§9) |
| `lib/03-system.sh` | `step_system` | B | timezone+`hwclock`, locale-gen (en_US+el_GR), hostname, user/`wheel`, sudoers drop-in, base `mkinitcpio.conf` MODULES/FILES/HOOKS (§5/§10) |
| `lib/04-boot.sh` | `step_boot` | B | GRUB `GRUB_ENABLE_CRYPTODISK`, `GRUB_CMDLINE_LINUX` cryptdevice+cryptkey, `GRUB_PRELOAD_MODULES`, `grub-install`, `grub-mkconfig`, `mkinitcpio -P` (§5) |
| `lib/05-snapper.sh` | `step_snapper` | B | snapper root config + `.snapshots` dance, `snap-pac`, `grub-btrfs.path`, snapper timers (§5) |
| `lib/06-desktop.sh` | `step_desktop` | B | Hyprland + DMS (quickshell/matugen/dgop), `dms-shell-git`, portals/qt6-wayland/polkit glue, `dms setup`, theming targets (no Kvantum) (§6) |
| `lib/07-apps.sh` | `step_apps` | B | official-repo apps from `packages/pacman.txt` (terminal/files/media/editors/messaging) (§9) |
| `lib/08-aur.sh` | `step_aur` | B | `/etc/makepkg.conf` MAKEFLAGS, `yay-bin` bootstrap as user, PGP key imports, AUR installs from `packages/aur.txt` (§9/§10) |
| `lib/09-greeter.sh` | `step_greeter` | B | greetd `config.toml` + `/etc/greetd/hypr.conf`, `dms greeter enable && sync`, enable greetd (reboot-after-sync note) (§6) |
| `lib/10-input.sh` | `step_input` | B | xremap user service, `/etc/udev/rules.d/99-input.rules`, `input` group, `uinput` modules-load, XKB `us,gr` ctrl_space_toggle (§7/§8) |
| `lib/11-services.sh` | `step_services` | B | NetworkManager, pipewire `--user` (global), bluetooth, `cups.socket`, avahi + nsswitch mDNS, ufw rules, timesyncd (§10) |
| `lib/12-dotfiles.sh` | `step_dotfiles` | B | oh-my-zsh `RUNZSH=no KEEP_ZSHRC=yes`, `chsh zsh`, then `stow --restow` packages (ordering matters) (§11) |
| `lib/13-postinstall.sh` | `step_postinstall` | B | Claude Code native installer (as user), Notion Helium PWA `.desktop`, LazyVim starter clone, final reboot notes (§9) |

### Dotfile packages (owned under `dotfiles/`, stowed by `step_dotfiles`)

`hypr/` · `ghostty/` · `dms/` · `xremap/` · `zsh/` (`.zshrc` + `.p10k.zsh`,
PATH includes `~/.local/bin`) · `nvim/` (LazyVim starter) · `zed/`.

---

## Call / dependency order

**Phase A — `install.sh`:**
```
step_preflight → step_disk → step_pacstrap
  → cp repo to NEWROOT+REPO_DEST → save_config → arch-chroot → setup.sh
```

**Phase B — `setup.sh`:**
```
step_system → step_boot → step_snapper → step_desktop → step_apps
  → step_aur → step_greeter → step_input → step_services
  → step_dotfiles → step_postinstall
```

Rationale for the order: system identity/locale/users and the base
`mkinitcpio.conf` must exist before GRUB/initramfs are generated
(`step_boot`); the encrypted Btrfs layout must be bootable before snapshots
(`step_snapper`); the desktop and its official deps land before AUR builds;
`yay` must exist (`step_aur`) before any AUR-sourced greeter/input package;
services and dotfiles come last; post-install touches the live user account.
