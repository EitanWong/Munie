// Munie modification: the pinned source removed makeGitSyncAlert/update strategy APIs; preserve Git-state safety coverage against the current eligibility and confirmation interfaces.
import XCTest
@testable import MunieRemodex

@MainActor
final class TurnGitSyncAlertTests: XCTestCase {
    func testBehindOnlyOffersSafeRemoteUpdate() {
        let viewModel = makeViewModel(state: "behind_only", dirty: false, ahead: 0, behind: 2)
        XCTAssertTrue(viewModel.canUpdateRepositoryFromRemote)
        XCTAssertFalse(viewModel.disabledGitActions.contains(.syncNow))
    }

    func testDivergedRequiresExplicitReconciliation() {
        let viewModel = makeViewModel(state: "diverged", dirty: false, ahead: 1, behind: 1)
        XCTAssertFalse(viewModel.canUpdateRepositoryFromRemote)
        XCTAssertTrue(viewModel.disabledGitActions.contains(.syncNow))
    }

    func testDirtyAndBehindKeepsRebaseConfirmationExplicit() {
        let viewModel = makeViewModel(state: "dirty_and_behind", dirty: true, ahead: 0, behind: 3)
        XCTAssertTrue(viewModel.canUpdateRepositoryFromRemote)
        let alert = TurnGitSyncAlert(title: "Local changes need attention", message: "Local and remote work must be reconciled.", action: .pullRebase)
        XCTAssertTrue(alert.buttons.contains { $0.action == .dismissOnly && $0.role == .cancel })
        XCTAssertTrue(alert.buttons.contains { $0.action == .pullRebase && $0.title == "Pull & Rebase" })
    }

    private func makeViewModel(state: String, dirty: Bool, ahead: Int, behind: Int) -> TurnViewModel {
        let viewModel = TurnViewModel()
        viewModel.applyGitRepoSync(GitRepoSyncResult(from: [
            "branch": .string("feature/sync"), "tracking": .string("origin/feature/sync"),
            "dirty": .bool(dirty), "ahead": .integer(ahead), "behind": .integer(behind),
            "state": .string(state), "canPush": .bool(false)
        ]))
        return viewModel
    }
}
