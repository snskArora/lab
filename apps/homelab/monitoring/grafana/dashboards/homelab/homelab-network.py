from dashlib import Board, RI

dashboard = Board("homelab-network", "Homelab / Networking and ingress", "MetalLB VIPs, Envoy Gateway traffic, DNS, the Cloudflare tunnel and TLS certificates.")
dashboard.row("Addresses and certificates")
dashboard.table("VIPs and the node announcing them", 'metallb_speaker_announced == 1', [("ip", "VIP"), ("service", "Service"), ("node", "Announced by")], w=10, h=7,
        desc="MetalLB L2: one node answers ARP for each VIP. If a VIP stops answering, check this node first.")
dashboard.bars("MetalLB pool used", '100 * sum(metallb_allocator_addresses_in_use_total) / sum(metallb_allocator_addresses_total)', "pool lab", maxv=100, w=6, h=7)
dashboard.table("Certificates", '(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400',
        [("exported_namespace", "Namespace"), ("name", "Certificate"), ("issuer_name", "Issuer")], value_name="Days left", unit="none", w=8, h=7,
        desc="cert-manager renews 30 days before expiry; below 21 days something is wrong.", sort=("Days left", False))
dashboard.row("Envoy Gateway")
dashboard.ts("Requests by status class", [('sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx{envoy_http_conn_manager_prefix=~"https?-.*"}[%s]))' % RI, "{{envoy_response_code_class}}xx")], unit="reqps", stack=True)
dashboard.ts("Requests by route", [('sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/.*"}[%s]))' % RI, "{{envoy_cluster_name}}")], unit="reqps")
dashboard.ts("Upstream latency p95 by route", [('histogram_quantile(0.95, sum by (le, envoy_cluster_name) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/.*"}[%s])))' % RI, "{{envoy_cluster_name}}")], unit="ms")
dashboard.ts("Active connections by listener", [('sum by (envoy_http_conn_manager_prefix) (envoy_http_downstream_cx_active{envoy_http_conn_manager_prefix=~"https?-.*"})', "{{envoy_http_conn_manager_prefix}}")])
dashboard.row("DNS")
dashboard.ts("DNS responses by server and code", [('sum by (job, rcode) (rate(coredns_dns_responses_total[%s]))' % RI, "{{job}} {{rcode}}")], unit="reqps",
     desc="coredns = cluster DNS; k8s-gateway = the .sunny zone answering for the house.")
dashboard.ts("DNS latency p95", [('histogram_quantile(0.95, sum by (le, job) (rate(coredns_dns_request_duration_seconds_bucket[%s])))' % RI, "{{job}}")], unit="s")
dashboard.row("Cloudflare tunnel")
dashboard.stat("Tunnel edge connections", 'sum(cloudflared_tunnel_ha_connections)', thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 4}], w=6, h=6,
       desc="Each cloudflared replica keeps 4 connections to Cloudflare's edge.")
dashboard.ts("Tunnel requests", [('sum by (pod) (rate(cloudflared_tunnel_total_requests[%s]))' % RI, "{{pod}}")], unit="reqps", w=9, h=6)
dashboard.ts("Tunnel request errors", [('sum by (pod) (rate(cloudflared_tunnel_request_errors[%s]))' % RI, "{{pod}}")], unit="reqps", w=9, h=6)
