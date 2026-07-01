# shellcheck shell=bash
# lib/04-boot.sh — step_boot
#
# Phase B, boot architecture (spec §5). Configures the initramfs and GRUB for
# an encrypted-root, single-passphrase, snapshot-capable boot:
#
#   * /etc/mkinitcpio.conf — udev/encrypt style hooks (NOT systemd, because
#     grub-btrfs-overlayfs is incompatible with the systemd hook). amdgpu in
#     MODULES, the binary keyfile in FILES, `encrypt` before `filesystems`,
#     and `grub-btrfs-overlayfs` LAST (or snapshot boots are read-only).
#   * /etc/default/grub — GRUB_ENABLE_CRYPTODISK=y, a cryptdevice/cryptkey
#     kernel cmdline keyed on the LUKS container UUID, and the cryptodisk
#     preload modules.
#   * grub-install (x86_64-efi -> /efi) + grub-mkconfig.
#
# Idempotent: it rewrites the two config files to a known-good state every
# run, re-derives the LUKS UUID from the target disk, and re-runs
# mkinitcpio/grub-install/grub-mkconfig (all safe to repeat).

step_boot() {
	info "boot: configuring mkinitcpio (udev/encrypt + overlayfs) and GRUB (cryptodisk)"

	need_cmd mkinitcpio
	need_cmd grub-install
	need_cmd grub-mkconfig
	need_cmd blkid

	# --- Resolve the LUKS container UUID -----------------------------------
	# The keyfile/cryptdevice cmdline references the LUKS *container* by UUID.
	# We re-derive it from the target disk each run so step_boot stays
	# re-runnable on the booted system (where no UUID is otherwise in scope).
	local luks_uuid=""
	if [[ -n "${TARGET_DISK:-}" ]]; then
		local part
		# The LUKS2 partition is partition 2 (partition 1 is the FAT32 ESP).
		# nvme/mmc style devices need a 'p' separator before the partition no.
		if [[ "$TARGET_DISK" == *[0-9] ]]; then
			part="${TARGET_DISK}p2"
		else
			part="${TARGET_DISK}2"
		fi
		if [[ -b "$part" ]]; then
			luks_uuid=$(blkid -s UUID -o value "$part" 2>/dev/null) || luks_uuid=""
		fi
	fi
	# Fallback: find the sole LUKS partition on the system.
	if [[ -z "$luks_uuid" ]]; then
		luks_uuid=$(blkid -t TYPE=crypto_LUKS -s UUID -o value 2>/dev/null | head -n1) || luks_uuid=""
	fi
	[[ -n "$luks_uuid" ]] || die "boot: could not determine the LUKS container UUID (TARGET_DISK=${TARGET_DISK:-unset})"
	info "boot: LUKS container UUID = ${luks_uuid}"

	# --- /etc/mkinitcpio.conf ----------------------------------------------
	# udev/encrypt hook layout. encrypt BEFORE filesystems; grub-btrfs-overlayfs
	# LAST. amdgpu in MODULES; the binary keyfile in FILES so it is embedded in
	# the initramfs and referenced via cryptkey=rootfs:/crypto_keyfile.bin.
	backup_file /etc/mkinitcpio.conf
	cat >/etc/mkinitcpio.conf <<EOF
# Managed by spede-arch (lib/04-boot.sh) — spec §5.
# udev/encrypt initramfs (NOT systemd: grub-btrfs-overlayfs is incompatible
# with the systemd hook). encrypt BEFORE filesystems; overlayfs hook LAST.
MODULES=(amdgpu)
BINARIES=()
FILES=(${KEYFILE})
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck grub-btrfs-overlayfs)
EOF

	info "boot: regenerating all initramfs images (mkinitcpio -P)"
	mkinitcpio -P

	# --- /etc/default/grub --------------------------------------------------
	# GRUB must unlock the LUKS2 container itself (cryptodisk). The kernel then
	# uses the embedded keyfile to avoid a second passphrase prompt. The
	# preload modules cover GPT + LUKS2/PBKDF2 + btrfs so the early GRUB core
	# can read the encrypted /boot.
	backup_file /etc/default/grub
	cat >/etc/default/grub <<EOF
# Managed by spede-arch (lib/04-boot.sh) — spec §5.
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
GRUB_CMDLINE_LINUX="cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ cryptkey=rootfs:${KEYFILE}"
GRUB_PRELOAD_MODULES="part_gpt cryptodisk luks2 gcry_sha256 gcry_pbkdf2 btrfs"
GRUB_ENABLE_CRYPTODISK=y
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=true
EOF

	# --- Install GRUB to the ESP and generate its config -------------------
	info "boot: installing GRUB (x86_64-efi -> /efi)"
	grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --recheck

	# Removable-media fallback: also write EFI/BOOT/BOOTX64.EFI so the machine
	# boots even if the firmware ignores/loses the GRUB NVRAM boot entry.
	info "boot: installing GRUB removable-media fallback (EFI/BOOT/BOOTX64.EFI)"
	grub-install --target=x86_64-efi --efi-directory=/efi --removable --recheck

	# Verify a UEFI boot entry was created; efivars may be unavailable in chroot.
	efibootmgr | grep -q GRUB || warn "no GRUB UEFI boot entry — efivars may not be mounted in chroot; re-run grub-install after boot"

	info "boot: generating /boot/grub/grub.cfg"
	grub-mkconfig -o /boot/grub/grub.cfg

	ok "boot: mkinitcpio + GRUB (cryptodisk + keyfile) configured"
}
