# shellcheck shell=bash
# lib/01-disk.sh — Phase A, step_disk.
#
# Partition, encrypt, format, and mount the target disk per spec §5.
#
#   - GPT: FAT32 ESP (~1 GiB, the only plaintext partition) + one LUKS2
#     partition holding everything else. /boot lives INSIDE the encrypted
#     Btrfs root (single passphrase + snapshottable /boot).
#   - LUKS2 with the GRUB-safe slot:
#       cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
#         --pbkdf-force-iterations 1000000 --hash sha256
#     PBKDF2/sha256 is the deterministic, GRUB-readable choice. NEVER LUKS1,
#     never default Argon2id (GRUB's 4 GiB EFI heap cap breaks first boot).
#   - Btrfs top-level subvolumes: @ @home @snapshots @var_log @var_cache
#     @var_tmp. @snapshots is a SEPARATE subvolume mounted at /.snapshots
#     (NOT nested in @, or a rollback wipes all snapshots).
#   - All mounts use noatime,compress=zstd,subvol=...; ESP at NEWROOT/efi.
#   - A binary crypto_keyfile is generated and luksAddKey'd as an extra
#     keyslot so the kernel stage unlocks without a second prompt.
#   - The LUKS UUID is captured with blkid for the summary; step_boot
#     re-derives it independently via blkid (no cross-step UUID channel).
#
# Contract: defines exactly step_disk(); no shebang/set/IFS (common.sh owns
# them); pure definition, no side effects at source time; uses only common.sh
# helpers/globals. Phase A is one-shot: stale mappings/mounts are torn down for
# a clean retry, but wipefs/sgdisk/mkfs are destructive and re-running this step
# re-erases the target disk — it is NOT idempotent over real data.

