# Kerberoasting in Graylog

Queries below were run against the PurpleForest lab on 2026-10-04, over a
seven-day window, on a domain BadBlood had seeded with 52 SPN accounts. The
counts in each **Result** line are what they actually returned, so you can
tell a broken query from a quiet domain.

## Field names

Vector's `enrich` transform flattens the Windows `EventData` section to
top-level fields and keeps Microsoft's own key names, so Sigma field names map
straight across. The one exception is the event ID, which lives in the event's
`System` section rather than `EventData`:

| Sigma | Graylog |
|---|---|
| `EventID` | `event_id` |
| `ServiceName` | `ServiceName` |
| `TargetUserName` | `TargetUserName` |
| `TicketEncryptionType` | `TicketEncryptionType` |
| `TicketOptions` | `TicketOptions` |
| `Status` | `Status` |
| `IpAddress` | `IpAddress` |

If `ServiceName` does not exist as a field, your Vector config predates the
flattening fix and `EventData` is still arriving as one JSON string. Events
already in the index are **not** reparsed — only events received after the
config change have these fields. Re-run `ansible-playbook site.yml`.

## Excluding computer accounts

Every machine in the domain requests service tickets constantly, and those
SPNs resolve to accounts ending in `$`. The obvious exclusion does not work:

```
NOT ServiceName:*$          <-- rejected: Graylog disallows a leading wildcard
```

Use a regex term instead. This is the form every query below relies on:

```
NOT ServiceName:/.*\$/
```

Result: 153 of 159 events, excluding 6 computer-account requests.

---

## Rule 1 - RC4 service ticket issued

```
event_id:4769
  AND TicketEncryptionType:"0x17"
  AND Status:"0x0"
  AND NOT ServiceName:/.*\$/
```

**Result: 1 event in 7 days** — the one account deliberately pinned to RC4.
Zero legitimate RC4 tickets in the whole window; every normal request was
`0x12` (AES256).

A near-zero false-positive rate, and almost no recall. It cannot see the AES
roast, which is what a default modern KDC hands out. Do not ship it alone.

## Rule 2 - requests refused for encryption type

```
event_id:4769 AND Status:"0xe"
```

**Result: 104 events in 7 days**, all from `10.10.10.50`, none legitimate.

`0xe` is `KDC_ERR_ETYPE_NOSUPP`. These are requests the KDC refused outright,
so `TicketEncryptionType` is `0xffffffff` and `ServiceSid` is the null SID
`S-1-0-0`. This is what a default `GetUserSPNs -request` run looks like
against a patched DC: loud, and completely unsuccessful.

## Rule 3 - burst of refusals from one account

Not a search. **Alerts & Events → Event Definitions → Create**:

| Field | Value |
|---|---|
| Condition type | Aggregation |
| Search query | `event_id:4769 AND Status:"0xe"` |
| Streams | All messages |
| Search within | 1 minute |
| Execute every | 1 minute |
| Group by | `TargetUserName` |
| Aggregation | `count()` |
| Condition | `count()` **>** `20` |

Measured burst rate in the lab: **52 refusals in a single second**, twice,
against a baseline of a few 4769 events per hour. A threshold of 20/minute has
enormous headroom here; set yours from your own baseline, not from this number.

## Rule 4 - one account, many distinct SPNs

The etype-agnostic one, and the only rule here that survives an attacker who
takes AES tickets or uses only built-in Windows APIs.

| Field | Value |
|---|---|
| Condition type | Aggregation |
| Search query | `event_id:4769 AND Status:"0x0" AND NOT ServiceName:/.*\$/` |
| Search within | 5 minutes |
| Execute every | 1 minute |
| Group by | `TargetUserName` |
| Aggregation | `card(ServiceName)` |
| Condition | `card(ServiceName)` **>** `15` |

Lab measurement: the roasting account touched **56 distinct SPNs**; the only
other principal on the domain touched **2**. That separation is the detection.

## The tool fingerprint, and why it is not a rule

```
event_id:4769 AND TicketOptions:"0x40810010"
```

**Result: 108 events** — every one from Kali.

```
event_id:4769 AND TicketOptions:"0x40810000"
```

**Result: 26 events** — and only 4 of those are legitimate. The other 22 are
the on-host PowerShell evasion in notes.md, which is an attack carrying the
native value.

Impacket sets ticket options Windows does not natively send, which makes this
look like a perfect discriminator. It is not. A legitimate request from the DC
carried `0x60810010`, which also has the `0x10` bit set, so the bit itself is
not attacker-only. Worse, the native value is what the evasion produces, so
the fingerprint is missing from exactly the attack you most want to catch.
Across a seven-day window on a lab with almost no genuine Kerberos traffic,
that is far too little evidence to alert on.

Use it to raise confidence on an alert another rule already raised, and to
pivot during triage. Never as a standalone detection.
