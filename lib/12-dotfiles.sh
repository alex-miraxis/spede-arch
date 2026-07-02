# shellcheck shell=bash
# lib/12-dotfiles.sh — step_dotfiles
#
# Phase B, spec §11 ("Dotfiles, with corrected ordering"). Runs as NEW_USER.
#
# ORDERING IS CRITICAL (spec §11): oh-my-zsh first (RUNZSH=no KEEP_ZSHRC=yes
# so it does NOT clobber the stowed .zshrc), then powerlevel10k + the zsh
# plugins (zsh-autosuggestions, zsh-syntax-highlighting), then
# `chsh -s /usr/bin/zsh`, and ONLY THEN stow the dotfile packages from the
# repo. stow aborts on pre-existing regular files, so we back up any
# conflicting target files first, then `stow --restow`.
#
# Idempotent: omz/p10k/plugin clones are guarded by directory checks, chsh is
# a no-op when the shell is already zsh, conflict backups only touch real
# files (and non-stow symlinks), and `stow --restow` is inherently re-safe.
#
# Contract: no shebang, no `set`, no `IFS=`; EXACTLY ONE top-level function
# (step_dotfiles); nothing runs at source time; uses only common.sh
# helpers/globals. Internal helpers below are defined INSIDE step_dotfiles.

