# shellcheck shell=bash
# lib/09-greeter.sh — step_greeter: greetd + DankMaterialShell greeter (niri-hosted).
#
# FULL DMS LOGIN, done to upstream's actual contract this time. The previous
# two iterations of this step both failed on real hardware:
#   v1 (greetd + dms-greeter under Hyprland): black screen / monitor standby /
#      dead VTs. Root cause (proven from upstream sources): quickshell died at
#      startup -> the wrapper's appended 'exec-once = "qs ...; hyprctl dispatch
#      exit"' killed the compositor -> greetd fatal "greeter exited without
#      creating a session" -> systemd Restart=always respawn loop force-
#      re-activating VT1 every second -> start-limit-hit -> dead black VT.
#      quickshell died because this step diverged from upstream: no
#      '[terminal] vt = 1', no --cache-dir, 'dms greeter sync' silently failed
#      (it requires 'enable' first), cache dir never initialized, theme
#      symlinks never created, deprecated u:greeter ACL form.
#   v2 (SDDM + Sugar Candy): worked, but was a compromise — replaced by this.
#
# This version replicates EXACTLY what upstream's `dms greeter enable` +
# `dms greeter sync` write (sourced from DankMaterialShell
# core/internal/greeter/installer.go and the dms-greeter wrapper script),
# deterministically and non-interactively:
#
#   - niri hosts the greeter UI. It is upstream's first-class greeter
#     compositor: the only one with a managed override path
#     (/etc/greetd/niri_overrides.kdl, auto-included by the wrapper), it
#     self-heals bad display modes, and it avoids the start-hyprland
#     watchdog trap (safe-mode infinite restart inside a dead greeter).
#     The USER session is untouched — still Hyprland.
#   - /etc/greetd/config.toml gets upstream's exact shape: [terminal] vt=1 +
#     '/usr/bin/dms-greeter --command niri --cache-dir /var/cache/dms-greeter'.
#   - /var/cache/dms-greeter initialized like EnsureGreeterCacheDir: owned
#     greeter:greeter, mode 2770, with users/, .local/state, .local/share,
#     .cache subdirs and a per-user slot.
#   - NEW_USER joins the 'greeter' group; theme dirs are group-shared
#     (chgrp greeter + g+rX) and parent dirs get g:greeter:rX ACLs (current
#     upstream form; stale u:greeter ACLs from v1 are remediated).
#   - Theme symlinks in the cache dir point at the user's DMS settings/
#     session/colors (sources seeded with '{}' when missing, as upstream does).
#   - PROOF assertions: the greeter user must actually be able to read the
#     settings through the whole ACL chain, or this step dies loudly at
#     install time instead of black-screening at boot.
#
# The greeter's own logs land in the journal under the syslog tag
# 'dms-greeter/niri' (the wrapper pipes compositor output through systemd-cat),
# and greetd's under '-u greetd' — that is where to look if anything fails.
#
# ORDERING: this step runs AFTER step_dotfiles (see setup.sh). stow replaces
# the DMS theme files with symlinks into its staging dir, so the group/ACL
# grants and the read-proof below must be applied to (and verified against)
# that FINAL layout — running before stow would validate a layout that stow
# then silently breaks.
#
# Idempotent: config rewritten to fixed content, mkdir/chown/chmod/setfacl/
# usermod -aG/ln -sfT are all re-runnable, package removals are guarded.
# Contract: no shebang, no `set`/`IFS=`; EXACTLY ONE top-level function
# (step_greeter); nothing runs at source time; helpers defined inside.

