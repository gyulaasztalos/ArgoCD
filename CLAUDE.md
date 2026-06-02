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

Each `apps/<name>/application.yaml` is an ArgoCD `Application`. Most use the **multi-source pattern**: one source refs this repo (`ref: config`) for `values.yaml`, another pulls the Helm chart from upstream. Chart version pinned in `targetRevision`, updated by Renovate.

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

## Known Constraints

- `EndpointSlice` for `unifi-redirect` must be applied manually — ArgoCD intentionally ignores EndpointSlices
- Paperless-NGX requires a manual SQL command after first install — see `apps/paperless-ngx/README.md`
- High memory pressure on rPi hardware; OOM kills possible under full load
