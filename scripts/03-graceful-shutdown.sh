#!/usr/bin/env bash
# Run on BOTH msi and dell.
#
# These are laptops. A power cut doesn't kill them, it puts them on
# battery -- then they die at 0% with no filesystem sync and no dqlite
# checkpoint. That dirty shutdown is the most likely cause of the
# datastore corruption that started all of this. Nothing here is
# Kubernetes config; it is all power management.
set -euo pipefail
[[ $EUID -eq 0 ]] && { echo "Run as your normal user; it will sudo where needed." >&2; exit 1; }

# --- FIX: an earlier draft overwrote UPower.conf wholesale, discarding
# --- whatever else the distro had set. Edit the existing keys in place.
echo "==> UPower: clean poweroff at 20% battery"
if [[ -f /etc/UPower/UPower.conf ]]; then
  sudo cp -n /etc/UPower/UPower.conf /etc/UPower/UPower.conf.bak
  set_key() {
    local k="$1" v="$2"
    if grep -qE "^\s*#?\s*${k}=" /etc/UPower/UPower.conf; then
      sudo sed -i -E "s|^\s*#?\s*${k}=.*|${k}=${v}|" /etc/UPower/UPower.conf
    else
      # Insert directly after the [UPower] header, NOT at end of file.
      # Appending only works while the file has one section; if a future
      # version adds another, an appended key lands in the wrong section
      # and is silently ignored.
      sudo sed -i -E "0,/^\[UPower\]/s|^\[UPower\]|[UPower]\n${k}=${v}|" /etc/UPower/UPower.conf
    fi
  }
  set_key UsePercentageForPolicy true
  set_key PercentageLow          25
  set_key PercentageCritical     22
  set_key PercentageAction       20
  set_key CriticalPowerAction    PowerOff
  if sudo systemctl restart upower; then
    echo "    configured"
  else
    # `cmd && echo` would have swallowed this silently: under set -e a
    # failing left-hand side of && does not abort, it just skips the echo.
    echo "    ERROR: upower failed to restart -- battery action NOT active" >&2
    echo "    check: systemctl status upower" >&2
  fi
else
  echo "    WARN: /etc/UPower/UPower.conf absent (upower not installed?)"
  echo "    Install it:  sudo apt-get install -y upower"
fi

echo "==> logind: ignore the lid, never idle-suspend"
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/99-homelab.conf >/dev/null <<'CONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
IdleAction=ignore
CONF

# --- FIX: logind config alone doesn't stop everything from suspending.
# --- Mask the sleep targets so nothing can pull the node down mid-write.
echo "==> Masking sleep/hibernate targets"
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Restarting logind can drop active desktop sessions; safe over SSH.
sudo systemctl restart systemd-logind || echo "    (restart deferred to reboot)"

echo "==> Giving dqlite time to checkpoint during shutdown"
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/99-shutdown-timeout.conf >/dev/null <<'CONF'
[Manager]
# Default is 90s. dqlite gets SIGKILLed mid-write if it needs longer.
DefaultTimeoutStopSec=120s
CONF
sudo systemctl daemon-reexec

echo
echo "==> Verify"
BAT=$(upower -e 2>/dev/null | grep -i BAT | head -1 || true)
if [[ -n "$BAT" ]]; then
  upower -i "$BAT" | grep -E 'state|percentage' || true
else
  echo "    no battery detected -- if this node is desktop/UPS-powered, fine"
fi
systemctl is-enabled sleep.target 2>&1 | head -1
echo
echo "Done. Run this on the other node too."
cat <<'VERIFY'

TEST IT, do not assume. The battery action is the single load-bearing piece
here and it fails silently if upower is not managing the battery:

    upower -i $(upower -e | grep -i BAT | head -1) | grep -E 'state|percentage'
    grep -E 'PercentageAction|CriticalPowerAction' /etc/UPower/UPower.conf

Then actually unplug the machine once and watch it drain to the threshold,
or accept that you are trusting an untested safety net.

This does NOT replace a UPS on your router -- it makes the crash survivable,
it does not stop the outage.
VERIFY
