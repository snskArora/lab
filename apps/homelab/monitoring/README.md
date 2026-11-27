# Monitoring

Metrics, logs and dashboards for the lab, all in namespace `monitoring` and deployed by Flux from this folder.

| Piece | What it does | Where |
|---|---|---|
| VictoriaMetrics (single node) | Scrapes every target itself and stores 30 days of metrics on msi | [victoria-metrics.yaml](victoria-metrics.yaml) |
| node-exporter | Host metrics from every node | [node-exporter.yaml](node-exporter.yaml) |
| kube-state-metrics | Kubernetes object state, plus Flux object state (`gotk_resource_info`) | [kube-state-metrics.yaml](kube-state-metrics.yaml) |
| VictoriaLogs (single node) | Stores 14 days of logs (at most 10 GiB) on msi | [victoria-logs.yaml](victoria-logs.yaml) |
| Fluent Bit | DaemonSet on every node: ships pod logs and MicroK8s/kernel journald to VictoriaLogs | [fluent-bit.yaml](fluent-bit.yaml) |
| Grafana | Dashboards and log search, state in the Postgres database `grafana` | [grafana/](grafana/) |

## URLs

- Grafana: https://grafana.lab.sanskararora.in (user `admin`, password in `passwords.json` under `grafana`)
- vmui and the VictoriaMetrics API: https://metrics.lab.sanskararora.in, or http://metrics.sunny on devices with the `.sunny` DNS setup. No login yet.
- VictoriaLogs UI: https://logs.lab.sanskararora.in (opens the log explorer at `/select/vmui/`). No login yet. Only the UI and the query API (`/select/...`) are routed, so nothing can be written or deleted through it.

## Getting an app scraped

Add these to the pod template (not the Deployment) and declare the port as a `containerPort`:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"      # must equal a declared containerPort
  prometheus.io/path: /metrics    # optional, /metrics is the default
