#!/bin/bash

set -e
clear

username="your_username_here"
hostname="archlinux"
display_server="Wayland"
mirrors_country="Sweden"
timezone="Europe/Stockholm"
keymap="sv-latin1"
keylayout="se"
locale="sv_SE.UTF-8"
terminal="kitty"
pkgs_extra=("$terminal" git vim)

main() {
	unmount_cryptroot
	disk_target
	password_select
	display_server
	firmware_detect
	cpu_detect
	partition_disk
	filesystem_setup
	pacman_mirrors
	basesystem_install
	bootloader_config
	password_set
	localization_config
	home_dir_setup
	fstab_generate
	mkinitcpio_generate
	snapper_config
	mirrors_config
	boot_backup_hook
	zram_config
	dns_config
	services_enable

	print "Done, you may now wish to reboot."
}

# Pretty print function.
print() {
	echo -e "\e[1m\e[93m[ \e[92m•\e[93m ] \e[4m$1\e[0m"
}

# If re-running script.
unmount_cryptroot() {
	if mount | grep -q /mnt; then
		print "Unmounting subvolumes and closing cryptroot."
		umount -R /mnt
		cryptsetup close cryptroot
	fi
}

disk_target() {
	disks=$(lsblk -dpnoNAME,SIZE | grep -P "/dev/sd|nvme|vd")

	echo "Available disks:"
	echo "$disks"
	echo ""

	PS3="Select the disk where Arch Linux is going to be installed: "
	select disk in $(awk '{print $1}' <<< "$disks"); do
		print "Installing Arch Linux on $disk."
		break
	done
}

password_select() {
	read -rsp "Insert password for encryption, root, and user: " password
	echo ""
	read -rsp "Confirm password: " password_confirm

	if [ -z "$password" ]; then
		print "You need to enter a password."
		password_select
	elif [ "$password" != "$password_confirm" ]; then
		print "Passwords do not match, please try again."
		password_select
	fi
}

display_server() {
	printf "\n"
	print "Targetting $display_server."

	if [ $display_server = "Xorg" ]; then
		pkgs_extra+=(i3-wm lightdm lightdm-gtk-greeter xorg-server xorg-xrdb)
		keymap="$keymap"
	elif [ $display_server = "Wayland" ]; then
		pkgs_extra+=(sway swayidle wayland)
	fi
}

firmware_detect() {
	if [ -d /sys/firmware/efi ]; then
		firmware_type="UEFI"
	else
		firmware_type="BIOS"
		pkgs_extra+=(grub)
	fi

	print "A $firmware_type system has been detected."
}

cpu_detect() {
	cpu=$(grep vendor_id /proc/cpuinfo)
	if [[ $cpu == *"AuthenticAMD"* ]]; then
		cpu_type="AMD"
		microcode="amd-ucode"
		video_drivers=(libva-mesa-driver xf86-video-amdgpu)
	else
		cpu_type="Intel"
		microcode="intel-ucode"
		video_drivers=(intel-media-driver libva-intel-driver xf86-video-intel)
	fi

	print "An $cpu_type CPU has been detected."
}

partition_disk() {
	print "Wiping $disk."

	wipefs -af "$disk" &> /dev/null
	sgdisk -Zo "$disk" &> /dev/null

	print "Creating the partitions on $disk."

	if [ $firmware_type = "UEFI" ]; then
		parted -s "$disk" \
			mklabel gpt \
			mkpart ESP fat32 1MiB 201MiB \
			set 1 esp on \
			mkpart root 201MiB 100%
	elif [ $firmware_type = "BIOS" ]; then
		parted -s "$disk" \
			mklabel msdos \
			mkpart primary ext4 1MiB 513MiB \
			set 1 boot on \
			mkpart primary btrfs 513MiB 100%
	fi

	partprobe "$disk"

	print "Formatting boot partition."

	if grep -q "^/dev/[a-z]d[a-z]" <<< "$disk"; then
		boot_partition="${disk}1"
		root_partition="${disk}2"
	elif grep -q "^/dev/nvme" <<< "$disk"; then
		boot_partition="${disk}p1"
		root_partition="${disk}p2"
	fi

	if [ $firmware_type = "UEFI" ]; then
		mkfs.fat -F 32 "$boot_partition" &> /dev/null
	elif [ $firmware_type = "BIOS" ]; then
		mkfs.ext4 -L boot "$boot_partition" &> /dev/null
	fi
}

