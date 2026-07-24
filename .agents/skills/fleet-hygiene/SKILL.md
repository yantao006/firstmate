---
name: fleet-hygiene
description: Generate and present a fleet hygiene checklist when the captain invokes /fleet-hygiene or asks for fleet hygiene, treehouse cleanup, project cleanup, or a treehouse and project cleanup checklist.
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
3. Read the resulting Chinese `data/hygiene/report-YYYY-MM-DD.md` and verify it contains the A 层 table, B 层 table, both appendices, and reply instructions.
4. Run `lavish-axi playbook input` and `lavish-axi playbook table`, then follow their current native-control, explicit-submit, semantic-table, and overflow guidance.
5. Set the artifact root to the active firstmate home, or the current working directory when no active home is available, create its `.lavish/` directory, and write `.lavish/fleet-hygiene-YYYY-MM-DD.html`.
6. Build a polished interactive Chinese HTML checklist from the report with one form wrapping the A 层 and B 层 candidate tables.
7. Use semantic tables and native multi-select checkboxes, and pre-check a row exactly when the Markdown report marks that row `[x]`.
8. Give each A 层 checkbox a concrete value containing its pool and slot, and give each B 层 checkbox a concrete value containing its project and suggested tier.
9. Keep every title, label, explanation, status message, safety notice, and button in the HTML in Chinese.
10. Show both report appendices in full beneath the selection tables so every exclusion and caution remains visible.
11. Place a prominent Chinese safety banner above the form stating that this is only a checklist, it does not delete or change anything, and any later cleanup requires a separate instruction and a fresh safety check.
12. Provide exactly one explicit submit button labeled in Chinese, such as `将所选项加入发送队列`.
13. On submit, read all currently checked native controls and call `window.lavish.queuePrompt()` exactly once with a concrete Chinese prompt that lists the selected `A 层池/槽位` rows and selected `B 层项目/级别` rows, including `无` for an empty layer.
14. Make the queued prompt state that cleanup is a separate instruction and requires a fresh safety check, and show a distinct Chinese queued-state message after submission so local selections are not confused with queued feedback.
15. Do not queue prompts from checkbox change handlers, do not call `window.lavish.sendQueuedPrompts()`, and do not add any cleanup, destroy, prune, archive, registry-edit, or project-removal action.
16. Open the finished surface with `lavish-axi <html-file>`.
17. Poll for feedback only when the current harness session expects feedback, and never block task cleanup on polling.
18. In chat, use only a concise Chinese pointer such as `船长，舰队卫生检查清单已在 Lavish 中打开；中文报告位于：<报告路径>。` rather than reproducing the tables or replacing Lavish with a long chat summary.
