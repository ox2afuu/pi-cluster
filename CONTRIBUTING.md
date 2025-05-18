# Contributing to ivaliceCluster

Thanks for your interest. This repo holds the cluster-level
infrastructure: image build, custom pi-gen stage, provisioning
scripts, Ansible playbooks, and design docs. ASR-specific changes
belong in the [sphinx-asr submodule's repo](https://github.com/masonarmand/sphinx-asr),
not here.

## Getting set up

```sh
git clone --recurse-submodules <repo-url> ivaliceCluster
cd ivaliceCluster
./scripts/download-assets.sh        # one-time, while online
./scripts/generate-ssh-key.sh
./scripts/generate-munge-key.sh
./scripts/generate-token.sh
```

The build itself requires privileged Podman (rootful machine on
macOS). pi-gen's own `build.sh` won't work outside the wrapper —
always go through `scripts/build.sh`.

## Branch model

```
main                  always buildable; --no-ff merges only
  feat/<area>         additive work (rebased on main before merge)
  fix/<area>          bug fixes (rebased on main before merge)
  submodule/<name>    submodule pointer bumps only
```

- No direct commits to `main` after the initial scaffold/foundation.
- Feature branches are kept after merge so the topology is legible
  in `git log --graph`.
- Use `git merge --no-ff` so merges show up as merge commits.

## Commit messages

Use conventional prefixes that match what's already in `git log --oneline`:

| Prefix                                   | Use for                                              |
| ---------------------------------------- | ---------------------------------------------------- |
| `feat(<area>): ...`                      | new functionality                                    |
| `fix(<area>): ...`                       | bug fixes                                            |
| `docs(<area>): ...`                      | documentation only                                   |
| `scaffold: ...`                          | repo scaffolding (rare; mostly initial commits)      |
| `foundation: ...`                        | foundational config (LICENSE, README, gitignore)     |
| `merge: feat/<area>` / `merge: fix/...`  | non-fast-forward merge into main                     |
| `<submodule>: bump to <sha> (<branch>)`  | submodule pointer update only — see below            |

Keep the subject line under 72 characters. Use the body for the why.

## Submodule discipline

Both `pi-gen/` and `sphinx-asr/` are submodules tracking upstream
repos. **Never** make commits inside a submodule from this working
tree. Workflow for upstream changes:

1. `cd pi-gen` (or `sphinx-asr`).
2. Create a feature branch in the submodule's own repo and land the
   change there via that repo's PR process.
3. From the outer repo: `cd ..` and `git -C <submodule> pull` to
   advance the submodule's HEAD.
4. Commit the pointer bump in a **dedicated** commit:

   ```sh
   git add <submodule>
   git commit -m "<submodule>: bump to <abbrev-sha> (<branch>)"
   ```

   No other files in this commit. Bisect-friendliness depends on it.

If `git -C sphinx-asr status --porcelain` is non-empty when you build,
`scripts/build.sh` warns you: uncommitted submodule work won't be
reflected in the image, so the build isn't reproducible.

## House style

- **No emojis** — code, comments, commit messages, doc bodies, PR
  descriptions, UML diagram labels.
- **aarch64-only** for cluster artifacts. Anything under
  `stages/.../files/` or `/opt/ivalice/` runs inside the Debian rootfs
  on a CM4. No macOS shell syntax (`brew`, BSD `sed -i ''`, `gsed`).
  No `x86_64` hardcoding. Wrapper scripts under `scripts/` may target
  the macOS host; everything else is Debian-trixie-aarch64-clean.
- **Airgapped at runtime.** No `pip install`, `apt-get update`,
  `apt-get install`, `git clone`, or `curl https://...` reachable from
  boot-onward code paths (firstboot service, postboot Ansible, Slurm
  prologs/epilogs, sphinx jobs). All binaries and wheels come from
  `assets/` baked into the image at build time. Build-time
  `apt-get` inside pi-gen stages is fine; **runtime network is not**.
- **State location.** Cluster state, experiment outputs, models,
  registry data live under `/srv/ivalice/` (NFS-exported, shared) or
  `/var/lib/ivalice/` (node-local). Never under `/home`, `/root`, or
  directly under `/`.
- **NFS ownership.** `/srv/ivalice/` and everything under it stays
  `ivalice:ivalice` (UID/GID 1000). Don't `chown root:root` on those
  paths in Ansible — cross-node access will silently break.
- **Idempotency.** Every Ansible task must use `creates:`,
  `changed_when:`, a state-aware module, or a handler. Shell scripts
  must be safely re-runnable.

## Topology coordination

Hostname/IP pairs are load-bearing. If a change touches **any** of
these, **all** must move in the same commit:

- `scripts/personalize-node.sh`
- `stages/stage-ivalice-base/00-ivalice-base/files/etc/slurm/slurm.conf`
  (NodeName / PartitionName lines)
- `stages/stage-ivalice-base/.../ansible/inventory/hosts.yml`
- Any `hosts.debian.tmpl` template under `stages/`

## Secrets

These files are gitignored and **must never** appear in a diff:

- `assets/munge.key`
- `assets/ivalice-cluster` (the private SSH key — pubkey
  `ivalice-cluster.pub` is fine)
- `assets/cluster-token`
- Anything else under `assets/` except `assets/README.md`.

Do not hardcode passwords, API tokens, or known-default
`FIRST_USER_PASS` values in `configs/config.base`.

## UML coupling

Runtime behavior changes in `scripts/`, `stages/`, or the Ansible
playbooks should bring matching `docs/uml/**/*.puml` updates in the
same PR, with `.svg` + `.png` re-rendered:

```sh
plantuml -tsvg -tpng docs/uml/<package>/<diagram>.puml
```

PRs that change behavior without updating UML are incomplete (the
Phase 0 gate from the design baseline).

## Linting

```sh
shellcheck scripts/*.sh stages/stage-ivalice-base/**/*.sh
yamllint -d relaxed stages/**/*.yml stages/**/*.yaml
ansible-lint stages/stage-ivalice-base/00-ivalice-base/files/opt/ivalice/ansible/
plantuml -checkonly docs/uml/**/*.puml
```

`ansible-playbook --syntax-check site.yml` requires `ansible-core`
installed in a venv; on macOS it's typically only available on the
head node post-deploy.

## Pull request flow

1. Branch off `main` (`git checkout -b feat/<area>` or `fix/<area>`).
2. Make commits with the conventions above. Keep them logically
   focused — separate refactors from feature work, separate submodule
   bumps from everything else.
3. Rebase onto current `main` before opening the PR
   (`git fetch && git rebase origin/main`).
4. Open the PR. Describe what changed, why, and whether topology
   coordination, secrets, or UML diagrams are affected.
5. After review, the PR is merged with `--no-ff` so the branch's
   topology stays visible in `git log --graph`.

## Reporting issues

For bugs in the cluster build (image bake, Ansible playbooks, network
config): open an issue here. For bugs in ASR training or decoding:
open it in the [sphinx-asr repo](https://github.com/masonarmand/sphinx-asr)
instead.
