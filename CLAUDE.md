# ArgoCD — HomeLab GitOps

k3s HA cluster on 4× Raspberry Pi 5, managed entirely via GitOps. Entry point: `bootstrap/app-of-apps.yaml` → `apps/`.

## Cluster

- **Nodes:** 1 worker Archer `10.10.50.21`, 3 control-plane Lana/Pam/Cheryl `10.10.50.22-24`, KubeVIP API `10.10.50.20`
- **Networking:** MetalLB BGP `10.10.50.30-39`, Traefik `.30`, Pi-Hole `.31`, Flannel (Multus decommissioned — `resources/unused/multus/`)
- **Storage:** Longhorn (HA), CloudNativePG (PostgreSQL HA), Redis HA
- **Secrets:** Sealed Secrets + 1Password-Connect + External Secrets Operator + Reflector
- **Auth:** Authentik (OIDC/forward auth for Traefik)
- **Monitoring:** kube-prometheus-stack, Loki, Alloy

## Application Manifest Pattern

Each `apps/<name>/application.yaml` is an ArgoCD `Application`. Three patterns:

- **Upstream chart (multi-source Helm)** — infrastructure and apps with a maintained upstream chart (traefik, longhorn, authentik, monitoring, …): one source refs this repo (`ref: config`) for `values.yaml`, another pulls the chart from upstream. Chart version pinned in `targetRevision`, updated by Renovate.
- **homelab-charts wrapper** — apps *without* a fitting upstream chart (paperless-ngx, influxdb, homepage, the exporters, …): the chart lives in the sibling repo [homelab-charts](https://github.com/gyulaasztalos/homelab-charts) (checked out at `../homelab-charts`) as a thin wrapper over its `common` library chart, which renders the homelab conventions (StatefulSet for RWO state, ExternalSecrets, Traefik IngressRoute + authentik middlewares, ServiceMonitor, CNPG `Database`, app-owned Middleware). Sources: `ref: config`, then `path: charts/<name>` at `targetRevision: main` with `valueFiles: $config/apps/<name>/values.yaml`, plus an optional `apps/<name>/post-install` source for Grafana dashboards, PrometheusRules and non-mandatory cross-namespace objects. `apps/whoami` is the minimal reference. Prefer this over a community chart that fights the conventions (plain `Ingress`, Deployment on an RWO PVC, inline secrets). homelab-charts' own `CLAUDE.md` holds the values contract and test gates.
- **Kustomize over a chart** — only when the chart's rendered output must be patched and no value exposes the field: `apps/<name>/kustomization.yaml` renders the chart via `helmCharts:` (version bumped by Renovate's kustomize manager) plus `patches:`, and the Application points `path:` at `apps/<name>`. Relies on `kustomize.buildOptions: --enable-helm` in argocd-cm. Keep `releaseName` equal to the old Helm release name, or every resource is renamed and the old ones pruned. Diff the render against the old Helm render before switching. (e.g. `apps/metallb`, for the frr liveness probe.)

Plain hand-written manifests (`path: apps/<name>/install`) are retired for apps — every former `install/` app was migrated to homelab-charts. Only `apps/cluster-defaults` (cluster-wide LimitRange, not an app) still uses it.

## Adding or Modifying an App

1. Create `apps/<name>/application.yaml` (copy existing as template)
2. Add `values.yaml` if needed
3. Register in `apps/kustomization.yaml`
4. Push to `main` — ArgoCD auto-syncs (`selfHeal: true`, `prune: true`)

A homelab-charts app spans **two repos**: add `charts/<name>/` there (generic `values.yaml` on `example.com`) and the Application + tailored `values.yaml` here. Push homelab-charts **first** — the Application tracks `charts/<name>` on `main` and errors until the path exists. An app with in-app OIDC also needs a provider + application in the Authentik blueprints (`apps/authentik/pre-install/`) and its client-secret field added to the 1Password item `authentik-blueprint-secrets` **before** pushing — a missing property fails that whole ExternalSecret, freezing every provider.

## Bootstrap (Fresh Cluster)

```bash
# 1. Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
#    bootstrap-values.yaml must set configs.cm."kustomize.buildOptions": --enable-helm,
#    or apps/metallb (kustomize-over-chart) fails to render until the argocd app syncs.
helm install argocd argo/argo-cd --namespace argocd --values bootstrap-values.yaml

# 2. Apply sealed-secrets master key BEFORE bootstrapping (stored in 1Password)
kubectl apply -f sealed-secrets-key.yaml

# 3. Trigger app-of-apps
kubectl apply -f bootstrap/app-of-apps.yaml

# 4. After bootstrap, apply manual EndpointSlice for Unifi redirect
kubectl apply -f apps/traefik/post-install/unifi-redirect.yaml

# 5. Apply manual Endpoints for the etcd ServiceMonitor (k3s embeds etcd, so the
#    chart's Service selector matches nothing). Endpoints, NOT EndpointSlice —
#    Prometheus defaults to serviceDiscoveryRole: Endpoints.
kubectl apply -f apps/monitoring/post-install/kube-etcd-endpoints.yaml
```

