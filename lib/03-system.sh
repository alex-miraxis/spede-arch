# shellcheck shell=bash
# lib/03-system.sh — step_system: base system configuration inside the chroot.
#
# Per spec §10: locales (en_US.UTF-8 + el_GR.UTF-8), timezone Europe/Athens +
# hwclock, hostname + /etc/hosts, the primary user in the wheel group, the
# /etc/sudoers.d/10-wheel drop-in (validated with visudo), MAKEFLAGS in
# /etc/makepkg.conf, and root + user passwords.
#
# Fully idempotent: re-running re-applies the same desired state without harm.
# The login shell is intentionally left at the default here; step_dotfiles
# runs `chsh -s /usr/bin/zsh` AFTER oh-my-zsh + stow so omz can't clobber the
# stowed .zshrc.
#
# Follows the libContract in lib/common.sh: no shebang, no `set`, no IFS,
# exactly one function (step_system), zero work at source time.

step_system() {
	info "step_system: locale, timezone, hostname, users, sudoers, makepkg"

	[[ -n "${NEW_HOSTNAME:-}" ]] || die "step_system: NEW_HOSTNAME is unset (run install.sh first)"
	[[ -n "${NEW_USER:-}" ]]     || die "step_system: NEW_USER is unset (run install.sh first)"

	# -- Locale (spec §10) ------------------------------------------------
	# Uncomment the two desired locales in /etc/locale.gen, then locale-gen.
	local locale
	for locale in "$LOCALE_PRIMARY" "$LOCALE_EXTRA"; do
		# Idempotent: only edit a still-commented line; an already-active
		# line (no leading '#') is left untouched.
		if grep -qE "^#[[:space:]]*${locale}[[:space:]]+UTF-8" /etc/locale.gen; then
			sed -i -E "s|^#[[:space:]]*(${locale}[[:space:]]+UTF-8)|\1|" /etc/locale.gen
			info "enabled locale: ${locale}"
		fi
	done
	locale-gen

	# /etc/locale.conf — LANG=en_US.UTF-8 (spec §10).
	printf 'LANG=%s\n' "$LOCALE_PRIMARY" >/etc/locale.conf
	ok "locale.conf set to LANG=${LOCALE_PRIMARY}"

	# -- Timezone (spec §10) ----------------------------------------------
	ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
	# hwclock writes the RTC from system time; harmless to repeat. In a
	# chroot without an RTC it may warn — don't let that abort the run.
	hwclock --systohc || warn "hwclock --systohc failed (no RTC in chroot?) — continuing"
	ok "timezone set to ${TIMEZONE}"

	# -- Hostname + hosts (spec §10) --------------------------------------
	printf '%s\n' "$NEW_HOSTNAME" >/etc/hostname
	# Standard loopback hosts file; written fresh so it's deterministic.
	cat >/etc/hosts <<-EOF
		127.0.0.1   localhost
		::1         localhost
		127.0.1.1   ${NEW_HOSTNAME}.localdomain ${NEW_HOSTNAME}
	EOF
	ok "hostname set to ${NEW_HOSTNAME}"

	# -- Primary user in wheel (spec §10) ---------------------------------
	# Guard creation with an id check; otherwise just ensure wheel membership.
	# Login shell is left default here (set in step_dotfiles, see header).
	if id "$NEW_USER" >/dev/null 2>&1; then
		info "user ${NEW_USER} already exists — ensuring wheel membership"
	else
		useradd -m -G wheel "$NEW_USER"
		ok "created user ${NEW_USER} (wheel)"
	fi
	# usermod -aG is additive + idempotent.
	usermod -aG wheel "$NEW_USER"

	# -- sudoers drop-in (spec §10) ---------------------------------------
	# Validate the candidate file with `visudo -cf` BEFORE installing it, so a
	# malformed drop-in can never lock the system out of sudo.
	local sudoers=/etc/sudoers.d/10-wheel tmp
	tmp=$(mktemp)
	printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$tmp"
	chmod 0440 "$tmp"
	if visudo -cf "$tmp" >/dev/null 2>&1; then
		install -m 0440 -o root -g root "$tmp" "$sudoers"
		ok "installed validated sudoers drop-in: ${sudoers}"
	else
		rm -f "$tmp"
		die "step_system: generated ${sudoers} failed visudo validation"
	fi
	rm -f "$tmp"

	# -- MAKEFLAGS in makepkg.conf (spec §10) -----------------------------
	# Parallelise makepkg builds: MAKEFLAGS="-j$(nproc)". Replace any existing
	# (commented or active) MAKEFLAGS line, else append — idempotent either way.
	local makepkg=/etc/makepkg.conf makeflags
	makeflags="-j$(nproc)"
	if [[ -f "$makepkg" ]]; then
		if grep -qE '^[#[:space:]]*MAKEFLAGS=' "$makepkg"; then
			sed -i -E "s|^[#[:space:]]*MAKEFLAGS=.*|MAKEFLAGS=\"${makeflags}\"|" "$makepkg"
		else
			ensure_line "$makepkg" "MAKEFLAGS=\"${makeflags}\""
		fi
		ok "set MAKEFLAGS=\"${makeflags}\" in ${makepkg}"
	else
		warn "${makepkg} not found — skipping MAKEFLAGS (base-devel not installed?)"
	fi

	# -- Passwords (spec §2: interactive) ---------------------------------
	# Set root + user passwords interactively via passwd, idempotently. Each
	# account is skipped when it already has a usable password (passwd -S
	# status 'P') or when running with no tty / ASSUME_YES=1, so re-running
	# setup.sh on the booted system won't nag.
	local account status
	for account in root "$NEW_USER"; do
		# passwd -S: 2nd field is P (usable), L (locked), or NP (no password).
		status=$(passwd -S "$account" 2>/dev/null | awk '{print $2}')
		if [[ "$status" == "P" ]]; then
			info "password already set for ${account} — skipping"
			continue
		fi
		if [[ "${ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
			warn "no tty / non-interactive — set password later with: passwd ${account}"
			continue
		fi
		info "set a password for ${account}:"
		# Loop until passwd succeeds (mismatch / too-weak prompts repeat).
		while ! passwd "$account"; do
			warn "passwd failed for ${account} — try again"
		done
		ok "password set for ${account}"
	done

	ok "step_system complete"
}
