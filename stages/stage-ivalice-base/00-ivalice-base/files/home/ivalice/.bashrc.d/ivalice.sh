# shellcheck shell=bash
# ~/.bashrc.d/ivalice.sh — sourced by ivalice's interactive bash on the head.
# Exposes k3s's kubeconfig so `kubectl` works without --kubeconfig.
if [ -r /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Symlink ~/.kube/config to the k3s kubeconfig the first time we log in after
# k3s has materialized it. Safe to run on every shell start.
if [ -r /etc/rancher/k3s/k3s.yaml ] && [ ! -e "${HOME}/.kube/config" ]; then
    mkdir -p "${HOME}/.kube"
    ln -sf /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config" 2>/dev/null || true
fi
