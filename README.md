# spede-arch

A from-scratch (no Omarchy) bare-metal installer + dotfiles for an
**Arch Linux + Hyprland + DankMaterialShell (DMS)** desktop with a
**macOS-style keyboard feel**.

- AMD desktop GPU (mesa + vulkan-radeon, pure Wayland)
- LUKS2 full-disk encryption (PBKDF2, GRUB-safe) + Btrfs + snapper snapshots
- GRUB with `grub-btrfs` snapshot boot menu
- `SDDM` (Wayland greeter under weston) with a DankMaterialShell-styled
  Sugar Candy theme
- macOS muscle memory via `xremap` (Cmd→Ctrl) + XKB `us,gr`

See the full verified design in
[`docs/superpowers/specs/2026-06-30-arch-hyprland-dms-design.md`](docs/superpowers/specs/2026-06-30-arch-hyprland-dms-design.md).

---

## ⚠️ WARNING — this wipes a disk

`install.sh` **partitions and erases the disk you select.** There is no undo.
It runs `cryptsetup luksFormat`, which destroys all existing data on the
target. Read the prompt carefully and confirm the device path before
proceeding. Do not run it on a machine whose data you have not backed up.

---

## Two-phase model

- **Phase A — `install.sh`** (runs ONCE, from the live ISO): preflight →
  interactive disk/hostname/user selection → partition (GPT: FAT32 ESP +
  LUKS2) → Btrfs subvolumes → `pacstrap` the base set → `genfstab` → copy
  this repo into the new system → `arch-chroot` and hand off to Phase B.
- **Phase B — `setup.sh`** (re-runnable, in chroot AND on the booted
  system): locale/users/boot → snapper → Hyprland + DMS → apps → yay/AUR →
  greeter → input layer → services → dotfiles → post-install. Every step is
  idempotent, so you can re-run `setup.sh` to repair or update.

---

## Quick start (one command)

Boot the official Arch ISO (UEFI). If you're on **Wi-Fi**, associate once so
the bootstrap can reach GitHub (`iwctl` → `station wlan0 connect "<SSID>"`).
Then, as root:

```sh
curl -fsSL https://raw.githubusercontent.com/alex-miraxis/spede-arch/main/bootstrap.sh | bash
```

`bootstrap.sh` installs `git` if needed, clones this repo to `/root/spede-arch`,
and launches Phase A. Preflight then asks for your **Wi-Fi SSID + password**
and writes them into the installed system, so the machine is online on first
boot (no offline first-login surprises). Override the source with
`SPEDE_REPO`, `SPEDE_BRANCH`, or seed Wi-Fi non-interactively with
`SPEDE_WIFI_SSID` / `SPEDE_WIFI_PSK`.

## On-the-metal flow (manual)

Prefer to drive it by hand? Boot the ISO (UEFI), then as root:

```sh
# 1. Connect Wi-Fi (skip if wired/DHCP already works)
iwctl
#   [iwctl]> device list
#   [iwctl]> station wlan0 scan
#   [iwctl]> station wlan0 connect "<SSID>"
#   [iwctl]> exit

# 2. Get git
pacman -Sy git

# 3. Clone and run Phase A
git clone <repo-url> spede-arch
cd spede-arch
./install.sh
```

`install.sh` will prompt for the target disk (with a loud destructive-wipe
confirmation), hostname, username, Wi-Fi (optional, for the installed
system), and passwords. Timezone (`Europe/Athens`) and locale
(`en_US.UTF-8` + `el_GR.UTF-8`) are hardcoded.

When it finishes:

```sh
umount -R /mnt
reboot
```

Remove the USB. At the GRUB prompt, type your LUKS passphrase once.

---

## Re-running Phase B on the booted system

```sh
cd ~/spede-arch        # the repo is copied to /root/spede-arch during install
sudo ./setup.sh
```

---

## ⚠️ Test on real hardware

The **LUKS2 + GRUB** path is the single most dangerous part of this build and
**must be validated on the actual AMD box**, not a VM or macOS. VMs routinely
pass where bare-metal UEFI fails: GRUB's 4 GiB EFI heap cap breaks the default
Argon2id KDF, which is exactly why this installer forces **PBKDF2**
(`--pbkdf pbkdf2 --pbkdf-force-iterations 1000000 --hash sha256`) plus
`GRUB_ENABLE_CRYPTODISK=y` and preloaded crypto modules. Confirm first boot
unlocks correctly before trusting the machine.

---

## Layout

```
spede-arch/
├── install.sh              # Phase A entry (live ISO)
├── setup.sh                # Phase B entry (re-runnable)
├── lib/                    # common.sh + numbered step files (00..13)
├── packages/               # pacman.txt, aur.txt (authoritative lists)
├── dotfiles/               # GNU stow packages (one dir per app)
├── wallpapers/
├── PLAN.md                 # build manifest / file-ownership map
└── README.md
```
