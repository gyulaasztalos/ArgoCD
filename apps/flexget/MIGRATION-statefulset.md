# FlexGet: Deployment → StatefulSet Migration

**Status:** planned · **Risk:** low–medium (single RWO config volume) · **Downtime:** ~5–15 min, planned

## Why

For consistency with the homelab controller rule — *an app that owns a writable
RWO volume is a StatefulSet* (see `homelab-charts` `CLAUDE.md`) — flexget moves
from a `Deployment` + static PVC to a `StatefulSet` with a `volumeClaimTemplate`
as part of helmification. This also fixes a latent bug: the old
`Deployment` + `RollingUpdate` on an RWO Longhorn volume causes multi-attach
flaps on every rollout (the new pod attaches before the old releases). A
`StatefulSet` (single replica, ordered update) never overlaps the attachment.

The config volume is not irreplaceable — `config.yml` and the web-UI password come
from 1Password via the ExternalSecret, and are re-seeded on start — but it does
hold flexget's **task database** (`db-config.sqlite`: seen-entries history, task
state). Losing it makes flexget re-evaluate feeds as if fresh, so we **preserve
it** with a volume clone rather than starting empty.

## What actually holds state

| Store | Backing | Contents | Precious? |
|-------|---------|----------|-----------|
| `flexget-config-pvc` (RWO, Longhorn, 350Mi) | `/config` | task DB (`db-config.sqlite`), logs, working files | **Somewhat** — re-buildable, but preserving it avoids re-grabs |
| `config.yml` | ExternalSecret → mounted subPath | feeds/trackers/rules | No — comes from 1Password |
| `FG_WEBUI_PASSWORD` | ExternalSecret → env | web-UI password | No — comes from 1Password |

Only **one** volume is migrated: the Longhorn RWO `flexget-config-pvc`.

## Strategy: Longhorn PVC clone

The StatefulSet (`name: flexget`, volumeClaimTemplate `config`) looks for a PVC
named **`config-flexget-0`**. A StatefulSet **adopts** an existing PVC of that
exact name and never overwrites it. So we pre-create `config-flexget-0` as a
byte-identical Longhorn clone of the current `flexget-config-pvc`; the StatefulSet
then comes up on a copy of the real data — no import step, and the original volume
is never touched until cleanup.

## Pre-flight checklist

- [ ] Announce downtime; confirm no feeds are mid-run in the web UI.
- [ ] Confirm Longhorn has free space for a full clone of `flexget-config-pvc`.
- [ ] Current size is `350Mi` — the volumeClaimTemplate requests the **same**;
      never smaller.
- [ ] Have the old `install/`-based `application.yaml` on a branch for rollback.
- [ ] Set the old PV reclaim policy to **Retain** so nothing is garbage-collected:
      `kubectl patch pv $(kubectl -n flexget get pvc flexget-config-pvc -o jsonpath='{.spec.volumeName}') -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`

## Procedure

### 1. Stop the writer
```bash
kubectl -n flexget scale deploy/flexget --replicas=0
kubectl -n flexget get pod -w      # wait until the pod is gone (RWO volume released)
```

### 2. Clone the Longhorn volume into the StatefulSet's expected PVC name
The StatefulSet will look for **`config-flexget-0`**. Create it as a clone:
```yaml
# clone-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: config-flexget-0
  namespace: flexget
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 350Mi            # == current size
  dataSource:
    kind: PersistentVolumeClaim
    name: flexget-config-pvc     # the existing, populated PVC
    apiGroup: ""
```
```bash
kubectl apply -f clone-pvc.yaml
kubectl -n flexget wait --for=jsonpath='{.status.phase}'=Bound pvc/config-flexget-0 --timeout=300s
```
> Longhorn supports CSI PVC-to-PVC cloning; step 1 must have released the source.
> Alternative: take a Longhorn snapshot of `flexget-config-pvc` and restore it
> into `config-flexget-0`.

### 3. Deploy the StatefulSet (helm chart) — it adopts the clone
Switch the ArgoCD Application to the new multi-source form (chart source with
`controller.type: statefulset`). Because `config-flexget-0` already exists, the
StatefulSet binds it instead of provisioning an empty one.
```bash
kubectl -n flexget get sts flexget
kubectl -n flexget get pod flexget-0 -w
```

### 4. Verify BEFORE cutover
- [ ] `flexget-0` reaches `Running`/ready.
- [ ] Web UI loads at `https://flexget.local.asztalos.net`.
- [ ] `kubectl -n flexget exec flexget-0 -- ls -la /config` shows the task DB and
      logs (i.e. the clone carried the data, not an empty volume).
- [ ] Logs clean (`kubectl -n flexget logs flexget-0`); a manual task run
      recognises already-seen entries (no unexpected re-grabs).

### 5. Cleanup (only after a confidence window, e.g. a few days)
- [ ] Delete the old `flexget-config-pvc` PVC (kept `Retain`ed until now).
- [ ] Delete the retained PV once you are sure.

## Rollback

| Failure point | Action |
|---------------|--------|
| Clone won't bind / STS won't start | `kubectl delete sts flexget`; scale the old Deployment back to 1 (`flexget-config-pvc` is untouched). Revert the Application to the `install/` source. |
| STS runs but data looks wrong | Same — the old PVC is intact and `Retain`ed. |

The original `flexget-config-pvc` is **never written to or deleted** during this
procedure until step 5, so rollback is always "point the Application back at the
old Deployment."

## Notes

- Keep the flexget **image version** identical across old and new during the
  controller migration; do any version bump as a separate change.
- `config.yml` and `FG_WEBUI_PASSWORD` are re-seeded from 1Password by the
  ExternalSecret regardless of the volume, so they are never at risk.
