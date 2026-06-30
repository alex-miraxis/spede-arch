# shellcheck shell=bash
# lib/00-preflight.sh — Phase A step 0: preflight checks + interactive config.
#
# Per spec §3 (install flow) and §5 (disk & boot). Runs ONCE from the live
# Arch ISO, before any disk is touched. It:
#   - verifies UEFI boot mode (/sys/firmware/efi must exist),
#   - verifies network reachability (AUR/pacstrap need it — risk §13.6),
#   - enables NTP so the clock is correct before pacman/keys,
#   - refreshes the pacman mirrorlist with reflector (best-effort),
#   - lists block devices and interactively prompts for TARGET_DISK,
#     NEW_HOSTNAME and NEW_USER,
#   - shows a LOUD destructive-wipe confirmation naming the disk and
#     requiring the operator to type the exact disk path,
#   - persists the answers via save_config so they survive the chroot.
#
# Defines exactly one function: step_preflight. Pure definition; nothing runs
# at source time. Obeys the libContract in lib/common.sh.

step_preflight() {
	info "preflight: verifying live-ISO environment"

	# --- 1. UEFI boot mode ---------------------------------------------------
	# The whole disk/boot design (GPT ESP, GRUB --target=x86_64-efi) assumes
	# UEFI. A BIOS/legacy boot would silently produce an unbootable system.
	if [[ ! -d /sys/firmware/efi ]]; then
		die "not booted in UEFI mode (/sys/firmware/efi missing). \
Reboot the ISO in UEFI mode; this installer is UEFI-only."
	fi
	if [[ ! -d /sys/firmware/efi/efivars ]]; then
		warn "/sys/firmware/efi/efivars missing — efivars not mounted; \
grub-install may fail to write a boot entry."
	fi
	ok "UEFI boot mode confirmed"

	# --- 2. Required live-ISO tools -----------------------------------------
	# These are present on the official Arch ISO; fail early if we are not on
	# it (or a stripped environment) rather than midway through partitioning.
	need_cmd lsblk
	need_cmd ping
	need_cmd timedatectl

	# --- 3. Network reachability --------------------------------------------
	# pacstrap (Phase A) and every AUR/PGP/installer step (Phase B) need the
	# network. Risk §13.6: no net => everything downstream fails. Check now.
	info "preflight: checking network reachability"
	local reachable=0 host
	for host in archlinux.org 1.1.1.1 8.8.8.8; do
		if ping -c 1 -W 3 -- "$host" >/dev/null 2>&1; then
			reachable=1
			break
		fi
	done
	# ICMP is commonly blocked on routed-but-working networks. Before giving
	# up, fall back to an HTTPS reachability probe (what pacstrap/AUR actually
	# use). Only die if BOTH ICMP and HTTPS fail.
	if [[ "$reachable" -ne 1 ]] && command -v curl >/dev/null 2>&1; then
		if curl -fsS --max-time 5 https://archlinux.org/ >/dev/null 2>&1; then
			reachable=1
		fi
	fi
	if [[ "$reachable" -ne 1 ]]; then
		err "no network connectivity detected (ICMP ping and HTTPS both failed)."
		err "Connect first (wired: usually automatic; wifi: 'iwctl' then"
		err "  station wlan0 connect <SSID>), verify with 'ping archlinux.org'."
		die "network is required before installing."
	fi
	ok "network reachable"

	# --- 4. NTP / clock ------------------------------------------------------
	# A wrong clock breaks TLS and pacman/gpg signature checks. Enable NTP and
	# give it a moment to settle. Idempotent: re-enabling is a no-op.
	info "preflight: enabling NTP time sync"
	timedatectl set-ntp true >/dev/null 2>&1 \
		|| warn "could not enable NTP via timedatectl (continuing)."

	# --- 5. Mirror refresh (reflector) --------------------------------------
	# Refresh the mirrorlist so the upcoming pacstrap is fast/reliable. Done
	# here per the spec §3 flow (reflector right after network). Best-effort:
	# a stale-but-working default mirrorlist is acceptable, so never die here.
	if command -v reflector >/dev/null 2>&1; then
		info "preflight: refreshing pacman mirrors with reflector"
		backup_file /etc/pacman.d/mirrorlist
		if reflector --latest 20 --protocol https --sort rate \
			--save /etc/pacman.d/mirrorlist >/dev/null 2>&1; then
			ok "mirrorlist refreshed"
		else
			warn "reflector failed; keeping existing mirrorlist."
		fi
	else
		warn "reflector not found; skipping mirror refresh."
	fi

	# --- 6. Interactive configuration ---------------------------------------
	log ""
	info "Available block devices:"
	lsblk -dpo NAME,SIZE,MODEL,TYPE >&2 || true
	log ""
	log "${_C_DIM}Pick the WHOLE disk to install onto (e.g. /dev/nvme0n1 or"
	log " /dev/sda), NOT a partition. EVERYTHING on it will be destroyed.${_C_RESET}"
	log ""

	# --- 6a. Target disk -----------------------------------------------------
	local disk=""
	while :; do
		printf 'Target disk (full path, e.g. /dev/nvme0n1): ' >&2
		read -r disk || die "no input (EOF) while reading target disk."
		disk="${disk%/}"
		if [[ -z "$disk" ]]; then
			warn "empty — enter a disk path."
			continue
		fi
		if [[ ! -b "$disk" ]]; then
			warn "'$disk' is not a block device. Try again."
			continue
		fi
		# Guard against picking a partition (ends in a digit on most disks,
		# or 'pN' on nvme/mmc) instead of the whole disk.
		local dtype
		dtype=$(lsblk -dno TYPE -- "$disk" 2>/dev/null || true)
		if [[ "$dtype" != "disk" ]]; then
			warn "'$disk' is type '${dtype:-unknown}', not a whole disk. \
Pick the parent device (e.g. /dev/nvme0n1, not /dev/nvme0n1p1)."
			continue
		fi
		break
	done

	# --- 6b. Hostname --------------------------------------------------------
	local hostname=""
	while :; do
		printf 'Hostname for the new system: ' >&2
		read -r hostname || die "no input (EOF) while reading hostname."
		hostname="${hostname// /}"
		if [[ -z "$hostname" ]]; then
			warn "empty — enter a hostname."
			continue
		fi
		# RFC 1123-ish: letters, digits, hyphen; not starting/ending with '-'.
		if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
			warn "invalid hostname '$hostname' (use letters, digits, hyphens; \
no leading/trailing hyphen)."
			continue
		fi
		break
	done

	# --- 6c. Username --------------------------------------------------------
	local username=""
	while :; do
		printf 'Primary (non-root) username: ' >&2
		read -r username || die "no input (EOF) while reading username."
		username="${username// /}"
		if [[ -z "$username" ]]; then
			warn "empty — enter a username."
			continue
		fi
		# Linux useradd portable name policy: lowercase start, then
		# lowercase/digits/_/-, optional trailing '$'.
		if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
			warn "invalid username '$username' (lowercase letter/underscore \
first, then lowercase/digits/_/-)."
			continue
		fi
		if [[ "$username" == "root" ]]; then
			warn "'root' already exists; choose a different username."
			continue
		fi
		break
	done

	# --- 7. LOUD destructive-wipe confirmation ------------------------------
	log ""
	log "${_C_RED}===========================================================${_C_RESET}"
	log "${_C_RED}  DESTRUCTIVE ACTION — READ CAREFULLY${_C_RESET}"
	log "${_C_RED}===========================================================${_C_RESET}"
	log "${_C_RED}  Disk to be WIPED:  ${disk}${_C_RESET}"
	log "${_C_RED}  Everything on it (all partitions, all data) is destroyed.${_C_RESET}"
	log "${_C_RED}  This CANNOT be undone.${_C_RESET}"
	log ""
	log "  New system:  hostname='${hostname}'  user='${username}'"
	log ""
	log "${_C_RED}  Current layout of ${disk}:${_C_RESET}"
	lsblk -po NAME,SIZE,FSTYPE,MOUNTPOINTS -- "$disk" >&2 || true
	log ""
	log "${_C_YEL}  To proceed, type the disk path EXACTLY: ${disk}${_C_RESET}"
	log "${_C_YEL}  (or anything else / Ctrl-C to abort)${_C_RESET}"

	# The typed-disk-path gate is the one real guard against wiping the wrong
	# disk, so a generic ASSUME_YES must NOT bypass it. Only a SEPARATE,
	# explicit ASSUME_WIPE_DISK that matches this exact disk may skip it.
	if [[ "${ASSUME_WIPE_DISK:-}" == "$disk" ]]; then
		warn "ASSUME_WIPE_DISK matches ${disk} — skipping typed wipe confirmation."
	else
		if [[ "${ASSUME_YES:-0}" == "1" ]]; then
			warn "ASSUME_YES does NOT bypass the typed wipe gate; set \
ASSUME_WIPE_DISK='${disk}' to skip it non-interactively."
		fi
		local typed=""
		printf 'Confirm disk to wipe: ' >&2
		read -r typed || die "no input (EOF) at wipe confirmation."
		if [[ "$typed" != "$disk" ]]; then
			die "confirmation '$typed' != '$disk' — aborting. Nothing was changed."
		fi
	fi
	ok "wipe confirmed for ${disk}"

	# --- 8. Persist runtime config ------------------------------------------
	# Commit to the globals (read by step_disk / step_pacstrap / setup.sh) and
	# write them out so they survive the arch-chroot boundary.
	TARGET_DISK="$disk"
	NEW_HOSTNAME="$hostname"
	NEW_USER="$username"
	save_config

	ok "preflight complete — disk=${TARGET_DISK} host=${NEW_HOSTNAME} user=${NEW_USER}"
}
