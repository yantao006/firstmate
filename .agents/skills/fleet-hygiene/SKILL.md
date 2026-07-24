---
name: fleet-hygiene
description: Generate a read-only fleet hygiene checklist when the captain invokes /fleet-hygiene or asks for fleet hygiene, treehouse cleanup, project cleanup, or a treehouse and project cleanup checklist. Runs the deterministic audit, ensures the dated report exists, summarizes Layer A and Layer B tables plus cautions, and never deletes or prunes anything.
user-invocable: true
metadata:
  internal: true
---

# fleet-hygiene

Generate the captain's current treehouse and stale-project cleanup checklist without performing cleanup.
The policy contract lives in `docs/fleet-hygiene.md`.
The script header and `--help` own command mechanics.

## Procedure

1. Run `bin/fm-fleet-hygiene-audit.sh --write` from the tracked firstmate code root.
2. If `gh-axi` is available and GitHub authentication is healthy, add `--check-prs` so eligible Layer B rows can be safely prechecked.
3. Read the resulting `data/hygiene/report-YYYY-MM-DD.md` and verify it contains the Layer A table, Layer B table, both appendices, and reply instructions.
4. Summarize the checklist in chat with a compact Layer A table, a compact Layer B table, the important appendix cautions, and the exact report path.
5. End by telling the captain to reply with the Layer A pool/slot rows and Layer B project/tier rows they want handled in a separate instruction.

## Safety boundary

This skill is read-mostly and may write only the dated hygiene report.
Never invoke treehouse destroy or prune, close or defer tracked work, move or archive data, edit the project registry, remove a project, delete a clone, or alter GitHub as part of this skill.
Do not interpret checked report rows as authority to perform cleanup.
If GitHub, git, Beads, backlog, or metadata evidence is unavailable or uncertain, preserve the audit's warning and do not upgrade an unchecked row.
