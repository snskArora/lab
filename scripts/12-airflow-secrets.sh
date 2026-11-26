#!/usr/bin/env bash
# Airflow secrets in namespace airflow. Run on sunny BEFORE pushing the Airflow change (the HelmRelease will not
# install without airflow-extra-values), after 07-postgres-secrets.sh, and again after a password change.
#
#   airflow-metadata        connection      Postgres URL for the airflow role     from .postgres.users.airflow (read only)
#   airflow-fernet-key      fernet-key      encrypts connections/variables in DB  .airflow.fernet_key (generated once, never rotate casually)
#   airflow-api-secret-key  api-secret-key  signs UI sessions                     .airflow.api_secret_key (generated once)
#   airflow-jwt-secret      jwt-secret      signs API and task tokens             .airflow.jwt_secret (generated once)
#   airflow-extra-values    values.yaml     chart values with the admin password  .airflow.admin.password (generated once)
#
# Airflow creates the admin user only once. To change its password later, change it in Airflow (Your Profile),
# put the new value in passwords.json, then re-run this script so the file and the Secret match.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FILE="$REPO/passwords.json"
NS=airflow
URL=https://airflow.lab.sanskararora.in
DB_HOST=pg-rw.databases.svc:5432

die() { echo "ERROR: $*" >&2; exit 1; }
for c in jq kubectl openssl; do command -v $c >/dev/null || die "$c is required"; done
git -C "$REPO" check-ignore -q "$FILE" || die "$FILE is not gitignored; refusing to write passwords there"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$FILE.tmp"' EXIT
umask 077
[[ -s $FILE ]] || die "$FILE missing; run scripts/07-postgres-secrets.sh first"
jq -e 'type == "object"' "$FILE" >/dev/null 2>&1 || die "$FILE is not a JSON object; fix it by hand. Nothing was changed."
chmod 600 "$FILE"

# Only ever writes .airflow (same guard as 07 and 09).
save() {
  jq "$@" "$FILE" > "$FILE.tmp"
  [[ $(jq -S 'del(.airflow)' "$FILE") == "$(jq -S 'del(.airflow)' "$FILE.tmp")" ]] ||
    die "update would change sections other than airflow; nothing was written"
  mv -f "$FILE.tmp" "$FILE"
}

jq -r '.postgres.users.airflow // empty' "$FILE" | tr -d '\n' > "$TMP/dbpw"
[[ -s $TMP/dbpw ]] || die "no .postgres.users.airflow in $FILE; run scripts/07-postgres-secrets.sh first"
grep -Eq '^[A-Za-z0-9._~-]+$' "$TMP/dbpw" || die ".postgres.users.airflow has characters that need URL encoding; regenerate it with 07"

# Keep what passwords.json already has; generate only what is missing.
field() {
  local key=$1 gen=$2
  jq -r --arg k "$key" 'getpath(["airflow"] + ($k | split("."))) // empty' "$FILE" | tr -d '\n' > "$TMP/$key"
  if [[ ! -s $TMP/$key ]]; then
    eval "$gen" | tr -d '\n' > "$TMP/$key"
    echo "    generated .airflow.$key"
  fi
}
field admin.password 'openssl rand -hex 24'
field fernet_key 'openssl rand -base64 32 | tr "+/" "-_"'
field api_secret_key 'openssl rand -hex 32'
field jwt_secret 'openssl rand -hex 64'

# shellcheck disable=SC2016 # $u, $a, $f, $s, $j are jq variables
save --arg u "$URL" --rawfile a "$TMP/admin.password" --rawfile f "$TMP/fernet_key" --rawfile s "$TMP/api_secret_key" --rawfile j "$TMP/jwt_secret" \
  '.airflow.admin.user = "admin" | .airflow.admin.password = $a | .airflow.url = $u | .airflow.fernet_key = $f | .airflow.api_secret_key = $s | .airflow.jwt_secret = $j'

printf 'postgresql://airflow:%s@%s/airflow?sslmode=require' "$(cat "$TMP/dbpw")" "$DB_HOST" > "$TMP/connection"
# shellcheck disable=SC2016 # $p is a jq variable
jq -n --rawfile p "$TMP/admin.password" '{createUserJob: {defaultUser: {password: $p}}}' > "$TMP/values.yaml"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
secret() {
  local name=$1; shift
  kubectl -n "$NS" create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "    $NS/$name"
}
secret airflow-metadata --from-file=connection="$TMP/connection"
secret airflow-fernet-key --from-file=fernet-key="$TMP/fernet_key"
secret airflow-api-secret-key --from-file=api-secret-key="$TMP/api_secret_key"
secret airflow-jwt-secret --from-file=jwt-secret="$TMP/jwt_secret"
secret airflow-extra-values --from-file=values.yaml="$TMP/values.yaml"
echo "Recorded in $FILE under .airflow (mode 600, gitignored). Login: admin at $URL"
