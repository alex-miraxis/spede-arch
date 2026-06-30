# shellcheck shell=bash
# lib/09-greeter.sh — step_greeter: greetd + DankMaterialShell (DMS) greeter.
#
# Runs AFTER step_aur, which installs greetd-dms-greeter-git from the AUR.
# greetd itself and qt6-wayland are official `extra` (installed in step_desktop /
# step_apps), but we re-assert qt6-wayland here because the known first-boot
# stall (DMS GH #494 "stuck on boot") is a Qt-Wayland-plugin/permissions issue:
# without the qt6 Wayland platform plugin the dms-greeter Qt process fails to
# start and the machine hangs at boot. This mitigation is per spec §6 and §13.
#
# Per spec §6 the greeter is configured as:
#   /etc/greetd/config.toml  [default_session]
#     command = "dms-greeter --command hyprland -C /etc/greetd/hypr.conf"
#     user    = "greeter"
# plus `dms greeter enable && dms greeter sync` (adds the user to the `greeter`
# group and sets ACLs so the greeter can read the theme), then a REBOOT — the
# greeter cannot read the theme until the session is restarted after sync.
#
# We also ensure NO other display manager (sddm/gdm/lightdm/lxdm/ly) is enabled,
# since two DMs fighting over the VT is itself a boot-stall cause (spec §13 #5).
#
# Idempotent: configs are rewritten to a fixed known-good content, service
# enables are no-ops when already enabled, `dms greeter enable/sync` are
# re-runnable, and pkg_install uses pacman -S --needed.

