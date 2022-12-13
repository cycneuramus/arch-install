## Overview

A *very* opinionated `bash` script for installing Arch Linux, designed to be non-interactive.

### Features

+ `BTRFS` with automatic snapshots + cleanup
+ Disk encryption using `LUKS2`
+ Auto-detects and configures UEFI + `systemd-boot` or BIOS + `GRUB`
+ Auto-detects CPU (Intel or AMD) and installs appropriate microcode + drivers
+ Automatic `/boot` backup on kernel upgrades
+ Installs Wayland + `sway` (default) or Xorg + `i3`
+ [zram](https://wiki.archlinux.org/title/improving_performance#zram_or_zswap)
+ [systemd-oomd](https://man.archlinux.org/man/systemd-oomd.service.8.en)

### Usage notes

Make sure to define the variables (username, hostname, *etc.*) at the top of the script to your liking.
