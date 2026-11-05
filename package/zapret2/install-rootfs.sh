#!/bin/sh
# Fill a package root with the zapret2 runtime, init script, and LuCI page.
set -eu
DEST=${DEST:?}
ZAPRET=${ZAPRET:?}
BIN=${BIN:?}

[ -x "$BIN/nfqws2" ] && [ -x "$BIN/mdig" ] && [ -x "$BIN/ip2net" ] || {
	echo "missing mipsel binaries in $BIN" >&2
	exit 1
}

copy_dir() {
	src=$1
	dst=$2
	mkdir -p "$dst"
	cp -a "$src"/. "$dst"/
}

mkdir -p \
	"$DEST/opt/zapret2/binaries/linux-mipsel" \
	"$DEST/opt/zapret2/nfq2" \
	"$DEST/opt/zapret2/mdig" \
	"$DEST/opt/zapret2/ip2net" \
	"$DEST/opt/zapret2/init.d" \
	"$DEST/opt/zapret2/files" \
	"$DEST/etc/init.d" \
	"$DEST/etc/hotplug.d/iface" \
	"$DEST/usr/bin" \
	"$DEST/usr/share/luci/menu.d" \
	"$DEST/usr/share/rpcd/acl.d" \
	"$DEST/www/luci-static/resources/view/zapret2"

copy_dir "$ZAPRET/common" "$DEST/opt/zapret2/common"
copy_dir "$ZAPRET/lua" "$DEST/opt/zapret2/lua"
copy_dir "$ZAPRET/blockcheck2.d" "$DEST/opt/zapret2/blockcheck2.d"
copy_dir "$ZAPRET/ipset" "$DEST/opt/zapret2/ipset"
copy_dir "$ZAPRET/files/fake" "$DEST/opt/zapret2/files/fake"
copy_dir "$ZAPRET/init.d/openwrt" "$DEST/opt/zapret2/init.d/openwrt"

for f in blockcheck2.sh zapret2-picker.sh config.default install_bin.sh; do
	cp "$ZAPRET/$f" "$DEST/opt/zapret2/$f"
done
# Packaged config. Upgrades and uninstall keep a modified copy because it is a conffile.
cp "$ZAPRET/config.default" "$DEST/opt/zapret2/config"

cp "$BIN/nfqws2" "$BIN/mdig" "$BIN/ip2net" "$DEST/opt/zapret2/binaries/linux-mipsel/"
ln -s ../binaries/linux-mipsel/nfqws2 "$DEST/opt/zapret2/nfq2/nfqws2"
ln -s ../binaries/linux-mipsel/mdig "$DEST/opt/zapret2/mdig/mdig"
ln -s ../binaries/linux-mipsel/ip2net "$DEST/opt/zapret2/ip2net/ip2net"

ln -s /opt/zapret2/init.d/openwrt/zapret2 "$DEST/etc/init.d/zapret2"
ln -s /opt/zapret2/init.d/openwrt/90-zapret2 "$DEST/etc/hotplug.d/iface/90-zapret2"
ln -s /opt/zapret2/zapret2-picker.sh "$DEST/usr/bin/zapret2-picker"

cp "$ZAPRET/luci-app-zapret2/root/usr/share/luci/menu.d/luci-app-zapret2.json" \
	"$DEST/usr/share/luci/menu.d/luci-app-zapret2.json"
cp "$ZAPRET/luci-app-zapret2/root/usr/share/rpcd/acl.d/luci-app-zapret2.json" \
	"$DEST/usr/share/rpcd/acl.d/luci-app-zapret2.json"
cp "$ZAPRET/luci-app-zapret2/htdocs/luci-static/resources/view/zapret2/picker.js" \
	"$DEST/www/luci-static/resources/view/zapret2/picker.js"

find "$DEST/opt/zapret2" -type d -exec chmod 755 {} \;
chmod 755 \
	"$DEST/opt/zapret2/blockcheck2.sh" \
	"$DEST/opt/zapret2/zapret2-picker.sh" \
	"$DEST/opt/zapret2/install_bin.sh" \
	"$DEST/opt/zapret2/init.d/openwrt/zapret2" \
	"$DEST/opt/zapret2/binaries/linux-mipsel/nfqws2" \
	"$DEST/opt/zapret2/binaries/linux-mipsel/mdig" \
	"$DEST/opt/zapret2/binaries/linux-mipsel/ip2net"
find "$DEST/opt/zapret2/ipset" "$DEST/opt/zapret2/common" -name '*.sh' -exec chmod 755 {} \;
