from dashlib import Board, RI, GREEN

dashboard = Board("homelab-data", "Homelab / Data stores", "Postgres (CloudNativePG cluster pg) and VictoriaMetrics.")
dashboard.row("Postgres")
dashboard.stat("Instances up", 'sum(cnpg_collector_up)', thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}])
dashboard.table("Roles", 'cnpg_pg_replication_in_recovery', [("pod", "Instance"), ("node", "Node")], value_name="Role", w=8, h=4,
        colored={"Value": {"0": ("primary", "green"), "1": ("replica", "blue")}})
dashboard.stat("Replication lag", 'max(cnpg_pg_replication_lag)', unit="s", thresholds=[GREEN, {"color": "orange", "value": 5}, {"color": "red", "value": 30}], w=4)
dashboard.stat("Connections", 'sum(cnpg_backends_total)', color_mode="value", w=4)
dashboard.stat("Max connections used", 'max(sum by (pod) (cnpg_backends_total)) / 100', unit="percentunit", thresholds=[GREEN, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.9}], w=4,
       desc="Against max_connections=100 from the Cluster spec.")
dashboard.ts("Transactions per database", [('sum by (datname) (rate(cnpg_pg_stat_database_xact_commit{datname!~"template.*"}[%s])) + sum by (datname) (rate(cnpg_pg_stat_database_xact_rollback{datname!~"template.*"}[%s]))' % (RI, RI), "{{datname}}")], unit="ops")
dashboard.ts("Connections by database and state", [('sum by (datname, state) (cnpg_backends_total)', "{{datname}} {{state}}")])
dashboard.ts("Replication lag", [('cnpg_pg_replication_lag', "{{pod}}")], unit="s", w=8)
dashboard.bars("Database size", 'max by (datname) (cnpg_pg_database_size_bytes{datname!~"template.*"})', "{{datname}}", unit="bytes", w=8, thresholds=[GREEN])
dashboard.ts("Postgres memory", [('sum by (pod) (container_memory_working_set_bytes{namespace="databases",container="postgres"})', "{{pod}}")], unit="bytes", w=8, desc="Limit is 1 GiB per instance.")
dashboard.row("VictoriaMetrics")
dashboard.stat("Active series", 'sum(vm_cache_entries{type="storage/hour_metric_ids"})', color_mode="value", desc="Series that received samples in the last hour.")
dashboard.stat("Samples/s", 'sum(rate(vm_rows_inserted_total[5m]))', unit="short", color_mode="value", decimals=0)
dashboard.stat("Data on disk", 'sum(vm_data_size_bytes)', unit="bytes", color_mode="value")
dashboard.stat("Free disk (local-path LV)", 'min(vm_free_disk_space_bytes)', unit="bytes", thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 10e9}, {"color": "green", "value": 30e9}])
dashboard.stat("VM memory", 'sum(process_resident_memory_bytes{job="victoriametrics"})', unit="bytes", thresholds=[GREEN, {"color": "orange", "value": 700e6}, {"color": "red", "value": 900e6}],
       desc="Limit is 1 GiB.")
dashboard.stat("New series (1h)", 'sum(increase(vm_new_timeseries_created_total[1h]))', color_mode="value", decimals=0, desc="High churn here means a label keeps changing.")
dashboard.ts("Ingestion rate", [('sum(rate(vm_rows_inserted_total[%s]))' % RI, "samples/s")], unit="short", w=8)
dashboard.ts("Series per scrape job", [('sum by (job) (scrape_samples_post_metric_relabeling)', "{{job}}")], w=8, stack=True)
dashboard.ts("Slowest scrapes", [('topk(5, max by (job) (scrape_duration_seconds))', "{{job}}")], unit="s", w=8)
dashboard.table("Scrape targets down", 'up == 0', [("job", "Job"), ("instance", "Target"), ("namespace", "Namespace"), ("pod", "Pod")], w=24, h=6, desc="Empty is good.")
