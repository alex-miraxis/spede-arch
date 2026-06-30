# shellcheck shell=bash
# lib/07-apps.sh — step_apps: official-repo GUI applications, editors, and CLIs.
#
# Per design spec §9, these all live in the official `extra` repo now — NOT
# the AUR. In particular Codex (openai-codex), Zed, and Bitwarden migrated to
# official, so they are installed here with pkg_install, not aur_install.
#
# Grouped exactly as spec §9 lists them:
#   - Terminal / file manager / media: ghostty, dolphin, ark, kio-extras,
#       kdegraphics-thumbnailers, ffmpegthumbs, vlc, vlc-plugins-all
#   - Editors / dev CLIs:              zed, neovim, ripgrep, fd, openai-codex
#   - Messaging / secrets:             telegram-desktop, bitwarden, bitwarden-cli
#
# Idempotent: pkg_install uses pacman -S --needed --noconfirm, so re-running
# in the chroot or on the booted system is safe. AUR helper apps, the Helium /
# 1Password PGP key imports, fonts, LazyVim bootstrap, and Claude Code all
# belong to other steps (08-aur, 12-dotfiles, 13-postinstall) — not here.

step_apps() {
	info "Installing official-repo applications, editors, and CLIs"

	# Terminal / file manager / archive / media.
	# kdegraphics-thumbnailers + ffmpegthumbs give Dolphin image/video previews.
	pkg_install \
		ghostty \
		dolphin \
		ark \
		kio-extras \
		kdegraphics-thumbnailers \
		ffmpegthumbs \
		vlc \
		vlc-plugins-all

	# Editors and dev CLIs. ripgrep + fd are also LazyVim deps (spec §9).
	# openai-codex and zed are official `extra` now — no AUR build.
	pkg_install \
		zed \
		neovim \
		ripgrep \
		fd \
		openai-codex

	# Messaging and secrets. bitwarden (GUI) + bitwarden-cli, both official now.
	pkg_install \
		telegram-desktop \
		bitwarden \
		bitwarden-cli

	ok "official applications installed"
}
