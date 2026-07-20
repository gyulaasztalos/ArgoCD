# InfluxDB 2.x OSS

Long-term storage for Home Assistant sensor data (fridge/freezer temperatures / HACCP), browsed in Grafana.

- **Image:** `influxdb:2.7` — official InfluxDB 2.x OSS. Multi-arch (**linux/arm64** for the rPi 5
  cluster)

## Layout

```
install/
  influxdb-secret.yaml        # ExternalSecret → admin username/password/token (1Password)
  statefulset.yaml            # single-replica StatefulSet; single Longhorn data volume (/var/lib/influxdb2)
  service.yaml                # ClusterIP :8086
  ingressroute.yaml           # https://influxdb.local.asztalos.net via traefik-external + Authentik SSO
  grafana-datasource.yaml            # ExternalSecret → Flux datasource (sidecar-discovered)
  fridge-haccp-dashboard.json        # two-section HACCP dashboard (fridges / freezers)
  influxdb-oss-metrics-dashboard.json# server-health dashboard (Flux, reads _monitoring bucket)
  servicemonitor.yaml                # scrapes /metrics into Prometheus (for the alert rules)
  prometheus-rules.yaml              # PrometheusRule alerts on the scraped /metrics
  haccp-backup-alert-template.yml    # InfluxDB Task (Flux) — backup HACCP temp/gap alarm
  haccp-backup-alert-job.yaml        # PostSync hook: `influx apply`s the Task above
  kustomization.yaml
```

## First-boot setup (automatic — no manual bootstrap)

Unlike v3, InfluxDB 2.x **self-initializes from env vars** on first start
(`DOCKER_INFLUXDB_INIT_MODE=setup`). The entrypoint creates:

- org **`homelab`**
- bucket **`homeassistant`** with **45-day retention** (`DOCKER_INFLUXDB_INIT_RETENTION=45d`)
- the admin user + admin token from the `influxdb-init` secret

On later restarts the entrypoint detects existing data and skips setup. **No `kubectl exec`
bootstrap step.**

### Prerequisite: populate 1Password

Create/confirm a 1Password item named **`influxdb`** with these properties (consumed by
`influxdb-secret.yaml`):

| property | value |
|----------|-------|
| `username` | admin login (e.g. `admin`) |
| `password` | strong admin password (≥ 8 chars) |
| `admin-token` | a strong random token — generate with `openssl rand -hex 32` |

If these are missing the `influxdb-init` ExternalSecret stays `SecretSyncedError` and the pod
won't complete setup.

> ⚠️ **Retention is applied only at bucket creation (first boot).** Changing
> `DOCKER_INFLUXDB_INIT_RETENTION` later has no effect on an already-created bucket — update it
> live instead: `influx bucket update --name homeassistant --retention 45d` (via `kubectl exec`),
> or from the InfluxDB UI.

## Access & authentication (two distinct paths)

InfluxDB 2.x **OSS has no OIDC/OAuth/SSO** — it only knows local username/password + API tokens
(SSO is a Cloud/Enterprise feature). We get the behaviour you want by splitting the two access
paths at the network layer rather than inside InfluxDB:

| Path | Who | Endpoint | Auth |
|------|-----|----------|------|
| **Browser** | you | `https://influxdb.local.asztalos.net` (Traefik ingress) | **Authentik SSO** (forward-auth middleware) → then InfluxDB's own local login |
| **API** | HA, Grafana | `http://influxdb.influxdb.svc:8086` (in-cluster Service) | **API token** only |

- The `authentik` forward-auth Middleware is attached to the IngressRoute, exactly like the other
  protected apps (e.g. nut-exporter). It guards **only** the ingress/browser path.
- HA and Grafana talk to the **in-cluster Service**, which never passes through Traefik/Authentik,
  so their token auth is completely independent of SSO. Nothing to configure for them here.
- **First browser visit = two gates:** Authentik SSO, then InfluxDB's local login form (OSS can't
  delegate its own login to Authentik). After that an InfluxDB session cookie keeps you in.
  This is intentional — Authentik ensures only your SSO identities can even reach the UI.

## Home Assistant wiring

HA is the source of truth (SQLite on the Yellow). This InfluxDB is a **parallel export sink** — a
disposable browse copy. HA keeps working if the cluster is down.