## Sealed Secrets

```bash
kubeseal --controller-name sealed-secrets -o yaml < secret.yaml > sealed-secret.yaml
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-backup.key
```

## Renovate

Auto-updates `targetRevision` and image tags. Minor/patch: auto-merged weekdays 05:00–16:00 + weekends (Europe/Budapest). Major: PR only.

## Conventions

### ExternalSecret `secretKey` names use underscores
`spec.data[].secretKey` is referenced from `spec.target.template` as a **Go template field** (`{{ .my_token }}`), so it may only contain letters, digits, and underscores — `my-token` fails to render with `bad character U+002D '-'`. The manifest is valid YAML and ArgoCD syncs it happily; the Secret just never populates, and the resource status shows only `could not update secret` / `SecretSyncedError`. Get the real error from events:
```bash
kubectl get events -n <ns> --field-selector involvedObject.name=<externalsecret-name>
```
(`{{ index . "my-token" }}` works around a hyphen, but keep to underscores for consistency.)

### Grafana provisioning (kube-prometheus-stack sidecars)
- **Dashboards:** ship a ConfigMap labeled `grafana_dashboard: "1"` with a `grafana_folder` annotation, generated via kustomize `configMapGenerator`. The dashboards sidecar has `searchNamespace: ALL` — discovered in any namespace.
- **Datasources:** ship a Secret labeled `grafana_datasource: "1"` (an ExternalSecret rendering the datasource YAML works well for token-bearing sources). The **datasource** sidecar's `searchNamespace` is set to `ALL` in `apps/monitoring/values.yaml` so app-owned datasources are found outside the `monitoring` namespace — it is NOT `ALL` by default in the chart.

### Prometheus auto-discovery
`serviceMonitorSelectorNilUsesHelmValues: false` (+ empty selectors) means **all** `ServiceMonitor` and `PrometheusRule` objects are auto-discovered regardless of labels/namespace — no `release:` label needed. Control metric cardinality with ServiceMonitor `metricRelabelings` (drop noisy high-cardinality label values at scrape time) — rPi is memory-constrained.

### Authentik: SSO for humans, tokens for machines
Guard the **browser** path by attaching the `traefik/authentik` forward-auth + `traefik/default-headers` middlewares to the IngressRoute. **API** clients (HA, Grafana, exporters) should hit the in-cluster `Service` directly — that bypasses Traefik/Authentik entirely, so authenticate them with API tokens. Apps whose own login can't delegate to OIDC still work: Authentik just gates who reaches the UI.

### Stateful workloads on rPi
Single-writer databases use a **StatefulSet** (not Deployment) with a Longhorn RWO `volumeClaimTemplate`; set pod `securityContext.fsGroup` to the image's uid/gid so the non-root process can write. Persist only real state dirs — don't PVC a config dir that holds no state (GitOps drift). Auto-setup via env vars (e.g. `DOCKER_INFLUXDB_INIT_*`) beats manual post-install exec steps where the image supports it.

## Known Constraints

- `EndpointSlice` for `unifi-redirect` and `Endpoints` for `kube-etcd` must be applied manually — `argocd-cm` excludes both kinds, so anything a chart renders of those kinds is silently dropped. The etcd one fails invisibly: Service and ServiceMonitor exist, but the dashboard is blank and all 15 etcd alerts can never fire.
- Paperless-NGX requires a manual SQL command after first install — see `apps/paperless-ngx/README.md`
- High memory pressure on rPi hardware; OOM kills possible under full load
- Pi 5 `macb` NIC can wedge its transmit queue (`NETDEV WATCHDOG: transmit queue 0 timed out`) — the node stays up with carrier and IP intact but sends nothing, so it is unreachable and cannot be fixed remotely. A **switch port bounce does not clear it**; only a full interface deconfigure/reconfigure does. Tell-tale: ARP *and* IPv6 NDP both `INCOMPLETE` from another node on the same segment. The driver usually self-recovers in ~5s; `nic-watchdog.service` (Ansible-Playbooks, `roles/rpi5_cluster`) handles the cases where it does not.
