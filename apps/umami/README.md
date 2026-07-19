# Umami — self-hosted, cookieless web analytics

Privacy-friendly visitor analytics for the public **cake-order** site
(anitatortai.hu). No cookies, no cross-site tracking, no personal data — just
aggregate counts, stored entirely in our own PostgreSQL. Runs internally behind
Authentik; the tracking script is exposed publicly through the cake-order
Cloudflare tunnel.

- **Image**: `umamisoftware/umami:3.2.0` (Docker Hub, multi-arch — amd64 + arm64
  for the rPi5). The v3 "unified" image auto-detects the DB from `DATABASE_URL`.
- **Namespace**: `umami`
- **Dashboard**: `https://umami.local.asztalos.net` (internal, Authentik-gated)
- **Public tracker**: `https://stats.anitatortai.hu` (path-restricted — see §4)

---

## 1. What's in this app

| File | Purpose |
|------|---------|
| `application.yaml` | Argo CD `Application` (registered in `apps/kustomization.yaml`) |
| `install/postgresql-database.yaml` | CNPG `Database` CRD — creates the `umami` DB (UTF-8) |
| `install/umami-postgres-secret.yaml` | ESO → `DATABASE_URL` composed from the CNPG role creds |
| `install/umami-app-secret.yaml` | ESO → `APP_SECRET` (signs Umami auth tokens) |
| `install/deployment.yaml` | The Umami Deployment (non-root, rPi-sized) |
| `install/service.yaml` | ClusterIP `:80 → :3000` |
| `install/ingressroute.yaml` | Internal Traefik IngressRoute behind Authentik |

Plus wiring outside this folder:

- `apps/cnpg/post-install/postgresql-cluster.yaml` — a **managed role** `umami`.
- `apps/cnpg/pre-install/umami-postgres-password.yaml` — ESO that materializes the
  role's `username`/`password` secret in the `databases` namespace.

## 2. Prerequisites — 1Password items

Create these two items in the vault backing the `ClusterSecretStore`
(`onepassword-connect`), then External Secrets Operator syncs them in.

1. **`umami-postgres-password`** — the Postgres role credentials. Fields:
   - `username` = `umami`
   - `password` = a strong random password
   > Backs both the CNPG managed role (pre-install ESO in `databases`) **and** the
   > `DATABASE_URL` composed in the `umami` namespace. Same item, two consumers.

2. **`umami-app`** — Umami's `APP_SECRET`. Field:
   - `credential` = `openssl rand -base64 32`
   > The ExternalSecret maps 1Password property **`credential`** → the k8s secret
   > key `app_secret`. Keep the field name `credential`.

## 3. Deploy

Everything is GitOps — Argo CD syncs on merge. Order of operations the first time:

1. Ensure the CNPG cluster picks up the new **`umami` managed role**
   (`apps/cnpg/post-install`) and the **pre-install** ESO created the
   `umami-postgres-password` secret in `databases`. CNPG then provisions the role
   and the `umami` database.
2. Argo CD syncs `apps/umami` (namespace auto-created). ESO fills
   `umami-postgres-secret` and `umami-app-secret`; the pod starts, runs its own
   schema migrations against the empty DB, and passes `/api/heartbeat`.
3. Validate locally before pushing:
   ```bash
   kubectl kustomize apps/umami/install >/dev/null && echo OK
   ```

## 4. First login & wiring the tracker into cake-order

1. Open `https://umami.local.asztalos.net` (Authentik will gate you first).
2. Log in with Umami's default **`admin` / `umami`** and **immediately change the
   password** (Settings → Profile). See §6 on why we keep Umami's own login.
3. Create a website: **Settings → Websites → Add**. Name it and set the domain to
   `anitatortai.hu`.
4. Copy its **Website ID** (a UUID).
5. In the ArgoCD **cake-order** deployment
   (`apps/cake-order/install/deployment.yaml`), set:
   ```yaml
   - name: ANALYTICS_SRC          # already set
     value: https://stats.anitatortai.hu/script.js
   - name: ANALYTICS_WEBSITE_ID   # starts empty — paste the UUID here
     value: "<website-id>"
   ```
   cake-order only renders the tracker (and widens its CSP to the Umami origin)
   when **both** are non-empty, so nothing tracks until this is filled in.

### Public tracking exposure (required for step 4 to work)

Anonymous visitors' browsers must reach `stats.anitatortai.hu/script.js` and
`POST /api/send`. Expose it via the **cake-order Cloudflare tunnel** as an extra
public hostname → `http://umami.umami.svc.cluster.local:80`, and allow the
cake-order `cloudflared` egress to the `umami` namespace in the NetworkPolicy.

> **Security — path-restrict the public route.** Only `/script.js` (the tracker)
> and `/api/send` (event collection; Umami v3 — this replaced v1's `/api/collect`)
> need to be public. Restrict the tunnel/ingress for `stats.anitatortai.hu` to
> exactly those paths so the **dashboard and management API are never reachable
> from the internet**. Use an **anchored** regex so nothing longer slips through:
>
> ```
> ^/(script\.js|api/send)$
> ```
>
> (Anchored on purpose — an unanchored `^/(script\.js|api/send)` would also match
> `/api/send/…`, `/script.js.map`, etc. A Traefik `PathPrefix` can't be anchored,
> so prefer `PathRegexp` or the tunnel Path field.) Umami's own login still guards
> the dashboard as defence-in-depth. Add the `stats` DNS record in the
> terraform-project repo (see that repo's Cloudflare guide).

## 5. Configuration (env)

| Env | Value | Notes |
|-----|-------|-------|
| `DATABASE_TYPE` | `postgresql` | |
| `DATABASE_URL` | from `umami-postgres-secret` | `postgresql://…@postgres-rw.databases…/umami` |
| `APP_SECRET` | from `umami-app-secret` | signs auth tokens |
| `DISABLE_TELEMETRY` | `1` | opt out of Umami's own phone-home (also matches the cluster's restricted egress) |

## 6. Why we do **not** set `DISABLE_LOGIN`

Umami v3's `DISABLE_LOGIN` does **not** cleanly auto-authenticate — it leaves the
dashboard returning *"access denied"* on its API calls. So we keep Umami's native
login (change the default password!) and put Authentik in front on the internal
route. Bonus: because login stays enabled, even if the public tracking route were
ever misconfigured to reach the dashboard, it would still require Umami
credentials.

## 7. Troubleshooting

- **Pod CrashLoop / "access denied" in the dashboard** — check `APP_SECRET` is
  present (`umami-app-secret`) and that `DISABLE_LOGIN` is **not** set.
- **`/api/heartbeat` failing / DB errors** — the `umami` role or database isn't
  provisioned yet; check the CNPG cluster status and that both the pre-install ESO
  (`databases/umami-postgres-password`) and the in-namespace
  `umami-postgres-secret` resolved.
- **No data showing** — confirm `ANALYTICS_WEBSITE_ID` is set in cake-order and
  matches the site's UUID, that `stats.anitatortai.hu/script.js` loads publicly,
  and that the cake-order CSP lists the Umami origin (it does automatically once
  both analytics envs are set).
- **ESO secret empty** — verify the 1Password field names: `username`/`password`
  on `umami-postgres-password`, and **`credential`** on `umami-app`.
