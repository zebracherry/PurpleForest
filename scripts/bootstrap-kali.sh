#!/usr/bin/env bash
# Turns the KALI guest into the Ansible control node for the lab.
# Runs once at `vagrant up kali`.
set -euo pipefail

echo "[*] Installing control-node dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  python3-pip python3-venv git sshpass \
  krb5-user libkrb5-dev gcc python3-dev >/dev/null

VENV=/opt/lab-venv
if [ ! -d "$VENV" ]; then
  echo "[*] Creating venv at $VENV"
  python3 -m venv "$VENV"
fi

"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet \
  "ansible-core>=2.17" \
  "pywinrm[credssp]" \
  requests-ntlm

echo "[*] Installing Ansible collections"
"$VENV/bin/ansible-galaxy" collection install -f \
  ansible.windows \
  community.windows \
  microsoft.ad \
  community.general \
  community.docker >/dev/null

# Make the venv the default for the vagrant user
if ! grep -q lab-venv /home/vagrant/.bashrc; then
  echo "export PATH=$VENV/bin:\$PATH" >> /home/vagrant/.bashrc
fi

cat <<'EOF'

[+] Kali is ready as the Ansible control node.

    Get the repo onto this box (either clone it or use a shared folder):
        git clone <your-repo-url> ~/noob2root-lab

    Then:
        cd ~/noob2root-lab/ansible
        ansible-playbook -i inventory/lab.ini site.yml

EOF
