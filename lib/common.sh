#!/usr/bin/env bash
#
# lib/common.sh — shared library for the spede-arch installer.
#
# This file owns the shebang + `set` line + IFS for the whole installer.
# install.sh and setup.sh source it. The numbered lib/NN-*.sh step files
# do NOT — they are sourced by setup.sh after this file is already loaded.
#
# ===========================================================================
#  libContract — EVERY lib/NN-<name>.sh step file MUST obey this, verbatim:
# ===========================================================================
#   1. NO shebang line. NO `set -euo pipefail`. NO `IFS=` line.
#      common.sh owns those; the step files are sourced into that context.
#   2. The file defines EXACTLY ONE function, named step_<name>, matching
#      its filename: lib/01-disk.sh defines step_disk(), lib/04-boot.sh
#      defines step_boot(), etc. No other top-level functions.
#   3. NOTHING executes at source time. The file is pure definitions —
#      sourcing it must have zero side effects. All work happens only when
#      setup.sh (or install.sh) later calls step_<name>.
#   4. Use ONLY the helpers and global vars defined in this file
#      (log/info/warn/err/die/ok, confirm, need_cmd, in_chroot, as_user,
#       pkg_install, aur_install, ensure_line, backup_file, enable_service,
#       enable_user_service_global, save_config, load_config, and the
#       global config vars below). Do not re-define them.
#   5. Every mutating action must be idempotent (pacman -S --needed,
#      getent/id guards, `ensure_line`, `stow --restow`, re-run-safe checks).
#      setup.sh is re-runnable in the chroot AND on the booted system.
#
#   Canonical filename → function map (do not deviate):
#     00-preflight.sh   -> step_preflight
#     01-disk.sh        -> step_disk
#     02-pacstrap.sh    -> step_pacstrap
#     03-system.sh      -> step_system
#     04-boot.sh        -> step_boot
#     05-snapper.sh     -> step_snapper
#     06-desktop.sh     -> step_desktop
#     07-apps.sh        -> step_apps
#     08-aur.sh         -> step_aur
#     09-greeter.sh     -> step_greeter
#     10-input.sh       -> step_input
#     11-services.sh    -> step_services
#     12-dotfiles.sh    -> step_dotfiles
#     13-postinstall.sh -> step_postinstall
# ===========================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
#  Global config — hardcoded defaults (spec §2, §10). Overridable via env.
# ---------------------------------------------------------------------------
: "${TIMEZONE:=Europe/Athens}"
: "${LOCALE_PRIMARY:=en_US.UTF-8}"
: "${LOCALE_EXTRA:=el_GR.UTF-8}"
: "${KEYFILE:=/crypto_keyfile.bin}"
: "${NEWROOT:=/mnt}"
: "${REPO_DEST:=/root/spede-arch}"

# ---------------------------------------------------------------------------
#  Runtime config — set interactively by step_preflight / step_disk, then
#  persisted with save_config so they survive the arch-chroot boundary and
#  are reloadable by setup.sh on the booted system. Empty until set/loaded.
# ---------------------------------------------------------------------------
: "${TARGET_DISK:=}"
: "${NEW_HOSTNAME:=}"
: "${NEW_USER:=}"

# The persisted config file. During Phase A it is written under the new
# system (NEWROOT+REPO_DEST); inside the chroot / on the booted system
# REPO_DEST resolves to the same path, so the file is found either way.
config_path() {
	if [[ -d "${NEWROOT}${REPO_DEST}" ]]; then
		printf '%s\n' "${NEWROOT}${REPO_DEST}/.install-config"
	else
		printf '%s\n' "${REPO_DEST}/.install-config"
	fi
}

# ---------------------------------------------------------------------------
#  Color logging — ALL diagnostics go to stderr so stdout stays clean for
#  any command substitution a step might do.
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
	_C_RESET=$'\033[0m'; _C_DIM=$'\033[2m'; _C_RED=$'\033[1;31m'
	_C_GRN=$'\033[1;32m'; _C_YEL=$'\033[1;33m'; _C_BLU=$'\033[1;34m'
