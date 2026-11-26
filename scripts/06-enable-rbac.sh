#!/usr/bin/env bash
# Read-only check on dell and msi first. Then --apply on msi only.
# --apply watches the cluster afterwards and rolls back by itself if it stays unhealthy.
set -euo pipefail
[[ $EUID -eq 0 ]] && { echo "Run as your normal user; it will sudo where needed." >&2; exit 1; }

APPLY=false
case "${1:-}" in
  "") ;;
  --apply) APPLY=true ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

HOST=$(hostname -s)
case "$HOST" in
  msi|dell) ;;
  *) echo "Unknown host $HOST; expected msi or dell." >&2; exit 1 ;;
esac
if $APPLY && [[ $HOST != msi ]]; then
  echo "--apply runs on msi only (the API server lives there)." >&2
  exit 1
fi

CRED=/var/snap/microk8s/current/credentials
KBIN=/snap/microk8s/current/kubectl
K=(sudo "$KBIN" --kubeconfig="$CRED/client.config")
GATE_TIMEOUT=300
GATE_STEP=15
GATE_PASSES=6
WHY=""

check_identity() {
  local file=$1 want_user=$2 want_group=$3 got user
  if ! got=$(sudo "$KBIN" --kubeconfig="$CRED/$file" auth whoami -o jsonpath='{.status.userInfo.username} {.status.userInfo.groups}' 2>/dev/null); then
    echo "    FAIL $file: could not ask the API who this is"
    return 1
  fi
  user=${got%% *}
  if [[ $user == "$want_user" && ( -z $want_group || $got == *"\"$want_group\""* ) ]]; then
    echo "    ok   $file -> $user"
  else
    echo "    FAIL $file -> $got (expected $want_user ${want_group:+in $want_group})"
    return 1
  fi
}

preflight() {
  local rc=0
  echo "==> Component identities on $HOST"
  check_identity kubelet.config "system:node:$HOST" system:nodes || rc=1
  check_identity proxy.config system:kube-proxy "" || rc=1
  if [[ $HOST == msi ]]; then
    check_identity controller.config system:kube-controller-manager "" || rc=1
    check_identity scheduler.config system:kube-scheduler "" || rc=1
    check_identity client.config admin system:masters || rc=1
    echo "    API server mode: $(sudo grep -h -- '--authorization-mode' /var/snap/microk8s/current/args/kube-apiserver)"
  fi
  return "$rc"
}

sa_can() {
  local who=$1
  shift
  "${K[@]}" auth can-i --quiet --as="system:serviceaccount:$who" "$@" 2>/dev/null
}

node_can() {
  "${K[@]}" auth can-i --quiet --as="system:node:$1" --as-group=system:nodes \
    update "leases.coordination.k8s.io/$1" -n kube-node-lease 2>/dev/null
}

gate() {
  local not_ready bad_pods flux
  WHY=""
  "${K[@]}" get --raw /readyz >/dev/null 2>&1 || { WHY="API not ready"; return 1; }

  if sa_can cloudflared:default list secrets -A; then
    WHY="RBAC is not enforcing (cloudflared can read secrets)"
    return 1
  fi

  node_can msi || { WHY="kubelet msi denied"; return 1; }
  node_can dell || { WHY="kubelet dell denied"; return 1; }
  sa_can kube-system:calico-node list nodes || { WHY="calico-node denied"; return 1; }
  sa_can kube-system:calico-node create serviceaccounts/calico-cni-plugin --subresource=token -n kube-system || { WHY="calico-node token denied"; return 1; }
  sa_can kube-system:calico-kube-controllers list nodes || { WHY="calico-kube-controllers denied"; return 1; }
  sa_can kube-system:coredns list endpointslices.discovery.k8s.io -A || { WHY="coredns denied"; return 1; }
  sa_can flux-system:kustomize-controller create deployments.apps -A || { WHY="flux kustomize denied"; return 1; }
  sa_can flux-system:helm-controller create deployments.apps -A || { WHY="flux helm denied"; return 1; }
  sa_can flux-system:source-controller list gitrepositories.source.toolkit.fluxcd.io -A || { WHY="flux source denied"; return 1; }
  sa_can envoy-gateway-system:envoy-gateway list gateways.gateway.networking.k8s.io -A || { WHY="envoy-gateway denied"; return 1; }
  sa_can local-path-storage:local-path-provisioner-service-account create persistentvolumes || { WHY="local-path denied"; return 1; }
  sa_can local-path-storage:local-path-reaper patch persistentvolumes || { WHY="reaper denied"; return 1; }

  not_ready=$("${K[@]}" get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" { print $1 }')
  [[ -z $not_ready ]] || { WHY="node not Ready: $not_ready"; return 1; }

  bad_pods=$("${K[@]}" get pods -A --no-headers 2>/dev/null | awk '$4 == "Completed" { next } { split($3, r, "/"); if ($4 != "Running" || r[1] != r[2]) print $1 "/" $2 }')
  [[ -z $bad_pods ]] || { WHY="pods not ready: $(echo "$bad_pods" | tr '\n' ' ')"; return 1; }

  flux=$("${K[@]}" get kustomizations.kustomize.toolkit.fluxcd.io -A -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -v '=True$' || true)
  [[ -z $flux ]] || { WHY="flux not Ready: $(echo "$flux" | tr '\n' ' ')"; return 1; }
}

watch_health() {
  local start=$SECONDS passes=0
  echo "==> Watching the cluster (up to ${GATE_TIMEOUT}s, needs $GATE_PASSES clean checks in a row)"
  while (( SECONDS - start < GATE_TIMEOUT )); do
    if gate; then
      passes=$((passes + 1))
      echo "    clean check $passes/$GATE_PASSES"
      (( passes >= GATE_PASSES )) && return 0
    else
      passes=0
      echo "    waiting: $WHY"
    fi
    sleep "$GATE_STEP"
  done
  return 1
}

sudo -v
if ! preflight; then
  echo "Preflight failed. Nothing was changed." >&2
  exit 1
fi

if ! $APPLY; then
  echo
  echo "Check passed on $HOST; nothing was changed."
  exit 0
fi

echo "==> Enabling RBAC (control plane restarts on msi; running pods keep running)"
sudo /snap/bin/microk8s enable rbac || echo "WARN: enable reported an error; the health watch decides whether to roll back"

if watch_health; then
  echo
  echo "==> RBAC is on"
  sudo grep -h -- '--authorization-mode' /var/snap/microk8s/current/args/kube-apiserver | sed 's/^/    /'
  echo "    cluster roles: $("${K[@]}" get clusterroles --no-headers | wc -l)"
  "${K[@]}" get nodes --no-headers | sed 's/^/    /'
  echo "Done."
else
  echo
  echo "==> Unhealthy after ${GATE_TIMEOUT}s: $WHY"
  echo "==> Rolling back"
  sudo /snap/bin/microk8s disable rbac
  sudo grep -h -- '--authorization-mode' /var/snap/microk8s/current/args/kube-apiserver | sed 's/^/    /'
  echo "Rolled back. Paste this output."
  exit 1
fi
