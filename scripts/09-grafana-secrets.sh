#!/usr/bin/env bash
# Grafana secrets in namespace monitoring. Run on sunny BEFORE pushing the Grafana change, after
# 07-postgres-secrets.sh, and again after either password changes.
#
#   grafana-admin  admin-user / admin-password   from passwords.json .grafana.admin (generated if missing)
#   grafana-db     GF_DATABASE_PASSWORD          from passwords.json .postgres.users.grafana (read only)
#
# Grafana reads the admin password only when it first creates its database. To rotate it later, change it
# in Grafana (Profile -> Change password) and put the new value in passwords.json, then re-run this script.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FILE="$REPO/passwords.json"
NS=monitoring
URL=https://grafana.lab.sanskararora.in

die() { echo "ERROR: $*" >&2; exit 1; }
for c in jq kubectl openssl; do command -v $c >/dev/null || die "$c is required"; done
git -C "$REPO" check-ignore -q "$FILE" || die "$FILE is not gitignored; refusing to write passwords there"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$FILE.tmp"' EXIT
umask 077
[[ -s $FILE ]] || die "$FILE missing; run scripts/07-postgres-secrets.sh first"
jq -e 'type == "object"' "$FILE" >/dev/null 2>&1 || die "$FILE is not a JSON object; fix it by hand. Nothing was changed."
chmod 600 "$FILE"

# Only ever writes .grafana (same guard as 07-postgres-secrets.sh).
save() {
  jq "$@" "$FILE" > "$FILE.tmp"
  [[ $(jq -S 'del(.grafana)' "$FILE") == "$(jq -S 'del(.grafana)' "$FILE.tmp")" ]] ||
    die "update would change sections other than grafana; nothing was written"
  mv -f "$FILE.tmp" "$FILE"
}

jq -r '.postgres.users.grafana // empty' "$FILE" | tr -d '\n' > "$TMP/dbpw"
[[ -s $TMP/dbpw ]] || die "no .postgres.users.grafana in $FILE; run scripts/07-postgres-secrets.sh first"

jq -r '.grafana.admin.password // empty' "$FILE" > "$TMP/pw"
src="file"
if [[ ! -s $TMP/pw ]]; then
  kubectl -n "$NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d > "$TMP/pw" || true
  src="cluster"
fi
if [[ ! -s $TMP/pw ]]; then
  openssl rand -hex 24 > "$TMP/pw"
  src="generated"
fi
tr -d '\n' < "$TMP/pw" > "$TMP/password"

# shellcheck disable=SC2016 # $p and $u are jq variables
save --rawfile p "$TMP/password" --arg u "$URL" '.grafana.admin.user = "admin" | .grafana.admin.password = $p | .grafana.url = $u'

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
printf 'admin' > "$TMP/user"
kubectl -n "$NS" create secret generic grafana-admin --from-file=admin-user="$TMP/user" --from-file=admin-password="$TMP/password" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic grafana-db --from-file=GF_DATABASE_PASSWORD="$TMP/dbpw" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "    admin password from $src -> $NS/grafana-admin; database password -> $NS/grafana-db"
echo "Recorded in $FILE under .grafana (mode 600, gitignored). Login: admin at $URL"
