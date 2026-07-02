#!/usr/bin/env bash
#
# bootstrap.sh — one-command entry point for a fresh Arch ISO.
#
# Turns "boot the ISO, then clone-and-run by hand" into a single line:
#
#   curl -fsSL https://raw.githubusercontent.com/alex-miraxis/spede-arch/main/bootstrap.sh | bash
#
# It clones (or fast-forwards) the spede-arch repo into /root/spede-arch and
# then launches the Phase A installer (install.sh), which handles the rest.
#
# Overridable via env (for forks / branches / unattended runs):
#   SPEDE_REPO    git URL to clone            (default: this repo on GitHub)
#   SPEDE_BRANCH  branch to install from      (default: main)
#   SPEDE_DEST    where to clone it           (default: /root/spede-arch)
#
# Re-runnable: if the destination already holds the repo it is fetched and
# reset to the requested branch rather than re-cloned.

set -euo pipefail

REPO="${SPEDE_REPO:-https://github.com/alex-miraxis/spede-arch.git}"
BRANCH="${SPEDE_BRANCH:-main}"
DEST="${SPEDE_DEST:-/root/spede-arch}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
	echo "bootstrap.sh must run as root (from the live Arch ISO)." >&2
	exit 1
fi

# git is on the official ISO, but a stripped image might lack it — pull it in.
if ! command -v git >/dev/null 2>&1; then
	echo "==> installing git (not present in this environment)"
	pacman -Sy --noconfirm git
fi

if [[ -d "${DEST}/.git" ]]; then
	echo "==> updating existing repo at ${DEST} (${BRANCH})"
	git -C "${DEST}" fetch --depth=1 origin "${BRANCH}"
	git -C "${DEST}" checkout -B "${BRANCH}" "origin/${BRANCH}"
else
	echo "==> cloning ${REPO} (${BRANCH}) -> ${DEST}"
	git clone --depth=1 --branch "${BRANCH}" "${REPO}" "${DEST}"
fi

cd "${DEST}"
echo "==> launching Phase A installer (install.sh)"
exec ./install.sh
