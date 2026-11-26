#!/usr/bin/env bash
# Rebuild msi as the control plane, rejoin dell as a worker, install Flux.
set -euo pipefail
[[ $EUID -eq 0 ]] && { echo "Run as your normal user; it will sudo where needed." >&2; exit 1; }

# $USER and $HOME are not guaranteed to be exported (sudo -i, cron, some
# minimal shells). Under `set -u` an unset var aborts the script -- and here
# that would happen AFTER `microk8s reset` had already wiped the cluster.
RUN_USER="$(id -un)"
RUN_HOME="${HOME:-$(getent passwd "$RUN_USER" | cut -d: -f6)}"
[[ -n "$RUN_HOME" ]] || { echo "cannot determine home directory" >&2; exit 1; }

MK="$(command -v microk8s || echo /snap/bin/microk8s)"
[[ -x "$MK" ]] || { echo "microk8s not found at $MK" >&2; exit 1; }

cat <<'NOTE'
------------------------------------------------------------------
BEFORE YOU RUN THIS
  * On dell:  sudo microk8s leave
  * Both nodes run the SAME microk8s channel. Check on each:
        snap list microk8s
    A version mismatch makes `join` fail in confusing ways.
  * scripts/00-host-prereqs.sh has run on BOTH nodes.
  * You have a git repo and a token with repo scope.
------------------------------------------------------------------
NOTE
read -rp "Continue? [y/N] " ok; [[ "$ok" == "y" ]] || exit 1

echo "==> Resetting msi"
sudo "$MK" reset
sudo rm -f  /var/snap/microk8s/common/var/lib/kubelet/plugins_registry/*.sock
sudo rm -rf /var/snap/microk8s/common/var/lib/kubelet/plugins/driver.longhorn.io

echo "==> Addons (rbac FIRST, while the cluster is empty)"
# Enabling rbac later breaks anything already installed without the right
# ServiceAccounts. Now is the only painless moment.
sudo "$MK" enable rbac
sudo "$MK" enable dns
sudo "$MK" status --wait-ready

echo "==> Letting you use microk8s without sudo"
sudo usermod -a -G microk8s "$RUN_USER"
sudo mkdir -p "$RUN_HOME/.kube" && sudo chown -R "$RUN_USER" "$RUN_HOME/.kube"
echo "    (takes effect on next login, or run: newgrp microk8s)"

echo
echo "==> Join dell as a WORKER"
cat <<'WHY'
    Two dqlite VOTERS is worse than one: Raft quorum for 2 is 2, so losing
    either node freezes the whole cluster. Three voters tolerate one loss --
    that is why MicroK8s only enables HA at 3.

    Worker-only dell still gives you multi-node scheduling, DaemonSets,
    affinity rules, cross-node Calico and Longhorn replication.

    When node 3 arrives: `microk8s add-node` with NO --worker, then
    promote dell the same way.
WHY
sudo "$MK" add-node --worker
read -rp "Press enter once dell has joined..."

sudo "$MK" status --wait-ready
sudo "$MK" kubectl get nodes -o wide

# --- FIX: kubeconfig must be written AFTER the join. Joining can rotate
# --- the apiserver certs, so a kubeconfig captured earlier goes stale and
# --- `flux bootstrap` fails with a TLS error that points nowhere useful.
echo "==> Writing kubeconfig (after join, deliberately)"
# Write to a temp file first and validate. A bare `sudo cmd > file` runs the
# redirect as YOUR shell, so a failing command truncates an existing
# kubeconfig to zero bytes before you find out anything went wrong.
TMPCFG=$(mktemp)
# shellcheck disable=SC2024  # redirect runs as us, into our own mktemp file --
# that is intended; the validation below covers the failure case.
if sudo "$MK" config > "$TMPCFG" && grep -q 'server: https://' "$TMPCFG"; then
  install -m 600 "$TMPCFG" "$RUN_HOME/.kube/config"
  echo "    kubeconfig written and validated"
else
  echo "ERROR: microk8s config produced nothing usable; kubeconfig left untouched" >&2
  rm -f "$TMPCFG"; exit 1
fi
rm -f "$TMPCFG"

echo "==> Installing flux CLI"
command -v flux >/dev/null || curl -s https://fluxcd.io/install.sh | sudo bash
flux check --pre

cat <<'NEXT'

==> Next, in order. The secrets step comes BEFORE bootstrap on purpose:
    the Airflow HelmRelease has `optional: false` on its values Secret, so
    bootstrapping first burns all 3 install retries against a secret that
    does not exist yet and leaves the release stuck needing a manual
    `flux reconcile --force`.

  1. Secrets, from the repo with passwords.json (sunny) -- FIRST:
       ./scripts/07-postgres-secrets.sh
       ./scripts/08-cloudflare-dns-token.sh
       ./scripts/09-grafana-secrets.sh
       ./scripts/12-airflow-secrets.sh

  2. Push this repo, then:
       export GITHUB_TOKEN=<pat>
       flux bootstrap github --owner=snskarora \
         --repository=homelab-gitops --branch=main \
         --path=clusters/homelab --personal

  3. ./scripts/03-graceful-shutdown.sh       # BOTH nodes -- do not skip

  4. ./scripts/04-install-dqlite-backup.sh   # msi only

  5. flux get kustomizations --watch
NEXT
