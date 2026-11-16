# Contributing

Read [AGENTS.md](AGENTS.md) and [project status](docs/project-status.md) before changing code. The project currently targets personal use, then a small invited beta.

## Branches and worktrees

- `main`: reviewed release history; no routine direct development.
- `dev`: integration branch for day-to-day work.
- `feat_<module>_<purpose>`: one focused behavior in a sibling worktree, PR targeting `dev`.
- Release PR: `dev` → `main` after validation and release review.

```sh
git switch dev
git worktree add ../.munie-worktrees/feat_capture_search -b feat_capture_search dev
```

Use one owner per module/worktree. Subagents can research or implement disjoint paths; the integrator reviews their diff, resolves ownership conflicts, and reruns affected checks. Do not commit generated projects, build products, reference checkouts, secrets, or private user data. Remove a feature worktree only after its work is integrated and preserved.

## Change checklist

1. State the user problem and the smallest observable acceptance condition.
2. Review official documentation and existing components; record adoption, rejection and license implications in `references/` or an ADR.
3. Implement small, descriptively named APIs with explicit failures and Swift concurrency isolation. Avoid speculative abstraction and unnecessary dependencies.
4. Add meaningful regression/unit tests for behavior. Update English and Simplified Chinese UI strings and matching README claims.
5. Run relevant checks from [testing](docs/testing.md); report actual commands and limitations in the PR.
6. Update architecture decisions and `docs/project-status.md` when scope or behavior changes.

Commits use `feat:`, `fix:`, `refactor:`, `test:`, `docs:` or `chore:` with a concrete summary. PRs explain behavior, reason, tests and material limitations. Small changes need concise descriptions, not ceremony.

GitHub branch protection and required checks must be enabled after a remote is connected. Local branch names and templates alone do not enforce review. Dependency license review does not grant a license to Munie itself.
