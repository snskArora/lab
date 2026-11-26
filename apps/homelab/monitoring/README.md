# Monitoring

Metrics and dashboards for the lab, all in namespace `monitoring` and deployed by Flux from this folder.

| Piece | What it does | Where |
|---|---|---|
| VictoriaMetrics (single node) | Scrapes every target itself and stores 30 days of metrics on msi | [victoria-metrics.yaml](victoria-metrics.yaml) |
| node-exporter | Host metrics from every node | [node-exporter.yaml](node-exporter.yaml) |
| kube-state-metrics | Kubernetes object state, plus Flux object state (`gotk_resource_info`) | [kube-state-metrics.yaml](kube-state-metrics.yaml) |
| Grafana | Dashboards, state in the Postgres database `grafana` | [grafana/](grafana/) |

## URLs

- Grafana: https://grafana.lab.sanskararora.in (user `admin`, password in `passwords.json` under `grafana`)
- vmui and the VictoriaMetrics API: https://metrics.lab.sanskararora.in, or http://metrics.sunny on devices with the `.sunny` DNS setup. No login yet.

## Getting an app scraped

Add these to the pod template (not the Deployment) and declare the port as a `containerPort`:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"      # must equal a declared containerPort
  prometheus.io/path: /metrics    # optional, /metrics is the default
```

VictoriaMetrics re-reads its scrape config every 30 s and discovers pods by itself, so nothing else changes. Plain HTTP only. The `job` label comes from the pod's `app` or `app.kubernetes.io/name` label. Components that need special handling (kubelet, cAdvisor, API server, CoreDNS, MetalLB, kube-state-metrics) have their own jobs in `victoria-metrics.yaml`.

## Dashboards from git

Grafana runs a sidecar that watches ConfigMaps labelled `grafana_dashboard: "1"` in this namespace and writes them into Grafana within about a minute. The `grafana_folder` annotation picks the Grafana folder. [grafana/kustomization.yaml](grafana/kustomization.yaml) builds one ConfigMap per folder from the JSON files under [grafana/dashboards/](grafana/dashboards/).

| Folder | Contents |
|---|---|
| `homelab/` -> Homelab | The lab's own boards: Kubernetes system (home page), Flux GitOps, Networking and ingress, Data stores |
| `kubernetes/` -> Kubernetes | dotdc Kubernetes views (global, namespaces, nodes, pods) and CoreDNS |
| `nodes/` -> Nodes | Node Exporter Full |
| `platform/` -> Platform | Flux cluster stats and control plane, Envoy Gateway |
| `data/` -> Data | CloudNativePG, VictoriaMetrics |

**Add a dashboard**
1. Build it in Grafana (New dashboard), or download one.
2. Export it: Share -> Export -> Save to file (leave "Export for sharing externally" off).
3. Save the file as `grafana/dashboards/<folder>/<name>.json` and add that path under the folder's `files:` in `grafana/kustomization.yaml`. A new folder needs a new generator entry with its own `grafana_folder`.
4. Commit and push. Flux applies the ConfigMap and the dashboard appears.

Use the datasource variable `${datasource}` or the uid `victoriametrics` in panels.

**Change a dashboard**: dashboards from git can be edited in the UI to try things, but saving is blocked. Export the edited version (step 2), replace the file, commit.

**Remove a dashboard**: delete the file and its line in `kustomization.yaml`, push. Flux deletes it from the ConfigMap and Grafana drops it.

**Size limit**: a ConfigMap holds at most 1 MiB. Keep each folder under about 900 KB (`du -cb grafana/dashboards/<folder>/*.json`); if one grows past that, split it into a second generator with the same `grafana_folder`.

**Upstream dashboards** (everything outside `homelab/`) are not edited by hand. [scripts/10-vendor-dashboards.py](../../../scripts/10-vendor-dashboards.py) downloads each at a pinned version, checks its sha256, and applies the lab fixes (no kube-prometheus recording rules, cAdvisor scraped as `job="cadvisor"`, the CNPG operator pod name). To update one, change its URL and hash in the script, run it, review the diff, commit.

## Credentials

[scripts/09-grafana-secrets.sh](../../../scripts/09-grafana-secrets.sh) creates `grafana-admin` and `grafana-db` from `passwords.json`. Run it before the first deploy and after a password change. Grafana only reads the admin password when it first creates its database; to rotate it later, change it in Grafana first, then update `passwords.json` and re-run the script.

## Known gaps

- Persistent volume usage panels stay empty: local-path volumes are host directories, which kubelet does not report. Use the `/var/lib/local-path` filesystem panels instead.
- vmui has no login until the Envoy Gateway SecurityPolicy phase.
- No alerting yet.