step_dotfiles() {
	info "dotfiles: oh-my-zsh + powerlevel10k + plugins + stow (user=${NEW_USER})"

	[[ -n "${NEW_USER:-}" ]] || die "step_dotfiles: NEW_USER is unset"
	getent passwd "$NEW_USER" >/dev/null 2>&1 \
		|| die "step_dotfiles: user '$NEW_USER' does not exist"

	# Resolve the user's home directly from the passwd db (do not trust $HOME,
	# which under runuser/chroot may still be root's).
	local user_home
	user_home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
	[[ -n "$user_home" && -d "$user_home" ]] \
		|| die "step_dotfiles: home dir for '$NEW_USER' not found: $user_home"

	need_cmd stow
	need_cmd git

	# --- internal helpers (locals to step_dotfiles, per the one-function
	#     contract; they close over $NEW_USER) ---------------------------

	# _clone_user URL DEST — idempotent shallow git clone as NEW_USER.
	_clone_user() {
		local url="$1" dest="$2"
		if [[ -d "${dest}/.git" ]]; then
			ok "already present: $(basename "$dest")"
			return 0
		fi
		info "cloning: $(basename "$dest")"
		as_user "$NEW_USER" git clone --depth=1 "$url" "$dest" \
			|| die "git clone failed: $url"
		ok "cloned: $(basename "$dest")"
	}

	# _backup_conflict PATH — back up a pre-existing real file or non-stow
	# symlink (timestamped copy) then remove it so stow can take the path.
	# Symlinks stow already owns are handled by the caller and never reach here.
	_backup_conflict() {
		local path="$1" bak
		[[ -e "$path" || -L "$path" ]] || return 0
		bak="${path}.bak.$(date +%Y%m%d%H%M%S)"
		cp -aP -- "$path" "$bak" || die "backup failed: $path"
		rm -f -- "$path" || die "could not remove conflicting path: $path"
		info "backed up & cleared conflict: $path -> $bak"
	}

	# _clear_pkg_conflicts STOW_DIR PKG — for every file the stow package
	# provides, back up any pre-existing real file / foreign symlink at the
	# target so `stow` does not abort. Stow-owned symlinks are left alone.
	_clear_pkg_conflicts() {
		local stow_dir="$1" pkg="$2"
		local pkg_root="${stow_dir}/${pkg}"
		local src rel target resolved_target resolved_src
		while IFS= read -r -d '' src; do
			rel="${src#"${pkg_root}/"}"
			target="${user_home}/${rel}"
			[[ -e "$target" || -L "$target" ]] || continue
			if [[ -L "$target" ]]; then
				resolved_target="$(readlink -f -- "$target" 2>/dev/null || true)"
				resolved_src="$(readlink -f -- "$src" 2>/dev/null || true)"
				# stow already owns this symlink -> leave it.
				[[ -n "$resolved_target" && "$resolved_target" == "$resolved_src" ]] && continue
				_backup_conflict "$target"
			elif [[ -f "$target" ]]; then
				_backup_conflict "$target"
			fi
		done < <(as_user "$NEW_USER" find "$pkg_root" -type f -print0 2>/dev/null)
	}

	# -- 1. oh-my-zsh -------------------------------------------------------
	# RUNZSH=no   -> do not switch into a zsh subshell at the end.
	# KEEP_ZSHRC=yes -> do NOT overwrite/move an existing .zshrc (ours stays).
	# CHSH=no     -> omz must not change the shell; we do that explicitly below.
	local omz_dir="${user_home}/.oh-my-zsh"
	if [[ -d "$omz_dir" ]]; then
		ok "oh-my-zsh already installed: $omz_dir"
	else
		info "installing oh-my-zsh (RUNZSH=no KEEP_ZSHRC=yes CHSH=no)"
		# The inner $() is deliberately deferred to the user's sh (it fetches
		# and runs the official installer). shellcheck SC2016 is suppressed
		# because non-expansion in this shell is exactly what we want.
		# shellcheck disable=SC2016
		as_user "$NEW_USER" env RUNZSH=no KEEP_ZSHRC=yes CHSH=no \
			sh -c '"$0" -c "$(curl -fsSL "$1")"' \
			sh https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
			|| die "oh-my-zsh install failed"
		ok "oh-my-zsh installed"
	fi

	# ZSH_CUSTOM defaults to $ZSH/custom; clone p10k + plugins under it.
	local zsh_custom="${omz_dir}/custom"

	# -- 2. powerlevel10k theme --------------------------------------------
	local p10k_dir="${zsh_custom}/themes/powerlevel10k"
	_clone_user "https://github.com/romkatv/powerlevel10k.git" "$p10k_dir"

	# Pre-fetch the gitstatusd daemon NOW, while we are guaranteed online (the
	# preflight required network). p10k otherwise downloads it lazily on the
	# first prompt; if that first shell is offline (e.g. before NetworkManager
	# has associated), p10k prints "gitstatus failed to initialize" every shell
	# until online. The installer script drops the binary into
	# ~/.cache/gitstatus, exactly where the p10k plugin looks for it. Non-fatal.
	if [[ -f "${p10k_dir}/gitstatus/install" ]]; then
		info "dotfiles: pre-fetching powerlevel10k gitstatusd (offline-safe first boot)"
		as_user "$NEW_USER" sh "${p10k_dir}/gitstatus/install" \
			|| warn "gitstatus pre-fetch failed (non-fatal; p10k will fetch it on the first online shell)"
	fi

	# -- 3. zsh plugins -----------------------------------------------------
	_clone_user "https://github.com/zsh-users/zsh-autosuggestions.git" \
		"${zsh_custom}/plugins/zsh-autosuggestions"
	_clone_user "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
		"${zsh_custom}/plugins/zsh-syntax-highlighting"

	# -- 4. chsh — make zsh the login shell --------------------------------
	local cur_shell
	cur_shell="$(getent passwd "$NEW_USER" | cut -d: -f7)"
	if [[ "$cur_shell" == "/usr/bin/zsh" ]]; then
		ok "login shell already /usr/bin/zsh"
	else
		need_cmd zsh
		info "setting login shell to /usr/bin/zsh"
		# chsh as root targets the user without prompting for a password.
		chsh -s /usr/bin/zsh "$NEW_USER" \
			|| die "chsh -s /usr/bin/zsh $NEW_USER failed"
		ok "login shell set to /usr/bin/zsh"
	fi

	# -- 5. stow the dotfile packages --------------------------------------
	# Done LAST so omz/p10k/plugins are in place and the stowed .zshrc wins.
	#
	# We CANNOT stow straight from REPO_DEST (/root/spede-arch, mode 0700):
	# NEW_USER cannot traverse /root, so both the install-time stow and the
	# resulting runtime symlinks (which would point into /root) would be
	# broken and unreadable at login. Stage the dotfiles into a user-owned
	# location first, chown it to NEW_USER, and stow from there so every
	# symlink resolves into a path the user actually owns. The staged copy is
	# refreshed on every run (idempotent).
	local src_stow_dir="${REPO_DEST}/dotfiles"
	[[ -d "$src_stow_dir" ]] || die "step_dotfiles: stow dir not found: $src_stow_dir"

	local stow_dir="${user_home}/.local/share/spede-arch/dotfiles"
	info "staging dotfiles into user-owned dir: $stow_dir"
	as_user "$NEW_USER" mkdir -p "${user_home}/.local/share/spede-arch" \
		|| die "step_dotfiles: mkdir staging parent failed: ${user_home}/.local/share/spede-arch"
	rm -rf -- "$stow_dir" \
		|| die "step_dotfiles: could not clear stale staging dir: $stow_dir"
	cp -a -- "$src_stow_dir" "$stow_dir" \
		|| die "step_dotfiles: copy to staging dir failed: $src_stow_dir -> $stow_dir"
	chown -R "$NEW_USER:$NEW_USER" "$stow_dir" \
		|| die "step_dotfiles: chown staging dir failed: $stow_dir"

	local packages=(hypr ghostty xremap dms zsh zed)
	local pkg
	for pkg in "${packages[@]}"; do
		if [[ ! -d "${stow_dir}/${pkg}" ]]; then
			warn "stow package missing, skipping: ${stow_dir}/${pkg}"
			continue
		fi
		_clear_pkg_conflicts "$stow_dir" "$pkg"
		info "stow --restow ${pkg} -> ${user_home}"
		as_user "$NEW_USER" stow \
			--dir="$stow_dir" \
			--target="$user_home" \
			--restow \
			"$pkg" \
			|| die "stow --restow $pkg failed"
		ok "stowed: $pkg"
	done

	ok "dotfiles complete."
}
