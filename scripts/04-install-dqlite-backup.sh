#!/usr/bin/env bash
# Run on msi (the control-plane node) ONLY.
#
# Flux rebuilds your manifests. It does NOT rebuild live cluster state --
# DAG run history, Longhorn volume metadata, secrets created out of band.
# `microk8s dbctl` is the dqlite equivalent of an etcd snapshot.
set -euo pipefail

BACKUP_DIR=/var/backups/microk8s
KEEP_DAYS=7        # time-based TTL
KEEP_MIN=3         # always keep at least this many, even if all are old
MAX_MB=2048        # hard ceiling on total backup dir size
MIN_FREE_MB=2048   # skip the run entirely if the disk is tighter than this

# MicroK8s lives in /snap/bin, which is NOT on systemd's default PATH.
# Resolve it now and bake the absolute path into the generated script,
# otherwise the 3am run dies with "microk8s: command not found".
MICROK8S=$(command -v microk8s || echo /snap/bin/microk8s)
if [[ ! -x "$MICROK8S" ]]; then
  echo "ERROR: microk8s binary not found at $MICROK8S" >&2
  exit 1
fi
echo "==> Using microk8s at: $MICROK8S"

sudo mkdir -p "$BACKUP_DIR"
# The YAML dump below contains Secrets in cleartext. Default 755 would
# leave every service account token on the box readable by any local user.
sudo chmod 700 "$BACKUP_DIR"

sudo tee /usr/local/bin/microk8s-backup.sh >/dev/null <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

# MicroK8s commands need root. Under systemd this script already IS root,
# so nothing prompts. This guard only catches a manual run as your user.
if [[ \$EUID -ne 0 ]]; then
  echo "must run as root: sudo \$0  (or: sudo systemctl start microk8s-backup)" >&2
  exit 1
fi

MICROK8S="$MICROK8S"
BACKUP_DIR="$BACKUP_DIR"
KEEP_DAYS=$KEEP_DAYS
KEEP_MIN=$KEEP_MIN
MAX_MB=$MAX_MB
MIN_FREE_MB=$MIN_FREE_MB

STAMP=\$(date +%Y%m%d-%H%M%S)

