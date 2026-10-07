platform_check_image() {
	local board=$(board_name)

	case "$board" in
	tplink,archer-c5v)
		# UBI sysupgrade image (sysupgrade-tar); validation is handled by
		# the firmware metadata check and nand_do_upgrade.
		return 0
		;;
	chinamobile,gs3101)
		return 0
		;;
	esac

	return 1
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	tplink,archer-c5v)
		# UBI layout: raw kernel slot + UBI rootfs. nand_do_upgrade writes
		# the kernel (CI_KERNPART, with the TP-Link v2 header so the vendor
		# bootloader can still decompress it) and updates the UBI volumes.
		CI_KERNPART="kernel"
		nand_do_upgrade "$1"
		;;
	chinamobile,gs3101)
		CI_KERNPART="tclinux_kernel"
		nand_do_upgrade "$1"
		;;
	esac
}
