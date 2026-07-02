# shellcheck shell=bash
# lib/09-greeter.sh — step_greeter: SDDM (Wayland greeter) + Sugar Candy theme.
#
# REPLACES the previous greetd + dms-greeter setup. dms-greeter launched a
# NESTED Hyprland session running quickshell as a separate `greeter` system
# user; on a Radeon 780M (Ryzen 8845HS) that greeter never grabbed the display
# and the machine sat at a black screen (no signal) — while a plain text login
# (multi-user.target) proved the GPU/KMS itself was fine. Rather than keep
# fighting the fragile nested-compositor greeter, we use SDDM with its Wayland
# greeter running under weston — the same approach proven to work in the
# maintainer's dot-files repo — themed with Sugar Candy for a DankMaterialShell
# ("DANK") look.
#
# Boot flow: systemd -> sddm.service -> weston (greeter compositor) -> SDDM
# Sugar Candy greeter -> user logs in -> Hyprland (stock wayland-session).
#
# Idempotent: pkg_install/aur_install use --needed; the SDDM config and theme
# override are rewritten to fixed known-good content; enabling sddm is a no-op
# when already enabled. Safe to re-run in the chroot AND on the booted system.
#
# Contract: `shellcheck shell=bash` directive, no shebang, no `set`/`IFS=`;
# EXACTLY ONE top-level function (step_greeter); nothing runs at source time.

step_greeter() {
	info "Configuring SDDM (Wayland greeter) + Sugar Candy 'Dank' theme"

	# --- 1. Install SDDM + weston (the Wayland greeter compositor). -----------
	# SDDM's Wayland greeter runs under weston (via [Wayland] CompositorCommand);
	# weston MUST be installed or the greeter has no compositor to launch in.
	pkg_install sddm weston

	# --- 2. Sugar Candy theme (AUR, built as NEW_USER via the yay bootstrapped
	#        in step_aur). Non-fatal: if the build fails, SDDM falls back to its
	#        built-in theme and login still works. ----------------------------
	local theme_dir=/usr/share/sddm/themes/sugar-candy
	if [[ -d "$theme_dir" ]]; then
		ok "Sugar Candy theme already present: $theme_dir"
	else
		info "installing Sugar Candy SDDM theme (sddm-sugar-candy-git, AUR)"
		aur_install sddm-sugar-candy-git \
			|| warn "sugar-candy build failed; SDDM will use its default theme (re-run setup.sh to retry)"
	fi

	# --- 3. Disable any competing display manager, INCLUDING greetd (which we
	#        just replaced). Two DMs fighting over the VT is itself a boot-stall
	#        cause, and a still-enabled greetd would re-launch the broken
	#        dms-greeter. sddm is intentionally NOT in this list — it is ours. --
	local _dm
	for _dm in greetd gdm lightdm lxdm ly; do
		if systemctl is-enabled "${_dm}.service" >/dev/null 2>&1; then
			warn "disabling competing display manager: ${_dm}.service"
			systemctl disable "${_dm}.service" >/dev/null 2>&1 \
				|| warn "could not disable ${_dm}.service"
		fi
	done

	# --- 4. Theme override — write theme.conf.user, which SDDM merges OVER the
	#        packaged theme.conf. We use .user (not theme.conf) because the AUR
	#        package marks theme.conf as a pacman backup file; editing it
	#        directly would spawn .pacnew churn. Colors mirror the DMS Catppuccin
	#        Mocha palette shipped in the dotfiles (base #1e1e2e, text #cdd6f4,
	#        mauve accent #cba6f7); Manrope is installed via step_aur. ---------
	if [[ -d "$theme_dir" ]]; then
		cat >"$theme_dir/theme.conf.user" <<-'EOF'
			# Managed by spede-arch (lib/09-greeter.sh). Overrides theme.conf.
			# Hand edits are overwritten on the next setup.sh run.
			[General]
			# Solid dark Material background (empty image -> BackgroundColor shows).
			Background=""
			BackgroundColor="#1e1e2e"
			FullBlur="false"
			PartialBlur="false"
			# Material "card" behind the login form, centered.
			HaveFormBackground="true"
			FormPosition="center"
			MainColor="#cdd6f4"
			AccentColor="#cba6f7"
			RoundCorners="24"
			InterfaceShadowSize="8"
			InterfaceShadowOpacity="0.5"
			Font="Manrope"
			FontSize="11"
			ForceLastUser="true"
			ForcePasswordFocus="true"
			HourFormat="HH:mm"
			DateFormat="dddd, d MMMM"
			HeaderText="Welcome"
		EOF
		ok "Sugar Candy 'Dank' override written: $theme_dir/theme.conf.user"
	else
		warn "sugar-candy theme dir absent ($theme_dir) — SDDM will use its default theme"
	fi

	# --- 5. SDDM config: Wayland greeter (weston) + our theme. Mirrors the
	#        maintainer's known-good dot-files setup. ------------------------
	local current_theme=sugar-candy
	[[ -d "$theme_dir" ]] || current_theme=""
	backup_file /etc/sddm.conf.d/10-spede.conf
	mkdir -p /etc/sddm.conf.d
	cat >/etc/sddm.conf.d/10-spede.conf <<-EOF
		# Managed by spede-arch (lib/09-greeter.sh). Hand edits will be
		# overwritten on the next setup.sh run.
		[General]
		# Wayland greeter — SDDM launches weston as the greeter compositor.
		DisplayServer=wayland

		[Theme]
		Current=${current_theme}
	EOF

	# --- 6. Make sure the greeter has a session to offer. Hyprland ships
	#        /usr/share/wayland-sessions/hyprland.desktop (Exec=Hyprland); SDDM
	#        lists it automatically. Assert it so a missing session surfaces
	#        loudly instead of as an empty session dropdown at the greeter. ---
	if [[ ! -e /usr/share/wayland-sessions/hyprland.desktop ]]; then
		warn "no hyprland.desktop wayland-session found — is hyprland installed (step_desktop)?"
	fi

	# --- 7. Enable SDDM as THE login manager. -------------------------------
	enable_service sddm.service

	ok "SDDM + Sugar Candy greeter configured and enabled"
	warn "The greeter runs a Wayland session under weston; if the screen is black"
	warn "after boot, TTY-test with:  systemctl start sddm  (from multi-user.target)"
}
