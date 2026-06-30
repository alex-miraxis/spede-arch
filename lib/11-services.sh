# shellcheck shell=bash
# lib/11-services.sh — step_services
#
# Phase B. Enables the system + per-user services and configures the firewall
# and mDNS name resolution, per spec §10 (verified):
#   - Audio:    pipewire pipewire-pulse wireplumber as global --user units;
#               pulseaudio MUST NOT be installed (conflicts with pipewire-pulse).
#   - Bluetooth: bluetooth.service (DMS provides the applet; no blueman).
#   - Printing: cups.socket (socket-activated, NOT cups.service) + avahi-daemon;
#               nsswitch hosts line gets `mdns_minimal [NOTFOUND=return]` before
#               resolve/dns for `.local` discovery.
#   - Network:  NetworkManager.service.
#   - Time:     systemd-timesyncd.
#   - Firewall: ufw default deny incoming / allow outgoing / allow 5353/udp,
#               then enable ufw.
#
# Idempotent: enable_service / enable_user_service_global skip already-enabled
# units, the nsswitch edit is guarded, and the ufw rules are declarative.

step_services() {
	info "configuring system services, mDNS & firewall (§10)"

	# --- Audio: PipeWire stack (per-user, global preset) ---------------------
	# pulseaudio conflicts with pipewire-pulse; the pacstrap/pacman set never
	# installs it, but guard explicitly so a re-run on a dirtied system is safe.
	if pacman -Qq pulseaudio >/dev/null 2>&1; then
		warn "pulseaudio is installed but conflicts with pipewire-pulse; removing"
		pacman -Rns --noconfirm pulseaudio >/dev/null 2>&1 \
			|| warn "could not remove pulseaudio; remove it manually"
	fi
	pkg_install pipewire pipewire-pulse pipewire-alsa wireplumber
	enable_user_service_global pipewire.service
	enable_user_service_global pipewire-pulse.service
	enable_user_service_global wireplumber.service

	# --- Bluetooth -----------------------------------------------------------
	pkg_install bluez bluez-utils
	enable_service bluetooth.service

	# --- Printing: CUPS (socket-activated) + Avahi for mDNS discovery --------
	pkg_install cups system-config-printer gutenprint foomatic-db avahi nss-mdns
	enable_service cups.socket
	enable_service avahi-daemon.service

	# nsswitch hosts: insert `mdns_minimal [NOTFOUND=return]` before resolve/dns
	# so `.local` names resolve via Avahi. Idempotent — skips if already present.
	local nss=/etc/nsswitch.conf
	if [[ -f "$nss" ]]; then
		if grep -qE '^[[:space:]]*hosts:' "$nss"; then
			if grep -qE '^[[:space:]]*hosts:.*mdns_minimal' "$nss"; then
				info "nsswitch hosts line already has mdns_minimal"
			else
				backup_file "$nss"
				# Insert mdns_minimal [NOTFOUND=return] immediately before the
				# first of `resolve`/`dns` on the hosts line.
				sed -i -E \
					'/^[[:space:]]*hosts:/ s/(\bresolve\b|\bdns\b)/mdns_minimal [NOTFOUND=return] \1/' \
					"$nss"
				ok "added mdns_minimal to nsswitch hosts line"
			fi
		else
			warn "no hosts: line in $nss; skipping mDNS nsswitch edit"
		fi
	else
		warn "$nss not found; skipping mDNS nsswitch edit"
	fi

	# --- Network -------------------------------------------------------------
	enable_service NetworkManager.service

	# --- Time sync -----------------------------------------------------------
	enable_service systemd-timesyncd.service

	# --- Firewall: ufw -------------------------------------------------------
	# Declarative defaults + the mDNS port, then enable. ufw commands are
	# idempotent (re-applying the same rule/default is a no-op).
	pkg_install ufw
	ufw default deny incoming  >/dev/null 2>&1 || warn "ufw default deny incoming failed"
	ufw default allow outgoing >/dev/null 2>&1 || warn "ufw default allow outgoing failed"
	ufw allow 5353/udp         >/dev/null 2>&1 || warn "ufw allow 5353/udp failed"
	# `ufw enable` flips the boot-time service on, but it cannot start netfilter
	# inside the chroot — only run it on a live system. enable_service ufw.service
	# restores the rules on every boot regardless. Both are idempotent.
	if ! in_chroot; then
		ufw --force enable >/dev/null 2>&1 || warn "ufw enable failed"
	fi
	enable_service ufw.service

	ok "services, mDNS & firewall configured"
}
