from dashlib import Board, RI, GREEN, bad_if_above

dashboard = Board("homelab-kubernetes", "Homelab / Kubernetes system", "Nodes, workloads and control plane of the MicroK8s cluster at a glance.",
          [("node", "Node", "label_values(kube_node_info, node)"), ("namespace", "Namespace", "label_values(kube_namespace_status_phase, namespace)")])
dashboard.row("Cluster health")
dashboard.stat("Nodes ready", 'sum(kube_node_status_condition{condition="Ready",status="true"}) / count(kube_node_info)', unit="percentunit",
       thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}], desc="Share of nodes reporting Ready.")
dashboard.stat("Node pressure", 'sum(kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"}) or vector(0)',
       thresholds=bad_if_above(1), desc="Memory, disk or PID pressure conditions currently true.")
dashboard.stat("Pods running", 'sum(kube_pod_status_phase{phase="Running"})', color_mode="value")
dashboard.stat("Pods not healthy", 'sum(kube_pod_status_phase{phase=~"Pending|Failed|Unknown"}) + sum(kube_pod_status_ready{condition="false"} * on(namespace, pod) group_left() kube_pod_status_phase{phase="Running"}) or vector(0)',
       thresholds=bad_if_above(1, "orange"), desc="Pending, failed or unknown pods, plus running pods that are not ready.")
dashboard.stat("Restarts (1h)", 'sum(increase(kube_pod_container_status_restarts_total[1h])) or vector(0)', thresholds=bad_if_above(1, "orange"), decimals=0)
dashboard.stat("Scrape targets down", 'count(up == 0) or vector(0)', thresholds=bad_if_above(1), desc="VictoriaMetrics scrape targets that failed their last scrape.")

dashboard.row("Nodes")
dashboard.ts("CPU used", [('100 * (1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle",node=~"$node"}[%s])))' % RI, "{{node}}")], unit="percent")
dashboard.ts("Memory used", [('100 * (1 - node_memory_MemAvailable_bytes{node=~"$node"} / node_memory_MemTotal_bytes{node=~"$node"})', "{{node}}")], unit="percent")
dashboard.bars("Filesystems used", '100 * (1 - node_filesystem_avail_bytes{node=~"$node",mountpoint=~"/|/var/lib/local-path|/boot"} / node_filesystem_size_bytes{node=~"$node",mountpoint=~"/|/var/lib/local-path|/boot"})',
       "{{node}} {{mountpoint}}", maxv=100, w=8, desc="/var/lib/local-path holds every PersistentVolume on that node.")
dashboard.ts("Load (1m) per core", [('node_load1{node=~"$node"} / on(node) count by (node) (node_cpu_seconds_total{mode="idle",node=~"$node"})', "{{node}}")], unit="short", w=8)
dashboard.ts("Network traffic", [('sum by (node) (rate(node_network_receive_bytes_total{node=~"$node",device!~"lo|cali.*|vxlan.*|veth.*"}[%s]))' % RI, "{{node}} in"),
                          ('-sum by (node) (rate(node_network_transmit_bytes_total{node=~"$node",device!~"lo|cali.*|vxlan.*|veth.*"}[%s]))' % RI, "{{node}} out")],
     unit="Bps", w=8, min0=False, desc="Physical interfaces only; out is drawn below zero.")

dashboard.row("Capacity")
dashboard.bars("CPU requests vs allocatable", '100 * sum by (node) (kube_pod_container_resource_requests{resource="cpu",node=~"$node"} * on(namespace, pod) group_left() (kube_pod_status_phase{phase="Running"} == 1)) / on(node) kube_node_status_allocatable{resource="cpu",node=~"$node"}',
       "{{node}}", maxv=100, w=6, h=6, desc="What the scheduler has handed out, not what is used.")
