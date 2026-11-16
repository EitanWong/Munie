# Release and CI/CD

## Flow

Feature PRs target `dev`; release PRs target `main`. Require successful validation and review before merging. Local initialization establishes branches and workflow configuration; it does not activate remote checks or protect a branch.

Configured workflows: `ci.yml` has `quality` and `ios-tests` jobs. `release.yml` is manually dispatched on `main`; it validates before signed archiving and TestFlight delivery through `scripts/release.sh`. Distribution requires the protected `testflight` environment, approval and configured signing/API secrets.

After a GitHub repository is selected and connected:

1. Run CI on `dev`, `main` and PRs, then make the actual stable check names required in branch rules.
2. Block direct pushes and force pushes to `main`; require a PR, resolved review conversations and current checks. Apply comparable integration rules to `dev` as appropriate for a solo project.
3. Restrict workflow permissions and deployment environments. Fork PRs must not receive signing or deployment secrets.
4. Observe a complete hosted build/test run before calling CI operational.

## Release gate

- Core, app and smoke checks pass; relevant real-device acceptance has evidence.
- Version/build number, changelog, privacy disclosures, dependency licenses and known limits are reviewed.
- App identity, signing team, entitlements and minimum OS are intentional.
- Data export/deletion and private feedback/security contact are ready for the intended test audience.
- The release PR describes user-visible behavior, checks and remaining limitations.

For invited beta, use TestFlight only after Apple Developer/App Store Connect configuration and signing are available. Store certificates, provisioning credentials and API keys in protected secrets. Require explicit approval for distribution environments. Never include them in source, reference checkouts or build logs.

Unsigned CI compilation/artifacts are development checks, not installable distribution or App Store approval. Automatic signed delivery remains gated until the account, bundle identity, secrets and environment are configured and an actual delivery succeeds.

Release notes should state what works, what changed and known limits in supported languages. Do not advertise remote AI, Watch or glasses behavior before their own acceptance gates pass.
