# Troubleshooting

Ordered roughly by how often each one bites.

---

## `vagrant up` fails immediately

**"Box doesn't support the provider you requested"**

Registry provider coverage varies by box *and* by version, and old versions
get retired, and maintainers sometimes rename boxes (a `404` from the
registry means the name no longer exists). Check the box on the registry,
then swap it in the `BOXES` or `WS_BOXES` hash at the top of the `Vagrantfile`. Browse alternatives at
the [HCP Vagrant registry](https://portal.cloud.hashicorp.com/vagrant/discover).

**"The Vagrant VMware Utility is not installed"**

The plugin and the utility are two separate installs. `vagrant plugin
install vagrant-vmware-desktop` gets the plugin; the utility is a system
package you download and install separately.

**VMs won't start at all**

Virtualisation is off in firmware, or Hyper-V is holding the hypervisor.
See [windows-11.md](windows-11.md) — the fix is the same regardless of which
guest OS you chose.

---

## Windows provisioning hangs or times out

This is the single most common failure, and it's usually transient.
`.\lab.ps1 up` (and `./lab.sh up` on Linux) already retries each VM three
times.

If it persists:

```bash
vagrant destroy -f ws01
vagrant up ws01 --provider vmware_desktop --debug 2>&1 | tee up.log
```

Common causes:

- **WinRM not ready.** The box is still running sysprep. Increase
  `boot_timeout` in the Vagrantfile.
- **Synced folders.** Already disabled in this repo — if you re-enable them,
  expect hangs.
- **Host under memory pressure.** Bring VMs up one at a time rather than all
  four at once.

---

## Domain join fails on WS01

Almost always DNS. `WS01` must resolve through `DC01`, not through the NAT
adapter's DNS.

From WS01:

```powershell
Get-DnsClientServerAddress          # should show 10.10.10.10
Resolve-DnsName _ldap._tcp.dc._msdcs.corp.lab -Type SRV
```

If the SRV record doesn't resolve, the DC either isn't finished promoting or
its DNS role didn't start. From DC01:

```powershell
Get-Service NTDS, DNS
Get-ADDomain
```

The workstation role already waits and retries on this, so a hard failure
usually means the DC itself didn't build.

---

## No events arriving in Graylog

Work down the pipeline, don't guess.

**1. Is Vector running and valid?**

```powershell
Get-Service vector
& 'C:\Program Files\Vector\bin\vector.exe' validate `
  --config 'C:\Program Files\Vector\config\vector.yaml'
```

**2. Is Vector reading anything?**

```powershell
& 'C:\Program Files\Vector\bin\vector.exe' top
```

If source throughput is zero, the source name is wrong. Vector has renamed
the Windows event log source across releases — run `vector list` and
reconcile with `ansible/roles/telemetry/templates/vector.yaml.j2`.

**3. Is the sink reaching the SIEM?**

```powershell
Test-NetConnection 10.10.10.30 -Port 12201
```

**4. Is Graylog listening?**

From SIEM01:

```bash
docker compose -f /opt/graylog/docker-compose.yml ps
docker compose -f /opt/graylog/docker-compose.yml logs graylog --tail 50
```

**Events arrive but look garbled** — GELF framing mismatch. The Vector sink
uses a null-delimited character framing and the Graylog input must have
`use_null_delimiter: true`. Both are set by the playbooks; if you hand-edited
one, match the other.

---

## Detections never fire

Before blaming the rule, confirm Windows is actually logging the event.

```powershell
auditpol /get /category:*
```

Check specifically:

| Missing subcategory | Breaks |
|---|---|
| Kerberos Service Ticket Operations | Kerberoasting (4769) |
| Kerberos Authentication Service | AS-REP roasting (4768) |
| Directory Service Access | DCSync (4662) |
| Process Creation | LOLbins (4688) |

And confirm command lines are included:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' `
  -Name ProcessCreationIncludeCmdLine_Enabled
```

All of this is set by the `dc` and `workstation` roles. If it's missing,
those roles didn't complete — re-run the playbook rather than fixing by hand.

---

## Graylog won't start

Almost always OpenSearch. Check its logs first:

```bash
docker compose -f /opt/graylog/docker-compose.yml logs opensearch --tail 50
```

- **`max virtual memory areas vm.max_map_count [65530] is too low`** — the
  Vagrantfile sets this at boot. If you rebuilt the VM outside Vagrant,
  re-apply: `sysctl -w vm.max_map_count=262144`.
- **Container OOM-killed** — lower `opensearch_heap` in
  `group_vars/all.yml`, or give SIEM01 more RAM.
- **Disk full** — set `graylog_retention_days` lower and delete old indices
  from the Graylog UI. Log storage grows faster than anything else here.

---

## Snapshots behave oddly

You're probably on Windows 11 with a vTPM attached, which forces VMware to
encrypt the VM. Encrypted VMs don't snapshot through Vagrant reliably. See
[windows-11.md](windows-11.md) for the three ways to handle it.

---

## Windows evaluation expired

```powershell
slmgr /rearm
```

Then reboot. This buys another period, a limited number of times. Eventually
you rebuild — which is a good argument for keeping the lab reproducible
rather than precious.

---

## Starting over

```powershell
.\lab.ps1 destroy        # every lab VM (never touches your own Kali)
vagrant destroy -f ws01  # one VM
```

Then rebuild. On a working setup the full cycle is about 70 minutes, most of
it unattended.
