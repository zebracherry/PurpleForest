# Kerberoasting - false positives, tuning and evasion

Everything here was measured in the PurpleForest lab on 2026-10-04: Windows
Server 2022 DC at current patch level, domain functional level
`Windows2016Domain`, 2,491 users and 52 SPN accounts courtesy of BadBlood,
attacker on Kali at `10.10.10.50`, workstation `ws01` at `10.10.10.20`.

## What actually happens on a patched DC

The thing most kerberoasting write-ups get wrong, because most were written
before November 2022: **you cannot get an RC4 service ticket for an account
that holds an AES key.** The KDC encrypts the ticket with the strongest key
the service account has, regardless of what the client asks for.

Impacket's `GetUserSPNs` converts the supplied password to an NT hash on
purpose, so the TGT session key is RC4 and every TGS request asks for RC4. Its
own comment says so: *"In order to maximize the probability of getting session
tickets with RC4 etype"*. Against a default modern domain that backfires
completely.

`msDS-SupportedEncryptionTypes` on the service account decides everything.
Verified, one row at a time:

| Value | Result |
|---|---|
| unset (the default) | `KDC_ERR_ETYPE_NOSUPP` **to an RC4-only client**. All 52 accounts failed Impacket. The same accounts hand out AES tickets happily to a client that advertises AES — see the evasion section. |
| `0x18` AES128+AES256 | `$krb5tgs$18$`, but only once the TGT itself is AES-negotiated |
| `0x1C` RC4+AES128+AES256 | Ticket issued — **still AES256**. Re-enabling RC4 does not restore the old attack. |
| `0x4` RC4 only | `$krb5tgs$23$`. The classic attack, and the only way to get it. |

The `0x1C` row is the trap. "Just turn RC4 back on" is the obvious thing to
try and it changes nothing, because the account still holds an AES key and the
KDC still prefers it.

### Cracking cost

Same lab, same CPU (i7-11800H, 4 cores to the VM, PoCL on CPU):

| | etype | hashcat mode | speed | time to crack |
|---|---|---|---|---|
| `svc_backup_sql` / `Password123` | 23 (RC4) | 13100 | **1,490,800 H/s** | instant, plain rockyou |
| `svc_mssql` / `Summer2024` | 18 (AES256) | 19700 | **2,099 H/s** | 20s, hybrid `base.txt ?d?d?d?d` |

**AES costs the attacker roughly 710x.** It does not save a weak password.
Both of these fell in under a minute. AES is worth enforcing, but it buys time
rather than safety, and the real fix is password length on service accounts —
or a gMSA, where the password is 240 bytes and managed.

## False positives

Honest caveat first: **this lab produced 159 `4769` events in seven days, 134 of them mine.** A
real domain produces millions a day, and `4769` is usually one of the top
events by volume in the whole estate. A zero false-positive rate here means
almost nothing about your environment. Baseline before you deploy any of this.

| Rule | Lab FPs | What will actually generate them |
|---|---|---|
| 1 - RC4 ticket issued | 0 in 7 days | Any legacy app with a service account pinned to RC4. Common in practice, and it will be *constant* rather than bursty. Allowlist by `ServiceName`, never by the requesting account. |
| 2 - ETYPE_NOSUPP | 0 in 7 days | Genuinely broken clients and old appliances. They hammer the same one or two SPNs; an attacker sweeps many distinct ones. |
| 3 - burst of refusals | 0 in 7 days | An application retrying in a loop. Same discriminator: distinct `ServiceName` count. |
| 4 - one account, many SPNs | 0 in 7 days | **This is the one that will hurt.** Vulnerability scanners, asset inventory, backup and monitoring agents all authenticate broadly and legitimately. Allowlist those service accounts explicitly and keep the list reviewed. |

Rule 1 is high precision and poor recall. Rule 4 is the opposite. Ship both.

### Thresholds

Rule 3 is set to 20 refusals per account per minute. Measured burst: **52 in a
single second**, twice. Rule 4 is set to 15 distinct SPNs per account per five
minutes. Measured: the roasting account touched **56 distinct SPNs**, while the
only other principal on the domain touched **2**.

