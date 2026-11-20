#!/usr/bin/env bash
# Re-runnable audit of this repo. Run it after you edit anything here.
#
#   ./scripts/99-audit.sh
#
# Needs: shellcheck, yamllint, kustomize, python3 (with pyyaml).
# Everything it checks is static or offline -- it never touches your cluster.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot cd to repo root" >&2; exit 1; }

FAIL=0
ok(){ echo "  ok    $1"; }
# shellcheck disable=SC2034  # FAIL is read at the end of the script
bad(){ echo "  FAIL  $1"; FAIL=1; }
have(){ command -v "$1" >/dev/null 2>&1; }

echo "=== [1] shell static analysis ==="
if have shellcheck; then
  out=$(shellcheck -S style scripts/*.sh 2>&1)
  if [[ -z "$out" ]]; then ok "shellcheck: all scripts clean"; else bad "shellcheck"; echo "$out"; fi
  # the script that 04 GENERATES is where bugs hide -- check it too
  sed -n '/^sudo tee \/usr\/local\/bin/,/^SCRIPT$/p' scripts/04-install-dqlite-backup.sh | sed '1d;$d' > /tmp/_raw.sh
  MICROK8S=/snap/bin/microk8s BACKUP_DIR=/var/backups/microk8s KEEP_DAYS=7 KEEP_MIN=3 \
  MAX_MB=2048 MIN_FREE_MB=2048 bash -c 'eval "cat <<SCRIPT
$(cat /tmp/_raw.sh)
SCRIPT" > /tmp/_gen.sh'
  out=$(shellcheck -S style /tmp/_gen.sh 2>&1)
  if [[ -z "$out" ]]; then ok "shellcheck: generated backup script clean"; else bad "generated script"; echo "$out"; fi
  rm -f /tmp/_raw.sh /tmp/_gen.sh
else echo "  skip  shellcheck not installed"; fi

echo "=== [2] yaml ==="
if have yamllint; then
  out=$(yamllint -d "{extends: relaxed, rules: {line-length: disable, comments-indentation: disable}}" . 2>&1)
  if [[ -z "$out" ]]; then ok "yamllint clean"; else bad "yamllint"; echo "$out"; fi
else echo "  skip  yamllint not installed"; fi

if have kustomize; then
  for d in infrastructure/controllers infrastructure/configs apps/homelab apps/homelab/airflow; do
    if kustomize build "$d" >/dev/null 2>&1; then ok "kustomize build $d"; else bad "kustomize build $d"; fi
  done
else echo "  skip  kustomize not installed"; fi

echo "=== [3] semantic cross-reference ==="
SEM_RC=0
python3 - <<'PY' || SEM_RC=$?
import yaml,glob,pathlib,os,sys
bad=[]
def c(l,x):
    if not x: bad.append(l)
docs={f:[d for d in yaml.safe_load_all(pathlib.Path(f).read_text()) if d]
      for f in glob.glob('**/*.yaml',recursive=True)}

for f,ds in docs.items():
    if os.path.basename(f)=='kustomization.yaml':
        for r in (ds[0].get('resources') or []):
            c(f"kustomization resource missing: {f} -> {r}",
              os.path.exists(os.path.join(os.path.dirname(f),r)))
    if f.startswith('clusters/'):
        for d in ds:
            if d.get('kind')=='Kustomization':
                c(f"flux path missing: {d['spec']['path']}",
                  os.path.isdir(d['spec']['path'].lstrip('./')))

names={d['metadata']['name'] for ds in docs.values() for d in ds
       if d.get('kind')=='Kustomization' and d.get('apiVersion','').startswith('kustomize.toolkit')}
for ds in docs.values():
    for d in ds:
        if d.get('kind')=='Kustomization' and d.get('apiVersion','').startswith('kustomize.toolkit'):
            for dep in (d['spec'].get('dependsOn') or []):
                c(f"dependsOn target missing: {dep['name']}", dep['name'] in names)

repos={(d['metadata']['name'],d['metadata']['namespace'])
       for ds in docs.values() for d in ds if d.get('kind')=='HelmRepository'}
for ds in docs.values():
    for d in ds:
        if d.get('kind')=='HelmRelease':
            sr=d['spec']['chart']['spec']['sourceRef']
            c(f"HelmRelease {d['metadata']['name']}: sourceRef unresolved",
              (sr['name'],sr.get('namespace')) in repos)

# secrets referenced in manifests must be created by 02
import re
created=set(re.findall(r'generic (airflow-[a-z-]+)',
            pathlib.Path('scripts/02-create-secrets.sh').read_text()))
for ds in docs.values():
    for d in ds:
        for r in set(re.findall(r'airflow-(?:git-ssh-key-secret|extra-values|jwt-secret)',
                                yaml.safe_dump(d))):
            c(f"secret {r} referenced but not created by 02", r in created)

# gateway chain
g=docs['infrastructure/configs/envoy-gateway-setup.yaml']
gc=[d for d in g if d['kind']=='GatewayClass'][0]
gw=[d for d in g if d['kind']=='Gateway'][0]
ep=[d for d in g if d['kind']=='EnvoyProxy'][0]
rt=docs['apps/homelab/airflow/httproute.yaml'][0]
ls={l['name']:l['port'] for l in gw['spec']['listeners']}
c("Gateway.gatewayClassName does not match GatewayClass",
  gw['spec']['gatewayClassName']==gc['metadata']['name'])
c("GatewayClass.parametersRef does not match EnvoyProxy",
  gc['spec']['parametersRef']['name']==ep['metadata']['name'])
c("HTTPRoute.parentRef does not match Gateway",
  rt['spec']['parentRefs'][0]['name']==gw['metadata']['name'])
c("HTTPRoute.sectionName not a Gateway listener",
  rt['spec']['parentRefs'][0]['sectionName'] in ls)
c("EnvoyProxy patch port != Gateway listener port",
  ep['spec']['provider']['kubernetes']['envoyService']['patch']['value']['spec']['ports'][0]['port']
  ==list(ls.values())[0])
c("HTTPRoute parentRef namespace != Gateway namespace",
  rt['spec']['parentRefs'][0]['namespace']==gw['metadata']['namespace'])

# local-path storage
lp=docs['infrastructure/controllers/local-path.yaml']
lpg=[d for d in lp if d.get('kind')=='GitRepository'][0]
lpk=[d for d in lp if d.get('kind')=='Kustomization'][0]
c("local-path GitRepository must pin a tag", 'tag' in lpg['spec']['ref'])
c("local-path Kustomization sourceRef does not match its GitRepository",
  lpk['spec']['sourceRef']['name']==lpg['metadata']['name'])
scp=[yaml.safe_load(p['patch']) for p in lpk['spec'].get('patches',[])
     if p.get('target',{}).get('kind')=='StorageClass']
c("local-path StorageClass is not patched to Retain",
  any(p.get('reclaimPolicy')=='Retain' for p in scp))
c("local-path StorageClass is not patched to be the default class",
  any(p.get('metadata',{}).get('annotations',{}).get('storageclass.kubernetes.io/is-default-class')=='true' for p in scp))
rp=[d for d in docs['infrastructure/configs/local-path-reaper.yaml'] if d.get('kind')=='CronJob'][0]
rpc=rp['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]
rpe={e['name']:e['value'] for e in rpc.get('env',[])}
c("reaper STORAGE_CLASS does not match the local-path class", rpe.get('STORAGE_CLASS')=='local-path')
c("reaper image must be pinned by digest", '@sha256:' in rpc['image'])

af=[d for d in docs['apps/homelab/airflow/helmrelease.yaml'] if d.get('kind')=='HelmRelease'][0]
# The chart hardcodes ReadWriteMany for the logs PVC and has no accessMode
# field. Asserting it is ABSENT is the correct check: setting it would be a
# silently-ignored value that looks like it is doing something.
c("logs.persistence.accessMode is set, but no such chart field exists "
  "(the PVC template hardcodes ReadWriteMany)",
  'accessMode' not in af['spec']['values'].get('logs',{}).get('persistence',{}))
# parse the YAML, don't grep -- these words appear in explanatory comments
d=yaml.safe_dump(af)
c("invented chart field passwordSecretName is present as a real key",
  'passwordSecretName' not in d)
c("nonexistent chart field logs.persistence.accessMode is set "
  "(chart hardcodes ReadWriteMany)",
  'accessMode' not in yaml.safe_dump(af['spec']['values'].get('logs',{})))
c("Airflow 3 uses jwtSecretName, not webserverSecretKeySecretName",
  'webserverSecretKeySecretName' not in d)
c("Airflow 3 component is apiServer, not webserver",
  'apiServer' in af['spec']['values'])
c("chart versions must be pinned, not floating ranges",
  all('x' not in x['spec']['chart']['spec']['version']
      for ds in docs.values() for x in ds if x.get('kind')=='HelmRelease'))
c("airflow valuesFrom missing (admin password would be unset)",
  any(x['name']=='airflow-extra-values' for x in af['spec'].get('valuesFrom',[])))

for b in bad: print("  FAIL ",b)
if not bad: print("  ok    all semantic cross-references resolve")
sys.exit(1 if bad else 0)
PY
if [[ "$SEM_RC" -ne 0 ]]; then FAIL=1; fi

echo "=== [4] documentation drift ==="
if grep -q '02-create-secrets.sh    # BEFORE bootstrap' README.md
then ok "README run order matches script 01"; else bad "README run order drift"; fi
if grep -q 'KEEP_DAYS=7' scripts/04-install-dqlite-backup.sh && grep -q '7-day TTL' README.md
then ok "retention claim matches"; else bad "retention claim drift"; fi
if grep -q 'hardcodes accessModes' apps/homelab/airflow/helmrelease.yaml && grep -q 'hardcodes' README.md
then ok "RWX explanation matches chart reality"; else bad "RWX claim drift"; fi

echo
if [[ "$FAIL" -eq 0 ]]; then echo "AUDIT PASSED"; else echo "AUDIT FAILED"; fi
exit "$FAIL"