filesystem_setup() {
	print "Creating LUKS container for the root partition."

	echo -n "$password" | cryptsetup luksFormat "$root_partition" -d -
	echo -n "$password" | cryptsetup open "$root_partition" cryptroot -d -
	cryptroot="/dev/mapper/cryptroot"

	print "Formatting the LUKS container as BTRFS."
	mkfs.btrfs $cryptroot &> /dev/null
	mount $cryptroot /mnt

	print "Creating BTRFS subvolumes."
	for volume in @ @home @hcache @root @vlog @vcache; do
		btrfs su cr /mnt/$volume &> /dev/null
	done

	mkdir /mnt/@root/live
	mkdir /mnt/@home/live
	btrfs su cr /mnt/@root/live/snapshot &> /dev/null
	btrfs su cr /mnt/@home/live/snapshot &> /dev/null

	print "Mounting the newly created subvolumes."
	umount /mnt

	btrfs_opts="noatime,compress-force=zstd:3,discard=async"

	mount -o $btrfs_opts,subvol=@root/live/snapshot $cryptroot /mnt
	mkdir -p /mnt/{boot,home,var/log,var/cache,.snapshots}

	mount -o $btrfs_opts,subvol=@root $cryptroot /mnt/.snapshots
	mount -o $btrfs_opts,subvol=@vlog $cryptroot /mnt/var/log
	mount -o $btrfs_opts,subvol=@vcache $cryptroot /mnt/var/cache
	mount -o $btrfs_opts,subvol=@home/live/snapshot $cryptroot /mnt/home

	mkdir -p /mnt/home/{.snapshots,$username,$username/.cache}
	mount -o $btrfs_opts,subvol=@home $cryptroot /mnt/home/.snapshots
	mount -o $btrfs_opts,subvol=@hcache $cryptroot /mnt/home/$username/.cache

	chattr +C /mnt/var/log
	chattr +C /mnt/var/cache
	chattr +C /mnt/home/$username/.cache

	mount "$boot_partition" /mnt/boot/
}

pacman_mirrors() {
	print "Updating pacman mirrors."

	reflector --country $mirrors_country \
		--latest 25 \
		--age 24 \
		--protocol https \
		--completion-percent 100 \
		--sort rate \
		--save /etc/pacman.d/mirrorlist
}

basesystem_install() {
	print "Installing base system with $display_server packages."

	timedatectl set-ntp 1 &> /dev/null

	sed -i 's/#Color/Color/' /etc/pacman.conf
	sed -i 's/#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

	pacman -Sy archlinux-keyring --noconfirm
	yes '' | pacstrap /mnt base base-devel btrfs-progs linux linux-firmware networkmanager dnsmasq reflector rsync snapper zram-generator $microcode "${video_drivers[@]}" "${pkgs_extra[@]}"

	print "Setting hosts file."
	cat > /mnt/etc/hosts <<- EOF
		127.0.0.1   localhost
		::1         localhost
		127.0.1.1   $hostname.localdomain   $hostname
	EOF
}