```

VictoriaMetrics re-reads its scrape config every 30 s and discovers pods by itself, so nothing else changes. Plain HTTP only. The `job` label comes from the pod's `app` or `app.kubernetes.io/name` label. Components that need special handling (kubelet, cAdvisor, API server, CoreDNS, MetalLB, kube-state-metrics) have their own jobs in `victoria-metrics.yaml`.

## Logs

Every container's stdout/stderr is collected automatically; apps need nothing. JSON log lines are split into fields (`level`, `msg`, ...) so they can be filtered on directly. From journald, Fluent Bit takes the MicroK8s services (kubelite, containerd, cluster-agent, k8s-dqlite and apiserver-kicker on msi, apiserver-proxy on dell) and kernel messages. It starts at new lines only (no backfill), keeps its read position and a disk buffer in `/var/lib/fluent-bit` on each node, and sends zstd-compressed batches, retrying until VictoriaLogs accepts them.

Search in Grafana -> Explore -> VictoriaLogs, with [LogsQL](https://docs.victoriametrics.com/victorialogs/logsql/):

| Want | Query |
|---|---|
| One namespace | `kubernetes.namespace_name:flux-system` |
| One pod, a word | `kubernetes.pod_name:grafana-* error` |
| JSON errors | `level:error` |
| A node service | `_SYSTEMD_UNIT:snap.microk8s.daemon-kubelite.service` |
| Kernel on dell | `_HOSTNAME:dell _TRANSPORT:kernel` |
| Lines per namespace | `* \| stats by (kubernetes.namespace_name) count()` |

Streams (the index) are namespace, pod, container and node for pods; host, unit and transport for journald. Pod labels are kept as fields, annotations are not.

## Dashboards from git

Grafana runs a sidecar that watches ConfigMaps labelled `grafana_dashboard: "1"` in this namespace and writes them into Grafana within about a minute. Each sub-folder of [grafana/dashboards/](grafana/dashboards/) becomes one ConfigMap and one Grafana folder (title-cased name). [scripts/11-dashboards.py](../../../scripts/11-dashboards.py) generates [grafana/kustomization.yaml](grafana/kustomization.yaml) from those folders, so it is never edited by hand.

| Folder | Contents |
|---|---|
| `homelab/` -> Homelab | The lab's own boards: Kubernetes system (home page), Flux GitOps, Networking and ingress, Data stores, Logs, Airflow |
| `kubernetes/` -> Kubernetes | dotdc Kubernetes views (global, namespaces, nodes, pods) and CoreDNS |
| `nodes/` -> Nodes | Node Exporter Full |
| `platform/` -> Platform | Flux cluster stats and control plane, Envoy Gateway |
| `data/` -> Data | CloudNativePG, VictoriaMetrics, VictoriaLogs |

A folder holds two kinds of file:
- `<name>.json`: a Grafana dashboard used as is (exported from Grafana, or vendored).
- `<name>.py`: a definition that builds `<name>.json`. It imports the helpers in [scripts/dashboards/dashlib.py](../../../scripts/dashboards/dashlib.py) and sets `dashboard = Board(...)`. The generated JSON is committed next to it, because Flux runs no code. The `homelab/` boards are written this way.

**Build** (Python 3 only, nothing to install), from the repo root:

```bash
python3 -I scripts/11-dashboards.py            # .py -> .json, regenerate kustomization.yaml, validate
python3 -I scripts/11-dashboards.py check      # exit 1 if anything is stale or invalid (writes nothing)
python3 -I scripts/11-dashboards.py --live     # also run every panel query against the cluster
python3 -I scripts/11-dashboards.py --live homelab-logs   # just one board
```

Validation stops the build on invalid JSON, a duplicate uid, a folder over 900 KB (a ConfigMap holds 1 MiB) or a panel pointing at a datasource that does not exist here. `--live` port-forwards to VictoriaMetrics and VictoriaLogs by itself (needs `kubectl` pointed at the lab) and lists empty or failing panels.

**Add a dashboard**
1. Either write `grafana/dashboards/<folder>/<name>.py` (copy one from `homelab/`), or build it in Grafana and export it (Share -> Export -> Save to file, "Export for sharing externally" off) as `grafana/dashboards/<folder>/<name>.json`. A new folder is just a new directory.
2. Run the build, then `--live` for that board.
3. Commit the folder files and `grafana/kustomization.yaml`, push. The dashboard appears about a minute after Flux applies it.

Datasources: `${datasource}` or the uid `victoriametrics` for metrics, the uid `victorialogs` for logs.

**Change a dashboard**: dashboards from git can be edited in the UI to try things, but saving is blocked. For a `.py` board, change the definition and rebuild; for a `.json` one, export the edited version over the file. Then commit.

**Remove a dashboard**: delete its file(s), run the build, push. Flux updates the ConfigMap and Grafana drops it.

**Upstream dashboards** (everything outside `homelab/`) are not edited by hand. [scripts/10-vendor-dashboards.py](../../../scripts/10-vendor-dashboards.py) downloads each at a pinned version, checks its sha256, and applies the lab fixes (no kube-prometheus recording rules, cAdvisor scraped as `job="cadvisor"`, the CNPG operator pod name, datasource uids from the author's Grafana pointed at the dashboard's datasource variable). To update one, change its URL and hash in the script, run it, then run `11-dashboards.py`, review the diff, commit.

## Credentials

[scripts/09-grafana-secrets.sh](../../../scripts/09-grafana-secrets.sh) creates `grafana-admin` and `grafana-db` from `passwords.json`. Run it before the first deploy and after a password change. Grafana only reads the admin password when it first creates its database; to rotate it later, change it in Grafana first, then update `passwords.json` and re-run the script.

## Known gaps

- Persistent volume usage panels stay empty: local-path volumes are host directories, which kubelet does not report. Use the `/var/lib/local-path` filesystem panels instead.
- vmui and the VictoriaLogs UI have no login until the Envoy Gateway SecurityPolicy phase. Anyone on the LAN can read metrics and logs.
- No alerting yet, and no log backups (VictoriaLogs keeps 14 days).
- The Logs board's "error-looking lines" are a heuristic (level field, klog `E` lines, the words error/fatal/panic).
