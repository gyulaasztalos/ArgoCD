# InfluxDB (refluxdb — unlocked InfluxDB 3 Core)

Long-term storage for Home Assistant sensor data (fridge temperatures / HACCP), browsed in Grafana.

- **Image:** `ghcr.io/refluxdb/refluxdb` — community fork of InfluxDB 3 Core with the artificial
  limits removed (query window, cardinality, retention, request size). Apache-2.0 / MIT, no license key.
- Single-node binary, file object store on a Longhorn volume.
- **Native HTTP API port:** `8181`.

## Layout

```
install/
  statefulset.yaml   # single-replica StatefulSet, Longhorn RWO data volume at /var/lib/influxdb3
  service.yaml       # ClusterIP :8181
  ingressroute.yaml  # https://influxdb.local.asztalos.net via traefik-external
  kustomization.yaml
```

## One-time bootstrap: create an admin token

InfluxDB 3 Core (v3.2+) starts with **authentication enabled**. On first start there is no token —
you must create one imperatively (analogous to the paperless-ngx post-install step). ArgoCD does not
do this for you.

```bash
# 1. Exec into the running pod
kubectl exec -it -n influxdb influxdb-0 -- sh

# 2. Create an admin token (prints the token ONCE — copy it immediately)
influxdb3 create token --admin

# 3. Store it in 1Password. If you want HA/Grafana to use scoped tokens later,
#    create resource tokens with `influxdb3 create token --help`.
```

Then create the database HA will write to:

```bash
influxdb3 create database homeassistant --token <ADMIN_TOKEN>
```

> **Simpler alternative (internal-only, no auth):** uncomment `--without-auth` in
> `statefulset.yaml`. Anyone who can reach the service can read/write. Acceptable for a
> LAN-only browse copy; do **not** expose it publicly in that mode.

## Home Assistant wiring

HA is the source of truth (SQLite on the Yellow). This InfluxDB is a **parallel export sink** — a
disposable browse copy. HA keeps working if the cluster is down.

> **The HACCP retention lives on the HA side, not here.** Set the recorder to keep full-resolution
> history for longer than your required window (default is only 10 days). In `configuration.yaml`
> on the Yellow:
>
> ```yaml
> recorder:
>   purge_keep_days: 45   # > 1 month HACCP window + buffer; SQLite stays authoritative, cluster-independent
> ```
>
> This InfluxDB copy is disposable — if it's ever lost, the record of truth is still HA's SQLite
> (backed up to NAS → Backblaze B2).

`configuration.yaml` on the Yellow:

```yaml
influxdb:
  api_version: 2                       # InfluxDB 3 speaks the v2 write API
  host: influxdb.local.asztalos.net
  port: 443
  ssl: true
  token: !secret influxdb_token        # the admin (or a write-scoped) token
  organization: default                # ignored by v3 but the integration requires a value
  bucket: homeassistant                # = the database created above
  max_retries: 10                      # buffer across brief cluster blips
  include:
    entities:
      - sensor.fridge_temperature       # keep the sink lean — only what you want long-term
```

## Grafana (auto-provisioned)

Datasource and dashboard are shipped as code — no manual Grafana clicking:

- `install/grafana-datasource.yaml` — an ExternalSecret that renders a labeled
  (`grafana_datasource: "1"`) Secret. The Grafana **datasources sidecar** discovers it.
  - Requires `sidecar.datasources.searchNamespace: ALL` in `apps/monitoring/values.yaml`
    (added alongside this app) so it's found outside the `monitoring` namespace.
  - Pulls the token from 1Password item **`influxdb`**, property **`token`**. Store the
    admin token there during the bootstrap step above, or the ExternalSecret stays `SecretSyncedError`.
  - Uses **InfluxQL** over the in-cluster service (`http://influxdb.influxdb.svc:8181`) — plain
    HTTP/1.1. (SQL/FlightSQL mode would need gRPC/HTTP2 and buys nothing for a browse copy.)
- `install/fridge-haccp-dashboard.json` — a HACCP temperature dashboard with two separate
  sections (Fridges, limit 5 °C / Freezers, limit −18 °C), each with current/min/max/mean tiles +
  step-line history over a 30-day default window and its own threshold line. Discovered via
  `grafana_dashboard: "1"`, lands in the **HomeAssistant** folder.

> **Measurement / entity-id caveats:** the HA InfluxDB integration names measurements after
> the unit of measurement — a °C sensor lands in a measurement literally called `°C`, tagged
> with `entity_id` (stored **without** the `sensor.` domain prefix). The dashboard filters on
> the four Zigbee probes of device `0x58e6c5fffe0f58b0`
> (`..._temperature_3` … `_6`) via `entity_id =~ /0x58e6c5fffe0f58b0_temperature_[3-6]/`,
> and every query is `GROUP BY "entity_id"` so each probe is its own series/tile — no averaging
> across probes (each is a separate HACCP control point). If you add probes or a different unit
> (or set `override_measurement`), adjust the `FROM` clause and the regexes in the JSON.
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