#!/usr/bin/env bash
# Build Redmi AX6000 (mtkuboot) firmware from chasey-dev/immortalwrt-mt798x-rebase 25.12.
# Run on Linux (case-sensitive fs, ~60GB free) as a non-root user with build deps installed
# (see Dockerfile). Usage: ./build.sh [workdir]  — expects ax6000.config next to this script.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HOME/ax6000-build}"
REPO=https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git
BRANCH=25.12
LAN_IP=192.168.5.1
SINGBOX_VER=1.14.4
SINGBOX_HASH=0958ccd23b1ea9a141d715d15478b1e040fd04bcca19d8ff5529636b1b753e18

log(){ printf '\n==> %s\n' "$*"; }

log "Source: $REPO ($BRANCH)"
if [ -d "$WORK/.git" ]; then
  git -C "$WORK" fetch --depth 1 origin "$BRANCH" && git -C "$WORK" reset --hard FETCH_HEAD
else
  git clone --depth 1 -b "$BRANCH" "$REPO" "$WORK"
fi
cd "$WORK"
git log -1 --format='commit %h  %cd  %s'

log "Feeds"
./scripts/feeds update -a

# ---- Latest upstream plugins (replace feed copies) ----
log "Latest plugins from upstream"
rm -rf package/extra && mkdir -p package/extra
rm -rf feeds/luci/applications/luci-app-openclash feeds/luci/applications/luci-app-homeproxy \
       feeds/luci/themes/luci-theme-argon feeds/luci/applications/luci-app-argon-config
rm -rf /tmp/openclash-src
git clone --depth 1 https://github.com/vernesong/OpenClash.git /tmp/openclash-src
mv /tmp/openclash-src/luci-app-openclash package/extra/ && rm -rf /tmp/openclash-src
git clone --depth 1 https://github.com/immortalwrt/homeproxy.git package/extra/luci-app-homeproxy
git clone --depth 1 https://github.com/jerrykuku/luci-theme-argon.git package/extra/luci-theme-argon
git clone --depth 1 https://github.com/jerrykuku/luci-app-argon-config.git package/extra/luci-app-argon-config

# sing-box: packaging from immortalwrt/packages master, bumped to latest release
rm -rf feeds/packages/net/sing-box /tmp/pkgs-master
git clone --depth 1 --filter=blob:none --sparse https://github.com/immortalwrt/packages.git /tmp/pkgs-master
git -C /tmp/pkgs-master sparse-checkout set net/sing-box
cp -r /tmp/pkgs-master/net/sing-box feeds/packages/net/sing-box && rm -rf /tmp/pkgs-master
sed -i -e "s/^PKG_VERSION:=.*/PKG_VERSION:=$SINGBOX_VER/" -e "s/^PKG_RELEASE:=.*/PKG_RELEASE:=1/" \
       -e "s/^PKG_HASH:=.*/PKG_HASH:=$SINGBOX_HASH/" feeds/packages/net/sing-box/Makefile

./scripts/feeds update -i
./scripts/feeds install -a

# ---- Files baked into the image ----
log "Image files: first-boot defaults + OpenClash core/geodata"
rm -rf files && mkdir -p files/etc/uci-defaults files/etc/openclash/core

cat > files/etc/uci-defaults/99-ax6000-custom <<EOF
# LAN address
uci -q set network.lan.ipaddr='$LAN_IP'
uci -q set network.lan.netmask='255.255.255.0'

# IPv6 off
uci -q delete network.wan6
uci -q delete network.lan.ip6assign
uci -q delete network.globals.ula_prefix
uci -q set network.wan.ipv6='0'
uci -q set dhcp.lan.ra='disabled'
uci -q set dhcp.lan.dhcpv6='disabled'
uci -q set dhcp.lan.ndp='disabled'
uci -q set dhcp.@dnsmasq[0].filter_aaaa='1'

# Firewall flow offloading must stay OFF: mtk_ppe (flow_offloading_hw) and
# mtk_hnat drive the same PPE registers and crash the router together.
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'

uci -q commit network
uci -q commit dhcp
uci -q commit firewall
exit 0
EOF

AUTH=(); [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
MIHOMO_TAG=$(curl -fsSL "${AUTH[@]}" https://api.github.com/repos/MetaCubeX/mihomo/releases/latest |sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$MIHOMO_TAG" ] || { echo "Cannot resolve latest mihomo tag"; exit 1; }
curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_TAG/mihomo-linux-arm64-$MIHOMO_TAG.gz" \
  | gunzip > files/etc/openclash/core/clash_meta
chmod 0755 files/etc/openclash/core/clash_meta
echo "mihomo $MIHOMO_TAG -> /etc/openclash/core/clash_meta"
RULES=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest
curl -fsSL -o files/etc/openclash/Country.mmdb "$RULES/country.mmdb"
curl -fsSL -o files/etc/openclash/GeoSite.dat  "$RULES/geosite.dat"
curl -fsSL -o files/etc/openclash/GeoIP.dat    "$RULES/geoip.dat"
ls -lh files/etc/openclash files/etc/openclash/core

# ---- Config ----
log "Config"
cp "$HERE/ax6000.config" .config
make defconfig

missing=0
for p in luci-app-homeproxy sing-box luci-app-openclash luci-theme-argon luci-app-argon-config \
         luci-app-eqos-mtk luci-app-turboacc-mtk hnat-detect kmod-mt_wifi kmod-mediatek_hnat ip-full; do
  grep -q "^CONFIG_PACKAGE_${p}=y" .config || { echo "MISSING: $p"; missing=1; }
done
for p in odhcp6c odhcpd-ipv6only luci-app-sqm https-dns-proxy; do
  if grep -q "^CONFIG_PACKAGE_${p}=y" .config; then echo "NOTE: $p still selected (pulled by a dependency)"; fi
done
[ "$missing" = 0 ] || { echo "Fix the packages above before building."; exit 1; }

# ---- Build ----
log "Download sources"
make download -j8
log "Build"
make -j"${JOBS:-$(nproc)}" || make -j1 V=s

log "Images"
ls -lh bin/targets/mediatek/filogic/*redmi-router-ax6000-mtkuboot*
grep -hE '^(luci-app-openclash|luci-app-homeproxy|sing-box|luci-theme-argon|luci-app-argon-config|luci-app-eqos-mtk|luci-app-turboacc-mtk) ' \
  bin/targets/mediatek/filogic/*.manifest 2>/dev/null || true
