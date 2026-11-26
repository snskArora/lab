from dashlib import Board, RI, GREEN, bad_if_above

# Heuristic for "looks like an error": a level field, klog E-lines (E1127 12:00:00...), or the words in the message.
ERRORS = r'(level:~"(?i)^(error|err|fatal|panic|crit|critical|e)$" or _msg:~"(?i)\\b(error|fatal|panic)\\b" or _msg:~"^E\\d{4} ")'

dashboard = Board("homelab-logs", "Homelab / Logs", "Log volume and errors from VictoriaLogs, and the health of the Fluent Bit -> VictoriaLogs pipeline.")

dashboard.row("Pipeline health")
dashboard.stat("Lines ingested/s", 'sum(rate(vl_rows_ingested_total[5m]))', color_mode="value", decimals=1)
dashboard.stat("Lost lines (1h)", '(sum(increase(vl_rows_dropped_total[1h])) or vector(0)) + (sum(increase(fluentbit_output_dropped_records_total[1h])) or vector(0))',
               thresholds=bad_if_above(1), decimals=0, desc="Lines VictoriaLogs rejected plus lines Fluent Bit gave up on. Should stay 0.")
dashboard.stat("Disk vs 10 GiB cap", 'sum(vl_data_size_bytes) / (10 * 1024 * 1024 * 1024)', unit="percentunit",
               thresholds=[GREEN, {"color": "orange", "value": 0.8}, {"color": "red", "value": 0.95}], desc="Beyond the cap VictoriaLogs deletes the oldest days.")
dashboard.stat("Oldest log", 'time() - min(vl_storage_log_min_timestamp_seconds)', unit="s", color_mode="value", desc="How far back search reaches; tops out at 14 days.")
dashboard.stat("New streams (24h)", 'sum(increase(vl_streams_created_total[24h]))', color_mode="value", decimals=0,
               desc="One per new container or node service; a jump means a stream field started changing.")
dashboard.stat("Lines too long (24h)", 'sum(increase(vl_too_long_lines_skipped_total[24h])) or vector(0)', thresholds=bad_if_above(1, "orange"), decimals=0)
dashboard.ts("Fluent Bit records read", [('sum by (node, name) (rate(fluentbit_input_records_total{name=~"pods|journald"}[%s]))' % RI, "{{node}} {{name}}")], w=8)
dashboard.ts("Fluent Bit records sent", [('sum by (node, name) (rate(fluentbit_output_proc_records_total[%s]))' % RI, "{{node}} {{name}}")], w=8)
dashboard.ts("Fluent Bit retries and errors", [('sum by (node, name) (rate(fluentbit_output_retries_total[%s]))' % RI, "{{node}} {{name}} retries"),
                                               ('sum by (node, name) (rate(fluentbit_output_errors_total[%s]))' % RI, "{{node}} {{name}} errors")],
             w=8, desc="Retries happen while VictoriaLogs restarts; errors that keep growing need a look.")

dashboard.row("Volume")
dashboard.logs_ts("Pod log lines per namespace", 'kubernetes.namespace_name:* | stats by (kubernetes.namespace_name) count() lines', "{{kubernetes.namespace_name}}")
dashboard.logs_ts("Node service lines", '_HOSTNAME:* | stats by (_HOSTNAME, _SYSTEMD_UNIT, _TRANSPORT) count() lines', "{{_HOSTNAME}} {{_SYSTEMD_UNIT}} {{_TRANSPORT}}",
                  desc="journald: MicroK8s services and kernel messages per node.")
dashboard.logs_bars("Noisiest pods (last hour)", '_time:1h kubernetes.pod_name:* | stats by (kubernetes.namespace_name, kubernetes.pod_name) count() lines | sort by (lines desc) | limit 10',
                    "{{kubernetes.namespace_name}}/{{kubernetes.pod_name}}", h=9)
dashboard.ts("VictoriaLogs ingest", [('sum(rate(vl_bytes_ingested_total[%s]))' % RI, "raw bytes/s")], unit="Bps", h=9, desc="Uncompressed bytes received; disk use is a fraction of this.")

dashboard.row("Errors")
dashboard.logs_ts("Error-looking pod lines per namespace", f'kubernetes.namespace_name:* {ERRORS} | stats by (kubernetes.namespace_name) count() errors', "{{kubernetes.namespace_name}}",
                  w=24, desc="Heuristic: a level field of error/fatal/panic, klog E-lines, or the words error/fatal/panic in the message.")
dashboard.logs("Recent error-looking pod lines", f'kubernetes.namespace_name:* {ERRORS}', h=12)
dashboard.logs("Node warnings (journald priority warning and worse)", '_HOSTNAME:* PRIORITY:<=4', h=10, desc="Kernel and MicroK8s service messages at priority 0 (emergency) to 4 (warning).")
