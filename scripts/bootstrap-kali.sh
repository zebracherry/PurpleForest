#!/usr/bin/env bash
# Turns a Kali machine into the Ansible control node for the lab.
#
# Runs automatically at `vagrant up kali`. On a Kali VM you already had,
# run it yourself after lab.ps1 has attached the lab NIC:
#     sudo ./scripts/bootstrap-kali.sh
set -euo pipefail

LAB_IP="10.10.10.50"

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
#
# The profile is bound to the NIC's MAC address, never to its interface name.
# Interface names come from driver probe order, and the lab NIC (vmxnet3) and
# the NAT NIC (e1000) can swap between eth0 and eth1 across reboots. A
# name-bound profile then puts the lab's static address on the NAT adapter,
# which costs you the lab and your internet route in one go -- and it presents
# as "Kali has no internet", with nothing obvious pointing at the lab.

# Virtual/physical ethernet NICs that have a carrier. Loopback excluded.
live_nics() {
  for path in /sys/class/net/*; do
    dev="$(basename "$path")"
    [ "$dev" = "lo" ] && continue
    [ -e "/sys/class/net/$dev/device" ] || continue
    [ "$(cat "/sys/class/net/$dev/carrier" 2>/dev/null)" = "1" ] || continue
    echo "$dev"
  done
}

nic_mac() { cat "/sys/class/net/$1/address"; }

# --escape no, or nmcli hands back the MAC with every colon backslashed.
LAB_PROFILE_MAC="$(nmcli --escape no -g 802-3-ethernet.mac-address connection show purpleforest-lab 2>/dev/null || true)"

if [ -n "$LAB_PROFILE_MAC" ] && ip -o link show | grep -qi "$LAB_PROFILE_MAC"; then
  echo "[*] Lab profile already bound to MAC $LAB_PROFILE_MAC"
  nmcli con up purpleforest-lab >/dev/null 2>&1 || true
else
  # Decide which NIC is the lab one BEFORE changing anything. The NAT adapter
  # holds a DHCP lease by now, so the lab NIC is the one with a carrier and no
  # IPv4 address. That test also picks correctly out of the broken state
  # described above, where the NAT adapter wrongly holds the lab's address.
  LAB_IF=""
  for dev in $(live_nics); do
    ip -4 -o addr show dev "$dev" | grep -q inet && continue
    LAB_IF="$dev"; break
  done
  if [ -z "$LAB_IF" ]; then
    echo "[-] No unconfigured NIC found. Did lab.ps1 attach the lab network, and" >&2
    echo "    was Kali shut down when it did? Check: ip -br link" >&2
    exit 1
  fi
  LAB_MAC="$(nic_mac "$LAB_IF")"
  echo "[*] Configuring $LAB_IF ($LAB_MAC) as ${LAB_IP}/24 (lab network, no gateway)"

  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    nmcli con delete purpleforest-lab >/dev/null 2>&1 || true
    nmcli con add type ethernet con-name purpleforest-lab \
      802-3-ethernet.mac-address "$LAB_MAC" \
      ipv4.method manual ipv4.addresses "${LAB_IP}/24" \
      ipv4.never-default yes ipv6.method disabled >/dev/null
    nmcli con up purpleforest-lab >/dev/null

    # Every other NIC is the route off the box. If an earlier name-bound run
    # stranded it, give it a DHCP profile of its own -- MAC-bound too, so the
    # pair cannot trade places again.
    for dev in $(live_nics); do
      [ "$dev" = "$LAB_IF" ] && continue
      ip -4 -o addr show dev "$dev" | grep -q inet && continue
      uplink_mac="$(nic_mac "$dev")"
      echo "[*] Restoring DHCP on $dev ($uplink_mac)"
      nmcli con delete purpleforest-uplink >/dev/null 2>&1 || true
      nmcli con add type ethernet con-name purpleforest-uplink \
        802-3-ethernet.mac-address "$uplink_mac" \
        ipv4.method auto ipv6.method auto >/dev/null
      nmcli con up purpleforest-uplink >/dev/null 2>&1 || true
    done
  else
    ip addr add "${LAB_IP}/24" dev "$LAB_IF"
    ip link set "$LAB_IF" up
    echo "[!] NetworkManager not running -- this address will not survive a reboot"
  fi
fi

# Without this, sudo prints "unable to resolve host" on every single call.
if ! grep -q "$(hostname)" /etc/hosts; then
  printf '127.0.1.1\t%s\n' "$(hostname)" >> /etc/hosts
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