Both thresholds have enormous headroom in a lab and are probably wrong for
you. Run the rule-4 query as a search over a week, grouped by
`TargetUserName`, and set the threshold above your noisiest legitimate account
rather than above the lab's.

## Evasion

### What beats rule 1

Take the AES ticket. `$krb5tgs$18$` never has `TicketEncryptionType: 0x17`, so
the RC4 rule is blind to it. **Cost to the attacker:** ~710x slower cracking,
which against a genuinely strong service-account password is the difference
between minutes and never. Against `Summer2024` it cost 20 seconds.

### What beats rules 2 and 3

Target one account instead of sweeping. `-request-user svc_mssql` produces a
single `4769` and no burst at all. **Cost:** you need to know which account is
worth roasting, which means doing the LDAP discovery first and choosing well —
and that discovery is itself visible as `4662`, if directory-service auditing
is on. Slow-rolling a sweep with a delay and jitter has the same effect on
these two rules.

### What beats the tool fingerprint

Stop using the tool. From a domain-joined host, LDAP discovery through
`DirectorySearcher` and ticket requests through
`System.IdentityModel.Tokens.KerberosRequestorSecurityToken` use nothing but
built-in Windows APIs, so the TGS-REQ is constructed by Windows itself. In the
lab this produced `TicketOptions: 0x40810000` — the native value — with
`TicketEncryptionType: 0x12` from a legitimate workstation IP. By etype,
ticket options and source host it is indistinguishable from a normal user
opening a file share.

**Cost, and this is the important part:** that method leaves the ticket in the
LSA cache and hands you nothing to crack. Getting the bytes out needs Rubeus
or Mimikatz reading from LSASS, which is a far louder event than the one you
just avoided — Sysmon Event 10 `ProcessAccess` on `lsass.exe`, which is the
single highest-value detection in this whole series. The evasion does not
remove the detection surface, it moves it somewhere better lit.

### Do not mistake this for immunity

It is tempting to read the `NOSUPP` wall as "a patched domain cannot be
kerberoasted". It cannot be kerberoasted *by Impacket's default*, which is not
the same thing. Those 52 accounts have `msDS-SupportedEncryptionTypes` unset
and refused every RC4 request — and then issued AES tickets without complaint
to a client that asked properly. Verified: 20 of them, from ws01, in one run.

### What all three evasions together look like

The on-host PowerShell run, measured end to end:

| | Impacket sweep | On-host PowerShell |
|---|---|---|
| Events | 104 refusals + 3 tickets | 22 tickets, 0 refusals |
| `Status` | `0xe` | `0x0` |
| `TicketEncryptionType` | `0xffffffff` / `0x17` | `0x12` (AES256) |
| `TicketOptions` | `0x40810010` | `0x40810000` (native) |
| Source | Kali, `10.10.10.50` | domain-joined ws01, `10.10.10.20` |
| Rule 1 (RC4) | fires | **0 matches** |
| Rules 2+3 (NOSUPP) | fires | **0 matches** |
| Rule 4 (SPN volume) | 56 distinct SPNs, fires | **20 distinct SPNs, fires** |

Three of the four rules go blind. By etype, ticket options and source host the
second run is a normal user opening file shares.

### What survives all of it

Rule 4. The behaviour of the technique is "one principal asks about an
unusual number of services in a short time", and no amount of etype or
tooling choice changes that. Only genuine restraint does — roasting two or
three well-chosen accounts rather than sweeping the domain. Which is exactly
why the volume threshold matters more than the clever fingerprint, and why
tuning it against your own baseline is the real work.

## Fixing it, not just seeing it

In rough order of how much they buy you:

1. **gMSAs** for anything that can take one. 240-byte managed password; the
   hash is not crackable in any meaningful sense.
2. **Length on the rest.** 25+ characters on service accounts. This defeats
   the attack outright rather than slowing it down.
3. **Remove stale SPNs.** BadBlood gave this domain 52 of them; a real domain
   accumulates them the same way. Every one is an offer.
4. **Drop RC4.** Set `msDS-SupportedEncryptionTypes` to `0x18` on service
   accounts, then remove RC4 domain-wide once nothing breaks. Worth 710x.
5. **Audit who can read SPNs.** Any authenticated user can enumerate them by
   default, which is what makes step one of the attack free.