step_disk() {
	need_cmd sgdisk
	need_cmd cryptsetup
	need_cmd mkfs.btrfs
	need_cmd mkfs.fat
	need_cmd blkid
	need_cmd btrfs
	need_cmd partprobe
	need_cmd wipefs

	[[ -n "${TARGET_DISK:-}" ]] || die "step_disk: TARGET_DISK is unset (run step_preflight first)."
	[[ -b "$TARGET_DISK" ]]     || die "step_disk: $TARGET_DISK is not a block device."

	# nvme/mmc disks suffix partitions with 'p' (nvme0n1p1); sata/virtio do not
	# (sda1). Detect by trailing digit on the base device name.
	local esp_part luks_part suffix=""
	if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
		suffix="p"
	fi
	esp_part="${TARGET_DISK}${suffix}1"
	luks_part="${TARGET_DISK}${suffix}2"

	info "Target disk: $TARGET_DISK"
	info "  ESP  partition -> $esp_part"
	info "  LUKS partition -> $luks_part"
	log  "${_C_RED}This ERASES all data on $TARGET_DISK.${_C_RESET}"
	confirm "Partition and wipe $TARGET_DISK now?" \
		|| die "step_disk: aborted by user."

	# --- Tear down any stale mapping/mounts from a previous run --------------
	if mountpoint -q "$NEWROOT"; then
		info "unmounting stale tree at $NEWROOT"
		umount -R "$NEWROOT" 2>/dev/null || true
	fi
	if [[ -e /dev/mapper/cryptroot ]]; then
		info "closing stale /dev/mapper/cryptroot"
		cryptsetup close cryptroot 2>/dev/null || true
	fi

	# --- Partition (GPT) ----------------------------------------------------
	info "wiping existing signatures and partition table on $TARGET_DISK"
	wipefs -a -- "$TARGET_DISK"
	sgdisk --zap-all -- "$TARGET_DISK"

	info "creating GPT layout (ESP ~1 GiB + LUKS)"
	sgdisk \
		--new=1:0:+1GiB --typecode=1:ef00 --change-name=1:EFI \
		--new=2:0:0     --typecode=2:8309 --change-name=2:cryptsystem \
		-- "$TARGET_DISK"

	partprobe "$TARGET_DISK" 2>/dev/null || true
	# Give udev a moment to materialize the new partition nodes.
	udevadm settle 2>/dev/null || true

	[[ -b "$esp_part"  ]] || die "step_disk: expected ESP partition $esp_part did not appear."
	[[ -b "$luks_part" ]] || die "step_disk: expected LUKS partition $luks_part did not appear."

	# --- ESP (FAT32) --------------------------------------------------------
	info "formatting ESP $esp_part as FAT32"
	mkfs.fat -F32 -n EFI "$esp_part"

	# --- LUKS2 (GRUB-safe PBKDF2 slot) --------------------------------------
	info "luksFormat $luks_part (LUKS2, pbkdf2/sha256, 1,000,000 iters)"
	log  "${_C_YEL}You will set the disk passphrase now, then confirm it once.${_C_RESET}"
	cryptsetup luksFormat \
		--type luks2 \
		--pbkdf pbkdf2 \
		--pbkdf-force-iterations 1000000 \
		--hash sha256 \
		--batch-mode --verify-passphrase \
		"$luks_part"

	info "opening $luks_part as /dev/mapper/cryptroot"
	log  "${_C_YEL}Enter the passphrase you just set, to open the container.${_C_RESET}"
	cryptsetup open "$luks_part" cryptroot

	# --- Btrfs filesystem + subvolumes --------------------------------------
	info "creating Btrfs filesystem on /dev/mapper/cryptroot"
	mkfs.btrfs -f -L spede /dev/mapper/cryptroot

	info "creating top-level subvolumes"
	mount /dev/mapper/cryptroot "$NEWROOT"
	local sv
	for sv in @ @home @snapshots @var_log @var_cache @var_tmp; do
		if btrfs subvolume show "$NEWROOT/$sv" >/dev/null 2>&1; then
			info "subvolume $sv already exists"
		else
			btrfs subvolume create "$NEWROOT/$sv"
		fi
	done
	umount "$NEWROOT"

	# --- Mount the tree -----------------------------------------------------
	local mopt="noatime,compress=zstd"
	info "mounting @ at $NEWROOT"
	mount -o "${mopt},subvol=@" /dev/mapper/cryptroot "$NEWROOT"

	mkdir -p "$NEWROOT/home" "$NEWROOT/.snapshots" \
		"$NEWROOT/var/log" "$NEWROOT/var/cache" "$NEWROOT/var/tmp" \
		"$NEWROOT/efi"

	info "mounting @home -> /home"
	mount -o "${mopt},subvol=@home"      /dev/mapper/cryptroot "$NEWROOT/home"
	info "mounting @snapshots -> /.snapshots"
	mount -o "${mopt},subvol=@snapshots" /dev/mapper/cryptroot "$NEWROOT/.snapshots"
	info "mounting @var_log -> /var/log"
	mount -o "${mopt},subvol=@var_log"   /dev/mapper/cryptroot "$NEWROOT/var/log"
	info "mounting @var_cache -> /var/cache"
	mount -o "${mopt},subvol=@var_cache" /dev/mapper/cryptroot "$NEWROOT/var/cache"
	info "mounting @var_tmp -> /var/tmp"
	mount -o "${mopt},subvol=@var_tmp"   /dev/mapper/cryptroot "$NEWROOT/var/tmp"
	chmod 1777 "$NEWROOT/var/tmp"

	info "mounting ESP $esp_part -> $NEWROOT/efi"
	mount "$esp_part" "$NEWROOT/efi"

	# --- Binary crypto keyfile (extra LUKS keyslot) -------------------------
	# Embedded in the initramfs (FILES=) so the kernel stage unlocks without a
	# second prompt; safe because /boot + initramfs live inside the container.
	# /crypto_keyfile.bin lives inside the encrypted root and must NEVER be
	# committed to the repo or copied outside the target tree.
	local keyfile_target="${NEWROOT}${KEYFILE}"
	info "generating binary crypto keyfile at $KEYFILE (inside the new root)"
	if [[ -f "$keyfile_target" ]]; then
		info "keyfile already present, reusing"
		# Defense-in-depth: lock down even a pre-existing keyfile.
		chmod 0000 "$keyfile_target"
	else
		dd if=/dev/urandom of="$keyfile_target" bs=512 count=8 status=none
	fi
	chmod 0000 "$keyfile_target"

	# Add the keyfile as an extra keyslot only if it is not already a valid key.
	if cryptsetup open --test-passphrase --type luks2 --key-file "$keyfile_target" \
		"$luks_part" >/dev/null 2>&1; then
		info "crypto keyfile is already a valid LUKS keyslot"
	else
		info "adding crypto keyfile as an extra LUKS keyslot"
		log  "${_C_YEL}Confirm the disk passphrase once more to register the keyfile.${_C_RESET}"
		cryptsetup luksAddKey "$luks_part" "$keyfile_target"
	fi

	# --- Capture the LUKS UUID for the summary line -------------------------
	# step_boot re-derives the UUID itself via blkid across the chroot boundary,
	# so there is no need to persist it here; this is only for the ok() summary.
	local luks_uuid
	luks_uuid=$(blkid -s UUID -o value "$luks_part") \
		|| die "step_disk: blkid failed to read UUID of $luks_part."
	[[ -n "$luks_uuid" ]] || die "step_disk: empty LUKS UUID for $luks_part."

	save_config

	ok "disk ready: ESP=$esp_part LUKS=$luks_part UUID=$luks_uuid"
	ok "mounted root tree at $NEWROOT (efi at $NEWROOT/efi)"
}
