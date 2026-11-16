# Reference verification

Observed on 2026-11-17:

- Queried GitHub repository metadata, exact commit objects and pinned contents for ten repositories.
- Reopened and hashed 31 relevant source/license files; retained nine root-license texts in `licenses/`.
- Verified actionlint `v1.7.12` release tag commit `914e7df21a07ef503a81201c76d2b11c789d3fca`, MIT `LICENSE.txt`, and both Darwin archive hashes against the official release checksum file. Local workflow validation passed in the app worktree (project-executor evidence); no signed release was run.
- Materialized clean detached checkouts for Remodex, Chums and OpenVision using the sync tool. A second invocation reported `VERIFIED` for all three without fetching.
- `python3 -B -m unittest discover -s references/tests -v`: 10 tests passed, including dirty/untracked preservation, unmanaged/symlink rejection, origin/pin/HEAD checks, idempotence and license-tamper rejection.
- No upstream applications were built; no hardware, SDK production-distribution or backend-security validation was performed.

Reproduce from the repository root:

```sh
python3 scripts/sync-references.py --list
python3 -B -m unittest discover -s references/tests -v
python3 scripts/sync-references.py --name remodex --name chums --name openvision
```

Ignored checkouts are local working material. A clean clone gets their pinned source
by running the last command; it does not carry machine-specific checkout paths or
third-party Git history in Munie's tracked tree. The archived product research is
indexed under `docs/research/`; its original pins remain historical evidence.
