#!/usr/bin/env bash
#
# noob2root detection lab -- wrapper
#
# Run this on the HOST (the machine running VMware Workstation), not inside
# a guest. Vagrant drives Workstation through the VMware Utility, and a guest
# cannot create sibling VMs.
#
#   ./lab.sh check     verify prerequisites, change nothing
#   ./lab.sh boxes     verify each box has a vmware_desktop build
#   ./lab.sh up        create all VMs
#   ./lab.sh up dc01   create one VM
#   ./lab.sh snapshot  snapshot every VM as 'baseline'
#   ./lab.sh restore   roll every VM back to 'baseline'
#   ./lab.sh destroy   delete everything
#
set -uo pipefail

VMS=(dc01 ws01 siem01 kali)
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'

ok()   { echo "  ${GRN}[ok]${RST}   $*"; }
warn() { echo "  ${YEL}[warn]${RST} $*"; }
fail() { echo "  ${RED}[fail]${RST} $*"; FAILED=1; }

check() {
  FAILED=0
  echo "Checking prerequisites..."

  if command -v vagrant >/dev/null 2>&1; then
    ok "vagrant $(vagrant --version 2>/dev/null | awk '{print $2}')"
  else
    fail "vagrant not found -- https://developer.hashicorp.com/vagrant/downloads"
  fi

  if vagrant plugin list 2>/dev/null | grep -q vagrant-vmware-desktop; then
    ok "vagrant-vmware-desktop plugin installed"
  else
    fail "missing plugin: vagrant plugin install vagrant-vmware-desktop"
  fi

  # The VMware Utility is a separate system service from the plugin.
  if pgrep -f vagrant-vmware-utility >/dev/null 2>&1 \
     || sc query "Vagrant VMware Utility" >/dev/null 2>&1; then
    ok "Vagrant VMware Utility running"
  else
    warn "could not detect the Vagrant VMware Utility service."
    warn "install it from the Vagrant VMware Utility downloads page if 'up' fails"
  fi

  if command -v vmrun >/dev/null 2>&1 \
     || [ -x "/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe" ]; then
    ok "VMware Workstation detected"
  else
    warn "vmrun not on PATH -- fine if Workstation is installed elsewhere"
  fi

  # Disk: boxes alone are ~40GB, the running lab wants a lot more.
  AVAIL=$(df -Pk . 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
  if [ -n "${AVAIL:-}" ] && [ "$AVAIL" -lt 150 ]; then
    warn "only ${AVAIL}GB free here -- budget ~150GB for boxes, disks and snapshots"
  else
    ok "disk space looks sufficient (${AVAIL:-?}GB free)"
  fi

  echo
  if [ "$FAILED" -eq 0 ]; then
    echo "${GRN}Prerequisites look good.${RST} Next: ./lab.sh up"
  else
    echo "${RED}Fix the failures above before running ./lab.sh up${RST}"
    exit 1
  fi
}

# Windows provisioning over WinRM times out often enough that a blind retry
# fixes most first-run failures. Same idea as GOAD's playbook failover.
up_one() {
  local vm="$1" attempt=1 max=3
  while [ "$attempt" -le "$max" ]; do
    echo "${YEL}==> ${vm}: attempt ${attempt}/${max}${RST}"
    if vagrant up "$vm" --provider vmware_desktop; then
      ok "${vm} is up"
      return 0
    fi
    warn "${vm} failed on attempt ${attempt}, retrying..."
    attempt=$((attempt + 1))
    sleep 10
  done
  fail "${vm} would not come up after ${max} attempts"
  return 1
}

# Confirm each box actually publishes a vmware_desktop build before you
# spend an hour downloading. Registry provider coverage varies per box AND
# per version, and old versions get retired without warning.
boxes() {
  echo "Checking vmware_desktop availability for each box..."
  echo
  grep -oE '"[^"]+/[^"]+"' Vagrantfile | tr -d '"' | sort -u | while read -r b; do
    case "$b" in */*) ;; *) continue ;; esac
    printf '  %-50s ' "$b"
    if vagrant box add --provider vmware_desktop --box-version 0 "$b" 2>&1 \
         | grep -qi "doesn't support the provider"; then
      echo "${RED}no vmware_desktop build${RST}"
    else
      echo "${GRN}available${RST}"
    fi
  done
  echo
  echo "A failure above means: swap that box in the BOXES hash in the Vagrantfile."
  echo "Browse alternatives at https://portal.cloud.hashicorp.com/vagrant/discover"
}

case "${1:-}" in
  check)   check ;;
  boxes)   boxes ;;
  up)
    shift
    targets=("${@:-}")
    [ -z "${targets[0]:-}" ] && targets=("${VMS[@]}")
    for vm in "${targets[@]}"; do up_one "$vm"; done
    echo
    echo "VMs are up. Now provision from KALI:"
    echo "    cd ansible && ansible-playbook -i inventory/lab.ini site.yml"
    ;;
  snapshot)
    for vm in "${VMS[@]}"; do vagrant snapshot save "$vm" baseline --force; done ;;
  restore)
    for vm in "${VMS[@]}"; do vagrant snapshot restore "$vm" baseline; done ;;
  destroy)
    vagrant destroy -f ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
