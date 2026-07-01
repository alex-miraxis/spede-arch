# shellcheck shell=bash
# lib/05-snapper.sh — Phase B step: snapper root config + grub-btrfs timers.
#
# Spec §5/§9: create the snapper root config, then perform the standard
# "delete snapper's auto-created nested /.snapshots subvolume and mount the
# SEPARATE @snapshots subvolume there instead" dance — otherwise a rollback
# of @ would destroy all snapshots (the nested subvol lives inside @).
# snap-pac (the pacman pre/post hook) is already installed via pacstrap.
# Enable snapper-timeline.timer, snapper-cleanup.timer, grub-btrfs.path.
#
# Runs inside the chroot where the target's @snapshots subvolume is already
# mounted at /.snapshots (per the fstab written by step_disk). Idempotent:
# skips create-config when the root config already exists, and is safe to
# re-run on the booted system.

step_snapper() {
	info "snapper: configuring root snapshot config"

	need_cmd snapper
	need_cmd btrfs
	need_cmd findmnt

	# -----------------------------------------------------------------------
	# 1. Create the root config — but ONLY if it does not already exist.
	#    `snapper -c root create-config /` auto-creates a NESTED subvolume at
	#    /.snapshots (inside @). We immediately undo that below so the
	#    separate top-level @snapshots subvolume can be mounted there instead.
	#
	#    NOTE: every snapper call uses --no-dbus. Modern snapper talks to the
	#    snapperd daemon over the system D-Bus by default; inside arch-chroot
	#    there is no running system bus, so a plain `snapper` invocation aborts
	#    with "Failure (org.freedesktop.DBus.Error.ServiceUnknown)". --no-dbus
	#    makes snapper operate directly (root-only, which we always are), and it
	#    is equally correct on the booted system, so we use it unconditionally.
	# -----------------------------------------------------------------------
	if snapper --no-dbus list-configs 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx 'root'; then
		ok "snapper: root config already exists, skipping create-config"
	else
		# The separate @snapshots subvolume is mounted at /.snapshots by the
		# fstab. snapper's create-config refuses to run if /.snapshots is a
		# mountpoint, so unmount it first, let snapper create its nested
		# subvol, delete that, then remount the real @snapshots.
		local snapshots_mounted=0
		if findmnt -no TARGET /.snapshots >/dev/null 2>&1; then
			snapshots_mounted=1
			info "snapper: temporarily unmounting /.snapshots"
			umount /.snapshots || die "snapper: could not unmount /.snapshots (busy?)"
		fi

		# create-config runs `btrfs subvolume create /.snapshots` and FAILS with
		# "already exists" if the path is present. Unmounting alone leaves the
		# empty mountpoint directory behind, so remove it first (guarded so we
		# never touch a still-live mount).
		if [[ -e /.snapshots ]] && ! findmnt /.snapshots >/dev/null 2>&1; then
			rmdir /.snapshots 2>/dev/null || rm -rf /.snapshots
		fi

		info "snapper: snapper --no-dbus -c root create-config /"
		snapper --no-dbus -c root create-config /

		# Delete the nested .snapshots subvolume snapper just created inside @.
		if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
			info "snapper: deleting snapper's nested /.snapshots subvolume"
			btrfs subvolume delete /.snapshots
		fi

		# Recreate the mountpoint so the SEPARATE @snapshots subvol can be
		# remounted by the unconditional mount-assertion below. We intentionally
		# do NOT remount here: if create-config is interrupted between deleting
		# the nested subvol and remounting, a re-run still self-heals because
		# the mount assertion in step 2 always runs.
		mkdir -p /.snapshots
		if [[ "$snapshots_mounted" != "1" ]]; then
			warn "snapper: /.snapshots was not mounted before create-config; relying on fstab to mount @snapshots"
		fi
	fi

	# -----------------------------------------------------------------------
	# 2. Ensure the SEPARATE @snapshots subvolume is mounted at /.snapshots,
	#    on EVERY run. This self-heals an interrupted create-config (nested
	#    subvol deleted but not yet remounted) and guarantees the chmod below
	#    operates on the real @snapshots, not the bare @ directory.
	# -----------------------------------------------------------------------
	mkdir -p /.snapshots
	if findmnt /.snapshots >/dev/null 2>&1; then
		ok "snapper: @snapshots already mounted at /.snapshots"
	else
		info "snapper: mounting @snapshots at /.snapshots"
		# Prefer fstab (mount by target); fall back to mounting the @snapshots
		# subvolume explicitly off the root device.
		if mount /.snapshots 2>/dev/null; then
			ok "snapper: mounted /.snapshots via fstab"
		else
			local root_src
			root_src="$(findmnt -no SOURCE / 2>/dev/null)"
			# Strip any existing [/subvol] suffix from the root source.
			root_src="${root_src%%[*}"
			if [[ -n "$root_src" ]] && mount -o subvol=@snapshots "$root_src" /.snapshots; then
				ok "snapper: mounted @snapshots subvolume explicitly at /.snapshots"
			else
				warn "snapper: could not mount @snapshots at /.snapshots; snapshots may be stored inside @"
			fi
		fi
	fi

	# -----------------------------------------------------------------------
	# 3. Lock down /.snapshots ownership + permissions (spec §5: chmod 750).
	# -----------------------------------------------------------------------
	if [[ -d /.snapshots ]]; then
		chown root:root /.snapshots
		chmod 750 /.snapshots
	fi

	# -----------------------------------------------------------------------
	# 4. Verify the @snapshots subvolume is present (spec risk #3 guard).
	# -----------------------------------------------------------------------
	info "snapper: verifying btrfs subvolume layout"
	if btrfs subvolume list / 2>/dev/null | grep -q '@snapshots'; then
		ok "snapper: @snapshots is a separate top-level subvolume"
	else
		warn "snapper: @snapshots not found in 'btrfs subvolume list /' — rollbacks may destroy snapshots"
	fi

	# -----------------------------------------------------------------------
	# 5. Enable the snapshot timers + grub-btrfs path unit.
	#    snap-pac is already installed (pacstrap) and needs no enabling — it
	#    is a pacman libalpm hook, not a service.
	# -----------------------------------------------------------------------
	enable_service snapper-timeline.timer
	enable_service snapper-cleanup.timer
	enable_service grub-btrfs.path

	ok "snapper: configured (timeline + cleanup timers, grub-btrfs.path enabled)"
}
