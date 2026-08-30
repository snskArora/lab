#!/usr/bin/env bash
# Run on BOTH msi and dell, before Flux installs Longhorn.
# Longhorn fails to attach volumes without these, usually silently.
set -euo pipefail
[[ $EUID -eq 0 ]] && { echo "Run as your normal user; it will sudo where needed." >&2; exit 1; }

echo "==> Longhorn host dependencies"
sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common cryptsetup dmsetup util-linux iw

echo "==> Enabling iscsid"
sudo systemctl enable --now iscsid

echo "==> Kernel modules"
for m in iscsi_tcp dm_crypt nfs; do
  sudo modprobe "$m" 2>/dev/null || echo "    WARN: could not load $m"
done
printf 'iscsi_tcp\ndm_crypt\nnfs\n' | sudo tee /etc/modules-load.d/longhorn.conf >/dev/null

echo "==> Longhorn data path"
sudo mkdir -p /var/lib/longhorn
sudo chmod 700 /var/lib/longhorn

# --- FIX: `iw set power_save off` is RUNTIME ONLY. It silently reverts on
# --- every reboot, which is exactly when you stop watching. Persist it
# --- through NetworkManager instead, then apply immediately for this boot.
echo "==> Disabling Wi-Fi power saving (persistently)"
if systemctl is-active --quiet NetworkManager; then
  sudo mkdir -p /etc/NetworkManager/conf.d
  sudo tee /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf >/dev/null <<'CONF'
[connection]
# 2 = disable powersave. Wi-Fi PSM drops the link under light load, which
# looks exactly like a network outage to dqlite.
wifi.powersave = 2
CONF
  sudo systemctl reload NetworkManager || sudo systemctl restart NetworkManager
  echo "    persisted via NetworkManager"
else
  echo "    WARN: NetworkManager not active -- persist powersave off yourself"
fi
for P in /sys/class/net/wl*; do
  [[ -e "$P" ]] || continue
  IFACE=$(basename "$P")
  if sudo iw dev "$IFACE" set power_save off 2>/dev/null; then
    echo "    applied now on $IFACE"
  else
    echo "    could not apply now on $IFACE (config still persists at boot)"
  fi
done

echo
echo "==> Verify"
systemctl is-active --quiet iscsid && echo "    iscsid: active" || echo "    iscsid: NOT ACTIVE"
lsmod | grep -q iscsi_tcp && echo "    iscsi_tcp: loaded" || echo "    iscsi_tcp: MISSING"
for P in /sys/class/net/wl*; do
  [[ -e "$P" ]] || continue
  IFACE=$(basename "$P")
  echo -n "    $IFACE powersave: "
  iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}' || echo "?"
done
echo
echo "Done. Run this on the other node too."
