#!/usr/bin/env bash
# Turns a Kali machine into the Ansible control node for the lab.
#
# Runs automatically at `vagrant up kali`. On a Kali VM you already had,
# run it yourself after lab.ps1 has attached the lab NIC:
#     sudo ./scripts/bootstrap-kali.sh
set -euo pipefail

LAB_IP="10.10.10.50"
LAB_PREFIX="10.10.10."

if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Run as root: sudo $0" >&2
  exit 1
fi

# The human who will run Ansible: the sudo caller on an existing Kali,
# 'vagrant' on a Vagrant-built one.
LAB_USER="${SUDO_USER:-vagrant}"
LAB_HOME="$(getent passwd "$LAB_USER" | cut -d: -f6)"
if [ -z "$LAB_HOME" ] || [ ! -d "$LAB_HOME" ]; then
  echo "[-] Could not find a home directory for '$LAB_USER'" >&2
  exit 1
fi

# --- Lab network ------------------------------------------------------------
# Vagrant configures the NIC itself. On an existing Kali, lab.ps1 adds a NIC
# on the lab vmnet but nothing inside the guest gives it an address -- do
# that here.
if ip -4 -o addr show | grep -q " ${LAB_PREFIX}"; then
  echo "[*] Already on the lab network: $(ip -4 -o addr show | awk -v p="$LAB_PREFIX" 'index($4,p)==1 {print $2, $4}')"
else
  # The lab NIC is the ethernet device with a link but no IPv4 address.
  LAB_IF=""
  for path in /sys/class/net/*; do
    dev="$(basename "$path")"
    [ "$dev" = "lo" ] && continue
    [ -e "/sys/class/net/$dev/device" ] || continue          # physical/virtual NICs only
    ip -4 -o addr show dev "$dev" | grep -q inet && continue
    LAB_IF="$dev"; break
  done
  if [ -z "$LAB_IF" ]; then
    echo "[-] No unconfigured NIC found. Did lab.ps1 attach the lab network, and" >&2
    echo "    was Kali shut down when it did? Check: ip -br link" >&2
    exit 1
  fi
  echo "[*] Configuring $LAB_IF as ${LAB_IP}/24 (lab network, no gateway)"
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    nmcli con delete purpleforest-lab >/dev/null 2>&1 || true
    nmcli con add type ethernet ifname "$LAB_IF" con-name purpleforest-lab \
      ipv4.method manual ipv4.addresses "${LAB_IP}/24" \
      ipv4.never-default yes ipv6.method disabled >/dev/null
    nmcli con up purpleforest-lab >/dev/null
  else
    ip addr add "${LAB_IP}/24" dev "$LAB_IF"
    ip link set "$LAB_IF" up
    echo "[!] NetworkManager not running -- this address will not survive a reboot"
  fi
fi

# --- Control-node dependencies ----------------------------------------------
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

# Collections go in the user's own path, so running ansible as that user
# (not root) finds them.
echo "[*] Installing Ansible collections for $LAB_USER"
sudo -u "$LAB_USER" -H "$VENV/bin/ansible-galaxy" collection install -f \
  ansible.windows \
  community.windows \
  microsoft.ad \
  community.general \
  community.docker >/dev/null

for rc in "$LAB_HOME/.bashrc" "$LAB_HOME/.zshrc"; do       # Kali defaults to zsh
  [ -f "$rc" ] || continue
  grep -q lab-venv "$rc" || echo "export PATH=$VENV/bin:\$PATH" >> "$rc"
done

cat <<MSG

[+] Kali is ready as the Ansible control node.

    Open a new terminal (so the venv is on PATH), then:
        git clone https://github.com/zebracherry/PurpleForest.git ~/PurpleForest   # if not already
        cd ~/PurpleForest/ansible
        ansible-playbook site.yml

    Quick reachability test first:
        ansible siem -m ping         # siem01
        ansible windows -m win_ping  # dc01, ws01

MSG
