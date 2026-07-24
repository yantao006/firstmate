---
name: fleet-hygiene
description: Generate and summarize a fleet hygiene checklist when the captain invokes /fleet-hygiene or asks for fleet hygiene, treehouse cleanup, project cleanup, or a treehouse and project cleanup checklist.
user-invocable: true
metadata:
  internal: true
---

# fleet-hygiene

The policy contract lives in `docs/fleet-hygiene.md`.
The script header and `--help` own command mechanics.

## Procedure

1. Run `bin/fm-fleet-hygiene-audit.sh --write` from the tracked firstmate code root.
2. Add `--check-prs` only when the captain explicitly requests PR checks.
3. Read the resulting `data/hygiene/report-YYYY-MM-DD.md` and verify it contains the Layer A table, Layer B table, both appendices, and reply instructions.
4. Summarize the checklist in chat with a compact Layer A table, a compact Layer B table, the important appendix cautions, and the exact report path.
5. End by telling the captain to reply with the Layer A pool/slot rows and Layer B project/tier rows they want handled in a separate instruction.
