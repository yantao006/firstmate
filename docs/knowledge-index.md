# Keyword knowledge index

The keyword knowledge index is a replaceable projection over canonical Markdown files.
Canonical project files and Beads remain authoritative.
Deleting an index never deletes or changes a canonical file, and `sync` deterministically rebuilds the complete selected-source projection.

This document is the single owner of the source registry and index contracts.
[`bin/fm-knowledge-index.sh`](../bin/fm-knowledge-index.sh) implements them, and [`tests/fm-knowledge-index.test.sh`](../tests/fm-knowledge-index.test.sh) verifies them with synthetic fixtures only.

## Source registry contract

The local registry is `config/knowledge-sources.json` under the selected `FM_HOME` by default.
It is gitignored because roots, owners, privacy classifications, and repository identities are local fleet configuration.
`FM_CONFIG_OVERRIDE` changes the config directory for tests and specialized environments.

The complete version 1 schema is:

```json
{
  "schema": "firstmate.knowledge-sources.v1",
  "sources": [
    {
      "id": "repo-alpha",
      "root": "/absolute/canonical/root",
      "owner": "human-owner",
      "privacy": "repo-private",
      "markdown_allow": ["AGENTS.md", "docs/*.md"],
      "deny": ["docs/drafts/*"],
      "repo": "owner/repository"
    }
  ]
}
```

The top-level object has exactly `schema` and `sources`.
`schema` must equal `firstmate.knowledge-sources.v1`.
`sources` is an array with no duplicate IDs.

Each source object has exactly these fields:

- `id` is required and matches `^[a-z0-9][a-z0-9-]{0,62}$`, with `all` reserved and forbidden.
- `root` is required, absolute, existing, not `/`, and already equal to its physical canonical directory path when registry validation or sync runs.
- `owner` is a required non-empty human owner label.
- `privacy` is one of `public`, `repo-private`, `fleet-private`, or `captain-private`.
- `markdown_allow` is a required non-empty array of relative Markdown glob patterns.
- `deny` is a required array of relative glob patterns and may be empty.
- `repo` is an optional non-empty repository identity string, normally `owner/repository`.

All string fields must be single-line strings without control characters.
Glob patterns are relative POSIX-style patterns using literal path characters, `*`, `**`, and `?`.
`*` and `**` both match across directory separators in C1, while `?` matches one character.
Allow patterns must end in `.md` or `.markdown`, case-insensitively.
Absolute patterns, empty segments, `.` or `..` segments, backslashes, and bracket expressions are rejected.

Registry validation resolves every root fail-closed and requires it to exist and already equal its canonical physical path.
Source roots are pairwise disjoint: no root may equal, contain, or be contained by another source root, regardless of registry order.
Search, status, and removal validate the registry structure and selected source identity without requiring the canonical root to remain online, so a previously built projection remains usable after a failed sync.
Sync additionally validates every registered physical root and their pairwise separation immediately before reading the selected source.

## Built-in safety denies

Configured denies can only add restrictions.
They cannot remove or override these built-in denies:

- `.env`, `.env.*`, and those names at any depth.
- `secret`, `secrets`, `credential`, and `credentials` directories and exact Markdown basenames at any depth.
- Any `backlog.md` or `backlogs` directory, plus Firstmate `data/captain.md` and `data/<task>/brief.md` paths.
- `.lavish`, `generated`, `feedback`, `node_modules`, `vendor`, `build`, `dist`, `out`, `target`, `coverage`, and `.next` directories at any depth.

Only regular files whose names end in `.md` or `.markdown` are candidates.
Directory and file symlinks are not followed.
Sync opens the canonical root from the filesystem root one component at a time without following symlinks, then binds enumeration and every candidate read to that single directory descriptor.
The snapshot records that opened directory's filesystem identity and reopens the registered path without following symlinks after copying and immediately before publication.
If the registered path no longer names the opened directory, sync fails closed and preserves the previous database, so stored canonical paths cannot describe content read from a renamed tree.
Every candidate must remain below that opened root, match at least one allow pattern, and match neither a built-in nor configured deny.

