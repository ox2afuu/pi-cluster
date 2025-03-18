# ~/.zshrc — ivalice user's zsh config. Minimal, offline-safe.
# Mirrors the kubeconfig / kube symlink guards from .bashrc.d/ivalice.sh.

# --- oh-my-zsh ------------------------------------------------------------
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git sudo)

if [ -r "$ZSH/oh-my-zsh.sh" ]; then
    source "$ZSH/oh-my-zsh.sh"
fi

# --- editor ---------------------------------------------------------------
export EDITOR=nvim
export VISUAL=nvim

# --- k3s kubeconfig (head-only; guarded so it's a no-op on workers) ------
if [ -r /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Symlink ~/.kube/config to the k3s kubeconfig the first time we log in
# after k3s has materialized it. Safe to run on every shell start.
if [ -r /etc/rancher/k3s/k3s.yaml ] && [ ! -e "${HOME}/.kube/config" ]; then
    mkdir -p "${HOME}/.kube"
    ln -sf /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config" 2>/dev/null || true
fi