> **Configure via YAML only — skip the UI integration.** The InfluxDB integration is YAML-only; it
> has **no config-flow**, which is why the UI setup shows no field for included entities. Do **not**
> add it from Settings → Devices & Services — that path can't filter entities and would firehose
> *every* entity into InfluxDB, bloating the 45-day bucket. Put the `influxdb:` block below in
> `configuration.yaml` and restart HA Core. The `include:` filter is the whole point — it's what
> keeps the sink scoped to the HACCP probes.

> **The HACCP retention record lives on the HA side too.** Set the recorder to keep full-resolution
> history longer than your required window (default is only 10 days). In `configuration.yaml`
> on the Yellow:
>
> ```yaml
> recorder:
>   purge_keep_days: 45   # > 1 month HACCP window + buffer; SQLite stays authoritative, cluster-independent
> ```
>
> `recorder:` is **not YAML-reloadable** — restart HA Core (not a host reboot) to apply, and note
> it only affects data **going forward**. This InfluxDB copy is disposable — if it's ever lost, the
> record of truth is still HA's SQLite (backed up to NAS → Backblaze B2).

`configuration.yaml` on the Yellow:

```yaml
influxdb:
  api_version: 2
  host: influxdb.local.asztalos.net
  port: 443
  ssl: true
  token: !secret influxdb_token        # the admin-token from 1Password
  organization: homelab                # = DOCKER_INFLUXDB_INIT_ORG
  bucket: homeassistant                # = the auto-created bucket
  max_retries: 10                      # buffer across brief cluster blips
  include:
    entities:
      - sensor.0x58e6c5fffe0f58b0_temperature_3   # LG Fridge
      - sensor.0x58e6c5fffe0f58b0_temperature_4   # Electrolux Fridge
      - sensor.0x58e6c5fffe0f58b0_temperature_5   # LG Freezer
      - sensor.0x58e6c5fffe0f58b0_temperature_6   # Electrolux Freezer
```

## HACCP gap detection (missing readings)

Retention answers "how long is data kept"; it says nothing about **holes**. A month of data with a
silent 2-day gap fails an audit as surely as an over-temperature reading. Because all four probes
ride one Zigbee device (`0x58e6c5fffe0f58b0`), a single device dropout loses **all** control points
at once — so gap detection matters more here than the threshold alert.

Gap detection must live on the **HA side**: the temperature data goes to InfluxDB, not Prometheus,
so a cluster-side Prometheus rule can't see per-probe readings. HA also keeps working if the cluster
is down. Add to `configuration.yaml` (or an `automations.yaml`) on the Yellow:

```yaml
# Fires when ANY of the four probes stops updating for 15 min (Zigbee drop, sensor dead, HA issue).
automation:
  - alias: "HACCP - fridge/freezer probe stopped reporting"
    trigger:
      - platform: state
        entity_id:
          - sensor.0x58e6c5fffe0f58b0_temperature_3
          - sensor.0x58e6c5fffe0f58b0_temperature_4
          - sensor.0x58e6c5fffe0f58b0_temperature_5
          - sensor.0x58e6c5fffe0f58b0_temperature_6
        to: "unavailable"
        for: { minutes: 15 }
      # also catch a probe that goes stale without flipping to 'unavailable'
      - platform: template
        value_template: >
          {{ now() - states.sensor.0x58e6c5fffe0f58b0_temperature_3.last_updated > timedelta(minutes=15)
          or now() - states.sensor.0x58e6c5fffe0f58b0_temperature_4.last_updated > timedelta(minutes=15)
          or now() - states.sensor.0x58e6c5fffe0f58b0_temperature_5.last_updated > timedelta(minutes=15)
          or now() - states.sensor.0x58e6c5fffe0f58b0_temperature_6.last_updated > timedelta(minutes=15) }}
    action:
      - service: notify.notify   # replace with your notifier
        data:
          title: "HACCP ALERT: refrigeration probe not reporting"
          message: >
            A fridge/freezer probe has not reported for 15+ minutes — temperature logging has a gap.
```

