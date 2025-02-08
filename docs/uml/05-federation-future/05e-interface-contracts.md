# 05e — Federation interface contracts

This is the design-review seed for the services and APIs that will glue
multiple clusters + arbitrary L2 nodes together. Companion to the PlantUML
diagrams `05a`..`05f`. Not binding; all choices are revisitable until the
second Super6c comes online and we measure real traffic.

## Scope

- How a second cluster discovers and uses the federation control plane.
- How arbitrary L2 nodes join and leave.
- Where artifacts (models, features, results) live and how they're named.
- What identity + authorization look like.

**Explicitly NOT scope:**

- A new RPC/gRPC layer — we compose existing services instead.
- A bespoke metadata schema beyond what Postgres needs to track experiments.
- A full AuthN/AuthZ design — this doc only flags the decision surface.

## Control plane — two options to decide between

### Option A — native Slurm federation (slurmdbd)

Slurm's built-in federation mode has slurmdbd as the controller; each
cluster's slurmctld registers with it and the operator can `sbatch -M
<cluster>` or `sbatch -M all`. Workload shifts between clusters
transparently when one has idle capacity.

| Aspect | Value |
| --- | --- |
| Added services | slurmdbd on one head (or dedicated host); MariaDB backing it |
| New config | `ClusterName` per cluster; federation registered via `sacctmgr` |
| Auth | munge key shared across federation |
| Sbatch routing | `sbatch -M federation <...>` |
| Queue::Slurm change | none (adapter passes `-M` via env if set) |
| Downside | Homogeneous Slurm only; adding a non-Slurm cluster needs option B |

### Option B — external meta-scheduler via slurmrestd

Each cluster exposes `slurmrestd` on a fixed port; a small meta-scheduler
(Python service, ~300 lines) receives sphinx submits and picks a cluster
based on queue depth / resource match. Each cluster stays independent
internally.

| Aspect | Value |
| --- | --- |
| Added services | slurmrestd on each head; meta-scheduler (new) on a neutral host |
| New config | JWT signing key for slurmrestd; meta-scheduler config listing clusters |
| Auth | JWT (slurmrestd native); cross-cluster trust via signed tokens |
| Sbatch routing | meta-scheduler decides, submits via REST to chosen cluster |
| Queue::Slurm change | new "Queue::SlurmREST" shim that POSTs to the meta-scheduler instead of shelling out |
| Downside | More moving parts; meta-scheduler logic is ours to write and debug |

### Recommendation

Start with **Option A** when the second Super6c arrives. Revisit Option B
if/when the federation wants to incorporate non-Slurm compute (k8s batch,
Flux, dedicated research boxes with local schedulers). Option A needs no
sphinx-asr code change; Option B needs a new queue shim.

## Artifact store — MinIO (s3-compatible)

### Bucket layout

```
s3://ivalice-fed/
  models/<sha256>/           # model_parameters/<db>.cd_cont_N/ tarball
  cfgs/<sha256>/             # etc/sphinx_train.cfg + etc/*.dic + etc/feat.params
  dicts/<sha256>/            # standalone dictionary objects
  lms/<sha256>/              # ARPA (compressed) addressed by hash
  features/<corpus>/<split>/<sha256>/    # pre-computed .mfc tarballs
  results/<experiment_id>/<decode_corpus>/<sha256>/  # *.match + metadata
  manifests/<experiment_id>.json         # cross-ref to all the above
