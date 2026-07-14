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
Each sync binds schema validation, all registered roots, and every selected-source field to one stable registry snapshot.
Before publication, sync checks whether the current registry locator still names the validated snapshot and fails closed if a change is observed.
That locator check is best-effort rather than a pathname lease because POSIX permits a cooperating process to rename the registry immediately after the check.

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
The snapshot records that opened directory's filesystem device and inode identity and obtains Git commit provenance while its process is positioned in that same opened directory.
Publication reopens the registered path without following symlinks and performs a best-effort current-locator check before commit.
The filesystem identity remains attached to every result because POSIX pathnames do not provide a lease against a cooperating process renaming an ancestor after that check.
Every candidate must remain below that opened root, match at least one allow pattern, and match neither a built-in nor configured deny.

## Index storage and schema

Indexes live under `state/knowledge-indexes/` in the selected `FM_HOME` by default.
`FM_STATE_OVERRIDE` changes the state directory for tests and specialized environments.
The index locator is always derived from that selected state directory and cannot be overridden independently.
Relative `FM_HOME` and `FM_STATE_OVERRIDE` values are resolved from the caller's invocation directory before supervised work begins.
The index directory is mode `0700`, and every published SQLite database is mode `0600`.

Each source has exactly one database named `<source-id>.sqlite3`.
The restricted ID grammar makes that mapping collision-free and prevents path traversal.
No database contains another source's rows.

Each database contains a `documents` table, its external-content FTS5 index, and projection metadata.
Projection metadata records the registry locator, filesystem device and inode, and SHA-256 of the exact stable registry snapshot that supplied validation and provenance.
Every document persists:

- source ID;
- owner;
- privacy class;
- source-relative paths and the registered canonical absolute locator at snapshot time;
- source-root filesystem device and inode identity for the directory tree actually read;
- optional repository identity;
- full Git commit SHA when the root is inside a Git worktree;
- content SHA-256;
- one UTC indexed timestamp for the completed sync;
- registered canonical source-root locator at snapshot time;
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

`sync` always builds a complete new database in a private operation directory under the selected state root and atomically renames it into the index locator only after integrity checks pass.
Every database command is launched by a Python supervisor that opens the selected state root from the filesystem root one component at a time without following symlinks and retains an exclusive lock on that stable descriptor until the command finishes.
The worker receives only the private operation directory and cannot publish, remove, or emit caller-visible success output.
The supervisor alone snapshots databases for reads, commits prepared sync databases, quarantines removals, and releases buffered output.
Inherited supervisor environment values are not authorization for index mutation.
The database rename is the publication linearization point.
The published database permanently identifies the exact source directory and registry snapshot used to build it, even if either current pathname is replaced after its final best-effort locator check.
A failed sync removes only its unpublished temporary files and leaves the previous database byte-for-byte intact.
Complete rebuild semantics deterministically propagate canonical deletion, rename, and allowlist changes without a watcher or timing promise.
Repeated unchanged sync produces one row per current relative path and cannot accumulate duplicates.
Sync and removal serialize on an exclusive lock on the stable opened state-root descriptor, so an earlier sync cannot publish into the selected index directory after a confirmed removal returns.
This deliberately serializes different sources as well as the same source in exchange for avoiding replaceable pathname lock anchors and retaining Bash 3.2 compatibility.
Search and status receive private snapshots created by the supervisor before the worker starts, so the worker never reads through a detached index directory.
The supervisor buffers command output until the worker exits, verifies that the index locator still identifies the directory opened at operation start, performs any final state-root-relative commit, and releases output only after success.
Replacing the index directory during an operation cannot make the worker publish, read, or remove through the detached directory.
An actor with the same operating-system identity can directly edit files in the selected state area and is outside this filesystem isolation boundary, but forged worker environment values do not grant the CLI supervisor's commit authority.

`remove` accepts exactly one validated source and requires `--confirm <same-source-id>`.
It quarantines the selected database with an atomic same-directory rename, verifies that the quarantined inode is the exact previously opened object, and only then unlinks it.
If the pathname was replaced during validation, removal preserves the replacement and fails closed.
It never changes the registry, canonical root, or any other source database.

`--json` emits stable schema names, field names, ordering, and JSON types for automation.
Human output is concise but includes source identity and provenance for every result.

## Boundary and deferred work

Physical per-source databases make an accidental query against an unselected source structurally impossible in the fixed CLI path because the command never opens that database.
They also prevent same paths, headings, or slugs in two sources from overwriting each other at rest.
Negative synthetic tests verify zero foreign-source canary leakage across exact, prefix, and metacharacter searches.

This is local process isolation, not operating-system identity authorization.
Any process running as the same owner that can read `state/knowledge-indexes/` can directly open every database.
Search and status atomically open the selected database without following symlinks, verify the same descriptor is a regular file, and query a private stable copy so a pathname replacement cannot redirect SQLite.
POSIX does not prevent a malicious process running as the same owner from renaming directories, deleting files, or directly bypassing this CLI, so these mechanisms provide fail-closed CLI linearization and operation ordering, not authorization against a hostile same-owner process.
The boundary does not protect a compromised owner account, malicious canonical Markdown, terminal scrollback, backups, or an operator who explicitly selects a source they are allowed to read at the filesystem layer.

C1 intentionally excludes semantic search, embeddings, code indexing, automatic capture, migration of existing content, background services, hooks, watchers, network listeners, cloud providers, credentials, and MCP.
Stdio MCP is deferred until the core registry, physical isolation, provenance, deletion propagation, atomic rebuild, and negative leakage contracts pass independently.
Adding MCP earlier would multiply query surfaces before the one trusted local index contract is stable.
