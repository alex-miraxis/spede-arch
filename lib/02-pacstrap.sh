# shellcheck shell=bash
# lib/02-pacstrap.sh — Phase A step: refresh mirrors, tune pacman, pacstrap
# the base set into NEWROOT, then genfstab. Sourced by install.sh; obeys the
# libContract in lib/common.sh (no shebang / no set / no IFS; one step_* fn).
#
# Spec §3 (live-ISO flow) + §9 (pacstrap base set). NetworkManager is in the
# base set and is non-negotiable — without it the rebooted system has no
# network and every later AUR/CLI installer fails (spec §9, §13 pitfall #6).

step_pacstrap() {
	info "step_pacstrap: refresh mirrors, tune pacman, pacstrap base, genfstab"

	# _pacstrap_base_pkgs — print the pacstrap base package list, one per line,
	# to stdout. Source of truth is packages/pacman.txt: the block between the
	# "Pacstrap base set" header and the next "# ---" section header. Falls back
	# to the verbatim spec §9 list if the file or that section is unavailable, so
	# the install never proceeds with a silently-empty package set.
	_pacstrap_base_pkgs() {
		local repo_root pkgfile
		repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
		pkgfile="${repo_root}/packages/pacman.txt"

		if [[ -f "$pkgfile" ]]; then
			# Print lines inside the base-set section only: start after the
			# "Pacstrap base set" header, stop at the next "# ---" header.
			# Strip inline comments / blank lines; emit bare package tokens.
			awk '
				/^# --- Pacstrap base set/ { inblk=1; next }
				inblk && /^# ---/          { inblk=0; next }
				inblk {
					sub(/#.*/, "")          # drop inline + full-line comments
					gsub(/[ \t]+/, "")      # trim whitespace
					if (length($0)) print
				}
			' "$pkgfile"
			return 0
		fi

		# Fallback: verbatim spec §9 base set. Keep this list in sync with the
		# base-set section of packages/pacman.txt (the awk source of truth above).
		printf '%s\n' \
			base base-devel linux linux-firmware amd-ucode btrfs-progs \
			cryptsetup grub efibootmgr grub-btrfs snapper snap-pac \
			inotify-tools networkmanager sudo git vim reflector \
			pacman-contrib zsh stow
	}

	# This step only makes sense from the live ISO, writing into NEWROOT.
	if in_chroot; then
		die "step_pacstrap is a Phase A (live-ISO) step; do not run it in the chroot."
	fi
	need_cmd pacstrap
	need_cmd genfstab
	[[ -d "$NEWROOT" ]] || die "step_pacstrap: NEWROOT ($NEWROOT) is not mounted."
	mountpoint -q "$NEWROOT" \
		|| die "step_pacstrap: $NEWROOT is not a mountpoint — run step_disk first."

	# --- Refresh the mirrorlist with reflector (sane country default) --------
	# Idempotent: reflector overwrites /etc/pacman.d/mirrorlist each run.
	# REFLECTOR_COUNTRY is overridable; default Greece to match the locale/tz.
	if command -v reflector >/dev/null 2>&1; then
		local country="${REFLECTOR_COUNTRY:-Greece}"
		info "reflector: refreshing mirrorlist (country=${country})"
		backup_file /etc/pacman.d/mirrorlist
		if ! reflector \
			--country "$country" \
			--protocol https \
			--age 12 \
			--latest 20 \
			--sort rate \
			--save /etc/pacman.d/mirrorlist; then
			warn "reflector failed for country=${country}; keeping existing mirrorlist"
		fi
	else
		warn "reflector not found on the live ISO; using the default mirrorlist"
	fi

	# --- Enable ParallelDownloads in the live-ISO pacman.conf ----------------
	# This speeds up pacstrap itself. Idempotent: uncomment or append once.
	local conf=/etc/pacman.conf
	if [[ -f "$conf" ]]; then
		if grep -qE '^[[:space:]]*#[[:space:]]*ParallelDownloads' "$conf"; then
			info "enabling ParallelDownloads in $conf"
			backup_file "$conf"
			sed -i 's/^[[:space:]]*#[[:space:]]*ParallelDownloads.*/ParallelDownloads = 10/' "$conf"
		elif ! grep -qE '^[[:space:]]*ParallelDownloads' "$conf"; then
			info "adding ParallelDownloads to $conf [options]"
			backup_file "$conf"
			# Insert under the [options] section header.
			sed -i '/^\[options\]/a ParallelDownloads = 10' "$conf"
		else
			ok "ParallelDownloads already enabled in $conf"
		fi
	fi

	# --- pacstrap the base set into NEWROOT ----------------------------------
	# -K initialises a fresh pacman keyring in the target (recommended).
	# Read the package list from packages/pacman.txt (architect contract).
	local -a base_pkgs=()
	local _p
	while IFS= read -r _p; do
		[[ -n "$_p" ]] && base_pkgs+=("$_p")
	done < <(_pacstrap_base_pkgs)

	[[ ${#base_pkgs[@]} -gt 0 ]] || die "step_pacstrap: empty base package set."

	# Hard guard: NetworkManager MUST be in the set (spec §9 non-negotiable).
	local _have_nm=0
	for _p in "${base_pkgs[@]}"; do
		[[ "$_p" == "networkmanager" ]] && _have_nm=1
	done
	[[ "$_have_nm" -eq 1 ]] \
		|| die "step_pacstrap: 'networkmanager' missing from base set — refusing (no net after reboot)."

	info "pacstrap -K $NEWROOT (${#base_pkgs[@]} packages)"
	log "  packages: ${base_pkgs[*]}"
	# pacstrap with --needed so a re-run over an already-populated NEWROOT is
	# cheap and idempotent rather than reinstalling everything.
	pacstrap -K "$NEWROOT" --needed "${base_pkgs[@]}"

	# --- genfstab ------------------------------------------------------------
	# Use UUIDs (-U). Guard against duplicate appends on a re-run by writing a
	# fresh fstab each time rather than blindly appending.
	local fstab="${NEWROOT}/etc/fstab"
	mkdir -p "${NEWROOT}/etc"
	backup_file "$fstab"
	info "genfstab -U $NEWROOT -> $fstab"
	{
		printf '# /etc/fstab — generated by spede-arch step_pacstrap (genfstab -U)\n'
		genfstab -U "$NEWROOT"
	} >"$fstab"

	ok "step_pacstrap: base system installed and fstab written"
}
