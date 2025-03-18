#!/usr/bin/env bash
set -euo pipefail
cd /opt/ivalice/ansible
exec ansible-playbook -i /opt/ivalice/ansible/inventory/hosts.yml site.yml "$@"