> Tune `for:` to your HACCP plan's tolerance. Shorter = noisier, longer = bigger allowable gap.
> This is separate from the temperature-threshold alerts (also best done as HA automations, since
> HA holds the live values). The Prometheus rule below is a **complementary** backstop only.

## Grafana (auto-provisioned)

Datasource and dashboard are shipped as code — no manual Grafana clicking:

- `install/grafana-datasource.yaml` — an ExternalSecret that renders a labeled
  (`grafana_datasource: "1"`) Secret. The Grafana **datasources sidecar** discovers it.
  - Requires `sidecar.datasources.searchNamespace: ALL` in `apps/monitoring/values.yaml`
    (added alongside this app) so it's found outside the `monitoring` namespace.
  - Reuses the **admin token** from 1Password item **`influxdb`**, property **`admin-token`**.
  - Uses **Flux** (the native v2 query language) over the in-cluster service
    (`http://influxdb.influxdb.svc:8086`) — no DBRP/InfluxQL compatibility mapping needed.
- `install/fridge-haccp-dashboard.json` — a HACCP temperature dashboard with two separate
  sections (Fridges, limit 5 °C / Freezers, limit −18 °C), each with current/min/max/mean tiles +
  step-line history over a 30-day default window and its own threshold line. Discovered via
  `grafana_dashboard: "1"`, lands in the **HomeAssistant** folder.
- `install/influxdb-oss-metrics-dashboard.json` — **server-health** dashboard built **only on the
  metrics actually present at `/metrics`**, using the **Prometheus** datasource (uid `prometheus`).
  No `_monitoring` bucket, no Flux. Panels: up / go version / goroutines / heap / threads; HTTP
  request rate by status & by path, latency p50/p90/p99, 4XX-5XX error ratio (from the
  `http_api_request_duration_seconds` histogram); Go memory, GC pause & rate, allocation rate; and
  BoltDB read/write ops. (The popular grafana.com InfluxDB dashboards were discarded — they assume
  the Flux `_monitoring` path, which this deployment intentionally does not use.)

## Server monitoring (Prometheus alerts)

Two separate monitoring paths — this is deliberate:

- **Dashboard health data → Flux/`_monitoring` bucket** (the dashboard above). Rich, InfluxDB-native.
- **Alerting → Prometheus** via `servicemonitor.yaml`, which scrapes the in-cluster Service
  `/metrics` (never through Traefik/Authentik, so no auth needed) into kube-prometheus-stack.
  `serviceMonitorSelectorNilUsesHelmValues: false` in the stack means it's auto-discovered — no
  special label required.
  - **Cardinality guard:** InfluxDB templates the `path` label of the request-duration histogram
    across every UI static asset (× `user_agent`). The ServiceMonitor `metricRelabelings` drop
    those series at scrape time, keeping only the bounded `/api/v2/*` paths the rules need —
    important on rPi. There is **no** `http_api_requests_total` counter; the request-duration
    histogram's `_count` is the source of truth for request rates.

`prometheus-rules.yaml` alerts on the scraped metrics (verified names from the InfluxDB metrics
reference):

| alert | condition | why |
|-------|-----------|-----|
| `InfluxDBDown` | `up{job="influxdb"}` absent 5m | sink + browse copy unavailable |
| `InfluxDBRestartLoop` | >3 restarts / 18m | crashloop |
| `InfluxDBHighServerErrorRate` | 5XX rate >5% (via `http_api_request_duration_seconds_count`) | writes/queries failing |
| `InfluxDBWriteAuthErrors` | any 4XX on `/api/v2/write` 15m | **likely bad/expired HA or Grafana token → dropped writes** |
| `InfluxDBNoWritesReceived` | no writes for 20m | **HACCP backstop: HA down / partitioned / token expired → whole-fleet gap** (enable after first write) |
| `InfluxDBWriteLatencyHigh` | p99 `/api/v2/write` >2s | ingestion struggling (I/O on rPi) |
| `InfluxDBMemoryHigh` | working set >90% of limit | OOM risk on rPi |
| `InfluxDBDiskFillingUp` | data PVC <15% free | writes will eventually fail |

