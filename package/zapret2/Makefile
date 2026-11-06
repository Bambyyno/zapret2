include $(TOPDIR)/rules.mk

PKG_NAME:=zapret2
PKG_VERSION:=1.0.6
PKG_RELEASE:=5

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Bambyyno

include $(INCLUDE_DIR)/package.mk

define Package/zapret2
  SECTION:=net
  CATEGORY:=Network
  TITLE:=zapret2
  DEPENDS:=+curl +nftables +kmod-nft-queue +kmod-nft-nat +luci-base
endef

define Package/zapret2/description
  zapret2 nfqws2 service and the LuCI strategy test.
  Removing the package removes the init script and the LuCI page.
endef

define Package/zapret2/conffiles
/opt/zapret2/config
endef

define Package/zapret2/prerm
#!/bin/sh
# apk removes packaged files after this script. Save the config first.
if [ -z "$${IPKG_INSTROOT}" ] && [ -f /opt/zapret2/config ]; then
	cp /opt/zapret2/config /tmp/zapret2.config.keep
fi
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/zapret2 ]; then
	/etc/init.d/zapret2 stop || true
	/etc/init.d/zapret2 disable || true
fi
exit 0
endef

define Package/zapret2/postrm
#!/bin/sh
if [ -f /tmp/zapret2.config.keep ] && [ ! -f /opt/zapret2/config ]; then
	mkdir -p /opt/zapret2
	mv /tmp/zapret2.config.keep /opt/zapret2/config
fi
rm -f /tmp/zapret2.config.keep
exit 0
endef

define Build/Compile
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	sh $(CURDIR)/fetch-bins.sh $(PKG_BUILD_DIR)/bins
endef

define Package/zapret2/install
	DEST="$(1)" ZAPRET="$(CURDIR)/../.." BIN="$(PKG_BUILD_DIR)/bins" \
		sh $(CURDIR)/install-rootfs.sh
endef

$(eval $(call BuildPackage,zapret2))