```

### Hash policy

- Every object addressed by `sha256` of its canonical bytes.
- Tarballs are deterministic (sorted entries, no timestamps) so the same
  content produces the same hash regardless of where it was built.
- Metadata lives in Postgres (below), not in object names.

### Retention

- No automatic GC for v1. Operator runs `sphinx gc --dry-run` to surface
  objects not referenced from the registry, then promotes to `--yes`.
- Models from failed runs get `failed=true` tag and are eligible for GC
  immediately.

## Experiment registry — Postgres

### Minimal schema

```sql
CREATE TABLE experiments (
  id            UUID PRIMARY KEY,
  name          TEXT NOT NULL,              -- user-chosen
  owner         TEXT NOT NULL,              -- ivalice user or SSO login
  origin        TEXT NOT NULL,              -- cluster name that ran training
  cfg_hash      TEXT NOT NULL,              -- sha256 into cfgs/
  model_hash    TEXT,                       -- sha256 into models/ (NULL if not yet trained)
  dict_hash     TEXT NOT NULL,
  lm_hash       TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL,
  trained_at    TIMESTAMPTZ,
  wer           REAL,                       -- last decode WER observed
  decode_corpus TEXT,                       -- corpus used for WER
  decode_split  TEXT,
  failed        BOOLEAN DEFAULT FALSE,
  notes         TEXT
);

CREATE TABLE runs (
  id            UUID PRIMARY KEY,
  experiment_id UUID REFERENCES experiments,
  cluster       TEXT NOT NULL,
  step          TEXT NOT NULL,              -- e.g. "50.cd_hmm_tied"
  started_at    TIMESTAMPTZ,
  finished_at   TIMESTAMPTZ,
  slurm_jobid   TEXT,
  state         TEXT,                       -- COMPLETED|FAILED|CANCELLED|...
  log_uri       TEXT                        -- s3://ivalice-fed/logs/<id>
);
```

### Postgres footprint

Low — Raspberry Pi 5 with a small SSD can host this comfortably for the
foreseeable cluster count. Put it on a dedicated host so a head reboot
doesn't take the registry offline.

## Node-join contract (arbitrary L2 node → federation member)

1. Operator bakes (or deploys) an ivaliceCluster-compatible image with
   `NODE_ROLE=worker` + federation-aware flags in `/boot/firmware/ivalice-node.conf`.
2. Firstboot script requests the shared munge key from a bootstrap endpoint
   (on one of the heads) **once**, authenticated via pre-shared operator
   token. Writes to `/etc/munge/munge.key`.
3. Postboot Ansible pulls the inventory Git repo and appends the new
   hostname to the appropriate group. A slurmctld reload includes the new
   node.
4. Node registers with slurmctld, becomes eligible for jobs.
5. If the node also needs NFS (for local training-style access), it mounts
   the NFS from **one** chosen home cluster. Cross-cluster artifacts come
   via MinIO, not NFS.

### Decommission

- Ansible removes the node from inventory, reloads slurmctld, optionally
  revokes the munge key rotation the next cycle.
- No artifact cleanup needed; everything the node produced is already in
  MinIO, content-addressed.

## Identity / AuthN / AuthZ (punt with pointers)

Decisions to make when federation is actually wired, not now. Options to
evaluate:

- **Munge shared key for Slurm**: required for federation. Rotate yearly
  with coordinated handover.
- **OIDC / SSO for operators**: plug a small OIDC provider on the registry
  host; operators get a session token that the sphinx CLI stores.
- **Service-to-service**: JWT signed by the federation controller for
  slurmrestd and MinIO; short-lived.
- **Per-experiment ACLs**: column on `experiments` table, default to
  `owner` read-write, others read-only.

Out of scope to specify today. Listed here so future work doesn't forget.

## Alternatives considered

- **gRPC service mesh across clusters** — reinvents slurmrestd, adds a
  heavy dependency, buys little. Skipped.
- **Kubernetes federation** — different workload model; HPC isn't
  request/response. Skipped.
- **Flux Framework** (LLNL) — interesting next-gen HPC scheduler with
  hierarchical resource management; worth revisiting in ~18 months if
  Slurm federation becomes the bottleneck for multi-cluster elastic
  scheduling.
- **CephFS everywhere** — viable but requires ops effort we don't have;
  per-cluster NFS + federation-wide MinIO is cheaper.

## Acceptance for 05

The 05 package is "documented future work" — acceptance is that the
diagrams + this doc are complete enough that a design review can produce
Phase-6 implementation tasks without further research. No code changes
follow from Phase 0; implementation is deferred until after the second
Super6c arrives.
