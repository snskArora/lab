# Airflow

Apache Airflow 3.2.2 (official chart 1.22.0) in namespace `airflow`, deployed by Flux from this folder.

| Piece | Setup |
|---|---|
| UI | https://airflow.lab.sanskararora.in (user `admin`, password in `passwords.json` under `airflow`) |
| Executor | LocalExecutor: tasks run inside the scheduler pod. Pods: api-server, scheduler, dag-processor, statsd, all on msi |
| Database | CNPG cluster `pg`, database `airflow`, role `airflow`; tables live in schema `airflow` (the role's default search path), over TLS |
| DAGs | git-sync pulls https://github.com/snskArora/airflow_homeserver_dags (branch `main`, folder `dags/`) every 60 s |
| Task logs | Airflow UI for 2 hours (pod-local disk, capped at 256Mi, gone if the scheduler restarts); VictoriaLogs for 14 days |
| Metrics | statsd exporter, scraped by VictoriaMetrics |

## Adding or changing a DAG

Push to `main` of the DAG repo. git-sync picks it up within a minute and the dag-processor parses it; import errors show at the top of the DAG list in the UI. The image is the stock `apache/airflow`, so only the standard providers are available; a DAG that needs extra Python packages needs a custom image first.

## Task logs in VictoriaLogs

Every task log line is also written to the scheduler's stdout, so it lands in VictoriaLogs with the other pod logs. In Grafana -> Explore -> VictoriaLogs, or https://logs.lab.sanskararora.in:

```
kubernetes.namespace_name:airflow kubernetes.container_name:scheduler
```

## Secrets

[scripts/12-airflow-secrets.sh](../../../scripts/12-airflow-secrets.sh) creates the Secrets the chart reads: the database connection (from the `airflow` Postgres password), the fernet key that encrypts connections and variables in the database, the session and token signing keys, and the admin password. Values are generated once into `passwords.json` and reused on every run. Run it before the first deploy and again after a password change.

- Never change `fernet_key` casually: connections and variables already stored would become unreadable.
- Airflow creates the admin user only once. To change the password, change it in the UI (Your Profile), put the new value in `passwords.json`, re-run the script.

## Known gaps

- No login wall beyond Airflow's own login; LAN only.
- No triggerer, so deferrable operators and sensors will not run until it is enabled.
- Stock image only (no extra Python packages).