else
	_C_RESET=''; _C_DIM=''; _C_RED=''; _C_GRN=''; _C_YEL=''; _C_BLU=''
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s::%s %s\n' "$_C_BLU" "$_C_RESET" "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$_C_YEL" "$_C_RESET" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
ok()   { printf '%s ok:%s %s\n' "$_C_GRN" "$_C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
#  confirm "prompt" — interactive y/N. Returns 0 on yes, 1 otherwise.
#  Defaults to No. Honors ASSUME_YES=1 for non-interactive runs.
# ---------------------------------------------------------------------------
confirm() {
	local prompt="${1:-Are you sure?}" reply
	if [[ "${ASSUME_YES:-0}" == "1" ]]; then
		return 0
	fi
	printf '%s [y/N] ' "$prompt" >&2
	read -r reply || true
	[[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# need_cmd name — die unless `name` is on PATH.
need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# in_chroot — true (0) when running inside arch-chroot / a chroot, else 1.
# Compares the device:inode of / against that of /proc/1/root/. They differ
# inside a chroot. Falls back to the ischroot heuristic if /proc is absent.
in_chroot() {
	if [[ -r /proc/1/root/. ]]; then
		local root_stat init_stat
		root_stat=$(stat -c '%d:%i' / 2>/dev/null) || return 1
		init_stat=$(stat -c '%d:%i' /proc/1/root/. 2>/dev/null) || return 0
		[[ "$root_stat" != "$init_stat" ]]
	else
		# No PID 1 root visible — assume chroot (e.g. arch-chroot w/o /proc map).
		return 0
	fi
}

# as_user USER CMD... — run CMD as USER with a login-ish env. Uses runuser
# when available (root, no PAM password), else sudo -u.
#
# CWD reset: setup.sh runs from REPO_DEST (/root/spede-arch, mode 0700).
# runuser/sudo do NOT change the working directory, so a command dropped to an
# unprivileged user would inherit that CWD — which the user cannot traverse.
# Tools that touch their starting dir then break: the oh-my-zsh installer does
# `cd "$ZSH" && ... && cd -`, and that `cd -` back into /root fails, aborting
# the whole install. We force CWD (and PWD/OLDPWD, which runuser leaves stale)
# to `/`, a path every user can access. Every as_user caller uses absolute
# paths, so resetting the CWD is safe.
as_user() {
	local user="$1"; shift
	[[ -n "$user" ]] || die "as_user: empty user"
	if command -v runuser >/dev/null 2>&1; then
		runuser -u "$user" -- env --chdir=/ PWD=/ OLDPWD=/ "$@"
	else
		sudo -u "$user" -- env --chdir=/ PWD=/ OLDPWD=/ "$@"
	fi
}

# pkg_install PKGS... — install official packages, idempotent.
#
# Retries transient failures: a single flaky mirror timing out on one package
# (seen on real metal: repo.greeklug.gr timing out on system-config-printer)
# must not abort the whole install under set -e. Three quick attempts with
# backoff, then a final attempt with pacman's relaxed download timeouts —
# only that last one is allowed to kill the run.
pkg_install() {
	[[ $# -gt 0 ]] || return 0
	local attempt
	for attempt in 1 2 3; do
		if pacman -S --needed --noconfirm "$@"; then
			return 0
		fi
		warn "pacman failed (attempt ${attempt}/4) — retrying in $((attempt * 5))s (flaky mirror?)"
		sleep $((attempt * 5))
	done
	warn "pacman final attempt with relaxed download timeouts"
	pacman -S --needed --noconfirm --disable-download-timeout "$@"
}

# aur_install PKGS... — build/install AUR packages as NEW_USER via yay.
# yay (and makepkg) refuse to run as root, hence as_user.
# Same transient-failure retry policy as pkg_install (downloads can hit the
# same flaky mirrors, plus AUR/GitHub fetch blips).
aur_install() {
	[[ $# -gt 0 ]] || return 0
	[[ -n "${NEW_USER:-}" ]] || die "aur_install: NEW_USER is unset"
	local attempt
	for attempt in 1 2 3; do
		if as_user "$NEW_USER" yay -S --needed --noconfirm "$@"; then
			return 0
		fi
		warn "yay failed (attempt ${attempt}/4) — retrying in $((attempt * 5))s (flaky mirror/AUR?)"
		sleep $((attempt * 5))
	done
	as_user "$NEW_USER" yay -S --needed --noconfirm "$@"
}

# ensure_line FILE LINE — append LINE to FILE only if not already present
# (exact full-line match). Creates FILE (and parent dir) if missing.
ensure_line() {
	local file="$1" line="$2"
	[[ -n "$file" ]] || die "ensure_line: empty file path"
	mkdir -p "$(dirname "$file")"
	[[ -f "$file" ]] || : >"$file"
	if ! grep -qxF -- "$line" "$file"; then
		printf '%s\n' "$line" >>"$file"
	fi
}

# backup_file PATH — copy PATH to PATH.bak.<timestamp> if it exists and is a
# regular file. No-op otherwise. Prints the backup path to stderr.
backup_file() {
	local path="$1" bak
	if [[ -f "$path" ]]; then
		bak="${path}.bak.$(date +%Y%m%d%H%M%S)"
		cp -a -- "$path" "$bak"
		info "backed up $path -> $bak"
	fi
}

# enable_service NAME — `systemctl enable` a system unit (idempotent).
# Skips the actual start; setup.sh runs in chroot where nothing is running.
enable_service() {
	local name="$1"
	systemctl enable "$name" >/dev/null 2>&1 \
		|| warn "could not enable system service: $name"
}

# enable_user_service_global NAME — enable a unit for ALL users via the
# global preset (systemctl --global enable). Works in the chroot because it
# only writes symlinks under /etc/systemd/user; no running manager needed.
enable_user_service_global() {
	local name="$1"
	systemctl --global enable "$name" >/dev/null 2>&1 \
		|| warn "could not globally enable user service: $name"
}

# write_wifi_connection ROOT SSID PSK — write a NetworkManager keyfile into the
# target so the INSTALLED system auto-connects to Wi-Fi on first boot.
#
# The live-ISO network (usually iwd via `iwctl`) does NOT carry into the
# installed system, so a Wi-Fi machine would otherwise boot offline. We write
# the profile ourselves, root-owned 0600 (NetworkManager ignores world/group
# readable keyfiles). No-op when SSID is empty (wired machines).
write_wifi_connection() {
	local root="$1" ssid="$2" psk="$3"
	[[ -n "$ssid" ]] || return 0
	local dir="${root}/etc/NetworkManager/system-connections"
	mkdir -p "$dir"
	local uuid; uuid="$(uuidgen 2>/dev/null || true)"
	# Sanitise the filename (slashes/spaces would break the path); the real
	# SSID is preserved verbatim inside the file.
	local safe_name="${ssid//\//_}"; safe_name="${safe_name// /_}"
	local f="${dir}/${safe_name}.nmconnection"
	(
		umask 077
		{
			printf '[connection]\n'
			printf 'id=%s\n' "$ssid"
			[[ -n "$uuid" ]] && printf 'uuid=%s\n' "$uuid"
			printf 'type=wifi\n'
			printf 'autoconnect=true\n\n'
			printf '[wifi]\n'
			printf 'mode=infrastructure\n'
			printf 'ssid=%s\n\n' "$ssid"
			printf '[wifi-security]\n'
			printf 'key-mgmt=wpa-psk\n'
			printf 'psk=%s\n\n' "$psk"
			printf '[ipv4]\nmethod=auto\n\n'
			printf '[ipv6]\nmethod=auto\n'
		} >"$f"
	)
	chmod 600 "$f"
	ok "wrote NetworkManager Wi-Fi profile for '${ssid}' -> ${f}"
}

# ---------------------------------------------------------------------------
#  Config persistence across the chroot boundary.
# ---------------------------------------------------------------------------

# save_config — write the runtime vars to the .install-config file.
save_config() {
	local f; f=$(config_path)
	mkdir -p "$(dirname "$f")"
	{
		printf '# spede-arch install config — generated by preflight\n'
		printf 'TARGET_DISK=%q\n'  "${TARGET_DISK:-}"
		printf 'NEW_HOSTNAME=%q\n' "${NEW_HOSTNAME:-}"
		printf 'NEW_USER=%q\n'     "${NEW_USER:-}"
	} >"$f"
	ok "saved install config -> $f"
}

# load_config — source the .install-config file if present. Safe to call
# when it does not yet exist (no-op). Re-exports the runtime vars.
load_config() {
	local f; f=$(config_path)
	if [[ -f "$f" ]]; then
		# shellcheck source=/dev/null
		source "$f"
		export TARGET_DISK NEW_HOSTNAME NEW_USER
	fi
}
