#!/bin/sh
# Download the mipsel nfqws2/mdig/ip2net binaries used by the OpenWrt package.
set -eu
out=${1:?}
url=${BIN_URL:-https://github.com/bol-van/zapret2/releases/download/v1.0.6/zapret2-v1.0.6-openwrt-embedded.tar.gz}
prefix=zapret2-v1.0.6/binaries/linux-mipsel
mkdir -p "$out"
if [ -x "$out/nfqws2" ] && [ -x "$out/mdig" ] && [ -x "$out/ip2net" ]; then
	exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -n "${BIN_TARBALL:-}" ] && [ -f "$BIN_TARBALL" ]; then
	cp "$BIN_TARBALL" "$tmp/bins.tgz"
else
	curl -fsSL -o "$tmp/bins.tgz" "$url"
fi
tar -xzf "$tmp/bins.tgz" -C "$tmp" "$prefix/nfqws2" "$prefix/mdig" "$prefix/ip2net"
cp "$tmp/$prefix/nfqws2" "$tmp/$prefix/mdig" "$tmp/$prefix/ip2net" "$out/"
chmod 755 "$out/nfqws2" "$out/mdig" "$out/ip2net"
