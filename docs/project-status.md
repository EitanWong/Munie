# Project status / 项目状态

Updated: 2026-11-17. Stage: repository foundation / 工程基础建立。

## Capability boundary

| Area | Foundation scope | Remaining acceptance |
|---|---|---|
| iPhone / iPad | Native SwiftUI local text capture, list/search and deletion | Simulator, accessibility and real-device acceptance |
| Reusable core | Swift 6 capture model and atomic file storage | Package tests and smoke evidence recorded by integrator |
| Localization | English and Simplified Chinese | Both languages, large text and VoiceOver device review |
| Engineering | `main`, `dev`, `feat_` worktrees, generated project, CI/CD configuration | Connect remote; activate and observe hosted checks |
| Remote AI / Mac | Planned adapter boundary | Authenticated cellular → Mac end-to-end task, replay and cancellation |
| Voice / Watch / glasses | Research only | Separate native entry, permissions, hardware and distribution validation |

The integrator records exact local validation outcomes below after checks complete. Configuration is not evidence of a successful hosted workflow, TestFlight delivery or real-device behavior.

## Validation ledger

| Check | Observed result |
|---|---|
| Core unit/integration tests | Pending integration run |
| Core smoke test | Pending integration run |
| Formatting / repository checks | Pending integration run |
| Generic iOS build | Pending integration run |
| iOS simulator app/UI tests | Pending available runtime and execution |
| Real device / cellular / Watch / Ray-Ban Meta | Not executed |
| Hosted GitHub CI, PR protection and signed delivery | Not activated; no remote configured |

## Next decision

Complete local validation, then use the app personally to establish the original-method baseline and whether saved thoughts are later found and used. E1–E8 remain planned; no interviews, retention or product-market-fit results exist. See [product experiments](product.md).

Before invited beta: select bundle identity/signing, establish private feedback/security contact, verify data controls, and execute real-device acceptance. Implement one remote adapter only after its scenario and authorization requirements are fixed.