bootloader_config() {
	computer_model=$(cat /sys/devices/virtual/dmi/id/product_version)
	uuid=$(blkid -s UUID -o value "$root_partition")
	kernel_params="rd.luks.name=$uuid=cryptroot root=$cryptroot rootflags=subvol=@root/live/snapshot rd.systemd.show_status=auto rd.udev.log_level=3 quiet rw"

	if [[ "$computer_model" = "ThinkPad"* ]]; then
		kernel_params+=" psmouse.synaptics_intertouch=1"
	fi

	if [[ "$cpu_type" = "AMD" ]]; then
		kernel_params+=" amd_pstate=active"
	fi

	if [ $firmware_type = "UEFI" ]; then
		print "Configuring systemd-boot."

		arch-chroot /mnt bootctl install &> /dev/null
		cat > /mnt/boot/loader/loader.conf <<- EOF
			default arch
			timeout 0
			editor no
		EOF

		cat > /mnt/boot/loader/entries/arch.conf <<- EOF
			title Arch Linux
			linux /vmlinuz-linux
			initrd /$microcode.img
			initrd /initramfs-linux.img
			options $kernel_params
		EOF
	elif [ $firmware_type = "BIOS" ]; then
		print "Configuring GRUB."

		sed -i "s,^GRUB_CMDLINE_LINUX=\"\",GRUB_CMDLINE_LINUX=\"$kernel_params\",g" /mnt/etc/default/grub
		arch-chroot /mnt grub-install --target=i386-pc "$disk" &> /dev/null
		arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg &> /dev/null
	fi
}

password_set() {
	print "Setting root password."
	echo "root:$password" | arch-chroot /mnt chpasswd

	print "Adding the user $username to the system with root privilege."
	arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$username" &> /dev/null
	sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers

	print "Setting user password for $username."
	echo "$username:$password" | arch-chroot /mnt chpasswd
}

localization_config() {
	print "Configuring localization settings."

	ln -sf /mnt/usr/share/zoneinfo/"$timezone" /mnt/etc/localtime &> /dev/null
	arch-chroot /mnt hwclock --systohc

	echo "KEYMAP=$keymap" > /mnt/etc/vconsole.conf
	echo "$locale UTF-8" > /mnt/etc/locale.gen
	echo "LANG=$locale" > /mnt/etc/locale.conf

	arch-chroot /mnt locale-gen &> /dev/null

	if [ $display_server = "Xorg" ]; then
		mkdir -p /mnt/etc/X11/xorg.conf.d/
		cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<- EOF
			Section "InputClass"
				Identifier "system-keyboard"
				MatchIsKeyboard "on"
				Option "XkbLayout" "$keylayout"
			EndSection
		EOF
	elif [ $display_server = "Wayland" ]; then
		mkdir -p /mnt/home/$username/{.config,.config/sway}
		sway_conf=/mnt/home/$username/.config/sway/config
		cp /mnt/etc/sway/config $sway_conf

		if [ "$terminal" = "kitty" ]; then
			sway_terminal="$terminal --single-instance"
		else
			sway_terminal="$terminal"
		fi

		sed -i "s/set \$term.*/set \$term \"$sway_terminal\"/g" $sway_conf
		cat >> $sway_conf <<- EOF
			input "type:keyboard" {
				xkb_layout $keylayout
			}
		EOF
	fi
}

home_dir_setup() {
	print "Setting up home directory."

	mkdir -p /mnt/home/$username/.local/vm
	chattr +C /mnt/home/$username/.local/vm
	arch-chroot /mnt chown -R $username:$username /home/$username
}

fstab_generate() {
	print "Generating a new fstab."
	genfstab -U /mnt | sed -e 's/suvolid=[0-9]*,//g' >> /mnt/etc/fstab
}

mkinitcpio_generate() {
	print "Configuring /etc/mkinitcpio.conf."
	cat > /mnt/etc/mkinitcpio.conf <<- EOF
		HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)
		COMPRESSION=(zstd)
	EOF

	print "Generating a new initramfs."
	arch-chroot /mnt mkinitcpio -P &> /dev/null
}

