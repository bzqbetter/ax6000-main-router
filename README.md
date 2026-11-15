# Redmi AX6000 main-router firmware

Builds `xiaomi_redmi-router-ax6000-mtkuboot` from
[chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase) `25.12`
(MTK closed-source Wi-Fi + hardware NAT) via GitHub Actions.

- Hardware NAT on (hnat-detect), Turbo ACC (MTK), EQoS (MTK hardware per-device limits)
- HomeProxy + sing-box (latest), OpenClash (latest) with Mihomo core and geodata bundled
- Argon theme + config, UPnP, ttyd, package manager, zram
- LAN `192.168.5.1`, IPv6 off, firewall flow offloading forced off (conflicts with mtk_hnat)

Run: Actions -> "Build Redmi AX6000 firmware" -> Run workflow. Images land in the run's artifacts.
Flash only the `*-mtkuboot-squashfs-sysupgrade.itb` file.
