#!/bin/sh
# One-command OpenWrt install for this fork.
#
#   uclient-fetch -O /tmp/install_openwrt.sh https://raw.githubusercontent.com/Bambyyno/zapret2/cursor/strategy-picker-96e1/install_openwrt.sh && sh /tmp/install_openwrt.sh
#
# Detects apk (OpenWrt 25, including netis N6 / ramips/mt7621) and opkg.
# Copies zapret2 to /opt/zapret2, links /etc/init.d/zapret2, and installs the
# LuCI page under Services. An existing /opt/zapret2/config and the user
# hostlists are left in place. Firewall, dhcp and network UCI are not edited.

FORK_REPO=Bambyyno/zapret2
FORK_REF=cursor/strategy-picker-96e1
BIN_URL=https://github.com/bol-van/zapret2/releases/download/v1.0.6/zapret2-v1.0.6-openwrt-embedded.tar.gz
BIN_PREFIX=zapret2-v1.0.6
DEST=/opt/zapret2

die()
{
	echo "$*" >&2
	exit 1
}

fetch()
{
	url=$1
	out=$2
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -O "$out" "$url" || die "download failed: $url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$out" "$url" || die "download failed: $url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$out" "$url" || die "download failed: $url"
	else
		die "need uclient-fetch, wget or curl"
	fi
}

openwrt_packager()
{
	# Same rule as common/installer.sh: apk only when its database exists.
	if [ -f /etc/openwrt_release ] && { command -v opkg >/dev/null 2>&1 || command -v apk >/dev/null 2>&1; } && command -v uci >/dev/null 2>&1; then
		packager=opkg
		if [ -d /lib/apk/db ] && command -v apk >/dev/null 2>&1; then
			packager=apk
		fi
		printf '%s\n' "$packager"
		return 0
	fi
	return 1
}

pkg_add()
{
	# shellcheck disable=SC2086
	case $1 in
		apk)
			shift
			apk add "$@" </dev/null || die "apk add failed: $*"
			;;
		opkg)
			shift
			opkg update </dev/null || die "opkg update failed"
			opkg install "$@" </dev/null || die "opkg install failed: $*"
			;;
		*)
			die "unknown packager"
			;;
	esac
}

arch_dir()
{
	# shellcheck disable=SC1091
	[ -f /etc/openwrt_release ] && . /etc/openwrt_release
	case ${DISTRIB_ARCH:-} in
		mipsel_*) echo linux-mipsel ;;
		mips64*) echo linux-mips64 ;;
		mips_*) echo linux-mips ;;
		aarch64*) echo linux-arm64 ;;
		arm*) echo linux-arm ;;
		x86_64) echo linux-x86_64 ;;
		i386|i686|x86) echo linux-x86 ;;
		riscv64*) echo linux-riscv64 ;;
		powerpc*|ppc*) echo linux-ppc ;;
		*) die "no nfqws2 build for arch ${DISTRIB_ARCH:-unknown}" ;;
	esac
}

keep_file()
{
	case $1 in
		./config) return 0 ;;
		./ipset/zapret-hosts-user.txt) return 0 ;;
		./ipset/zapret-hosts-user-exclude.txt) return 0 ;;
		./ipset/zapret-hosts-user-ipban.txt) return 0 ;;
		./ipset/zapret-hosts-auto.txt) return 0 ;;
		./ipset/zapret-hosts-user.txt.gz) return 0 ;;
		./ipset/zapret-hosts-user-exclude.txt.gz) return 0 ;;
		./ipset/zapret-hosts-user-ipban.txt.gz) return 0 ;;
	esac
	return 1
}

copy_tree()
{
	src=$1
	dest=$2
	mkdir -p "$dest"
	(
		cd "$src" || exit 1
		find . -path ./.git -prune -o -type d -print | while read -r d; do
			mkdir -p "$dest/$d"
		done
		find . -path ./.git -prune -o -type f -print | while read -r f; do
			if keep_file "$f" && [ -e "$dest/$f" ]; then
				echo "keeping $dest/$f"
				continue
			fi
			cp "$src/$f" "$dest/$f"
		done
	)
}

