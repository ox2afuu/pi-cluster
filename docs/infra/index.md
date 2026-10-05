# Infrastructure

The machines and services that build and check the cluster image, as
opposed to the cluster itself (see [Architecture](../architecture/index.md)).

| Page | What it covers |
| --- | --- |
| [GitLab CI](gitlab-ci.md) | The two runners, how to create and register the `pigen-builder` VM, the pipeline's stages, rules and artifacts, how to run a build by hand, and why the artifacts are secret |
| [Lab image](lab-image.md) | What the lab-ready image contains, how the sphinx-asr payload is pinned to the submodule commit, and what `scripts/ci/verify-image.sh` checks |

Everything runs on the operator's Mac:

- **GitLab CE 19.3** at `https://git.bytehearth.internal:8443` (project
  `unh/pi-cluster`, TLS from an mkcert CA), in its own Lima VM.
- **`mac-local`**, the shared GitLab runner for light jobs.
- **`pigen-builder`**, a dedicated Debian 13 arm64 Lima VM that builds and
  verifies images. Its definition is `infra/lima/pigen-builder.yaml` and
  its registration script is `infra/lima/register-runner.sh`.

The decision to give image builds their own VM is recorded in
[ADR 0002](../standards/adr/0002-dedicated-lima-runner-for-image-builds.md).
