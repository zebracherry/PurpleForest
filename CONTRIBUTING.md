# Contributing

Contributions are welcome — especially new exercises, detection rules, and
fixes for things that broke on your setup but not mine.

---

## The bar for an exercise

An exercise isn't finished when the attack works. It's finished when:

- [ ] The attack is **reproducible** from the commands exactly as written,
      on a lab built from `main`
- [ ] The detection **fires on a clean lab** — not on a domain you'd already
      broken in other ways
- [ ] **False positives are documented honestly.** If the rule alerts on
      normal admin activity, say so and say roughly how often
- [ ] **Evasion is documented.** How does a real attacker dodge this, and
      what does it cost them? A rule you can't describe evading is a rule
      you don't understand yet
- [ ] The Sigma rule lives in `detections/<exercise>/sigma.yml`

That last-but-one point is the one people skip, and it's what separates this
from the hundred other detection write-ups.

---

## Adding an exercise

**1. Add a misconfiguration toggle** in `ansible/group_vars/all.yml`,
defaulting to `false`:

```yaml
misconfig_your_thing: false
```

**2. Implement it** in the relevant role, guarded by the flag:

```yaml
- name: Misconfig - short description
  when: misconfig_your_thing | bool
  block:
    - ...
```

Never make it unconditional. The clean-domain default is load-bearing — a
domain broken in twelve ways makes it impossible to tell which flaw an
attack actually used.

**3. Add the detection** in `detections/<exercise>/`:

```
detections/kerberoasting/
├── sigma.yml      the rule (source of truth)
├── graylog.md     the Graylog query and alert definition
└── notes.md       false positives, tuning, evasion
```

Sigma is the source of truth so the rules stay useful to people running
Elastic or Splunk instead of Graylog.

**4. Update `docs/exercises.md`** with the row for your exercise.

---

## Testing before you open a PR

Test from a genuinely clean state, not from your working lab:

```bash
./lab.sh destroy
./lab.sh up
# from KALI
ansible-playbook site.yml -e misconfig_your_thing=true
```

A playbook that only works on your half-configured box is the most common
reason a PR needs three rounds of review.

Lint locally:

```bash
yamllint .
ansible-lint ansible/
shellcheck lab.sh scripts/*.sh
```

CI runs all three.

---

## Reporting a problem

Open an issue with:

- What you ran and what happened
- Host OS, VMware Workstation version, Vagrant version
- Relevant output — `vagrant up --debug`, or the failing Ansible task

Check [docs/troubleshooting.md](docs/troubleshooting.md) first. Most
first-run failures are covered there, especially box provider mismatches and
Vector source naming.

---

## Scope

**In scope:** attack/detection exercises, telemetry improvements, detection
rules, docs, reliability fixes, support for other hypervisors.

**Out of scope:** anything that only works against systems you don't own.
This is a lab. Keep it that way.

---

## Ground rules

Everything here targets an isolated lab you built yourself. Don't file
issues containing real hostnames, real credentials, or telemetry from a
production environment. If a detection idea comes from work, bring the
technique, not the data.