step_greeter() {
	info "Configuring greetd + DankMaterialShell greeter (niri-hosted login UI)"

	[[ -n "${NEW_USER:-}" ]] || die "step_greeter: NEW_USER is unset"
	getent passwd "$NEW_USER" >/dev/null 2>&1 \
		|| die "step_greeter: user '$NEW_USER' does not exist"

	local user_home
	user_home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
	[[ -n "$user_home" && -d "$user_home" ]] \
		|| die "step_greeter: home dir for '$NEW_USER' not found: $user_home"

	# --- 1. Packages: greetd (login daemon + 'greeter' sysuser), niri (host
	#        compositor for the login UI), acl (setfacl). The DMS greeter
	#        itself (greetd-dms-greeter-git) is AUR — installed in step_aur. ---
	pkg_install greetd niri acl

	# --- 2. Assert the AUR greeter artifacts BEFORE touching login config.
	#        If these are missing the greeter would crash-loop at boot; die
	#        now, at install time, with an actionable message instead. -------
	[[ -x /usr/bin/dms-greeter ]] \
		|| die "step_greeter: /usr/bin/dms-greeter missing — greetd-dms-greeter-git not installed (re-run step_aur)"
	[[ -f /usr/share/quickshell/dms-greeter/shell.qml ]] \
		|| die "step_greeter: /usr/share/quickshell/dms-greeter/shell.qml missing — greetd-dms-greeter-git broken?"
	command -v qs >/dev/null 2>&1 || command -v quickshell >/dev/null 2>&1 \
		|| die "step_greeter: quickshell (qs) not found — dependency of the DMS greeter"
	need_cmd niri
	need_cmd setfacl
	getent passwd greeter >/dev/null 2>&1 \
		|| die "step_greeter: 'greeter' user missing — greetd package sysusers did not run?"

	# --- 3. Purge the v2 SDDM stack completely (per maintainer decision).
	#        Disable first so a failed removal can never leave two DMs
	#        fighting over the VT. Guarded: fresh installs have none of it. --
	systemctl disable sddm.service >/dev/null 2>&1 || true
	local _pkg
	for _pkg in sddm-sugar-candy-git sddm weston; do
		if pacman -Qq "$_pkg" >/dev/null 2>&1; then
			info "removing ${_pkg} (SDDM login stack replaced by the DMS greeter)"
			pacman -Rns --noconfirm "$_pkg" \
				|| warn "could not remove ${_pkg} (continuing; it is disabled anyway)"
		fi
	done
	rm -f /etc/sddm.conf.d/10-spede.conf
	# Old v1 greeter-Hyprland config, superseded by the niri-hosted setup.
	rm -f /etc/greetd/hypr.conf

	# --- 4. Disable every other display manager (mirrors upstream 'dms
	#        greeter enable', which disables gdm/gdm3/lightdm/sddm/lxdm/xdm/
	#        cosmic-greeter). Two DMs on one VT is a boot-stall by itself. ----
	local _dm
	for _dm in gdm gdm3 lightdm lxdm xdm ly cosmic-greeter; do
		if systemctl is-enabled "${_dm}.service" >/dev/null 2>&1; then
			warn "disabling competing display manager: ${_dm}.service"
			systemctl disable "${_dm}.service" >/dev/null 2>&1 \
				|| warn "could not disable ${_dm}.service"
		fi
	done

	# --- 5. /etc/greetd/config.toml — byte-for-byte what upstream's
	#        ConfigureGreetd writes for niri on a packaged (AUR) install:
	#        '[terminal] vt = 1' pinned, wrapper by absolute path, lowercase
	#        compositor name (the wrapper's case-match is lowercase-only),
	#        explicit --cache-dir. --------------------------------------------
	backup_file /etc/greetd/config.toml
	mkdir -p /etc/greetd
	cat >/etc/greetd/config.toml <<-'EOF'
		# Managed by spede-arch (lib/09-greeter.sh). Hand edits will be
		# overwritten on the next setup.sh run.

		[terminal]
		vt = 1

		[default_session]
		user = "greeter"
		command = "/usr/bin/dms-greeter --command niri --cache-dir /var/cache/dms-greeter"
	EOF

	# --- 6. /etc/greetd/niri_overrides.kdl — upstream's managed hook for
	#        local greeter-compositor tweaks (the wrapper auto-includes it
	#        when present). Seed it with documentation only; niri's default
	#        preferred-mode handling is self-healing and proven on this
	#        hardware. Never overwrite an existing file: it is the operator's. -
	if [[ ! -f /etc/greetd/niri_overrides.kdl ]]; then
		cat >/etc/greetd/niri_overrides.kdl <<-'EOF'
			// Local overrides for the DMS greeter's niri session (auto-included
			// by the dms-greeter wrapper). niri auto-picks each monitor's
			// preferred mode, so this is usually best left empty.
			//
			// To pin a mode explicitly (connector names via `niri msg outputs`
			// from a TTY, or `hyprctl monitors` in the desktop session):
			//
			// output "DP-1" {
			//     mode "3440x1440@180.000"
			//     scale 1.0
			// }
		EOF
	fi

	# --- 7. Greeter cache dir — replica of upstream EnsureGreeterCacheDir:
	#        greeter:greeter, setgid 2770, with users/, .local/state,
	#        .local/share, .cache and the per-user slot. The wrapper hard-
	#        exits if this dir is missing; DMS state/theme live inside it
	#        (the wrapper sets HOME=/var/cache/dms-greeter). -----------------
	local cache=/var/cache/dms-greeter d
	mkdir -p "$cache/users/$NEW_USER" \
		"$cache/.local/state" "$cache/.local/share" "$cache/.cache"
	chown -R greeter:greeter "$cache" 2>/dev/null \
		|| chown -R root:greeter "$cache" \
		|| die "step_greeter: could not chown $cache"
	for d in "$cache" "$cache/users" "$cache/users/$NEW_USER" \
		"$cache/.local" "$cache/.local/state" "$cache/.local/share" "$cache/.cache"; do
		chmod 2770 "$d"
	done

	# --- 8. Groups. NEW_USER joins 'greeter' so theme sharing works both
	#        ways (takes effect at next login — the post-install reboot).
	#        greeter joins 'render' as belt-and-braces for the systemd-258
	#        /dev/dri/renderD* permission regression ('video' membership
	#        already comes from greetd's sysusers). --------------------------
	usermod -aG greeter "$NEW_USER" \
		|| warn "usermod -aG greeter $NEW_USER failed"
	usermod -aG render greeter \
		|| warn "usermod -aG render greeter failed"

	# --- 9. User-side theme sources. Seed with '{}' when absent exactly like
	#        upstream SyncDMSConfigs, then group-share every DMS dir with the
	#        greeter (chgrp + g+rX, upstream SetupDMSGroup). ------------------

	# _seed_json FILE — create FILE with '{}' owned by NEW_USER if missing.
	_seed_json() {
		local f="$1"
		if [[ ! -f "$f" ]]; then
			printf '{}\n' >"$f"
			chown "$NEW_USER:$NEW_USER" "$f"
		fi
	}

	local _dms_dirs=(
		"$user_home/.config/DankMaterialShell"
		"$user_home/.local/state/DankMaterialShell"
		"$user_home/.cache/DankMaterialShell"
		"$user_home/.cache/quickshell"
		"$user_home/.config/quickshell"
	)
	for d in "${_dms_dirs[@]}"; do
		if [[ ! -d "$d" ]]; then
			install -d -o "$NEW_USER" -g "$NEW_USER" "$d"
		fi
	done
	_seed_json "$user_home/.config/DankMaterialShell/settings.json"
	_seed_json "$user_home/.local/state/DankMaterialShell/session.json"
	_seed_json "$user_home/.cache/DankMaterialShell/dms-colors.json"
	for d in "${_dms_dirs[@]}"; do
		chgrp -R greeter "$d" || warn "chgrp greeter failed on $d"
		chmod -R g+rX "$d" || warn "chmod g+rX failed on $d"
	done

	# --- 9b. Stow staging tree. step_dotfiles (which runs BEFORE this step —
	#         see setup.sh order) replaces ~/.config/DankMaterialShell files
	#         with symlinks into the stow staging dir under ~/.local/share.
	#         The greeter resolves the theme THROUGH those symlinks, so it
	#         needs traverse+read down the staging path too. chgrp/chmod on
	#         the symlink itself would not touch the target tree — grant on
	#         the real staged directories explicitly. ------------------------
	local stage_root="$user_home/.local/share/spede-arch"
	if [[ -d "$stage_root/dotfiles/dms" ]]; then
		setfacl -m g:greeter:rX "$stage_root" \
			|| warn "setfacl failed on $stage_root"
		setfacl -m g:greeter:rX "$stage_root/dotfiles" \
			|| warn "setfacl failed on $stage_root/dotfiles"
		chgrp -R greeter "$stage_root/dotfiles/dms" \
			|| warn "chgrp greeter failed on staged dms dotfiles"
		chmod -R g+rX "$stage_root/dotfiles/dms" \
			|| warn "chmod g+rX failed on staged dms dotfiles"
	fi

	# --- 10. Parent-directory ACLs, current upstream form (g:greeter:rX),
	#         after removing the deprecated v1 u:greeter entries (upstream
	#         RemediateStaleACLs does the same). ------------------------------
	local _acl_paths=(
		"$user_home"
		"$user_home/.config"
		"$user_home/.local"
		"$user_home/.local/state"
		"$user_home/.local/share"
		"$user_home/.cache"
	)
	local p
	for p in "${_acl_paths[@]}"; do
		[[ -d "$p" ]] || install -d -o "$NEW_USER" -g "$NEW_USER" "$p"
		setfacl -x u:greeter "$p" 2>/dev/null || true
		setfacl -m g:greeter:rX "$p" \
			|| warn "setfacl g:greeter:rX failed on $p"
	done

	# --- 11. Theme symlinks in the greeter cache (upstream SyncDMSConfigs):
	#         the greeter's HOME is the cache dir; these links let it read
	#         the user's live DMS settings, session and matugen colors. ------
	ln -sfT "$user_home/.config/DankMaterialShell/settings.json" "$cache/settings.json"
	ln -sfT "$user_home/.local/state/DankMaterialShell/session.json" "$cache/session.json"
	ln -sfT "$user_home/.cache/DankMaterialShell/dms-colors.json" "$cache/colors.json"

	# --- 11b. Per-user slot sync (wallpaper / profile image / localized
	#          theme), upstream's 'dms greeter sync --profile' — the no-sudo
	#          variant that only fills /var/cache/dms-greeter/users/<user>/.
	#          Best-effort: on a fresh install there is nothing to sync yet
	#          (the desktop shell populates it after first login); on an
	#          already-themed system it carries the wallpaper into the
	#          greeter. runuser re-inits groups, so NEW_USER's fresh
	#          'greeter' membership is already effective here. ---------------
	if command -v dms >/dev/null 2>&1; then
		# </dev/null: guard against any interactive prompt hanging the install.
		as_user "$NEW_USER" dms greeter sync --profile </dev/null >/dev/null 2>&1 \
			|| warn "dms greeter sync --profile failed (non-fatal: greeter uses default theme until next sync)"
	else
		warn "dms CLI not found — skipping per-user greeter theme sync (dms-shell-git missing?)"
	fi

	# --- 12. PROOF: the greeter user must be able to read the user's theme
	#         through symlink + ACL + group chain RIGHT NOW. If it cannot,
	#         fail the install loudly — this exact breakage is what black-
	#         screened v1 at boot. -------------------------------------------
	local f
	for f in settings.json session.json colors.json; do
		runuser -u greeter -- cat "$cache/$f" >/dev/null 2>&1 \
			|| die "step_greeter: greeter user cannot read $cache/$f (ACL/group chain broken — do NOT reboot into this)"
	done
	ok "greeter user verified able to read the DMS theme chain"

	# --- 13. Make boot graphical and enable greetd as THE login manager
	#         (upstream 'enable' does both; greetd.service already carries
	#         Conflicts=getty@tty1). ------------------------------------------
	systemctl set-default graphical.target >/dev/null 2>&1 \
		|| warn "could not set default target to graphical.target"
	enable_service greetd.service

	ok "greetd + DMS greeter configured (niri-hosted, cache + ACLs verified)"
	log "    Render-test the greeter UI inside a running desktop session:"
	log "      DMS_RUN_GREETER=1 DMS_GREET_CFG_DIR=/var/cache/dms-greeter \\"
	log "        qs -p /usr/share/quickshell/dms-greeter"
	log "    (login button inert without greetd — rendering is what's tested)"
	log "    If boot ever fails: journalctl -b -u greetd -t dms-greeter/niri"
}
