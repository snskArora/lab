#!/usr/bin/env bash
# Cloudflare API token for cert-manager's DNS-01 challenges (wildcard *.lab.sanskararora.in).
# Run on sunny BEFORE pushing the cert-manager change, and again to rotate the token.
#
# Token (Cloudflare dashboard -> My Profile -> API Tokens -> Create Token -> Custom token):
#   Permissions: Zone / DNS / Edit and Zone / Zone / Read. Zone Resources: Include / Specific zone / sanskararora.in.
#
# passwords.json (repo root, gitignored) is the record: a token already in the file is reused, otherwise
# the script asks for it (input hidden). It is checked against Cloudflare, saved under .cloudflare,
# and applied as Secret cert-manager/cloudflare-api-token. To rotate: delete it from the file, re-run.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FILE="$REPO/passwords.json"
NS=cert-manager
SECRET=cloudflare-api-token
ZONE=sanskararora.in
API=https://api.cloudflare.com/client/v4

die() { echo "ERROR: $*" >&2; exit 1; }
for c in jq kubectl curl; do command -v $c >/dev/null || die "$c is required"; done
git -C "$REPO" check-ignore -q "$FILE" || die "$FILE is not gitignored; refusing to write secrets there"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$FILE.tmp"' EXIT
umask 077
[[ -s $FILE ]] || echo '{}' > "$FILE"
jq -e 'type == "object"' "$FILE" >/dev/null 2>&1 || die "$FILE is not a JSON object; fix it by hand. Nothing was changed."
chmod 600 "$FILE"

# Only ever writes .cloudflare (same guard as 07-postgres-secrets.sh).
save() {
  jq "$@" "$FILE" > "$FILE.tmp"
  [[ $(jq -S 'del(.cloudflare)' "$FILE") == "$(jq -S 'del(.cloudflare)' "$FILE.tmp")" ]] ||
    die "update would change sections other than cloudflare; nothing was written"
  mv -f "$FILE.tmp" "$FILE"
}

jq -r '.cloudflare.api_tokens["cert-manager"] // empty' "$FILE" | tr -d '\n' > "$TMP/token"
src="file"
if [[ ! -s $TMP/token ]]; then
  read -rsp "Paste the Cloudflare API token (input hidden): " token; echo
  printf '%s' "$token" > "$TMP/token"; unset token
  src="prompt"
fi
[[ -s $TMP/token ]] || die "empty token"

# The token goes to curl through a header file, never on the command line.
printf 'Authorization: Bearer %s\n' "$(cat "$TMP/token")" > "$TMP/auth"
cf() { curl -fsS --max-time 20 -H @"$TMP/auth" "$API$1"; }

[[ $(cf /user/tokens/verify | jq -r '.result.status') == active ]] || die "Cloudflare says the token is not active"
zone_id=$(cf "/zones?name=$ZONE" | jq -r '.result[0].id // empty')
[[ -n $zone_id ]] || die "token cannot read zone $ZONE (needs Zone / Zone / Read on it)"
cf "/zones/$zone_id/dns_records?per_page=1" | jq -e '.success' >/dev/null || die "token cannot read DNS records of $ZONE (needs Zone / DNS / Edit)"
echo "    token ($src) is active and can see zone $ZONE"

# shellcheck disable=SC2016 # $t and $z are jq variables
save --rawfile t "$TMP/token" --arg z "$ZONE" \
  '.cloudflare.api_tokens["cert-manager"] = $t | .cloudflare.zone = $z'

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic "$SECRET" --from-file=api-token="$TMP/token" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "    -> $NS/$SECRET"
echo "Token recorded in $FILE under .cloudflare (mode 600, gitignored)."