> **Measurement / entity-id caveats:** the HA InfluxDB integration names measurements after
> the unit of measurement — a °C sensor lands in a measurement literally called `°C`, with field
> `value` and tag `entity_id` (stored **without** the `sensor.` domain prefix). The Flux queries
> filter `r._measurement == "°C" and r._field == "value"` then match `entity_id`. In Flux each
> `entity_id` stays a separate series, so each probe is its own tile/line — no averaging across
> probes (each is a separate HACCP control point). If you add probes or a different unit (or set
> `override_measurement`), adjust the measurement name and the regexes in the JSON.
>
> **Probe map.** The dashboard has two fully separate sections — fridges and freezers are
> never mixed (different limits, different control points). Each section's queries hard-filter
> its own endpoints and its threshold line matches its own limit:
>
> | section | endpoints | appliances | over-temp limit |
> |---------|-----------|------------|-----------------|
> | Fridges | `_temperature_[34]` | LG Fridge (`_3`), Electrolux Fridge (`_4`) | > 5 °C |
> | Freezers | `_temperature_[56]` | LG Freezer (`_5`), Electrolux Freezer (`_6`) | > −18 °C |
>
> **This mapping is current-setup-specific and will change** (per your note). When appliances
> change, update the `entity_id` regexes in each section's queries and the `displayName`
> field overrides.

## HACCP backup alarm (InfluxDB-native)

The **primary** HACCP alarm is the Home Assistant automation described above ("HACCP gap
detection") — it's already live and notifies directly. `haccp-backup-alert-template.yml` adds a
**secondary, independently-implemented** alarm that runs entirely inside InfluxDB itself, so a
failure on the HA side (automation misfire, HA down, a YAML typo) doesn't leave HACCP silently
unmonitored by a single point of failure.

It's a native InfluxDB **Task** (Flux, scheduled every 15m) — not the UI Checks/Notification-Rules
objects. The Task uses `http.post()` directly, giving full control over the request body, and
POSTs straight to Apprise's REST API (`http://apprise.apprise.svc.cluster.local:8000/notify/apprise`,
no mailrise hop) with the existing `influxdb` tag — routes to Telegram, see
`apps/apprise/install/apprise-config.yaml`. No new pod, no new image: it reuses the bucket, the
running InfluxDB instance, and the already-running apprise service.

> **Why not the Checks/Notification-Rules/Notification-Endpoints UI feature?** That's the
> InfluxDB-intended mechanism for exactly this kind of alarm, and it was tried first. Its HTTP
> Notification Endpoint only lets you configure a URL and an auth method — the outbound JSON body
> is generated internally and isn't documented or customizable. Tested directly against Apprise
> (2026-07-20): `apprise-api` rejected every notification with `Payload lacks minimum requirements
> using KEY: apprise` (HTTP 400) — its `/notify/<key>` endpoint requires a `body` field, and
> whatever InfluxDB sends doesn't include one. A raw Flux Task sidesteps this entirely by
> constructing the exact JSON `apprise-api` expects. **Worth revisiting** if a future InfluxDB 2.x
> release adds a customizable/templatable body for the HTTP notification endpoint — at that point
> the native Checks/Notification-Rules feature would be the simpler choice over hand-written Flux.

It re-implements the same two checks as the HA automation:

- **Threshold** — mean temperature over the last 15m per probe, fridges > 5 °C / freezers > −18 °C
  (same limits as the dashboard — see the probe map above).
- **Deadman** — via Flux's `monitor.deadman()`, any of the four probes silent for 30m+ (a longer
  window than HA's 15m, intentionally: this is a backstop, not the fast path).

### Idempotent apply — no manual bootstrap

`influx apply` is normally one-shot (every run **adds** resources — reapplying without tracking
would create a duplicate Task on every ArgoCD sync). Idempotent reapply requires an InfluxDB
**stack**, so `haccp-backup-alert-job.yaml`'s entrypoint finds-or-creates one itself on every run:
it looks up a stack named `haccp-backup-alert` via `influx stacks --stack-name ...` (a server-side
exact-name filter), creates it with `influx stacks init` if missing, then applies the template
against that stack ID. No manual step, no ID to copy into git — the stack's existence inside
InfluxDB itself *is* the durable "already applied" marker, the same way ArgoCD tracks every other
resource in this repo. From then on, each sync updates the Task in place instead of duplicating
it.
