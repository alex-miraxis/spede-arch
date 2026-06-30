# shellcheck shell=bash
# lib/06-desktop.sh — step_desktop
#
# Hyprland + DankMaterialShell (DMS) desktop stack, OFFICIAL-repo set only.
# Spec §6, §9. DMS (Quickshell + Go) replaces waybar/swaylock/swayidle/mako/
# fuzzel AND the polkit agent, so we deliberately do NOT install hyprpaper,
# hyprlock, hypridle, or hyprpolkitagent — DMS provides wallpaper, lock, idle
# and polkit; duplicates conflict.
#
# AUR pieces (dms-shell, the DMS greeter, xremap) are handled in step_aur /
# step_greeter / step_input — NOT here. quickshell/matugen/dgop live in the
# official `extra` repo (the bare AUR names don't exist), so they go here.
#
# Idempotent: pacman -S --needed, and xdg-user-dirs-update is naturally
# re-run-safe. Sourced by setup.sh; nothing runs until step_desktop is called.

step_desktop() {
	info "Desktop stack — Hyprland + DMS (official-repo packages)"

	# DMS official-repo runtime + Wayland/portal/clipboard/screenshot glue +
	# AMD graphics stack + fonts. Verbatim from spec §6/§9. Excludes the
	# DMS-provided pieces (hyprpaper/hyprlock/hypridle/hyprpolkitagent) and
	# the AUR pieces (dms-shell, greeter, xremap).
	pkg_install \
		hyprland \
		quickshell \
		matugen \
		dgop \
		accountsservice \
		xdg-desktop-portal \
		xdg-desktop-portal-hyprland \
		xdg-desktop-portal-gtk \
		qt6-wayland \
		qt5-wayland \
		polkit \
		qt6ct \
		adw-gtk-theme \
		wl-clipboard \
		cliphist \
		brightnessctl \
		mesa \
		vulkan-radeon \
		libva-mesa-driver \
		vulkan-icd-loader \
		xdg-user-dirs \
		grim \
		slurp \
		satty \
		noto-fonts \
		noto-fonts-cjk \
		noto-fonts-emoji \
		ttf-jetbrains-mono-nerd \
		ttf-meslo-nerd \
		inter-font

	# Populate the XDG user dirs (~/Desktop, ~/Downloads, ...). On the booted
	# system this must run as the real user so the dirs land in their $HOME;
	# inside the chroot there is no user session, so run it for NEW_USER's HOME
	# when that user exists, else fall back to the global update.
	if [[ -n "${NEW_USER:-}" ]] && id "$NEW_USER" >/dev/null 2>&1; then
		as_user "$NEW_USER" xdg-user-dirs-update \
			|| warn "xdg-user-dirs-update failed for $NEW_USER"
	else
		xdg-user-dirs-update \
			|| warn "xdg-user-dirs-update failed"
	fi

	ok "Desktop stack installed (DMS shell/greeter/xremap come from AUR steps)."
}