# --- Guard: never let a backup be the thing that fills the disk ----------
FREE_MB=\$(df -Pm "\$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print \$4}')
# Validate it is actually a number. Empty would be silently treated as 0 by
# bash arithmetic, making this guard skip every run forever, invisibly.
if ! [[ "\$FREE_MB" =~ ^[0-9]+\$ ]]; then
  echo "FAIL: could not read free space on \$BACKUP_DIR (df gave: '\$FREE_MB')" >&2
  exit 1
fi
if (( FREE_MB < MIN_FREE_MB )); then
  echo "SKIP: only \${FREE_MB}MB free on \$BACKUP_DIR, need \${MIN_FREE_MB}MB" >&2
  exit 0
fi

# --- Guard: a backup of a half-started cluster is worse than none, because
# --- it silently becomes the newest one you'd restore from.
if ! "\$MICROK8S" status --wait-ready --timeout 60 >/dev/null 2>&1; then
  echo "SKIP: microk8s not ready; refusing to snapshot a broken cluster" >&2
  exit 0
fi

# --- Snapshot the datastore ----------------------------------------------
"\$MICROK8S" dbctl backup "\$BACKUP_DIR/dqlite-\$STAMP"

# --- Verify the artifact actually exists and has bytes in it. dbctl's
# --- output filename convention varies by version; without this check a
# --- no-op would be logged as a successful backup and you would only find
# --- out on the day you tried to restore.
ARTIFACT=\$(find "\$BACKUP_DIR" -maxdepth 1 -name "dqlite-\$STAMP*" -print -quit)
if [[ -z "\$ARTIFACT" ]]; then
  echo "FAIL: dbctl produced no file matching dqlite-\$STAMP*" >&2
  exit 1
fi
SIZE=\$(du -sk "\$ARTIFACT" 2>/dev/null | cut -f1)
if ! [[ "\$SIZE" =~ ^[0-9]+\$ ]]; then
  echo "FAIL: could not size \$ARTIFACT (du gave: '\$SIZE')" >&2
  exit 1
fi
if (( SIZE < 8 )); then
  echo "FAIL: \$ARTIFACT is only \${SIZE}KB -- almost certainly not a real backup" >&2
  rm -rf -- "\$ARTIFACT"
  exit 1
fi
# The snapshot contains every Secret in the cluster. dbctl writes it 644;
# don't depend on the parent directory's mode for confidentiality.
chmod -R go-rwx "\$ARTIFACT" 2>/dev/null || true
echo "  datastore snapshot: \$ARTIFACT (\${SIZE}KB)"

# --- Plain-YAML dump, gzipped. Second format in case dqlite is unrestorable.
"\$MICROK8S" kubectl get all,pvc,pv,cm,secret,gateway,httproute,storageclass -A -o yaml 2>/dev/null \\
  | gzip -9 > "\$BACKUP_DIR/objects-\$STAMP.yaml.gz" || true
chmod 600 "\$BACKUP_DIR/objects-\$STAMP.yaml.gz" 2>/dev/null || true

# --- Backups are PAIRS: dqlite-<stamp> plus objects-<stamp>.yaml.gz.
# --- Prune them as a unit. An earlier version pruned only dqlite-* on the
# --- size path, which deleted the valuable datastore snapshots while the
# --- YAML dumps kept the directory over budget -- exactly backwards.
stamps_newest_first() {
  find "\$BACKUP_DIR" -maxdepth 1 -name 'dqlite-*' -printf '%T@ %f\n' \
    | sort -rn | sed -E 's/^[0-9.]+ dqlite-([0-9]{8}-[0-9]{6}).*/\1/'
}
delete_set() {
  local st="\$1"
  rm -rf -- "\$BACKUP_DIR"/dqlite-"\$st"* "\$BACKUP_DIR"/objects-"\$st"* 2>/dev/null || true
}

# --- Prune 1: age. Always keeps KEEP_MIN newest sets regardless of age.
i=0
while read -r st; do
  [[ -n "\$st" ]] || continue
  i=\$((i+1))
  (( i <= KEEP_MIN )) && continue
  newest=\$(find "\$BACKUP_DIR" -maxdepth 1 -name "dqlite-\$st*" -mtime "+\$KEEP_DAYS" -print -quit)
  if [[ -n "\$newest" ]]; then
    echo "prune (age): \$st"
    delete_set "\$st"
  fi
done < <(stamps_newest_first)

# --- Prune 2: size ceiling, oldest set first. Age alone cannot bound disk
# --- use: a fat cluster or a tighter schedule blows the budget inside the TTL.
while :; do
  USED_MB=\$(du -sm "\$BACKUP_DIR" 2>/dev/null | cut -f1)
  [[ "\$USED_MB" =~ ^[0-9]+\$ ]] || { echo "WARN: cannot size \$BACKUP_DIR; skipping size prune" >&2; break; }
  (( USED_MB <= MAX_MB )) && break
  COUNT=\$(stamps_newest_first | grep -c . || true)
  (( COUNT <= KEEP_MIN )) && { echo "WARN: at \${USED_MB}MB but only \$COUNT backup sets left; not pruning further" >&2; break; }
  OLDEST=\$(stamps_newest_first | tail -1)
  [[ -n "\$OLDEST" ]] || break
  echo "prune (size, \${USED_MB}MB > \${MAX_MB}MB): \$OLDEST"
  delete_set "\$OLDEST"
done

# --- Orphan sweep: an objects-*.gz whose dqlite partner is gone would
# --- otherwise be invisible to both prunes and accumulate forever.
while read -r orph; do
  [[ -n "\$orph" ]] || continue
  st=\$(echo "\$orph" | sed -E 's/.*objects-([0-9]{8}-[0-9]{6}).*/\1/')
  if ! compgen -G "\$BACKUP_DIR/dqlite-\$st*" >/dev/null; then
    echo "prune (orphan): \$orph"
    rm -f -- "\$orph"
  fi
done < <(find "\$BACKUP_DIR" -maxdepth 1 -name 'objects-*')

echo "backup complete: \$STAMP  (\$(du -sh "\$BACKUP_DIR" | cut -f1) total, \$(stamps_newest_first | grep -c . || true) sets)"
SCRIPT
sudo chmod +x /usr/local/bin/microk8s-backup.sh

sudo tee /etc/systemd/system/microk8s-backup.service >/dev/null <<'UNIT'
[Unit]
Description=MicroK8s dqlite backup
After=snap.microk8s.daemon-k8s-dqlite.service

[Service]
Type=oneshot
# Explicit, though oneshot units already default to root. This is what
# means the nightly run never asks anyone for a password.
User=root
Group=root
# /snap/bin is absent from systemd's default PATH. Belt and braces --
# the script also calls microk8s by absolute path.
Environment=PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/microk8s-backup.sh
# Backups are not urgent; never let them starve the control plane.
Nice=10
IOSchedulingClass=idle
UNIT

sudo tee /etc/systemd/system/microk8s-backup.timer >/dev/null <<'UNIT'
[Unit]
Description=Nightly MicroK8s dqlite backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now microk8s-backup.timer

echo "==> Running one now to prove it works"
# Must not abort the installer: the run legitimately exits non-zero if the
# cluster is not ready or dbctl produced nothing, and you need to SEE that
# rather than have set -e kill the script before the notes print.
if sudo systemctl start microk8s-backup.service; then
  echo "    first run: OK"
else
  echo "    first run: FAILED -- read the journal below before trusting this" >&2
fi
sudo journalctl -u microk8s-backup.service -n 30 --no-pager || true
sudo ls -lah "$BACKUP_DIR" || true

cat <<'NOTE'

Runs as root via systemd -- no password, ever. `sudo` is only needed when
you invoke it by hand.

Retention: 7 days, minimum 3 snapshots kept, hard ceiling 2GB.
Skips the run entirely if free space drops under 2GB.

Tune at the top of this script, then re-run it to regenerate.

Restore if dqlite is ever unrecoverable:
    sudo microk8s stop
    microk8s dbctl restore /var/backups/microk8s/dqlite-<stamp>
    sudo microk8s start

Copy these off the node. A backup on the disk that died is not a backup:
    rsync -a msi:/var/backups/microk8s/ /somewhere/else/

Separately: you should not need sudo for microk8s interactively either.
    sudo usermod -a -G microk8s $USER
    sudo chown -R $USER ~/.kube
    newgrp microk8s          # or just log out and back in
That is the documented MicroK8s setup and it does not weaken the backup
job, which keeps running as root regardless.
NOTE
