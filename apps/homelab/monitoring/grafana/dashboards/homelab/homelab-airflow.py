from dashlib import Board, RI, bad_if_above

ALIVE = [{"color": "red", "value": None}, {"color": "green", "value": 0.5}]
NS = 'namespace="airflow", container!=""'

dashboard = Board("homelab-airflow", "Homelab / Airflow",
                  "Airflow 3 on LocalExecutor: scheduler and DAG processor health, DAG runs and tasks, pod resources and logs. Metrics come from the statsd exporter.")

dashboard.row("Health")
dashboard.stat("Scheduler heartbeats/min", 'sum(rate(airflow_scheduler_heartbeat[5m])) * 60', thresholds=ALIVE, decimals=0, desc="Red means the scheduler stopped.")
dashboard.stat("DAG processor heartbeats/min", 'sum(rate(airflow_dag_processor_heartbeat[5m])) * 60', thresholds=ALIVE, decimals=0)
dashboard.stat("DAGs loaded", 'max(airflow_dagbag_size)', color_mode="value", decimals=0)
dashboard.stat("Import errors", 'max(airflow_dag_processing_import_errors)', thresholds=bad_if_above(1), decimals=0,
               desc="DAG files that fail to parse; the UI shows the details above the DAG list.")
dashboard.stat("Running tasks", 'sum(airflow_executor_running_tasks)', color_mode="value", decimals=0)
dashboard.stat("Failed tasks (24h)", 'sum(increase(airflow_ti_failures[24h])) or vector(0)', thresholds=bad_if_above(1), decimals=0)

dashboard.row("Runs and tasks")
dashboard.ts("Tasks finished per hour", [('sum(increase(airflow_ti_successes[1h])) or vector(0)', "success"),
                                         ('sum(increase(airflow_ti_failures[1h])) or vector(0)', "failed")], w=8)
dashboard.ts("DAG run duration (median of recent runs)", [('max by (dag_id) (airflow_dagrun_duration{quantile="0.5"})', "{{dag_id}}")], unit="s", w=8,
             desc="The statsd exporter keeps quantiles for the last 10 minutes of runs, so the line has gaps between runs.")
dashboard.ts("Executor slots", [("sum(airflow_executor_running_tasks)", "running"), ("sum(airflow_executor_queued_tasks)", "queued"),
                                ("sum(airflow_executor_open_slots)", "open")], w=8)
dashboard.table("Runs per DAG (dashboard range)", 'sum by (dag_id) (increase(airflow_dagrun_duration_count[$__range]))',
                [("dag_id", "DAG")], value_name="Runs", sort=("Runs", True))
dashboard.table("Average task duration (dashboard range)",
                'sum by (dag_id, task_id) (increase(airflow_task_duration_sum[$__range])) / sum by (dag_id, task_id) (increase(airflow_task_duration_count[$__range]))',
                [("dag_id", "DAG"), ("task_id", "Task")], value_name="Average", unit="s", sort=("Average", True))

dashboard.row("Scheduler and DAG parsing")
dashboard.ts("Scheduler loop duration", [('max by (quantile) (airflow_scheduler_scheduler_loop_duration{quantile=~"0.5|0.99"})', "p{{quantile}}")], unit="s", w=8)
dashboard.ts("Seconds since each DAG file was parsed", [("max by (dag_file) (airflow_dag_processing_last_run_seconds_ago)", "{{dag_file}}")], unit="s", w=8)
dashboard.ts("Total DAG parse time", [("max(airflow_dag_processing_total_parse_time)", "all files")], unit="s", w=8)

dashboard.row("Pods")
dashboard.ts("Memory by container", [(f"sum by (pod, container) (container_memory_working_set_bytes{{{NS}}})", "{{container}} ({{pod}})")], unit="bytes", w=10)
dashboard.ts("CPU by container (cores)", [(f"sum by (pod, container) (rate(container_cpu_usage_seconds_total{{{NS}}}[{RI}]))", "{{container}} ({{pod}})")], w=10)
dashboard.stat("Container restarts (24h)", 'sum(increase(kube_pod_container_status_restarts_total{namespace="airflow"}[24h])) or vector(0)',
               thresholds=bad_if_above(1, "orange"), decimals=0, w=4, h=8)

dashboard.row("Logs")
dashboard.logs_ts("Log lines per container", "kubernetes.namespace_name:airflow | stats by (kubernetes.container_name) count() lines", "{{kubernetes.container_name}}", w=24, h=6)
dashboard.logs("Warnings, errors and failed tasks",
               'kubernetes.namespace_name:airflow (level:in(warning,error,critical) or final_state:failed or Traceback) -"is deprecated"', h=10,
               desc="Airflow logs JSON, so task lines carry dag_id, task_id and run_id fields; add e.g. dag_id:test_health_check to the query in Explore to narrow it down.")
