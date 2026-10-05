# CentOS 6.10 legacy baseline VM

A reproducible CentOS 6.10 x86_64 virtual machine that stands in for the
RHEL 6.x environment on UNH's Dell HPC servers. It builds the sphinx-asr
vendor tools (sphinxtrain, pocketsphinx, cmu_toolkit) with the legacy
toolchain (gcc 4.4.7, glibc 2.12, perl 5.10.1) so their output can be
compared with the same code built on the modern Debian 13 Pi cluster.

The full write-up, including the 2x2 design and the measured results, is in
the engineering wiki: `docs/baselines/rhel6-centos6.md`.

## Read this first

- **Timings from this VM are not valid.** On an Apple Silicon host the VM
  runs under QEMU TCG (full x86_64 emulation, no hardware acceleration).
  Use it for correctness and accuracy (features, models, WER), never for
  wall-clock comparisons. For timing, run the same scripts on an x86_64
  Linux host with KVM: `ACCEL=kvm CPU_MODEL=host ./vm.sh up`.
- **CentOS 6 is end of life** (no security updates since 2020-11-30). The VM
  listens only on `127.0.0.1:2226` (ssh, key auth only, root password
  locked). Do not forward it to a routable address, do not expose it to a
  network, and do not put real credentials in it.

## Files

| File | Purpose |
| --- | --- |
| `fetch-image.sh` | Download and sha256-verify the pinned image and every pinned dependency (`deps.lock`) into `.cache/` |
| `deps.lock` | Pinned host-side inputs: Kitware cmake 3.25.3, Python 3.12.15 source, offline wheelhouse |
| `make-seed.sh` | Build the NoCloud seed ISO (`cidata`): user `baseline`, dedicated VM key, vault yum repos |
| `vm.sh` | `up`, `down`, `ssh`, `status`, `destroy --yes` |
| `provision.sh` | Stage inputs, install the legacy toolchain, build Python 3.12, build sphinx-asr with gcc 4.4.7, write the manifest |
| `guest/provision-guest.sh` | The in-guest half of `provision.sh` (resumable phases) |
| `guest/CentOS-Vault-6.10.repo` | yum repos: 6.10 `os`, `updates`, `extras`, SCLo `rh` on vault.centos.org |
| `vault-proxy.py` | Loopback-only caching proxy to vault.centos.org, run by `provision.sh` (see below) |
| `patches/gcc44-pocketsphinx.patch` | Declaration-only fix so pocketsphinx 5.0.4 compiles with gcc 4.4.7 |
| `run-checks.sh` | pytest suite, tool sanity, compiler audit; copies artifacts to `results/` |
| `run-experiment.sh` | Hook for a real train/decode run once a corpus is staged (not yet exercised) |
| `results/` | Committed research artifacts: `TOOLCHAIN-MANIFEST.txt`, `run-checks.txt` |
| `.cache/`, `.state/` | Gitignored: base image, downloads, vault package cache, overlay disk, seed, VM key, console log |

## Quick start

```sh
cd baselines/rhel6
./fetch-image.sh     # about 800 MB, verified against sha256sum.txt and the pin
./vm.sh up           # boots in about 2 minutes under TCG
./provision.sh       # long under TCG; resumable
./run-checks.sh      # writes results/
./vm.sh down         # overlay kept; ./vm.sh up resumes
```

`./vm.sh ssh` opens a shell; `./vm.sh ssh 'cmd'` runs one command.

## Why plain QEMU and not Lima

Lima cannot host CentOS 6:

- its guest agent is a Go program (Lima 2.2.1 ships one built with Go
  1.27), and Go 1.24 and later need Linux 3.2 or newer; CentOS 6 runs
  2.6.32;
- its boot scripts install the agent as a systemd (or OpenRC) service;
  CentOS 6 uses Upstart and SysV init;
- this Homebrew install ships only aarch64 guest agents
  (`share/lima/lima-guestagent.Linux-aarch64.gz`); an x86_64 guest would
  also need the separate additional-guestagents package.

So the scripts drive `qemu-system-x86_64` directly with a cloud-init NoCloud
seed, which CentOS 6's cloud-init 0.7.5 supports.

## Deviations from the original plan

- **ECDSA, not ed25519, VM key.** CentOS 6's OpenSSH 5.3p1 predates
  ed25519; RHEL backported ECDSA. The host also has to re-enable the
  `ssh-rsa` host-key algorithm for this VM only, because 5.3p1 offers
  only `ssh-rsa`/`ssh-dss` host keys.
- **cmake 3.25.3 from Kitware.** `vendor/pocketsphinx` needs cmake 3.25;
  CentOS 6 ships 2.8.12. Kitware's static binary needs only `GLIBC_2.10`.
  cmake only drives the build; the compiler is still `/usr/bin/gcc` 4.4.7.
- **yum goes through a host proxy.** vault.centos.org (CloudFront) often
  cuts HTTPS transfers short, from the host as well as the guest, and
  CentOS 6's yum gives up on a file after one failure per mirror, so large
  packages like gcc never finished. `provision.sh` runs `vault-proxy.py`
  on `127.0.0.1:8610`; it fetches with retries over the host's TLS stack,
  caches under `.cache/vault/`, and serves the guest (as `10.0.2.2`) over
  plain HTTP. yum still checks every package signature (`gpgcheck=1`).
  The repo file lists the proxy first and vault.centos.org second.
- **sfdisk instead of growpart.** `cloud-utils-growpart` is only in EPEL,
  so the root partition is grown by rewriting the single MBR entry with
  `sfdisk` (same start sector), rebooting, and running `resize2fs`.
- **pocketsphinx patch.** pocketsphinx 5.0.4 repeats three typedefs and
  writes `__thread` before `static`; gcc 4.4.7 rejects both. The
  declaration-only patch in `patches/` fixes that in the guest copy. No
  flags or compilers changed.
- **Prebuilt objects removed.** `vendor/cmu_toolkit/src` in the sphinx-asr
  submodule tracks 24 x86-64 `.o` files built by GCC 14.2 (Ubuntu). A fresh
  checkout gives them the same mtime as their sources, so `make` would link
  them unchanged. Provisioning deletes all `*.o`/`*.a` under `vendor/`
  first, and `run-checks.sh` fails if any binary records a compiler other
  than GCC 4.4.7.

See the wiki page for the Python decision, the toolchain results and the
re-pinning procedure.
