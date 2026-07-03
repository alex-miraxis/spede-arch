#!/usr/bin/env bash
#
# setup.sh — spede-arch Phase B entry point.
#
# Re-runnable. Runs inside the arch-chroot during a fresh install AND later
# on the fully booted system to repair/update. Every step is idempotent.
#
# It sources lib/common.sh, loads the persisted install config, sources all
# the Phase B step files (lib/03-*.sh .. lib/13-*.sh), then calls the step_*
# functions in strict dependency order.
#
# Usage:
#   cd /root/spede-arch && ./setup.sh      # in chroot (called by install.sh)
#   cd ~/spede-arch && sudo ./setup.sh     # later, on the booted system

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config

# Source every Phase B step file: lib/03-*.sh through lib/13-*.sh.
# Globbing 0[3-9]* and 1[0-3]* mirrors the architect contract exactly.
shopt -s nullglob
for _f in "${SCRIPT_DIR}"/lib/0[3-9]*.sh "${SCRIPT_DIR}"/lib/1[0-3]*.sh; do
	# shellcheck source=/dev/null
	source "$_f"
done
shopt -u nullglob
unset _f

main() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "setup.sh must run as root (use sudo on the booted system)."
	[[ -n "${NEW_USER:-}" ]] || die "NEW_USER unset — is ${REPO_DEST}/.install-config present? Run install.sh first."

	log ""
	log "${_C_BLU}===========================================================${_C_RESET}"
	log "${_C_BLU}  spede-arch — Phase B  (system -> desktop -> dotfiles)${_C_RESET}"
	log "${_C_BLU}  user=${NEW_USER}  host=${NEW_HOSTNAME}  chroot=$(in_chroot && echo yes || echo no)${_C_RESET}"
	log "${_C_BLU}===========================================================${_C_RESET}"
	log ""

	# Dependency order — DO NOT reorder.
	step_system        # locale, timezone, hostname, users, sudoers, mkinitcpio base
	step_boot          # GRUB cryptodisk + keyfile, mkinitcpio regen, grub-install
	step_snapper       # snapper config, snap-pac, grub-btrfs, timers
	step_desktop       # Hyprland + DMS (quickshell/matugen/dgop) + portals/glue
	step_apps          # official-repo applications
	step_aur           # yay bootstrap + AUR packages (PGP key imports)
	step_input         # xremap, uinput udev/group, XKB us,gr
	step_services      # NetworkManager, pipewire, bluetooth, cups, avahi, ufw, timesyncd
	step_dotfiles      # oh-my-zsh, chsh, GNU stow packages
	step_greeter       # greetd + DMS greeter — AFTER dotfiles: stow replaces the
	                   # DMS theme files with symlinks into its staging dir, and
	                   # the greeter's group/ACL grants + read-proof must cover
	                   # that FINAL layout, not the pre-stow one.
	step_postinstall   # Claude Code installer, Notion PWA, LazyVim, final notes

	log ""
	ok "Phase B complete."
}

main "$@"
