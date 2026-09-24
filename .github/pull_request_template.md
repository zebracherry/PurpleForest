### What this changes

<!-- One or two lines -->

### Type

- [ ] New exercise
- [ ] Detection rule
- [ ] Bug fix
- [ ] Docs
- [ ] Infrastructure

### For a new exercise

- [ ] Misconfiguration is behind a toggle, defaulting to `false`
- [ ] Attack reproduces from the commands as written
- [ ] Detection fires on a clean lab
- [ ] False positives documented
- [ ] Evasion documented
- [ ] Sigma rule in `detections/<exercise>/sigma.yml`
- [ ] Row added to `docs/exercises.md`

### Tested from clean

- [ ] `./lab.sh destroy && ./lab.sh up && ansible-playbook site.yml`

<!-- If not, say what you did test. Partial testing is fine if you're
     honest about it — silent partial testing is what costs review rounds. -->
