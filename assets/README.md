# assets/

Airgap payloads bundled into the pi-gen image at build time. **Nothing
under `assets/` except this README is tracked in git** — see the root
`.gitignore`. Two reasons:

1. Some files are secrets (`munge.key`, `ivalice-cluster` private SSH
   key, `cluster-token`). They must never reach a remote.
2. Some files are large binaries (`k3s` ~64 MiB, the airgap images
   tarball ~128 MiB) regenerated from upstream. Git is the wrong store.

## Populating assets/

One-time per fresh workstation, while online:

```
./scripts/download-assets.sh        # fetches k3s, k3s-install.sh,
                                    # k3s-airgap-images-arm64.tar.zst,
                                    # ohmyzsh.tar.gz; records K3S_VERSION
./scripts/generate-ssh-key.sh       # writes assets/ivalice-cluster[.pub]
./scripts/generate-munge-key.sh     # writes assets/munge.key (mode 0400)
./scripts/generate-token.sh         # writes assets/cluster-token
```

After all four, `assets/` should contain:

| File | Source | Sensitivity |
| --- | --- | --- |
| `K3S_VERSION` | download-assets.sh | public |
| `k3s` | k3s-io release tag | public, large |
| `k3s-install.sh` | get.k3s.io | public |
| `k3s-airgap-images-arm64.tar.zst` | k3s-io release tag | public, large |
| `ohmyzsh.tar.gz` | ohmyzsh/ohmyzsh master | public, large |
| `ivalice-cluster` | generate-ssh-key.sh | **secret** |
| `ivalice-cluster.pub` | generate-ssh-key.sh | public |
| `munge.key` | generate-munge-key.sh | **secret** |
| `cluster-token` | generate-token.sh | **secret** |

## Bumping k3s

Edit `K3S_VERSION` at the top of `scripts/download-assets.sh`, delete
the existing `assets/k3s`, `assets/k3s-airgap-images-arm64.tar.zst`,
and `assets/K3S_VERSION`, then re-run `download-assets.sh`. The
`K3S_VERSION` file is consumed by `stages/stage-ivalice-base/00-ivalice-base/01-run.sh`.

## Rotating cluster secrets

Delete `assets/munge.key`, `assets/ivalice-cluster*`, or
`assets/cluster-token` and rerun the matching `generate-*.sh`. Then
rebuild and reflash all nodes — the cluster cannot tolerate mixed key
material.
