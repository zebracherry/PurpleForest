# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# noob2root detection lab
#
# Creates 4 VMs in VMware Workstation Pro. No images are shipped with this
# repo -- Vagrant pulls public boxes from the registry at `vagrant up` time.
# You are responsible for complying with the licensing of whatever OS images
# you download. Windows boxes are Microsoft evaluation builds (180/90 day).
#
# Provisioning is NOT done here. Bring the VMs up on the host, then run the
# Ansible playbooks from the KALI guest. See README.md.

Vagrant.require_version ">= 2.4.0"

LAB_NET = "10.10.10"

# Boxes are pinned so the lab is reproducible. Bump deliberately, not by accident.
#
# Boxes come from gusztavvargadr, who ships a fresh catalog on a monthly
# cycle (version numbers are YYMM.minor.patch) and publishes VirtualBox and
# VMware artifacts for each. StefanScherer's boxes are the better-known
# option but have not been refreshed since 2021, so Server 2022 is not there.
#
# VERIFY BEFORE YOUR FIRST RUN -- run `./lab.sh boxes`. Provider coverage
# varies per box and per version, and old versions get retired. If a box has
# no vmware_desktop build, swap it here rather than fighting it.
#
# Leaving version unpinned ( ">= 0" ) takes whatever is current. Pin to an
# exact version once your build works, so readers get the same lab you
# screenshotted.

# --- Workstation OS -------------------------------------------------------
# Windows 10 is the default because it boots with no firmware prerequisites.
# Windows 11 needs TPM 2.0 and Secure Boot on the host and the guest; see
# docs/windows-11.md before switching. Nothing in the exercise series
# depends on which one you pick.
#
#   LAB_WS_OS=win11 vagrant up ws01
#
WS_OS = (ENV["LAB_WS_OS"] || "win10").downcase

WS_BOXES = {
  "win10" => "gusztavvargadr/windows-10-enterprise",
  "win11" => "gusztavvargadr/windows-11-enterprise"
}

unless WS_BOXES.key?(WS_OS)
  abort "LAB_WS_OS must be one of: #{WS_BOXES.keys.join(', ')} (got '#{WS_OS}')"
end

BOXES = {
  "dc01"   => { box: "gusztavvargadr/windows-server-2022-standard", version: ">= 0" },
  "ws01"   => { box: WS_BOXES[WS_OS],                               version: ">= 0" },
  "siem01" => { box: "bento/ubuntu-24.04",                          version: ">= 0" },
  "kali"   => { box: "kalilinux/rolling",                           version: ">= 0" }
}

Vagrant.configure("2") do |config|

  # Synced folders are a common source of Windows provisioning hangs.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ---------------------------------------------------------------- DC01 ---
  config.vm.define "dc01" do |cfg|
    cfg.vm.box         = BOXES["dc01"][:box]
    cfg.vm.box_version = BOXES["dc01"][:version]
    cfg.vm.hostname    = "dc01"
    cfg.vm.communicator = "winrm"
    cfg.winrm.username = "vagrant"
    cfg.winrm.password = "vagrant"
    cfg.vm.boot_timeout = 900
    cfg.vm.graceful_halt_timeout = 300

    cfg.vm.network "private_network", ip: "#{LAB_NET}.10"

    cfg.vm.provider "vmware_desktop" do |v|
      v.gui       = true
      v.memory    = 4096
      v.cpus      = 2
      v.vmx["displayname"]              = "lab-dc01"
      v.vmx["virtualhw.version"]        = "19"
      v.vmx["vhv.enable"]               = "FALSE"
      v.whitelist_verified              = true
    end
  end

  # ---------------------------------------------------------------- WS01 ---
  config.vm.define "ws01" do |cfg|
    cfg.vm.box         = BOXES["ws01"][:box]
    cfg.vm.box_version = BOXES["ws01"][:version]
    cfg.vm.hostname    = "ws01"
    cfg.vm.communicator = "winrm"
    cfg.winrm.username = "vagrant"
    cfg.winrm.password = "vagrant"
    cfg.vm.boot_timeout = 900
    cfg.vm.graceful_halt_timeout = 300

    cfg.vm.network "private_network", ip: "#{LAB_NET}.20"

    cfg.vm.provider "vmware_desktop" do |v|
      v.gui       = true
      v.memory    = 4096
      v.cpus      = 2
      v.vmx["displayname"]       = "lab-ws01-#{WS_OS}"
      v.vmx["virtualhw.version"] = "19"
      v.whitelist_verified       = true

      if WS_OS == "win11"
        # Windows 11 requires UEFI + Secure Boot + TPM 2.0. Attaching a
        # virtual TPM in Workstation forces VM encryption, which breaks
        # `vagrant snapshot` -- and snapshots are how you reset between
        # exercises. Read docs/windows-11.md before going further.
        v.vmx["firmware"]                = "efi"
        v.vmx["uefi.secureBoot.enabled"] = "TRUE"
        v.vmx["managedvm.autoAddVTPM"]   = "software"
      end
    end
  end

  # -------------------------------------------------------------- SIEM01 ---
  config.vm.define "siem01" do |cfg|
    cfg.vm.box         = BOXES["siem01"][:box]
    cfg.vm.box_version = BOXES["siem01"][:version]
    cfg.vm.hostname    = "siem01"

    cfg.vm.network "private_network", ip: "#{LAB_NET}.30"

    cfg.vm.provider "vmware_desktop" do |v|
      v.gui       = false
      v.memory    = 8192
      v.cpus      = 4
      v.vmx["displayname"] = "lab-siem01"
      v.whitelist_verified = true
    end

    # OpenSearch needs this and will refuse to start without it.
    cfg.vm.provision "shell", inline: <<-SHELL
      echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
      sysctl -p /etc/sysctl.d/99-opensearch.conf
    SHELL
  end

  # ---------------------------------------------------------------- KALI ---
  # This is both the attacker box and the Ansible control node.
  config.vm.define "kali" do |cfg|
    cfg.vm.box         = BOXES["kali"][:box]
    cfg.vm.box_version = BOXES["kali"][:version]
    cfg.vm.hostname    = "kali"

    cfg.vm.network "private_network", ip: "#{LAB_NET}.50"

    cfg.vm.provider "vmware_desktop" do |v|
      v.gui       = true
      v.memory    = 4096
      v.cpus      = 2
      v.vmx["displayname"] = "lab-kali"
      v.whitelist_verified = true
    end

    cfg.vm.provision "shell", path: "scripts/bootstrap-kali.sh"
  end
end
