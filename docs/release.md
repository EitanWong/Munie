# Release and CI/CD

## Flow

Feature PRs target `dev`; release PRs target `main`. Require successful validation and review before merging. Local initialization establishes branches and workflow configuration; it does not activate remote checks or protect a branch.

Configured workflows: `ci.yml` has one `quality` job with separate source/build and iOS test steps. `release.yml` is manually dispatched on `main`; it validates before signed archiving and TestFlight delivery through `scripts/release.sh`. Distribution requires the protected `testflight` environment, approval and configured signing/API secrets.

The public [GitHub repository](https://github.com/EitanWong/Munie) is connected. `main` protection requires the complete `Quality, build and tests` check, a PR, resolved conversations and current checks, with administrator enforcement; a solo developer can merge without a second reviewer. The `testflight` environment requires owner approval and permits protected branches; the workflow additionally allows only `main`.

Maintain these controls:

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

## Configuration

Hosted jobs explicitly select Xcode 26.2 on `macos-15` for a consistent toolchain. Update the image/toolchain together after reviewing the [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) and [Apple upload requirements](https://developer.apple.com/news/upcoming-requirements/). Local checks were run with the locally installed toolchain; see project status.

The `testflight` environment needs these secrets:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` / `APP_BUNDLE_ID` | Your registered team and explicit application identifier |
| `DISTRIBUTION_CERTIFICATE_BASE64` | Base64 Apple Distribution `.p12` |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `PROVISIONING_PROFILE_BASE64` | Base64 App Store distribution profile matching that app/team |
| `APP_STORE_CONNECT_KEY_BASE64` | Base64 App Store Connect `.p8` key |
| `APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API key identity |

Create the app record first and restrict API access to the necessary app. `release.sh` rejects local execution, non-main refs, missing credentials and Xcode older than 26. It uses an ephemeral signing keychain and cleans credentials on exit. Build numbers derive from the workflow run and attempt. An upload exit status is not proof that Apple processing or review completed; verify App Store Connect afterward. The first signed delivery still needs a real account run.
