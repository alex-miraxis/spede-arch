# shellcheck shell=bash
# lib/10-input.sh — step_input
#
# The macOS-feel input layer's SYSTEM-side plumbing for xremap (spec §7).
# The xremap binary itself (xremap-hypr-bin, AUR) is built+installed in
# step_aur; its config.yml and the XKB `us,gr`/`ctrl_space_toggle` layout
# live in the hypr/xremap stow dotfiles (step_dotfiles) — NOT here.
#
# This step is responsible only for the kernel/udev/group prerequisites that
# let xremap grab /dev/uinput without root:
#   1. /etc/udev/rules.d/99-input.rules  (uinput owned by `input`, uaccess)
#   2. add NEW_USER to the `input` group
#   3. load the uinput module now + on every boot (/etc/modules-load.d)
#   4. reload udev so the rule applies without a reboot
#   5. install (but leave DISABLED) the xremap `systemd --user` unit as a
#      documented manual fallback — hyprland.conf's exec-once is the active
#      launcher, so enabling the unit too would double-launch xremap
#
# Idempotent: file writes are content-controlled, gpasswd/modprobe are no-ops
# when already applied, udev reloads are safe to repeat. Re-runnable in the
# chroot (where udev/modprobe may be unavailable — those are best-effort) and
# on the booted system.

step_input() {
	[[ -n "${NEW_USER:-}" ]] || die "step_input: NEW_USER is unset"

	# --- 1. udev rule: uinput node owned by `input`, granted via uaccess -----
	# Verbatim from spec §7. static_node ensures /dev/uinput exists even before
	# the module's first open. MODE:= (with the colon) makes the mode final so
	# nothing later loosens it.
	local udev_rule=/etc/udev/rules.d/99-input.rules
	local udev_line='KERNEL=="uinput", GROUP="input", TAG+="uaccess", MODE:="0660", OPTIONS+="static_node=uinput"'
	mkdir -p /etc/udev/rules.d
	if [[ ! -f "$udev_rule" ]] || ! grep -qF -- "$udev_line" "$udev_rule"; then
		backup_file "$udev_rule"
		printf '%s\n' \
			'# Managed by spede-arch (lib/10-input.sh) — xremap uinput access.' \
			"$udev_line" >"$udev_rule"
		ok "wrote $udev_rule"
	else
		info "$udev_rule already current"
	fi

	# --- 2. add the user to the `input` group --------------------------------
	# Guarded so it stays a no-op once the user is already a member.
	if id -nG "$NEW_USER" 2>/dev/null | tr ' ' '\n' | grep -qx 'input'; then
		info "$NEW_USER already in group: input"
	elif gpasswd -a "$NEW_USER" input >/dev/null; then
		ok "added $NEW_USER to group: input"
	else
		warn "could not add $NEW_USER to group: input"
	fi

	# --- 3. ensure the uinput module loads (now + every boot) ----------------
	ensure_line /etc/modules-load.d/uinput.conf 'uinput'
	# Load it immediately too. In the chroot there is usually no running udev /
	# loadable module path, so treat failure as non-fatal — the modules-load.d
	# entry guarantees it on the next boot regardless.
	if modprobe uinput >/dev/null 2>&1; then
		ok "loaded kernel module: uinput"
	else
		info "deferred uinput load to next boot (modprobe unavailable here)"
	fi

	# --- 4. reload udev so the new rule applies without a reboot -------------
	# Best-effort: udevadm is a no-op/failure inside the chroot.
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules >/dev/null 2>&1 || true
		udevadm trigger --subsystem-match=misc --sysname-match=uinput \
			>/dev/null 2>&1 || true
		info "reloaded udev rules"
	fi

	# --- 5. xremap systemd --user unit (installed but left DISABLED) ---------
	# The config.yml is a stow dotfile; here we only INSTALL the unit file. We
	# deliberately do NOT enable it, because hyprland.conf already ships
	#   exec-once = xremap --watch ~/.config/xremap/config.yml
	# as the ACTIVE launcher. Launching from Hyprland's exec-once is the more
	# reliable path: it inherits HYPRLAND_INSTANCE_SIGNATURE, so the
	# window-class-aware Ghostty exclusion works. A `systemd --user` service can
	# start before Hyprland exports HIS, making that exclusion silently fail.
	#
	# Enabling the service here too would double-launch xremap (exec-once +
	# unit). So the unit is installed only as a DOCUMENTED MANUAL FALLBACK: if
	# the exec-once approach is ever removed from hyprland.conf, enable it with
	#   systemctl --user enable xremap.service
	local user_unit_dir=/etc/systemd/user
	local user_unit="$user_unit_dir/xremap.service"
	mkdir -p "$user_unit_dir"
	local desired_unit
	desired_unit=$(cat <<-'UNIT'
		# Managed by spede-arch (lib/10-input.sh).
		# xremap (built with the `hypr` feature from xremap-hypr-bin) as a
		# per-user service. --watch picks up hotplugged keyboards; the Hyprland
		# window-class awareness needs HYPRLAND_INSTANCE_SIGNATURE in the unit
		# environment (imported by the graphical session). See the exec-once
		# fallback noted in lib/10-input.sh.
		[Unit]
		Description=xremap key remapper (macOS-feel layer)
		PartOf=graphical-session.target
		After=graphical-session.target

		[Service]
		Type=simple
		ExecStart=/usr/bin/xremap --watch %h/.config/xremap/config.yml
		Restart=on-failure
		RestartSec=2

		[Install]
		WantedBy=graphical-session.target
	UNIT
	)
	if [[ ! -f "$user_unit" ]] || [[ "$(cat "$user_unit")" != "$desired_unit" ]]; then
		backup_file "$user_unit"
		printf '%s\n' "$desired_unit" >"$user_unit"
		ok "installed $user_unit"
	else
		info "$user_unit already current"
	fi

	# Intentionally NOT enabled: hyprland.conf's exec-once is the active
	# launcher. Enabling the unit too would run xremap twice (see note above).

	ok "input layer (xremap prerequisites) configured"
}
