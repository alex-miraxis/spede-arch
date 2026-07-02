#!/usr/bin/env bash
#
# install.sh — spede-arch Phase A entry point.
#
# Runs ONCE from the live Arch ISO. It is destructive: it partitions and
# wipes the chosen disk. Flow:
#   step_preflight  — checks, interactive disk/hostname/user, save_config
#   step_disk       — partition, LUKS2 (PBKDF2), Btrfs subvols, mount
#   step_pacstrap   — pacstrap the base set, genfstab
# then copy this repo into the new system and arch-chroot into it to run
# Phase B (setup.sh), which performs the rest of the install.
#
# Usage (from the live ISO, as root):
#   ./install.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Phase A step files.
# shellcheck source=lib/00-preflight.sh
source "${SCRIPT_DIR}/lib/00-preflight.sh"
# shellcheck source=lib/01-disk.sh
source "${SCRIPT_DIR}/lib/01-disk.sh"
# shellcheck source=lib/02-pacstrap.sh
source "${SCRIPT_DIR}/lib/02-pacstrap.sh"

main() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "install.sh must run as root (live ISO)."
	if in_chroot; then
		die "install.sh is the live-ISO entry. Inside the system run ./setup.sh."
	fi

	log ""
	log "${_C_BLU}===========================================================${_C_RESET}"
	log "${_C_BLU}  spede-arch — Phase A  (Arch + Hyprland + DankMaterialShell)${_C_RESET}"
	log "${_C_RED}  WARNING: this WIPES the disk you select. No undo.${_C_RESET}"
	log "${_C_BLU}===========================================================${_C_RESET}"
	log ""

	step_preflight
	step_disk
	step_pacstrap

	# Copy the whole repo into the target so Phase B is self-contained.
	info "copying repo into ${NEWROOT}${REPO_DEST}"
	mkdir -p "${NEWROOT}${REPO_DEST}"
	cp -aT -- "$SCRIPT_DIR" "${NEWROOT}${REPO_DEST}"

	# Re-save config inside the target tree (config_path now resolves there).
	save_config

	# Persist the Wi-Fi credentials captured in preflight into the target so the
	# rebooted system is online immediately (NetworkManager is enabled in Phase
	# B). Written here in Phase A — the PSK stays in memory and never lands in
	# .install-config. No-op for wired installs (empty WIFI_SSID).
	write_wifi_connection "$NEWROOT" "${WIFI_SSID:-}" "${WIFI_PSK:-}"

	info "entering chroot to run Phase B (setup.sh)"
	arch-chroot "$NEWROOT" /usr/bin/env bash -c \
		"cd '${REPO_DEST}' && exec ./setup.sh"

	log ""
	log "${_C_GRN}===========================================================${_C_RESET}"
	log "${_C_GRN}  Phase A + B complete.${_C_RESET}"
	log "${_C_GRN}  Now: umount -R ${NEWROOT}  &&  reboot${_C_RESET}"
	log "${_C_GRN}  Remove the USB. At GRUB, type the LUKS passphrase once.${_C_RESET}"
	log "${_C_GRN}===========================================================${_C_RESET}"
	log ""
}

main "$@"
