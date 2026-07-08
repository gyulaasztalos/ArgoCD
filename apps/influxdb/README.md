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
  grafana-datasource.yaml     # ExternalSecret → Flux datasource (sidecar-discovered)
  fridge-haccp-dashboard.json # two-section HACCP dashboard (fridges / freezers)
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
