#!/usr/bin/env bash
# Install gitlab-runner in the pigen-builder Lima VM and register it as a
# project runner for unh/pi-cluster with the shell executor.
#
# Usage: infra/lima/register-runner.sh
#
# Environment (all optional):
#   GITLAB_HOST     GitLab host:port            (git.bytehearth.internal:8443)
#   GITLAB_PROJECT  project path                (unh/pi-cluster)
#   LIMA_VM         Lima instance name          (pigen-builder)
#   RUNNER_VERSION  gitlab-runner release tag   (v19.3.0)
#   MKCERT_CA       public CA cert for GitLab's TLS
#                   ($HOME/.local/share/mkcert/rootCA.pem)
#
# Requires glab authenticated against GITLAB_HOST. The runner token is
# created through the API and handed to the VM on stdin; it is never put
# on a command line or printed. Re-running is safe: an already registered
# VM is left alone.
#
# Exit codes: 0 registered (or already registered), 1 on any failure.
set -euo pipefail

GITLAB_HOST="${GITLAB_HOST:-git.bytehearth.internal:8443}"
GITLAB_PROJECT="${GITLAB_PROJECT:-unh/pi-cluster}"
LIMA_VM="${LIMA_VM:-pigen-builder}"
RUNNER_VERSION="${RUNNER_VERSION:-v19.3.0}"
MKCERT_CA="${MKCERT_CA:-$HOME/.local/share/mkcert/rootCA.pem}"
export GITLAB_HOST

vm() { limactl shell "$LIMA_VM" -- "$@"; }

[ -f "$MKCERT_CA" ] || { echo "error: CA cert not found: $MKCERT_CA" >&2; exit 1; }

echo "==> trusting the GitLab CA inside $LIMA_VM"
vm sudo tee /usr/local/share/ca-certificates/bytehearth-mkcert.crt \
  >/dev/null < "$MKCERT_CA"
vm sudo update-ca-certificates >/dev/null

echo "==> installing gitlab-runner $RUNNER_VERSION"
if ! vm sh -c 'command -v gitlab-runner >/dev/null'; then
  base="https://gitlab-runner-downloads.s3.amazonaws.com/${RUNNER_VERSION}/deb"
  vm sh -c "set -e; cd /tmp
    curl -fsSLO '${base}/gitlab-runner-helper-images.deb'
    curl -fsSLO '${base}/gitlab-runner_arm64.deb'
    sudo apt-get install -y ./gitlab-runner-helper-images.deb ./gitlab-runner_arm64.deb
    rm -f gitlab-runner-helper-images.deb gitlab-runner_arm64.deb"
fi

# pi-gen must run as root. The VM is dedicated to this runner, so the
# runner user gets passwordless sudo here and nowhere else.
vm sudo sh -c 'echo "gitlab-runner ALL=(root) NOPASSWD: ALL" \
  > /etc/sudoers.d/gitlab-runner && chmod 0440 /etc/sudoers.d/gitlab-runner'

if vm sudo grep -q '^\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>/dev/null; then
  echo "==> already registered; leaving config.toml alone"
  exit 0
fi

echo "==> creating a project runner for $GITLAB_PROJECT"
project_id="$(glab api "projects/${GITLAB_PROJECT//\//%2F}" | jq -r .id)"
token="$(glab api -X POST user/runners \
  -f runner_type=project_type -F project_id="$project_id" \
  -f description="$LIMA_VM" -f tag_list="pigen,aarch64" \
  -F run_untagged=false -F locked=true -f maximum_timeout=10800 \
  | jq -r .token)"
[ -n "$token" ] && [ "$token" != null ] || { echo "error: no runner token" >&2; exit 1; }

echo "==> registering (shell executor)"
printf '%s\n' "$token" | vm sudo sh -c '
  set -e
  read -r CI_SERVER_TOKEN; export CI_SERVER_TOKEN
  gitlab-runner register --non-interactive \
    --url "https://'"$GITLAB_HOST"'" \
    --executor shell --name "'"$LIMA_VM"'"
  sed -i "s/^concurrent = .*/concurrent = 1/" /etc/gitlab-runner/config.toml
  systemctl enable --now gitlab-runner
  systemctl restart gitlab-runner'
unset token

vm sudo gitlab-runner verify 2>&1 | grep -E 'is (alive|valid)' || {
  echo "error: runner did not verify" >&2; exit 1; }
echo "==> done: $LIMA_VM is a project runner for $GITLAB_PROJECT (tags: pigen, aarch64)"
