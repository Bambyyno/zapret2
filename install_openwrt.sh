#!/bin/sh
# Install zapret2 as an OpenWrt package so Software can remove it.
#
#   uclient-fetch -O /tmp/install_openwrt.sh https://raw.githubusercontent.com/Bambyyno/zapret2/cursor/zapret2-apk-96e1/install_openwrt.sh && sh /tmp/install_openwrt.sh
#
# OpenWrt 25.12 (apk, ramips/mt7621) installs zapret2-mipsel_24kc.apk.
# apk del zapret2 removes the init script, hotplug hook, and LuCI page.
# /opt/zapret2/config is a conffile and is kept when it was modified.

FORK_REPO=Bambyyno/zapret2
FORK_REF=cursor/zapret2-apk-96e1
APK_NAME=zapret2-mipsel_24kc.apk
APK_URL=${APK_URL:-https://raw.githubusercontent.com/$FORK_REPO/$FORK_REF/openwrt/bin/$APK_NAME}

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

main()
{
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -f /etc/openwrt_release ] || die "this installer only runs on OpenWrt"
	# shellcheck disable=SC1091
	. /etc/openwrt_release
	saved=
	if [ -f /opt/zapret2/config ]; then
		saved=$(mktemp)
		cp /opt/zapret2/config "$saved"
	fi
	if [ -d /lib/apk/db ] && command -v apk >/dev/null 2>&1; then
		apkfile=/tmp/$APK_NAME
		if [ -n "${ZAPRET_APK:-}" ] && [ -f "$ZAPRET_APK" ]; then
			apkfile=$ZAPRET_APK
		else
			echo "downloading $APK_URL"
			fetch "$APK_URL" "$apkfile"
		fi
		apk add --allow-untrusted "$apkfile" </dev/null || die "apk add zapret2 failed"
		echo "installed package zapret2"
		echo "remove it with: apk del zapret2"
	elif command -v opkg >/dev/null 2>&1; then
		die "OpenWrt 25.12 ramips/mt7621 uses apk. This build does not ship an ipk."
	else
		die "need apk (OpenWrt 25) "
	fi
	if [ -n "$saved" ]; then
		cp "$saved" /opt/zapret2/config
		rm -f "$saved"
		echo "kept existing /opt/zapret2/config"
	fi
	echo "LuCI: Services -> Zapret2. A modified /opt/zapret2/config is kept on apk del."
}

main "$@"