dashboard.bars("Memory requests vs allocatable", '100 * sum by (node) (kube_pod_container_resource_requests{resource="memory",node=~"$node"} * on(namespace, pod) group_left() (kube_pod_status_phase{phase="Running"} == 1)) / on(node) kube_node_status_allocatable{resource="memory",node=~"$node"}',
       "{{node}}", maxv=100, w=6, h=6)
dashboard.bars("Memory limits vs allocatable", '100 * sum by (node) (kube_pod_container_resource_limits{resource="memory",node=~"$node"} * on(namespace, pod) group_left() (kube_pod_status_phase{phase="Running"} == 1)) / on(node) kube_node_status_allocatable{resource="memory",node=~"$node"}',
       "{{node}}", maxv=150, w=6, h=6, thresholds=[GREEN, {"color": "orange", "value": 100}, {"color": "red", "value": 130}], desc="Above 100% the node is overcommitted on limits.")
dashboard.ts("Running pods per node", [('kubelet_running_pods{node=~"$node"}', "{{node}}")], w=6, h=6)

dashboard.row("Workloads")
dashboard.ts("CPU by namespace", [('sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="",namespace=~"$namespace"}[%s]))' % RI, "{{namespace}}")], unit="short", stack=True, desc="CPU cores used.")
dashboard.ts("Memory by namespace", [('sum by (namespace) (container_memory_working_set_bytes{container!="",namespace=~"$namespace"})', "{{namespace}}")], unit="bytes", stack=True)
dashboard.table("Top 15 pods by memory", 'topk(15, sum by (namespace, pod) (container_memory_working_set_bytes{container!="",namespace=~"$namespace"}))',
        [("namespace", "Namespace"), ("pod", "Pod")], value_name="Working set", unit="bytes", w=8, h=9, sort=("Working set", True))
dashboard.table("Top 15 pods by CPU", 'topk(15, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="",namespace=~"$namespace"}[5m])))',
        [("namespace", "Namespace"), ("pod", "Pod")], value_name="Cores", w=8, h=9, sort=("Cores", True))
dashboard.table("Restarts in the last 24h", 'sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total{namespace=~"$namespace"}[24h])) > 0',
        [("namespace", "Namespace"), ("pod", "Pod"), ("container", "Container")], value_name="Restarts", w=8, h=9, sort=("Restarts", True))
dashboard.table("Pods not healthy", '(kube_pod_status_phase{phase=~"Pending|Failed|Unknown",namespace=~"$namespace"} == 1) or (kube_pod_status_ready{condition="false",namespace=~"$namespace"} * on(namespace, pod) group_left() (kube_pod_status_phase{phase="Running"} == 1))',
        [("namespace", "Namespace"), ("pod", "Pod"), ("phase", "Phase")], w=12, h=7, desc="Empty is good.")
dashboard.ts("OOM kills", [('sum by (namespace, pod) (increase(container_oom_events_total{namespace=~"$namespace"}[%s])) > 0' % RI, "{{namespace}}/{{pod}}")], w=12, h=7, desc="Empty is good.")

dashboard.row("Control plane")
dashboard.ts("API requests by verb", [('sum by (verb) (rate(apiserver_request_total[%s]))' % RI, "{{verb}}")], unit="reqps", w=8)
dashboard.ts("API errors (5xx)", [('sum by (resource, code) (rate(apiserver_request_total{code=~"5.."}[%s])) > 0' % RI, "{{resource}} {{code}}")], unit="reqps", w=8, desc="Empty is good.")
dashboard.ts("API requests in flight", [('sum by (request_kind) (apiserver_current_inflight_requests)', "{{request_kind}}")], w=8)
dashboard.ts("Cluster DNS responses (CoreDNS)", [('sum by (rcode) (rate(coredns_dns_responses_total{job="coredns"}[%s]))' % RI, "{{rcode}}")], unit="reqps")
dashboard.ts("Cluster DNS latency p95", [('histogram_quantile(0.95, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket{job="coredns"}[%s])))' % RI, "p95")], unit="s")
