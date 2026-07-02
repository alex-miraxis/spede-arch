# shellcheck shell=bash
# lib/08-aur.sh — step_aur
#
# Phase B. Bootstrap the `yay` AUR helper from yay-bin as the NON-root user,
# import the mandatory PGP keys for the PGP-gated builds, then install the
# AUR package set listed in packages/aur.txt (spec §9, §10).
#
# Why non-root: makepkg (and yay) refuse to run as root by design, so every
# build action goes through `as_user "$NEW_USER" ...`. NEW_USER must be set
# (load_config restored it); aur_install enforces this too.
#
# Idempotent: the yay bootstrap is skipped when `yay` is already on PATH;
# `gpg --recv-keys` is a no-op when the key is already in the user's keyring;
# pacman -S --needed (inside yay) skips already-installed packages.
#
# NOTE (dms-shell official-extra migration): packages/aur.txt pins the shell
# to `dms-shell-git`. Per spec §6/§14 this is a build-time check — if/when
# `dms-shell` lands in the official `extra` repo, prefer that pacman package
# over the AUR -git build. We detect it here and swap before building.

step_aur() {
	info "step_aur: bootstrapping yay + installing AUR packages"

	[[ -n "${NEW_USER:-}" ]] || die "step_aur: NEW_USER is unset (config missing)"
	getent passwd "$NEW_USER" >/dev/null 2>&1 \
		|| die "step_aur: user '$NEW_USER' does not exist"

	# base-devel + git are required to build anything from the AUR. --needed
	# makes this a no-op when they are already present (pacstrap pulls them).
	pkg_install base-devel git

	# --- yay bootstrap (skipped when already installed) ----------------------
	if as_user "$NEW_USER" bash -lc 'command -v yay' >/dev/null 2>&1; then
		ok "yay already present — skipping bootstrap"
	else
		info "bootstrapping yay from yay-bin (as $NEW_USER)"
		local build_dir
		build_dir=$(as_user "$NEW_USER" mktemp -d) \
			|| die "step_aur: could not create build dir"
		# Clone, build and install as the user; makepkg -si invokes pacman via
		# sudo for the final install, so the wheel sudoers drop-in (step_system)
		# must already be in place.
		as_user "$NEW_USER" git clone --depth=1 \
			https://aur.archlinux.org/yay-bin.git "$build_dir/yay-bin" \
			|| die "step_aur: failed to clone yay-bin"
		as_user "$NEW_USER" bash -c \
			"cd '$build_dir/yay-bin' && makepkg -si --noconfirm" \
			|| die "step_aur: yay-bin build/install failed"
		# Best-effort cleanup of the throwaway build tree.
		rm -rf -- "$build_dir" 2>/dev/null || true
		as_user "$NEW_USER" bash -lc 'command -v yay' >/dev/null 2>&1 \
			|| die "step_aur: yay not on PATH after bootstrap"
		ok "yay bootstrapped"
	fi

	# --- mandatory PGP key imports (BEFORE any PGP-gated build; spec §9) ------
	# Imported into NEW_USER's keyring (makepkg verifies as that user). Both
	# calls are idempotent; the 1Password key periodically expires, so a
	# re-run simply refreshes it (spec §13 risk 4).
	info "importing mandatory PGP keys (Helium, 1Password)"
	# Helium (required since 0.7.7.2):
	as_user "$NEW_USER" gpg --keyserver keyserver.ubuntu.com \
		--recv-keys BE677C1989D35EAB2C5F26C9351601AD01D6378E \
		|| warn "step_aur: could not import Helium PGP key (helium build may fail)"
	# 1Password (AgileBits):
	as_user "$NEW_USER" gpg --keyserver keyserver.ubuntu.com \
		--recv-keys 3FEF9748469ADBE15DA7CA80AC2D62742012EA22 \
		|| warn "step_aur: could not import 1Password PGP key (1password build may fail)"

	# --- official-extra migration check for the DMS shell --------------------
	# Default to the AUR -git build; prefer the official extra package if it
	# has appeared there since the spec was written.
	local dms_pkg="dms-shell-git"
	if pacman -Si dms-shell >/dev/null 2>&1; then
		info "dms-shell found in official repos — using it instead of dms-shell-git"
		pkg_install dms-shell
		dms_pkg=""
	fi

	# --- AUR package set (spec §9) -------------------------------------------
	# Built individually so one failing PGP-gated package does not abort the
	# whole set; the user can re-run setup.sh to retry.
	local pkgs=(
		"$dms_pkg"
		xremap-hypr-bin
		helium-browser-bin
		1password
		1password-cli
		zapzap
		slack-desktop
		hyprshot
		ttf-manrope
	)

	local pkg
	for pkg in "${pkgs[@]}"; do
		[[ -n "$pkg" ]] || continue
		info "AUR install: $pkg"
		aur_install "$pkg" || warn "step_aur: AUR install failed for $pkg (re-run setup.sh to retry)"
	done

	ok "step_aur: AUR packages installed"
}
