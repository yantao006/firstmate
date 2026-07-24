# Fleet hygiene policy

Fleet hygiene is a manual, read-only-first review of treehouse disk usage and possibly stale projects.
The captain invokes `/fleet-hygiene`; no schedule, cron job, or automatic prune is permitted.
The P0 workflow produces a checklist only, and every deletion, archive, task closure, registry change, or project removal is outside P0 and requires a later explicit instruction.
`bin/fm-fleet-hygiene-audit.sh` owns command mechanics, flags, input discovery, report paths, and conservative detection details.

## Layer A - treehouse slots

Layer A considers each `~/.treehouse/<pool>/<slot>/` independently, then applies the Size quota per pool.
The audit uses bounded recent-mtime inspection, slot disk usage, git safety evidence when available, and every `state/*.meta` `worktree=` reference.

### Safety classes and hard exclusions

A slot referenced by live metadata is classified `live` and is always excluded from safe candidates.
A dirty slot, a slot with unmerged commits, an in-use or leased slot, or any other non-disposable slot is always excluded from safe candidates.
An orphan or a slot whose git safety cannot be established is shown separately in the appendix and is never a safe candidate.
Only a slot established as `disposable` can enter either safe-candidate path.

### Safe-candidate paths

The Age and Size paths are alternatives after the safety exclusions.

| Path | Conditions | Keep two slots per pool |
|---|---|---|
| Age | Disposable and at least 7 days since the most recent bounded write | No |
| Size | Disposable, less than 7 days since the most recent bounded write, and at least 1 GiB | Yes |

A slot that is both at least 7 days old and at least 1 GiB follows Age.
Age does not have a minimum size and can select every old disposable slot in a pool.
Size is only for young large slots and cannot reduce the hypothetical post-selection pool below two remaining slots.
The Size calculation assumes every selected Age slot is removed first, counts live and otherwise retained slots among the remaining two, and reduces Size selections when needed.
When Size must retain candidates, it keeps the most recently written slot first and the larger slot second.
Within each candidate path, older and then larger slots are listed first.
Dirty, unmerged, live, orphan, retained-by-quota, and below-threshold slots remain visible only in the appendix.

## Layer B - stale projects

Layer B identifies projects from `data/projects.md` and local `projects/<name>` clones, including research repositories with no Beads records.
The stale clock uses the minimum age among available project activity sources: project Beads activity when detectable, the local clone's latest commit or directory mtime fallback, and matching `data/docs/<name>*` activity.
A project at least 30 days stale enters the candidate list only after the hard exclusions are applied.
A project 30 through 44 days stale is listed for observation and is not prechecked.
A project at least 45 days stale is prechecked for tier 2 only when all required safety evidence is clear.
An unavailable or failed open-PR check is unknown and prevents a tier 2 precheck.

### Layer B hard exclusions

The static whitelist is `adcue`, `firstmate`, and `google-ads-tools`, plus captain-configured additions.
A project with in-flight work or an active second mate is excluded.
A project with queued ship or documentation work is excluded.
A project with an unresolved captain or Beads decision is excluded when detectable.
A project with an open PR is excluded and shown with an instruction to merge or close the PR first.
A project with an obviously dirty clone or unpushed commits is excluded.
Uncertain local-branch, decision, or PR evidence is highlighted and never prechecked.

### Retirement tiers

| Tier | Meaning | Local clone | GitHub remote |
|---|---|---|---|
| 1 | Sleep the project and optionally clean treehouse slots through Layer A | Keep | Keep |
| 2 | Abandon locally by closing or archiving tracked work, clearing the project's non-live treehouse slots, archiving clearly owned local data, and removing it from the active registry | Keep | Keep |
| 3 | Apply tier 2 and then remove the local clone and active registration | Remove | Keep |

Tier 2 is the default recommendation.
Tier 2 and tier 3 may later clear an entire project treehouse pool without the Layer A Size keep-two quota, but live metadata worktrees remain excluded.
GitHub repositories are never archived or deleted by this policy.
Ambiguously owned data is listed for review and is never moved automatically.

## P0 report and confirmation boundary

Captain-facing P0 presentation is delivered in Chinese through an interactive Lavish checklist, with the dated Markdown report retained as its source artifact.
The P0 report contains a prechecked Layer A table, a Layer B table, appendices for every exclusion or caution the scanner can establish, and a reply format.
A captain reply identifies desired Layer A pool/slot rows and Layer B project/tier rows.
That reply does not alter P0's zero-delete behavior, and implementation of any selected action belongs to a later phase with fresh safety checks and explicit authority.
