#!/usr/bin/env python3
"""Download the pinned upstream Grafana dashboards, fit them to this lab, and write them into
apps/homelab/monitoring/grafana/dashboards/<folder>/. Run from anywhere: python3 -I scripts/10-vendor-dashboards.py

To update one: change its URL (tag/commit/revision), run once with --print-sha to get the new hash,
put the hash in SOURCES, run again, check the diff, commit. A hash mismatch stops the run.
"""
import hashlib
import json
import pathlib
import re
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "apps/homelab/monitoring/grafana/dashboards"
GH = "https://raw.githubusercontent.com"

# folder, file name, url, sha256 of the upstream file
SOURCES = [
    ("kubernetes", "k8s-views-global.json", f"{GH}/dotdc/grafana-dashboards-kubernetes/v3.1.0/dashboards/k8s-views-global.json", "0f719c95ed159e112dfe26e4ac938de6f85d632572ed662a35ee98b16dcbadff"),
    ("kubernetes", "k8s-views-namespaces.json", f"{GH}/dotdc/grafana-dashboards-kubernetes/v3.1.0/dashboards/k8s-views-namespaces.json", "c4272f53a23631c030eb2c3a7eff4a99ca47307f2521a9d7c9be292ce185be55"),
    ("kubernetes", "k8s-views-nodes.json", f"{GH}/dotdc/grafana-dashboards-kubernetes/v3.1.0/dashboards/k8s-views-nodes.json", "4a11656116232acc2b1fdf77261e7c814af88c52a5559039db56e84b88772be7"),
    ("kubernetes", "k8s-views-pods.json", f"{GH}/dotdc/grafana-dashboards-kubernetes/v3.1.0/dashboards/k8s-views-pods.json", "8f961a15ee3ab27b12a9ae17ff349fbc8350ad98984f5b1a760cec90595cb7ea"),
    ("kubernetes", "k8s-system-coredns.json", f"{GH}/dotdc/grafana-dashboards-kubernetes/v3.1.0/dashboards/k8s-system-coredns.json", "f64d0344d05a2aafaf3ea63cc7c7a052bf40f1d181dc5ac5588cfdb1939dac7a"),
    ("nodes", "node-exporter-full.json", "https://grafana.com/api/dashboards/1860/revisions/46/download", "e58ddc5dc535d4c901f94da9648bc3e3d5ae7b6f78e98e185bce8b289961cea3"),
    ("platform", "flux-cluster.json", f"{GH}/fluxcd/flux2-monitoring-example/7ab65dc8b90f7a6751d88f18bbb4e1bee33bf334/monitoring/configs/dashboards/cluster.json", "2a52d416ca7fee166c7703524332d3c8e586808c21ff5679a259c9dd744ed309"),
    ("platform", "flux-control-plane.json", f"{GH}/fluxcd/flux2-monitoring-example/7ab65dc8b90f7a6751d88f18bbb4e1bee33bf334/monitoring/configs/dashboards/control-plane.json", "604dd55eadc2fc66ee6933d339d51ed475595699fc11c6fec26b91f6831a8e27"),
    ("platform", "envoy-gateway-global.json", f"{GH}/envoyproxy/gateway/v1.9.1/charts/gateway-addons-helm/dashboards/envoy-gateway-global.json", "2cdc2c605b270ad2843708ad1c5defb787cf7d4d43373261188f11871f1bd94e"),
    ("platform", "envoy-proxy-global.json", f"{GH}/envoyproxy/gateway/v1.9.1/charts/gateway-addons-helm/dashboards/envoy-proxy-global.json", "bde5d6326921d45a0807e523a2ce496fd6460fd93ab356b1d4118ae149d586ef"),
    ("platform", "envoy-clusters.json", f"{GH}/envoyproxy/gateway/v1.9.1/charts/gateway-addons-helm/dashboards/envoy-clusters.json", "896e598739c562e8221bb5a7fe660a94a62e9d68c02acfb4381491dd453110be"),
    ("data", "cloudnative-pg.json", f"{GH}/cloudnative-pg/grafana-dashboards/cluster-v0.0.5/charts/cluster/grafana-dashboard.json", "676b10ae3a8850108d484e4491739207b2ad1ebca44300472168d81a8788e4fb"),
    ("data", "victoriametrics.json", f"{GH}/VictoriaMetrics/VictoriaMetrics/v1.157.0/dashboards/victoriametrics.json", "3da52d42d0aabd89d9d92917cff9d965773ae516231c7353d69a560f572f315a"),
]

# Defaults for template variables, so the dashboard opens on this lab's objects.
VAR_DEFAULTS = {"flux-control-plane.json": {"namespace": "flux-system"}}


def recording_rule_cpu(m):
    sel = m.group(1).strip().rstrip(",")
    sel = f'{sel}, container!=""' if sel else 'container!=""'
    return f"irate(container_cpu_usage_seconds_total{{{sel}}}[5m])"


# Applied to every string in every dashboard. Upstream assumes kube-prometheus; this lab has no
# recording rules and scrapes cAdvisor as job="cadvisor".
STRING_FIXES = [
    (re.compile(r'job="kubelet",\s*metrics_path="/metrics/cadvisor"'), 'job="cadvisor"'),
    (re.compile(r"node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate\{([^}]*)\}"), recording_rule_cpu),
    (re.compile(re.escape('pod=~"cloudnative-pg.+|cnpg-controller-manager.+"')), 'pod=~"(cnpg-)?cloudnative-pg.+|cnpg-controller-manager.+"'),
    (re.compile(re.escape("${DS_EXPRESSION}")), "__expr__"),
    (re.compile(re.escape("PBFA97CFB590B2093")), "${datasource}"),
]


def fix_strings(obj):
    if isinstance(obj, dict):
        return {k: fix_strings(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [fix_strings(v) for v in obj]
    if isinstance(obj, str):
        for pat, rep in STRING_FIXES:
            obj = pat.sub(rep, obj)
    return obj


def fit(name, d):
    for k in ("__inputs", "__requires", "__elements"):
        d.pop(k, None)
    d["id"] = None
    d = fix_strings(d)
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "datasource":
            v["current"] = {}
        default = VAR_DEFAULTS.get(name, {}).get(v.get("name"))
        if default:
            v["current"] = {"selected": True, "text": default, "value": default}
    return d


def main():
    print_sha = "--print-sha" in sys.argv
    for folder, name, url, sha in SOURCES:
        req = urllib.request.Request(url, headers={"User-Agent": "lab-dashboard-vendor"})
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
        got = hashlib.sha256(raw).hexdigest()
        if print_sha:
            print(f"{got}  {folder}/{name}")
            continue
        if got != sha:
            sys.exit(f"{name}: sha256 {got} != pinned {sha}; upstream changed under the same ref. Nothing written for it.")
        out = OUT / folder / name
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(fit(name, json.loads(raw)), indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {out.relative_to(REPO)}")


if __name__ == "__main__":
    main()
