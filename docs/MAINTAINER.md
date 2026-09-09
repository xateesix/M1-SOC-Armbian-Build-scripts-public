# Maintainer notes (private workflow)

## Dual repository workflow

| Remote | Purpose |
|--------|---------|
| **Private** (`origin`) | Full development tree: discovery/debug history, local configs, factory data |
| **Public** | Sanitized, allow-listed snapshot for community use |

```bash
git push origin main              # private: all work
bash tools/push-to-public.sh      # public: allow-listed squashed snapshot
```

Set `PUBLIC_REPO_URL` in `config.env`.

## Public export model

`tools/push-to-public.sh` publishes the public repo as a **fresh, squashed
snapshot** (a single orphan commit), not a copy of private history. This is
deliberate:

- **Allow-list**, not deny-list: only paths matched by `.public-export-allow`
  are published. Anything new (discovery scripts, factory data, audit dumps,
  reverse-engineering notes, session logs) is dropped by default.
- **No shared history**: because the public repo is a single commit, private
  commit messages and any pre-sanitization diffs (which contained real
  credentials) can never reach the public remote via `git log`.
- **Sanitization pass**: as defense-in-depth, the kept files are still scrubbed
  of known credential/host/path patterns before commit.

To change what is published, edit `.public-export-allow` and re-run the export.

## Public export safety

- Treat `config.env`, logs, serial captures, and release binaries as private-only unless explicitly sanitized.
- Never add secret-bearing paths to `.public-export-allow`; the real `config.env` is excluded (only `config.env.example` templates are published).
- Keep the public repository limited to sanitized source, templates, and approved release artifacts.
- Assume the workspace is unstable and may close at any time; preserve durable notes in tracked files, not live session state.
