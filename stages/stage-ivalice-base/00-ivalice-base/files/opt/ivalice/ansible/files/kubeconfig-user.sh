# /etc/profile.d-style snippet: export KUBECONFIG when the k3s kubeconfig is readable.
# Not installed automatically yet — reserved for future use.
if [ -r /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
