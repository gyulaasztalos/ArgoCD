# ArgoCD — HomeLab GitOps

k3s HA cluster on 4× Raspberry Pi 5, managed entirely via GitOps. Entry point: `bootstrap/app-of-apps.yaml` → `apps/`.

## Cluster

- **Nodes:** 1 worker Archer `10.10.50.21`, 3 control-plane Lana/Pam/Cheryl `10.10.50.22-24`, KubeVIP API `10.10.50.20`
- **Networking:** MetalLB BGP `10.10.50.30-39`, Traefik `.30`, Pi-Hole `.31`, Flannel + Multus
- **Storage:** Longhorn (HA), CloudNativePG (PostgreSQL HA), Redis HA
- **Secrets:** Sealed Secrets + 1Password-Connect + External Secrets Operator + Reflector
- **Auth:** Authentik (OIDC/forward auth for Traefik)
- **Monitoring:** kube-prometheus-stack, Loki, Alloy

## Application Manifest Pattern

Each `apps/<name>/application.yaml` is an ArgoCD `Application`. Two patterns:

- **Multi-source (Helm)** — most apps: one source refs this repo (`ref: config`) for `values.yaml`, another pulls the Helm chart from upstream. Chart version pinned in `targetRevision`, updated by Renovate.
- **Single-source (plain manifests)** — apps *without* an upstream chart: one source, `path: apps/<name>/install` pointing at a kustomize dir of hand-written manifests. Use this instead of forcing a chart. (e.g. `apps/influxdb`.)

## Adding or Modifying an App

1. Create `apps/<name>/application.yaml` (copy existing as template)
2. Add `values.yaml` if needed
3. Register in `apps/kustomization.yaml`
4. Push to `main` — ArgoCD auto-syncs (`selfHeal: true`, `prune: true`)

## Bootstrap (Fresh Cluster)

```bash
# 1. Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd --namespace argocd --values bootstrap-values.yaml

# 2. Apply sealed-secrets master key BEFORE bootstrapping (stored in 1Password)
kubectl apply -f sealed-secrets-key.yaml

# 3. Trigger app-of-apps
kubectl apply -f bootstrap/app-of-apps.yaml

# 4. After bootstrap, apply manual EndpointSlice for Unifi redirect
kubectl apply -f apps/traefik/post-install/unifi-redirect.yaml
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

- `EndpointSlice` for `unifi-redirect` must be applied manually — ArgoCD intentionally ignores EndpointSlices
- Paperless-NGX requires a manual SQL command after first install — see `apps/paperless-ngx/README.md`
- High memory pressure on rPi hardware; OOM kills possible under full load