## Index storage and schema

Indexes live under `state/knowledge-indexes/` in the selected `FM_HOME` by default.
`FM_STATE_OVERRIDE` changes the state directory for tests and specialized environments.
The index directory is mode `0700`, and every published SQLite database is mode `0600`.

Each source has exactly one database named `<source-id>.sqlite3`.
The restricted ID grammar makes that mapping collision-free and prevents path traversal.
No database contains another source's rows.

Each database contains a `documents` table, its external-content FTS5 index, and projection metadata.
Every document persists:

- source ID;
- owner;
- privacy class;
- source-relative and canonical absolute paths;
- optional repository identity;
- full Git commit SHA when the root is inside a Git worktree;
- content SHA-256;
- one UTC indexed timestamp for the completed sync;
- canonical source root;
- Markdown content.

Search SQL is fixed and uses a bound FTS query parameter.
Operator text is converted to quoted FTS5 prefix tokens, so SQL and FTS metacharacters remain data instead of syntax.
Malformed or tokenless queries fail without changing or opening an unselected database.

## Command contract

`bin/fm-knowledge-index.sh` supports:

```text
fm-knowledge-index.sh validate [--json]
fm-knowledge-index.sh sync --source <id> [--json]
fm-knowledge-index.sh search --source <id> [--source <id> ...] --query <text> [--limit <n>] [--json]
fm-knowledge-index.sh status --source <id> [--json]
fm-knowledge-index.sh remove --source <id> --confirm <id> [--json]
```

Runtime dependencies are Bash, `jq`, SQLite with FTS5 and JSON functions, `find`, `sort`, Git, Python 3, either `shasum` or `sha256sum`, and either `flock` or `lockf`.

Every search requires one or more explicit `--source` values.
There is no default source, `all`, wildcard, registry-wide search, or implicit federation mode.
When several sources are explicitly named, each database is opened independently in caller order and its results are appended in that order.
The per-source limit is between 1 and 100 and defaults to 20.

`sync` always builds a complete new database in the index directory and atomically renames it over the old database only after integrity checks pass.
A failed sync removes only its unpublished temporary files and leaves the previous database byte-for-byte intact.
Complete rebuild semantics deterministically propagate canonical deletion, rename, and allowlist changes without a watcher or timing promise.
Repeated unchanged sync produces one row per current relative path and cannot accumulate duplicates.
Sync and removal serialize on a source-scoped operation lock, so a same-source sync already in progress cannot publish after a confirmed removal returns, while different sources remain independent.

`remove` accepts exactly one validated source and requires `--confirm <same-source-id>`.
It removes only that source's exact disposable SQLite file.
It never changes the registry, canonical root, or any other source database.

`--json` emits stable schema names, field names, ordering, and JSON types for automation.
Human output is concise but includes source identity and provenance for every result.

## Boundary and deferred work

Physical per-source databases make an accidental query against an unselected source structurally impossible in the fixed CLI path because the command never opens that database.
They also prevent same paths, headings, or slugs in two sources from overwriting each other at rest.
Negative synthetic tests verify zero foreign-source canary leakage across exact, prefix, and metacharacter searches.

This is local process isolation, not operating-system identity authorization.
Any process running as the same owner that can read `state/knowledge-indexes/` can directly open every database.
The boundary does not protect a compromised owner account, malicious canonical Markdown, terminal scrollback, backups, or an operator who explicitly selects a source they are allowed to read at the filesystem layer.

C1 intentionally excludes semantic search, embeddings, code indexing, automatic capture, migration of existing content, background services, hooks, watchers, network listeners, cloud providers, credentials, and MCP.
Stdio MCP is deferred until the core registry, physical isolation, provenance, deletion propagation, atomic rebuild, and negative leakage contracts pass independently.
Adding MCP earlier would multiply query surfaces before the one trusted local index contract is stable.
