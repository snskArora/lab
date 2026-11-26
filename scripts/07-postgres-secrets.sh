#!/usr/bin/env bash
# Postgres passwords for the CNPG cluster `pg`. Run on sunny BEFORE Flux applies apps/homelab/postgres,
# and again after any rebuild.
#
# passwords.json (repo root, gitignored) is the record. For each user: a password already in the file is
# reused, one that only exists in the cluster is copied into the file, anything missing is generated.
# The file's values are then applied to the cluster, so editing a password in the file and re-running
# rotates it (CNPG picks up the change through the cnpg.io/reload label).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FILE="$REPO/passwords.json"
NS=databases

die() { echo "ERROR: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
command -v kubectl >/dev/null || die "kubectl is required"
git -C "$REPO" check-ignore -q "$FILE" || die "$FILE is not gitignored; refusing to write passwords there"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$FILE.tmp"' EXIT
umask 077
[[ -s $FILE ]] || echo '{}' > "$FILE"
jq -e 'type == "object"' "$FILE" >/dev/null 2>&1 || die "$FILE is not a JSON object; fix it by hand. Nothing was changed."
chmod 600 "$FILE"

# Only ever writes .postgres: the result must leave every other top-level key exactly as it was,
# and it replaces the file in one rename so an interrupted run can't leave it half written.
save() {
  jq "$@" "$FILE" > "$FILE.tmp"
  [[ $(jq -S 'del(.postgres)' "$FILE") == "$(jq -S 'del(.postgres)' "$FILE.tmp")" ]] ||
    die "update would change sections other than postgres; nothing was written"
  mv -f "$FILE.tmp" "$FILE"
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# user -> Kubernetes secret name (pg-superuser is CNPG's superuserSecret)
for pair in postgres:pg-superuser grafana:pg-grafana airflow:pg-airflow; do
  user=${pair%%:*}
  secret=${pair#*:}

  jq -r --arg u "$user" '.postgres.users[$u] // empty' "$FILE" > "$TMP/pw"
  src="file"
  if [[ ! -s $TMP/pw ]]; then
    kubectl -n "$NS" get secret "$secret" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d > "$TMP/pw" || true
    src="cluster"
  fi
  if [[ ! -s $TMP/pw ]]; then
    openssl rand -hex 24 > "$TMP/pw"
    src="generated"
  fi
  tr -d '\n' < "$TMP/pw" > "$TMP/password"

  # shellcheck disable=SC2016 # $u and $p are jq variables
  save --arg u "$user" --rawfile p "$TMP/password" '.postgres.users[$u] = $p'

  printf '%s' "$user" > "$TMP/username"
  kubectl -n "$NS" create secret generic "$secret" --type=kubernetes.io/basic-auth \
    --from-file=username="$TMP/username" --from-file=password="$TMP/password" \
    --dry-run=client -o json |
    jq '.metadata.labels["cnpg.io/reload"] = "true"' |
    kubectl apply -f - >/dev/null
  echo "    $user: password from $src -> $NS/$secret"
done

save '.postgres.host = "postgres.sunny" | .postgres.ip = "10.10.10.3" | .postgres.port = 5432'
echo "Passwords recorded in $FILE (mode 600, gitignored)."
