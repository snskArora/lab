from dashlib import Board, RI, READY, bad_if_above

dashboard = Board("homelab-flux", "Homelab / Flux GitOps", "What Flux has applied from git, what is failing, and how hard the controllers work.")
dashboard.row("State")
dashboard.stat("Flux objects", 'count(gotk_resource_info)', color_mode="value")
dashboard.stat("Not ready", 'count(gotk_resource_info{ready!="True"}) or vector(0)', thresholds=bad_if_above(1), desc="Objects whose Ready condition is not True.")
dashboard.stat("Suspended", 'count(gotk_resource_info{suspended="true"}) or vector(0)', thresholds=bad_if_above(1, "orange"))
dashboard.stat("Reconcile errors (1h)", 'sum(increase(controller_runtime_reconcile_errors_total{namespace="flux-system"}[1h])) or vector(0)', thresholds=bad_if_above(1, "orange"), decimals=0)
dashboard.stat("Kustomizations", 'count(gotk_resource_info{customresource_kind="Kustomization"})', color_mode="value")
dashboard.stat("HelmReleases", 'count(gotk_resource_info{customresource_kind="HelmRelease"})', color_mode="value")
dashboard.table("Kustomizations", 'gotk_resource_info{customresource_kind="Kustomization"}',
        [("name", "Name"), ("ready", "Ready"), ("suspended", "Suspended"), ("source_name", "Source"), ("revision", "Applied revision")], w=24, h=7, colored={"ready": READY})
dashboard.table("HelmReleases", 'gotk_resource_info{customresource_kind="HelmRelease"}',
        [("exported_namespace", "Namespace"), ("name", "Name"), ("ready", "Ready"), ("chart_name", "Chart"), ("revision", "Chart version"), ("chart_app_version", "App version"), ("chart_source_name", "Repository")],
        w=24, h=9, colored={"ready": READY})
dashboard.table("Sources", 'gotk_resource_info{customresource_kind=~"GitRepository|HelmRepository|OCIRepository|Bucket|HelmChart"}',
        [("customresource_kind", "Kind"), ("name", "Name"), ("ready", "Ready"), ("url", "URL"), ("revision", "Revision")], w=24, h=9, colored={"ready": READY})
dashboard.row("Reconciliation")
dashboard.ts("Reconcile duration p95 by kind", [('histogram_quantile(0.95, sum by (le, kind) (rate(gotk_reconcile_duration_seconds_bucket[%s])))' % RI, "{{kind}}")], unit="s")
dashboard.ts("Reconciles by controller and result", [('sum by (controller, result) (rate(controller_runtime_reconcile_total{namespace="flux-system"}[%s]))' % RI, "{{controller}} {{result}}")], unit="ops")
dashboard.ts("Slowest objects (p95, top 10)", [('topk(10, histogram_quantile(0.95, sum by (le, kind, exported_namespace, name) (rate(gotk_reconcile_duration_seconds_bucket[30m]))))', "{{kind}} {{exported_namespace}}/{{name}}")], unit="s")
dashboard.ts("Work queue depth", [('sum by (name) (workqueue_depth{namespace="flux-system"})', "{{name}}")], desc="Items waiting per controller queue; should sit near zero.")
dashboard.row("Controllers")
dashboard.ts("Controller CPU", [('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="flux-system",container!=""}[%s]))' % RI, "{{pod}}")], unit="short")
dashboard.ts("Controller memory", [('sum by (pod) (container_memory_working_set_bytes{namespace="flux-system",container!=""})', "{{pod}}")], unit="bytes")