install_bins()
{
	src=$1
	arch=$2
	if [ -x "$src/binaries/$arch/nfqws2" ]; then
		echo "using binaries already in the tree ($arch)"
		return 0
	fi
	echo "fetching nfqws2 for $arch from bol-van/zapret2 v1.0.6"
	tmp=$(mktemp -d) || die "mktemp"
	fetch "$BIN_URL" "$tmp/bins.tgz"
	mkdir -p "$tmp/ex" "$src/binaries/$arch"
	tar -xzf "$tmp/bins.tgz" -C "$tmp/ex" "$BIN_PREFIX/binaries/$arch" || die "bad binary archive"
	cp "$tmp/ex/$BIN_PREFIX/binaries/$arch/nfqws2" \
		"$tmp/ex/$BIN_PREFIX/binaries/$arch/ip2net" \
		"$tmp/ex/$BIN_PREFIX/binaries/$arch/mdig" \
		"$src/binaries/$arch/" || die "binary copy failed"
	rm -rf "$tmp"
	chmod 755 "$src/binaries/$arch/nfqws2" "$src/binaries/$arch/ip2net" "$src/binaries/$arch/mdig"
}

install_luci()
{
	src=$1
	menu="$src/luci-app-zapret2/root/usr/share/luci/menu.d/luci-app-zapret2.json"
	acl="$src/luci-app-zapret2/root/usr/share/rpcd/acl.d/luci-app-zapret2.json"
	view="$src/luci-app-zapret2/htdocs/luci-static/resources/view/zapret2/picker.js"
	[ -f "$menu" ] && [ -f "$acl" ] && [ -f "$view" ] || die "LuCI files missing in the tree"
	mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view/zapret2
	cp "$menu" /usr/share/luci/menu.d/luci-app-zapret2.json
	cp "$acl" /usr/share/rpcd/acl.d/luci-app-zapret2.json
	cp "$view" /www/luci-static/resources/view/zapret2/picker.js
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd reload >/dev/null 2>&1 || true
	fi
}

main()
{
	[ "$(id -u)" = 0 ] || die "run as root"
	packager=$(openwrt_packager) || die "this installer only runs on OpenWrt (apk or opkg)"
	echo "package manager: $packager"
	arch=$(arch_dir)
	echo "binary arch: $arch"

	# curl is required by the picker. nftables/kmod-nft-queue match fw4 on 25.12.
	# iptables modules are used only when fw4 is absent. luci-base is the menu.
	if [ -x /sbin/fw4 ] || [ -x /usr/sbin/fw4 ]; then
		pkgs="curl nftables kmod-nft-queue kmod-nft-nat luci-base"
	else
		pkgs="curl ipset iptables iptables-mod-nfqueue iptables-mod-conntrack-extra luci-base"
	fi
	# shellcheck disable=SC2086
	pkg_add "$packager" $pkgs

	if [ -n "$ZAPRET_SRC" ] && [ -f "$ZAPRET_SRC/config.default" ]; then
		src=$ZAPRET_SRC
	elif [ -f "$0" ] && [ -f "$(dirname "$0")/config.default" ]; then
		src=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
	else
		tmp=$(mktemp -d) || die "mktemp"
		echo "downloading $FORK_REPO $FORK_REF"
		fetch "https://github.com/$FORK_REPO/archive/refs/heads/$FORK_REF.tar.gz" "$tmp/src.tgz"
		tar -xzf "$tmp/src.tgz" -C "$tmp" || die "bad source archive"
		src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
		[ -n "$src" ] && [ -f "$src/config.default" ] || die "source tree has no config.default"
	fi

	install_bins "$src" "$arch"
	echo "installing files to $DEST"
	copy_tree "$src" "$DEST"
	if [ ! -f "$DEST/config" ]; then
		cp "$DEST/config.default" "$DEST/config"
		echo "created $DEST/config from config.default"
	else
		echo "left existing $DEST/config untouched"
	fi
	chmod 755 "$DEST/zapret2-picker.sh" "$DEST/blockcheck2.sh" "$DEST/install_bin.sh" \
		"$DEST/install_easy.sh" "$DEST/install_prereq.sh" "$DEST/install_openwrt.sh" \
		"$DEST/init.d/openwrt/zapret2" 2>/dev/null || true
	find "$DEST/binaries" -type f \( -name nfqws2 -o -name ip2net -o -name mdig \) -exec chmod 755 {} \;
	( cd "$DEST" && sh "$DEST/install_bin.sh" ) || die "no working nfqws2 for this device"

	ln -sfn "$DEST/init.d/openwrt/zapret2" /etc/init.d/zapret2
	chmod 755 /etc/init.d/zapret2
	mkdir -p /etc/hotplug.d/iface
	ln -sfn "$DEST/init.d/openwrt/90-zapret2" /etc/hotplug.d/iface/90-zapret2
	ln -sfn "$DEST/zapret2-picker.sh" /usr/bin/zapret2-picker

	install_luci "$DEST"
	echo
	echo "Installed. LuCI: Services -> Zapret2."
	echo "The page starts a curl test and can write NFQWS2_OPT. A curl pass is not a browser."
	echo "Existing config, user hostlists, and other UCI files were not replaced."
}

main "$@"
