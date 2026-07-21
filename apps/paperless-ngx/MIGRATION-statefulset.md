# Paperless-NGX: Deployment → StatefulSet Migration

**Status:** planned · **Risk:** medium (touches the document media/index volume) · **Downtime:** ~10–30 min, planned

## Why

For consistency with the homelab controller rule — *an app that owns a writable
RWO volume is a StatefulSet* (see `homelab-charts` chart docs and `CLAUDE.md`) —
paperless moves from a `Deployment` to a `StatefulSet` as part of helmification.
This is **not** functionally required (a `Deployment` with `strategy: Recreate`
would also fix the RWO multi-attach flap), but we choose the consistent form.

Because the document store is precious and irreplaceable, this migration is
designed to be **reversible at every step** and to never mutate the original
volume until success is confirmed.

## What actually holds state

| Store | Backing | Contents | Precious? |
|-------|---------|----------|-----------|
| `paperless-ngx-data` (RWO, Longhorn) | subPaths `media/` + `data/` | **scanned documents, search index, thumbnails** | **YES** |
| PostgreSQL | CNPG `Cluster` (`postgresql-database.yaml`) | document metadata, users | YES — but already CNPG-HA + Barman/Backblaze backed up |
| `paperless-ngx-consume` (RWX, NFS) | consume/ + export/ | ingest dropbox + export target | No — transient |

Only **one** volume is being migrated: the Longhorn RWO `paperless-ngx-data`.
The database is **not touched** — CNPG stays exactly as-is. The NFS consume/export
share is recreated by the chart (no data move).

## Migration strategy: volume clone (primary), app-export (insurance)

Two **independent** safety nets, used in a strict order:

1. **Primary path — Longhorn clone.** A StatefulSet with a `volumeClaimTemplate`
   named `data` looks for a PVC named **`data-paperless-ngx-0`**. A StatefulSet
   *adopts* an existing PVC of that exact name and **never overwrites it**. So we
   pre-create `data-paperless-ngx-0` as a byte-identical Longhorn clone of the
   current `paperless-ngx-data`. The StatefulSet then comes up on a copy of the
   real data — it works immediately, no import step.

2. **Insurance — application export.** Before starting, run paperless's built-in
   `document_exporter` to produce a self-contained, version-aware bundle
   (documents + metadata + a manifest, consistent with the DB) on the NFS export
   share. We keep it and only ever use `document_importer` if the clone turns out
   bad. Ideally it is never touched.

> `document_exporter` / `document_importer` are Django management commands baked
> into the paperless image (exposed as bare commands by the entrypoint). They run
> via `kubectl exec` into a **running** pod — not separate tools or pods.

### Why clone *and* export, when clone alone works

The clone is the migration; it restores byte-for-byte and needs no import. The
export exists purely as a fallback that is *application-consistent* (captures DB
+ files together), covering the one weakness of a raw volume copy: if the index
and DB were momentarily inconsistent at clone time, the export can rebuild
cleanly. You do not import in the happy path.

---

## Pre-flight checklist

- [ ] Announce downtime; confirm no scans are being ingested.
- [ ] Confirm CNPG backup is current (`kubectl -n cnpg-system get backups` / Barman).
- [ ] Confirm Longhorn has free space for a full clone of `paperless-ngx-data`.
- [ ] Note the current PVC size (`1500Mi`) — the volumeClaimTemplate must request
      **the same or larger**; never smaller.
- [ ] Have the old `application.yaml` (kustomize/`install`) on a branch for rollback.
- [ ] Set the old PV/PVC reclaim policy to **Retain** so nothing is garbage-collected.

## Procedure

### 0. Insurance export (pod still running)
```bash
# quiesce ingest first (stop uploading); the pod stays up
kubectl exec -n paperless-ngx deploy/paperless-ngx -- \
  document_exporter ../export -z          # -z = zip; lands on the NFS export share
# copy the bundle somewhere off-cluster as well (belt and braces)
```

### 1. Stop the writer
```bash
kubectl -n paperless-ngx scale deploy/paperless-ngx --replicas=0
# confirm the pod is gone so the RWO volume is released
kubectl -n paperless-ngx get pod -w
```

### 2. Clone the Longhorn volume into the StatefulSet's expected PVC name
The StatefulSet (`name: paperless-ngx`, volumeClaimTemplate `data`) will look for
**`data-paperless-ngx-0`**. Create it as a clone of the current data PVC:
```yaml
# clone-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-paperless-ngx-0
  namespace: paperless-ngx
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1500Mi            # == current size (or larger)
  dataSource:
    kind: PersistentVolumeClaim
    name: paperless-ngx-data     # the existing, populated PVC
    apiGroup: ""
```
```bash
kubectl apply -f clone-pvc.yaml
kubectl -n paperless-ngx wait --for=jsonpath='{.status.phase}'=Bound pvc/data-paperless-ngx-0 --timeout=300s
```
> Longhorn supports CSI PVC-to-PVC cloning. If the clone source must be detached,
> ensure step 1 completed. Alternatively: take a Longhorn snapshot/backup of
> `paperless-ngx-data` and restore it into `data-paperless-ngx-0`.

### 3. Deploy the StatefulSet (helm chart) — it adopts the clone
Switch the ArgoCD Application to the new `homelab-charts` source with
`controller.type: statefulset`. Because `data-paperless-ngx-0` already exists,
the StatefulSet binds it instead of provisioning an empty one.
```bash
# after ArgoCD syncs:
kubectl -n paperless-ngx get sts paperless-ngx
kubectl -n paperless-ngx get pod paperless-ngx-0 -w
```

### 4. Verify BEFORE cutover
- [ ] `paperless-ngx-0` reaches `Running`/ready.
- [ ] UI loads; **document count matches** the pre-migration count.
- [ ] Open a document; run a search (proves index + media + DB all aligned).
- [ ] Logs clean (`kubectl -n paperless-ngx logs paperless-ngx-0`).

### 5. Cutover
- Flip the IngressRoute/traffic to the StatefulSet service (if not already, via
  the chart). Re-enable Authentik SSO on the profile if needed.

### 6. Cleanup (only after a confidence window, e.g. a few days)
- [ ] Delete the old `paperless-ngx-data` PVC (kept `Retain`ed until now).
- [ ] Delete the old Deployment remnants if any lingered.
- [ ] Keep the export bundle archived for one retention cycle.

## Rollback

| Failure point | Action |
|---------------|--------|
| Clone won't bind / STS won't start | `kubectl delete sts paperless-ngx`; scale the old Deployment back to 1 (`paperless-ngx-data` is untouched). |
| STS runs but data looks wrong | Same as above — old PVC is intact and `Retain`ed. |
| Both volumes suspect | Stand up a fresh empty STS, `document_importer ../export` the insurance bundle. |

The original `paperless-ngx-data` volume is **never written to or deleted** during
this procedure until step 6, so rollback is always "point traffic back at the old
Deployment."

## Notes / gotchas

- Match the paperless **image version** across old and new to avoid an unintended
  schema migration mid-cutover. Do the controller migration and any version bump
  as *separate* changes.
- The `consume`/`export` NFS mounts and the notification-script ConfigMap are
  recreated by the chart; no data lives there that needs moving.
- CNPG DB grants for the `paperless` user (see `README.md`) remain valid — the DB
  is not re-created.
