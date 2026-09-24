# Detections

One folder per exercise. Each holds:

- `sigma.yml`      — the rule in Sigma format (portable)
- `graylog.md`     — the Graylog search query and alert definition
- `notes.md`       — expected false positives, tuning, and how to evade it

Sigma is the source of truth. Graylog queries are generated from it, so the
rules stay useful to readers running Splunk or Elastic instead.
