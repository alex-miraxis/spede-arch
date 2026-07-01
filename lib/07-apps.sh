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

	# --- Standardize the Node.js provider FIRST (spec §9 conflict guard) ------
	# Two packages we install disagree on Node: `zed` depends on `nodejs>=18`
	# (pacman's default provider is the package literally named `nodejs`, i.e.
	# Node 26), while `bitwarden-cli` hard-depends on `nodejs-lts-jod` (Node 22),
	# which *conflicts* with `nodejs`. If zed is installed first, Node 26 lands,
	# then bitwarden-cli aborts with "nodejs-lts-jod and nodejs are in conflict.
	# Remove nodejs? [y/N]" (--noconfirm answers No -> transaction fails).
	#
	# nodejs-lts-jod `provides nodejs=22.23.1`, which satisfies zed's `nodejs>=18`
	# and npm's `nodejs>=20.17.0`, so making it the single provider keeps every
	# consumer happy. Install it up front so it wins the provider slot. If a
	# prior (failed) run already pulled the conflicting `nodejs` package, swap it
	# out first with -Rdd (skip dep checks; dependents are re-satisfied by the
	# provides) so the install stays non-interactive and idempotent.
	if pacman -Qq nodejs >/dev/null 2>&1; then
		info "removing conflicting 'nodejs' (Node 26) in favor of nodejs-lts-jod"
		pacman -Rdd --noconfirm nodejs
	fi
	pkg_install nodejs-lts-jod

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