snapper_config() {
	print "Configuring snapper."

	cat > /mnt/etc/snapper/configs/root <<- EOF
		SUBVOLUME="/"
		FSTYPE="btrfs"
		QGROUP=""
		SPACE_LIMIT="0.5"
		FREE_LIMIT="0.2"
		ALLOW_USERS=""
		ALLOW_GROUPS="wheel"
		SYNC_ACL="no"
		BACKGROUND_COMPARISON="yes"
		NUMBER_CLEANUP="yes"
		NUMBER_MIN_AGE="1800"
		NUMBER_LIMIT="6"
		NUMBER_LIMIT_IMPORTANT="3"
		TIMELINE_CREATE="yes"
		TIMELINE_CLEANUP="yes"
		TIMELINE_MIN_AGE="1800"
		TIMELINE_LIMIT_HOURLY="2"
		TIMELINE_LIMIT_DAILY="2"
		TIMELINE_LIMIT_WEEKLY="2"
		TIMELINE_LIMIT_MONTHLY="2"
		TIMELINE_LIMIT_YEARLY="0"
		EMPTY_PRE_POST_CLEANUP="yes"
		EMPTY_PRE_POST_MIN_AGE="1800"
	EOF

	cp /mnt/etc/snapper/configs/root /mnt/etc/snapper/configs/home
	sed -i "1s/.*/SUBVOLUME=\"\/home\"/" /mnt/etc/snapper/configs/home
	echo "SNAPPER_CONFIGS=\"root home\"" > /mnt/etc/conf.d/snapper

	cp /mnt/usr/lib/systemd/system/snapper-cleanup.timer /mnt/etc/systemd/system/snapper-cleanup.timer
	sed -i "s/OnBootSec=.*/OnCalendar=hourly/" /mnt/etc/systemd/system/snapper-cleanup.timer
	sed -i "s/OnUnitActiveSec=.*/Persistent=true/" /mnt/etc/systemd/system/snapper-cleanup.timer
}

mirrors_config() {
	print "Configuring reflector."

	cat > /mnt/etc/xdg/reflector/reflector.conf <<- EOF
		--country $mirrors_country
		--latest 25
		--age 24
		--protocol https
		--completion-percent 100
		--sort rate
		--save /etc/pacman.d/mirrorlist
	EOF
}

boot_backup_hook() {
	print "Configuring /boot backup on kernel upgrades."

	mkdir -p /mnt/etc/pacman.d/hooks
	cat > /mnt/etc/pacman.d/hooks/boot-backup.hook <<- EOF
		[Trigger]
		Operation = Upgrade
		Operation = Install
		Operation = Remove
		Type = Path
		Target = usr/lib/modules/*/vmlinuz

		[Action]
		Depends = rsync
		Description = Backing up /boot...
		When = PreTransaction
		Exec = /usr/bin/rsync -a --delete /boot /.bootbackup
	EOF
}

zram_config() {
	print "Configuring ZRAM."

	cat > /mnt/etc/systemd/zram-generator.conf <<- EOF
		[zram0]
		zram-fraction = 1
		max-zram-size = 4096
	EOF
}

dns_config() {
	print "Configuring dns"

	mkdir -p /mnt/etc/NetworkManager/conf.d
	mkdir -p /mnt/etc/NetworkManager/dnsmasq.d

	cat > /mnt/etc/NetworkManager/conf.d/dns.conf <<- EOF
		[main]
		dns=dnsmasq
	EOF

	# Example: direct "*.nomad" domains to 192.168.1.160
	# cat > /mnt/etc/NetworkManager/dnsmasq.d/hosts.conf <<- EOF
	# 	address=/nomad/192.168.1.160
	# EOF
}

services_enable() {
	print "Enabling services."

	services="archlinux-keyring-wkd-sync.timer btrfs-scrub@-.timer dnsmasq.service NetworkManager.service reflector.timer snapper-cleanup.timer snapper-timeline.timer systemd-oomd systemd-timesyncd"

	if [ $display_server = "Xorg" ]; then
		services+=" lightdm.service"
	elif [ $display_server = "Wayland" ]; then
		services+=" systemd-boot-update.service"
	fi

	for service in $services; do
		systemctl enable "$service" --root=/mnt &> /dev/null
	done
}

if [ $# = 0 ]; then
	main
else
	"$@"
fi
