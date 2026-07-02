# shellcheck shell=bash
# lib/13-postinstall.sh — step_postinstall
#
# Phase B, spec §9 ("External installers, as the user") + final notes. Runs
# as NEW_USER. This is the LAST step setup.sh calls.
#
# Per spec §9 this step:
#   - Installs Claude Code via the native installer (curl … | bash), which
#     lands `~/.local/bin/claude`. No npm. PATH is handled by the stowed
#     .zshrc (it puts ~/.local/bin on PATH), so we do NOT edit PATH here.
#   - Bootstraps LazyVim: clone the starter into ~/.config/nvim then strip its
#     .git, ONLY when ~/.config/nvim does not already exist (needs ripgrep+fd,
#     installed in step_apps).
#   - Creates a Notion PWA launcher .desktop running `helium --app=…` (Notion
#     has no official Linux app; Helium comes from step_aur).
#   - Prints a final summary + reboot instruction.
#
# NOT here: Codex was installed via `openai-codex` in step_apps — do NOT
# reinstall it. Helium itself is built in step_aur.
#
# Idempotent: Claude install is skipped when ~/.local/bin/claude exists;
# LazyVim clone is guarded by the ~/.config/nvim existence check; the .desktop
# is rewritten in place (stable content) and ensures no stale state.
#
# Contract: no shebang, no `set`, no `IFS=`; single function step_postinstall;
# nothing runs at source time; uses only common.sh helpers/globals.

step_postinstall() {
	info "post-install: Claude Code + LazyVim + Notion PWA (user=${NEW_USER})"

	[[ -n "${NEW_USER:-}" ]] || die "step_postinstall: NEW_USER is unset"
	getent passwd "$NEW_USER" >/dev/null 2>&1 \
		|| die "step_postinstall: user '$NEW_USER' does not exist"

	# Resolve the user's home from the passwd db (do not trust $HOME, which
	# under runuser/chroot may still be root's).
	local user_home
	user_home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
	[[ -n "$user_home" && -d "$user_home" ]] \
		|| die "step_postinstall: home dir for '$NEW_USER' not found: $user_home"

	need_cmd curl
	need_cmd git

	# -- 1. Claude Code native installer -----------------------------------
	# Lands ${user_home}/.local/bin/claude. No npm. The stowed .zshrc puts
	# ~/.local/bin on PATH, so no PATH edits are needed here.
	local claude_bin="${user_home}/.local/bin/claude"
	if [[ -x "$claude_bin" ]]; then
		ok "Claude Code already installed: $claude_bin"
	else
		info "installing Claude Code (curl -fsSL https://claude.ai/install.sh | bash)"
		# shellcheck disable=SC2016
		as_user "$NEW_USER" sh -c \
			'exec "$(command -v sh)" -c "$(curl -fsSL https://claude.ai/install.sh)"' \
			|| die "Claude Code install failed"
		if [[ -x "$claude_bin" ]]; then
			ok "Claude Code installed: $claude_bin"
		else
			warn "Claude Code installer ran but $claude_bin not found — check ~/.local/bin"
		fi
	fi

	# -- 2. LazyVim starter -------------------------------------------------
	# Clone the starter into ~/.config/nvim and strip its .git so it becomes
	# the user's own config. ONLY when ~/.config/nvim is absent. Needs ripgrep
	# + fd (installed in step_apps).
	local nvim_dir="${user_home}/.config/nvim"
	if [[ -e "$nvim_dir" ]]; then
		ok "nvim config already present, leaving untouched: $nvim_dir"
	else
		info "bootstrapping LazyVim starter -> $nvim_dir"
		as_user "$NEW_USER" git clone \
			https://github.com/LazyVim/starter "$nvim_dir" \
			|| die "LazyVim starter clone failed"
		as_user "$NEW_USER" rm -rf -- "${nvim_dir}/.git" \
			|| die "could not strip .git from $nvim_dir"
		ok "LazyVim bootstrapped: $nvim_dir"
	fi

	# -- 3. Notion PWA launcher (.desktop) ----------------------------------
	# Notion has no official Linux app; run it as a Helium PWA. Helium is built
	# in step_aur. Stable content, so rewriting in place is idempotent.
	local apps_dir="${user_home}/.local/share/applications"
	local notion_desktop="${apps_dir}/notion-pwa.desktop"
	as_user "$NEW_USER" mkdir -p "$apps_dir" \
		|| die "could not create $apps_dir"

	info "writing Notion PWA launcher -> $notion_desktop"
	as_user "$NEW_USER" tee "$notion_desktop" >/dev/null <<-'EOF'
		[Desktop Entry]
		Type=Application
		Name=Notion
		Comment=Notion (Helium PWA)
		Exec=helium --app=https://www.notion.so
		Icon=helium
		Terminal=false
		Categories=Office;Utility;
		StartupNotify=true
	EOF
	ok "Notion PWA launcher written: $notion_desktop"

	# Refresh the desktop database if the tool is present (best-effort).
	if command -v update-desktop-database >/dev/null 2>&1; then
		as_user "$NEW_USER" update-desktop-database "$apps_dir" >/dev/null 2>&1 \
			|| true
	fi

	# -- 4. Final summary + reboot instruction ------------------------------
	log ""
	log "${_C_GRN}===========================================================${_C_RESET}"
	log "${_C_GRN}  spede-arch install complete${_C_RESET}"
	log "${_C_GRN}===========================================================${_C_RESET}"
	log "  user      : ${NEW_USER}"
	log "  hostname  : ${NEW_HOSTNAME:-<unset>}"
	log "  disk      : ${TARGET_DISK:-<unset>}"
	log ""
	log "  Installed in this step:"
	log "    - Claude Code   -> ${user_home}/.local/bin/claude (on PATH via .zshrc)"
	log "    - LazyVim       -> ${nvim_dir}"
	log "    - Notion PWA    -> ${notion_desktop} (helium --app=https://www.notion.so)"
	log ""
	log "  Next steps:"
	if in_chroot; then
		log "    1. Exit the chroot, unmount, and reboot:"
		log "         exit            # leave arch-chroot"
		log "         umount -R ${NEWROOT}"
		log "         reboot"
	else
		log "    1. Reboot to apply the greeter + login shell + services:"
		log "         reboot"
	fi
	log "    2. At boot you get the SDDM 'Sugar Candy' greeter; pick the"
	log "       Hyprland session and log in (configured in step_greeter)."
	log "    3. Open nvim once to let LazyVim sync its plugins."
	log "    4. Sign in to Claude Code (\`claude\`), 1Password, Bitwarden, etc."
	log "${_C_GRN}===========================================================${_C_RESET}"
	log ""

	ok "post-install complete."
}
