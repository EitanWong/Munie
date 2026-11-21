# Contributing

Read [AGENTS.md](AGENTS.md) and [project status](docs/project-status.md) before changing code. The project currently targets personal use, then a small invited beta.

## Branches and worktrees

- `main`: reviewed release history; no routine direct development.
- `dev`: integration branch for day-to-day work.
- `feat_<module>_<purpose>`: one focused change per feature branch, with a PR targeting `dev`.
- Release PR: `dev` → `main` after validation and release review.

Reuse a suitable worktree or follow the [daily development workflow](docs/development.md#daily-workflow) to create one.

Use one owner per module/worktree. Subagents can research or implement disjoint paths; the integrator reviews their diff, resolves ownership conflicts, and reruns affected checks. Do not commit generated projects, build products, reference checkouts, secrets, or private user data. Remove a feature worktree only after its work is integrated and preserved.

## Change checklist

1. State the user problem and the smallest observable acceptance condition.
2. Review official documentation and existing components; record adoption, rejection and license implications in `references/` or an ADR.
3. Implement small, descriptively named APIs with explicit failures and Swift concurrency isolation. Avoid speculative abstraction and unnecessary dependencies.
4. Add meaningful regression/unit tests for behavior. Update English and Simplified Chinese UI strings and matching README claims.
5. Run relevant checks from [testing](docs/testing.md); report actual commands and limitations in the PR.
6. Update architecture decisions and `docs/project-status.md` when scope or behavior changes.

Commits use `feat:`, `fix:`, `refactor:`, `test:`, `docs:` or `chore:` with a concrete summary. PRs explain behavior, reason, tests and material limitations. Small changes need concise descriptions, not ceremony.

## AI-maintained pull requests / AI 维护 PR

The AI implementing a change owns its PR through integration: maintain its description, review the final diff, follow CI to completion, fix failures/conflicts, handle review threads and verify the checked commit before merging. A skipped bot review does not replace review. Preserve required checks and branch protection.

Completed feature PRs merge into `dev`; reviewed release PRs merge `dev` into `main` after required checks pass. The owner has authorized routine integration without repeated confirmation. Product decisions, credentials, destructive changes and TestFlight distribution retain their own approval boundaries. After merging, update local branches, observe integration checks and clean only merged worktrees.

AI 应负责 PR 的创建、说明、代码复审、CI 跟进、修复、评审意见处理、合并和清理。不能只提交 PR 就结束，也不能绕过保护或把排队、取消、跳过的检查当成通过。阻塞时记录确切提交、运行链接和下一步；没有配置调度器时，不宣称任务结束后还会后台维护。

Both `main` and `dev` are protected in GitHub. Local branch names and templates alone do not enforce review. Dependency license review does not grant a license to Munie itself.
