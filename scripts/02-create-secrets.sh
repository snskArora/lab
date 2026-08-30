#!/usr/bin/env bash
# The secrets that cannot live in plaintext git.
#
# Run on msi AFTER 01 (cluster must exist) and BEFORE `flux bootstrap`.
# The Airflow HelmRelease declares `optional: false` on airflow-extra-values,
# so if Flux reconciles first it exhausts its 3 install retries against a
# missing secret and parks the release in a failed state.
#
# Re-run verbatim after any future rebuild -- that is the point.
set -euo pipefail

# --- FIX: standalone `kubectl` may not be installed. MicroK8s ships its
# --- own. Prefer a real kubectl if present, else fall back.
# $HOME is not guaranteed to be exported; derive it if missing.
RUN_HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
[[ -n "$RUN_HOME" ]] || { echo "cannot determine home directory" >&2; exit 1; }

MK="$(command -v microk8s || echo /snap/bin/microk8s)"
if command -v kubectl >/dev/null && kubectl version --client >/dev/null 2>&1; then
  K() { kubectl "$@"; }
else
  K() { sudo "$MK" kubectl "$@"; }
fi

NS=airflow
REPO_HOST=github.com
K create namespace "$NS" --dry-run=client -o yaml | K apply -f -

# --- 1. Git deploy key + known_hosts --------------------------------------
# Generate a dedicated read-only key if you don't have one:
#   ssh-keygen -t ed25519 -N "" -f ~/.ssh/airflow_dags -C airflow-dags
# Add ~/.ssh/airflow_dags.pub as a Deploy Key on
#   github.com/snskarora/airflow_homeserver_dags -> Settings -> Deploy keys
KEY="${RUN_HOME}/.ssh/airflow_dags"
[[ -f "$KEY" ]] || { echo "ERROR: $KEY not found. Generate it and add the .pub as a deploy key." >&2; exit 1; }

# --- FIX: git-sync fails host key verification without known_hosts. This
# --- is the classic "gitSync container CrashLoopBackOff with no useful
# --- error" and it is not obvious from the chart docs.
echo "==> Fetching $REPO_HOST host keys"
KNOWN=$(mktemp); ssh-keyscan -t rsa,ecdsa,ed25519 "$REPO_HOST" 2>/dev/null > "$KNOWN"
[[ -s "$KNOWN" ]] || { echo "ERROR: ssh-keyscan returned nothing (no network?)" >&2; exit 1; }

# The chart's git-ssh-key-secret template reads the key `gitSshKey`.
K -n "$NS" create secret generic airflow-git-ssh-key-secret \
  --from-file=gitSshKey="$KEY" \
  --dry-run=client -o yaml | K apply -f -

# --- 2. Chart values containing the admin password ------------------------
# --- FIX: an earlier draft referenced `createUserJob.defaultUser.
# --- passwordSecretName`, which this chart does NOT support -- the user
# --- job would have been created with an empty password. The chart only
# --- reads a literal value, so instead we feed those values in through a
# --- Secret via the HelmRelease's `valuesFrom`. That is a real Flux
# --- mechanism and keeps the password out of git.
read -rsp "Airflow admin password: " ADMIN_PW; echo
read -rsp "Confirm: " ADMIN_PW2; echo
[[ "$ADMIN_PW" == "$ADMIN_PW2" ]] || { echo "Passwords differ." >&2; exit 1; }
[[ ${#ADMIN_PW} -ge 12 ]] || echo "WARN: short password; this UI may end up reachable on your LAN."

# knownHosts is a chart VALUE (a string), not a secret reference, so it
# rides in here alongside the password.
#
# Built with a real serializer, NOT shell string concatenation. A password
# containing a double quote, backslash, colon or leading `#` silently
# produces invalid or misparsed YAML, and the failure surfaces much later
# as an unexplained HelmRelease error. JSON is valid YAML 1.2, and
# json.dumps is stdlib -- no PyYAML dependency on the node.
VALS=$(mktemp)
if ! ADMIN_PW="$ADMIN_PW" KNOWN_HOSTS="$(cat "$KNOWN")" python3 -c '
import os, json, sys
json.dump({
  "createUserJob": {"defaultUser": {"password": os.environ["ADMIN_PW"]}},
  "dags": {"gitSync": {"knownHosts": os.environ["KNOWN_HOSTS"]}},
}, sys.stdout, indent=2)
' > "$VALS"; then
  echo "ERROR: could not serialise chart values" >&2
  rm -f "$VALS" "$KNOWN"; exit 1
fi
rm -f "$KNOWN"
K -n "$NS" create secret generic airflow-extra-values \
  --from-file=values.yaml="$VALS" \
  --dry-run=client -o yaml | K apply -f -
shred -u "$VALS" 2>/dev/null || rm -f "$VALS"

# --- 3. Static JWT signing key -------------------------------------------
# Airflow 3 signs JWTs; `webserverSecretKeySecretName` is the Airflow <3
# path and is ignored on 3.x. The chart's helper expects the key to be
# named exactly `jwt-secret`. Without a fixed value the chart regenerates
# one on every render and restarts your components -- the warning your
# original helm install printed.
if ! K -n "$NS" get secret airflow-jwt-secret >/dev/null 2>&1; then
  K -n "$NS" create secret generic airflow-jwt-secret \
    --from-literal=jwt-secret="$(openssl rand -hex 32)"
  echo "==> Generated a new JWT signing key"
else
  echo "==> JWT secret already exists, keeping it (rotating restarts pods)"
fi

echo
K -n "$NS" get secrets airflow-git-ssh-key-secret airflow-extra-values airflow-jwt-secret

cat <<'NOTE'

If you ran this AFTER bootstrap and the release already failed, retries are
spent and a plain reconcile will not retry. Force it:
    flux reconcile helmrelease airflow -n airflow --force
  or:
    flux suspend helmrelease airflow -n airflow
    flux resume  helmrelease airflow -n airflow

To stop doing this by hand, encrypt them into git with SOPS + age:
    age-keygen -o age.agekey
    flux bootstrap ... --decryption-provider=sops --decryption-secret=sops-age
NOTE
