#!/usr/bin/env bash
# Run on BOTH msi and dell. Prints the plan by default; --apply makes the changes.
set -euo pipefail
[[ $EUID -eq 0 ]] && { echo "Run as your normal user; it will sudo where needed." >&2; exit 1; }

APPLY=false
case "${1:-}" in
  "") ;;
  --apply) APPLY=true ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

VG=ubuntu-vg
LV=local-path
MNT=/var/lib/local-path
DEV="/dev/$VG/$LV"
JOURNAL_CONF=/etc/systemd/journald.conf.d/50-size-cap.conf
REMOVE_SNAPS=()
REMOVE_BASES=()
REMOVING=()

case "$(hostname -s)" in
  msi)
    LV_GIB=200
    REMOVE_SNAPS=(prometheus etcd lxd)
    REMOVE_BASES=(core18 core20 core26)
    ;;
  dell) LV_GIB=100 ;;
  *) echo "Unknown host $(hostname -s); expected msi or dell." >&2; exit 1 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }
run() { if $APPLY; then "$@"; else printf '    would run: %s\n' "$*"; fi; }
has_snap() { snap list "$1" >/dev/null 2>&1; }

setup_volume() {
  echo "==> Storage: ${LV_GIB} GiB at $MNT"
  if [[ -d $MNT ]] && ! mountpoint -q "$MNT" && [[ -n $(sudo find "$MNT" -mindepth 1 -print -quit) ]]; then
    die "$MNT already has files; refusing to mount over them"
  fi

  if sudo lvs "$VG/$LV" >/dev/null 2>&1; then
    echo "    logical volume already exists"
  else
    local free
    free=$(sudo vgs --noheadings --nosuffix --units g -o vg_free "$VG" | tr -d ' ')
    awk -v f="$free" -v n="$LV_GIB" 'BEGIN { exit !(f >= n) }' || die "$VG has ${free} GiB free, need $LV_GIB"
    echo "    $VG has ${free} GiB free"
    run sudo lvcreate -y -Wy -L "${LV_GIB}G" -n "$LV" "$VG"
  fi

  if ! $APPLY; then
    echo "    would format it if blank, make the bare mountpoint immutable, add it to /etc/fstab (nofail) and mount it"
    return
  fi

  local fstype uuid
  fstype=$(sudo blkid -o value -s TYPE "$DEV" || true)
  case "$fstype" in
    "") sudo mkfs.ext4 -q -L local-path -m 0 "$DEV" ;;
    ext4) ;;
    *) die "$DEV already holds a $fstype filesystem" ;;
  esac

  if ! mountpoint -q "$MNT"; then
    sudo mkdir -p "$MNT"
    sudo chattr +i "$MNT"
  fi

  if ! awk -v m="$MNT" '$1 !~ /^#/ && $2 == m { f = 1 } END { exit !f }' /etc/fstab; then
    uuid=$(sudo blkid -o value -s UUID "$DEV")
    sudo cp /etc/fstab /etc/fstab.pre-phase0
    echo "UUID=$uuid $MNT ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2" | sudo tee -a /etc/fstab >/dev/null
    if ! sudo findmnt --verify --tab-file /etc/fstab >/dev/null; then
      sudo cp /etc/fstab.pre-phase0 /etc/fstab
      die "fstab check failed; restored /etc/fstab"
    fi
    sudo systemctl daemon-reload
  fi
  mountpoint -q "$MNT" || sudo mount "$MNT"
}

cap_journal() {
  echo "==> journald: cap at 500 MiB (now: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1))"
  if ! $APPLY; then
    echo "    would write $JOURNAL_CONF, restart journald and trim old logs"
    return
  fi
  sudo mkdir -p "$(dirname "$JOURNAL_CONF")"
  printf '[Journal]\nSystemMaxUse=500M\n' | sudo tee "$JOURNAL_CONF" >/dev/null
  sudo systemctl restart systemd-journald
  sudo journalctl --vacuum-size=500M >/dev/null 2>&1
}

hold_microk8s() {
  echo "==> Hold MicroK8s automatic refresh"
  has_snap microk8s || die "microk8s snap not installed"
  run sudo snap refresh --hold microk8s
}

safe_to_remove() {
  case "$1" in
    lxd)
      local instances
      instances=$(sudo lxc list --format csv -c n 2>/dev/null) || { echo "    KEEP lxd: could not list instances"; return 1; }
      [[ -z $instances ]] || { echo "    KEEP lxd: it has instances: $instances"; return 1; }
      ;;
    etcd)
      [[ -z $(sudo ss -Hltn 'sport = :2379') ]] || { echo "    KEEP etcd: something is listening on 2379"; return 1; }
      ;;
  esac
}

remove_snaps() {
  [[ ${#REMOVE_SNAPS[@]} -gt 0 ]] || return 0
  echo "==> Remove unused snaps"
  local retention s
  retention=$(sudo snap get system snapshots.automatic.retention 2>/dev/null || true)
  [[ $retention != no ]] || die "automatic snap snapshots are off; refusing to remove snaps without a safety net"

  for s in "${REMOVE_SNAPS[@]}"; do
    has_snap "$s" || { echo "    $s already gone"; continue; }
    safe_to_remove "$s" || continue
    REMOVING+=("$s")
    echo "    $s data: $(sudo du -sh "/var/snap/$s" 2>/dev/null | cut -f1)"
    run sudo snap remove "$s"
  done
}

remove_bases() {
  [[ ${#REMOVE_BASES[@]} -gt 0 ]] || return 0
  echo "==> Remove unused base snaps"
  local used="" s b
  for s in $(snap list | awk 'NR > 1 { print $1 }'); do
    [[ " ${REMOVING[*]:-} " == *" $s "* ]] && continue
    used+=" $(awk '$1 == "base:" { print $2 }' "/snap/$s/current/meta/snap.yaml" 2>/dev/null || true) "
  done
  for b in "${REMOVE_BASES[@]}"; do
    has_snap "$b" || { echo "    $b already gone"; continue; }
    if [[ $used == *" $b "* ]]; then
      echo "    KEEP $b: still used by another snap"
      continue
    fi
    run sudo snap remove "$b"
  done
}

summary() {
  echo
  echo "==> Result on $(hostname -s)"
  sudo /snap/bin/microk8s status --wait-ready --timeout 120 >/dev/null && echo "    microk8s: ready" || echo "    microk8s: NOT READY"
  df -h "$MNT" | sed 's/^/    /'
  journalctl --disk-usage 2>/dev/null | sed 's/^/    /'
  snap list | sed 's/^/    /'
  echo "    snapshots kept for restore:"
  sudo snap saved 2>/dev/null | sed 's/^/    /'
  free -h | sed 's/^/    /'
}

sudo -v
$APPLY && echo "APPLYING changes on $(hostname -s)" || echo "PLAN ONLY on $(hostname -s); nothing will change. Re-run with --apply."
setup_volume
cap_journal
hold_microk8s
remove_snaps
remove_bases
$APPLY && summary
echo "Done."
