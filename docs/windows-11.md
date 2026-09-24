# Using Windows 11 for WS01

The lab defaults to **Windows 10 Enterprise** for the workstation. It boots
with no firmware prerequisites, snapshots cleanly, and nothing in the
exercise series depends on the OS version.

Windows 11 works too, but it costs you some setup and one real trade-off.
Read this before switching.

```bash
LAB_WS_OS=win11 ./lab.sh up ws01
```

---

## What Windows 11 requires

Three things, all of which have to line up:

| Layer | Requirement |
|---|---|
| Physical host | CPU virtualisation enabled in BIOS/UEFI (Intel VT-x / AMD-V) |
| VMware Workstation | Hardware version 19+, UEFI firmware, Secure Boot enabled |
| Guest VM | A virtual TPM 2.0 device |

The Vagrantfile sets the Workstation side automatically when
`LAB_WS_OS=win11`. The host side is on you.

---

## Enabling virtualisation on the host

If VMs fail to start at all, virtualisation is off in firmware. Check first:

**Windows** — open Task Manager → Performance → CPU. Look for
"Virtualization: Enabled". If it says Disabled:

1. Reboot into BIOS/UEFI (usually `F2`, `F10`, `Del`, or via
   Settings → System → Recovery → Advanced startup → UEFI Firmware Settings)
2. Find **Intel VT-x** / **Intel Virtualization Technology**, or
   **AMD-V** / **SVM Mode** — usually under Advanced or CPU Configuration
3. Enable it, save, reboot

**Also check Hyper-V is off.** Hyper-V and VMware Workstation fight over the
hypervisor on Windows hosts, and the symptoms are confusing. In an admin
PowerShell:

```powershell
bcdedit /set hypervisorlaunchtype off
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
# also turn off Core Isolation / Memory Integrity in Windows Security
```

Reboot after. Newer Workstation versions coexist with Hyper-V, but not
reliably enough to debug during a lab build.

---

## The trade-off you need to know about

**Attaching a virtual TPM forces VMware to encrypt the VM.** Encrypted VMs
do not snapshot the way unencrypted ones do, and `vagrant snapshot` will
either fail or behave unpredictably.

Snapshots are how you reset the lab between exercises. Attack telemetry from
one exercise poisons the baseline for the next, so losing snapshots is not a
cosmetic problem — it means rebuilding the domain by hand every time.

Three ways to handle it:

1. **Use Windows 10.** Recommended for anyone following the exercise series.
2. **Snapshot inside Workstation's UI** instead of via Vagrant. Slower and
   manual, but it works on encrypted VMs.
3. **Rebuild instead of restoring** — `vagrant destroy ws01 && vagrant up
   ws01` then re-run the workstation playbook. Clean, but slow.

---

## Does it matter for detection?

Barely, for this series. Both are current clients with the same Event Log
channels, the same Sysmon behaviour, and the same audit policy surface.

Where they diverge is credential protection. Windows 11 enables
Virtualization-Based Security and Credential Guard by default on capable
hardware, which changes how LSASS dumping behaves. That is a genuinely
interesting difference — but it makes the credential-dumping exercise
*harder to demonstrate*, not more instructive, on a first pass.

The honest sequencing: run the exercises on Windows 10 first so you see the
attack work and the detection fire. Then, if you want, rebuild WS01 on
Windows 11 with Credential Guard on and write the follow-up post about what
changed. That comparison is better content than either box alone.

---

## A note on Windows 10

Windows 10 reached end of support in October 2025, so the box gets no
security updates. For an isolated lab that is fine, and arguably realistic —
plenty of real environments run unpatched endpoints. Do not connect it to
anything you care about.