step_greeter() {
	info "Configuring greetd + DankMaterialShell greeter"

	# --- Install greetd itself (do NOT rely on the AUR greeter pulling it in). ---
	# greetd is the login daemon; the AUR greeter package may not depend on it
	# transitively, so install it explicitly up front.
	pkg_install greetd

	# --- Mitigate the known first-boot stall (GH #494): Qt Wayland plugin. ---
	# qt6-wayland provides the `wayland` Qt platform plugin the greeter needs.
	pkg_install qt6-wayland

	# --- Ensure no competing display manager is enabled (spec §13 #5). ---
	# A second DM grabbing the VT is a classic boot-stall cause. Disable any
	# that happen to be enabled; ignore those that aren't installed/enabled.
	local _dm
	for _dm in sddm gdm lightdm lxdm ly; do
		if systemctl is-enabled "${_dm}.service" >/dev/null 2>&1; then
			warn "disabling competing display manager: ${_dm}.service"
			systemctl disable "${_dm}.service" >/dev/null 2>&1 \
				|| warn "could not disable ${_dm}.service"
		fi
	done

	# --- /etc/greetd/config.toml — the DMS greeter session (spec §6). ---
	backup_file /etc/greetd/config.toml
	mkdir -p /etc/greetd
	cat >/etc/greetd/config.toml <<-'EOF'
		# Managed by spede-arch (lib/09-greeter.sh). Hand edits will be
		# overwritten on the next setup.sh run.
		#
		# DankMaterialShell greeter, launched under a minimal Hyprland session.
		# See /etc/greetd/hypr.conf for that session's config.

		[default_session]
		command = "dms-greeter --command hyprland -C /etc/greetd/hypr.conf"
		user = "greeter"
	EOF

	# We own config.toml outright (no second writer). Assert the session command
	# still points at our hypr.conf — guards against a clobbered/partial write.
	grep -q -- '-C /etc/greetd/hypr.conf' /etc/greetd/config.toml \
		|| die "/etc/greetd/config.toml lost '-C /etc/greetd/hypr.conf' after write"

	# --- /etc/greetd/hypr.conf — minimal Hyprland config for the greeter. ---
	# Deliberately tiny: no bars, no autostart, no user dotfiles. dms-greeter is
	# the only surface; once it exits, the Hyprland session it ran under exits
	# too, handing the VT back to greetd. No hyprpaper/hyprlock/hypridle here.
	backup_file /etc/greetd/hypr.conf
	cat >/etc/greetd/hypr.conf <<-'EOF'
		# Managed by spede-arch (lib/09-greeter.sh). Hand edits will be
		# overwritten on the next setup.sh run.
		#
		# Minimal Hyprland session used solely to host the DMS greeter. The
		# greeter (dms-greeter) is launched by greetd via config.toml; when it
		# exits, this session exits and greetd reclaims the VT.

		# No monitor overrides — let Hyprland auto-detect the AMD outputs.
		monitor = , preferred, auto, 1

		# Sensible env for a Qt/Wayland greeter on AMD (mirrors the user session).
		env = QT_QPA_PLATFORM, wayland
		env = QT_QPA_PLATFORMTHEME, qt6ct
		env = XDG_SESSION_TYPE, wayland

		# Keep the greeter session inert: no animations work to do, no idle/lock.
		animations {
		    enabled = false
		}

		misc {
		    disable_hyprland_logo = true
		    disable_splash_rendering = true
		    force_default_wallpaper = 0
		}
	EOF

	# --- Wire DMS into greetd: group membership + ACLs (as ROOT), then sync. ---
	# We own the greetd config above, so we do NOT call `dms greeter enable`
	# (which would be a second writer racing our config.toml). Instead we set up
	# the privileged glue ourselves as root, so group + ACL state is guaranteed:
	#   - add NEW_USER to the `greeter` group;
	#   - grant the `greeter` user traverse (x) ACLs down to the DMS config;
	#   - make ~/.config/DankMaterialShell group-readable by `greeter`.
	# Then `dms greeter sync` runs AS THE USER and is purely theme sync (non-fatal).
	local _home
	_home=$(getent passwd "$NEW_USER" | cut -d: -f6)
	: "${_home:=/home/$NEW_USER}"

	# These run as root (this step already executes privileged). Group first.
	usermod -aG greeter "$NEW_USER" \
		|| warn "usermod -aG greeter $NEW_USER failed (non-fatal; continuing)"

	# Grant the greeter user traverse access down the path to the DMS theme.
	setfacl -m u:greeter:x "$_home" \
		|| warn "setfacl u:greeter:x on $_home failed (non-fatal)"
	setfacl -m u:greeter:x "$_home/.config" \
		|| warn "setfacl u:greeter:x on $_home/.config failed (non-fatal)"
	setfacl -m u:greeter:x "$_home/.local" \
		|| warn "setfacl u:greeter:x on $_home/.local failed (non-fatal)"
	setfacl -m u:greeter:x "$_home/.local/state" \
		|| warn "setfacl u:greeter:x on $_home/.local/state failed (non-fatal)"
	setfacl -m u:greeter:x "$_home/.cache" \
		|| warn "setfacl u:greeter:x on $_home/.cache failed (non-fatal)"

	# Make the DMS config readable by the greeter group.
	if [ -d "$_home/.config/DankMaterialShell" ]; then
		chgrp -R greeter "$_home/.config/DankMaterialShell" \
			|| warn "chgrp greeter on DankMaterialShell failed (non-fatal)"
		chmod -R g+rX "$_home/.config/DankMaterialShell" \
			|| warn "chmod g+rX on DankMaterialShell failed (non-fatal)"
	fi

	# Theme sync only — runs as the user, and is non-fatal.
	if command -v dms >/dev/null 2>&1; then
		as_user "$NEW_USER" dms greeter sync >/dev/null 2>&1 \
			|| warn "'dms greeter sync' failed (non-fatal; theme sync only)"
	else
		warn "dms binary not found — is dms-shell-git installed (step_aur)?"
		warn "skipping 'dms greeter sync'; re-run setup.sh after it lands."
	fi

	# --- Enable greetd as THE login manager. ---
	enable_service greetd.service

	ok "greetd + DMS greeter configured and enabled"
	warn "REBOOT REQUIRED after 'dms greeter sync': the greeter cannot read the"
	warn "theme until the session is restarted. Before trusting it at boot, you"
	warn "can TTY-test it with:  dms-greeter --command hyprland -C /etc/greetd/hypr.conf"
}
