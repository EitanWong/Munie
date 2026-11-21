// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
// FILE: TurnViewAlertModifier.swift
// Purpose: Centralizes TurnView approval + git alerts so TurnView stays focused on orchestration.
// Layer: View Modifier
// Exports: turnViewAlerts
// Depends on: SwiftUI, CodexApprovalRequest, GitActionModels

import SwiftUI

private struct TurnViewAlertModifier: ViewModifier {
    @Binding var alertApprovalRequest: CodexApprovalRequest?
    @Binding var isApprovalAlertPresented: Bool
    @Binding var isShowingNothingToCommitAlert: Bool
    @Binding var gitSyncAlert: TurnGitSyncAlert?
    @Binding var isShowingMacHandoffConfirm: Bool
    @Binding var macHandoffErrorMessage: String?

    let onDeclineApproval: (CodexApprovalRequest) -> Void
    let onApproveApproval: (CodexApprovalRequest) -> Void
    let onApproveForSession: ((CodexApprovalRequest) -> Void)?
    let onConfirmGitSyncAction: (TurnGitSyncAlertAction) -> Void
    let onDismissGitSyncAlert: () -> Void
    let onConfirmMacHandoff: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Approval request"),
                isPresented: $isApprovalAlertPresented,
                presenting: alertApprovalRequest
            ) { request in
                Button(String(localized: "Decline"), role: .destructive) {
                    onDeclineApproval(request)
                }
                Button(String(localized: "Approve")) {
                    onApproveApproval(request)
                }
                if let onApproveForSession,
                   (request.method == "item/commandExecution/requestApproval"
                    || request.method == "item/command_execution/request_approval") {
                    Button(String(localized: "Always allow this pattern")) {
                        onApproveForSession(request)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    // A dismissed permission request still blocks the agent.
                    onDeclineApproval(request)
                }
            } message: { request in
                Text(approvalAlertMessage(for: request))
            }
            .alert(String(localized: "Nothing to Commit"), isPresented: $isShowingNothingToCommitAlert) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "There are no changes to commit."))
            }
            .alert(
                gitSyncAlert?.title ?? "Git",
                isPresented: gitSyncAlertIsPresented,
                presenting: gitSyncAlert
            ) { alert in
                // Renders alert buttons from the shared model so new Git prompts do not add more switch cases here.
                ForEach(alert.buttons) { alertButton in
                    Button(alertButton.title, role: buttonRole(for: alertButton.role)) {
                        let action = alertButton.action
                        if action == .dismissOnly {
                            onDismissGitSyncAlert()
                        } else {
                            onConfirmGitSyncAction(action)
                        }
                    }
                }
            } message: { alert in
                Text(alert.message)
            }
            .alert(String(localized: "Continue on Desktop App"), isPresented: $isShowingMacHandoffConfirm) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Force Close & Continue")) {
                    onConfirmMacHandoff()
                }
            } message: {
                Text("Munie will force close and reopen Codex.app on this device. Any desktop runs in progress will be stopped, and unsaved draft text there may be lost before this chat is opened.")
            }
            .alert(
                String(localized: "Couldn't continue on desktop app"),
                isPresented: macHandoffErrorIsPresented
            ) {
                Button(String(localized: "OK"), role: .cancel) {
                    macHandoffErrorMessage = nil
                }
            } message: {
                Text(macHandoffErrorMessage ?? String(localized: "Could not continue this chat on the desktop app."))
            }
    }

    private var gitSyncAlertIsPresented: Binding<Bool> {
        Binding(
            get: { gitSyncAlert != nil },
            set: { isPresented in
                if !isPresented {
                    onDismissGitSyncAlert()
                }
            }
        )
    }

    private var macHandoffErrorIsPresented: Binding<Bool> {
        Binding(
            get: { macHandoffErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    macHandoffErrorMessage = nil
                }
            }
        )
    }

    private func approvalAlertMessage(for request: CodexApprovalRequest) -> String {
        var lines: [String] = []

        if let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            lines.append(reason)
        }

        if let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            lines.append(String(localized: "Command: \(command)"))
        }

        if let workingDirectory = request.workingDirectory {
            lines.append(String(localized: "Working directory: \(workingDirectory)"))
        }

        if lines.isEmpty {
            return String(localized: "Codex is requesting permission to continue.")
        }

        return lines.joined(separator: "\n\n")
    }

    private func buttonRole(for role: TurnGitSyncAlertButtonRole?) -> ButtonRole? {
        switch role {
        case .cancel:
            return .cancel
        case .destructive:
            return .destructive
        case nil:
            return nil
        }
    }
}

extension View {
    func turnViewAlerts(
        alertApprovalRequest: Binding<CodexApprovalRequest?>,
        isApprovalAlertPresented: Binding<Bool>,
        isShowingNothingToCommitAlert: Binding<Bool>,
        gitSyncAlert: Binding<TurnGitSyncAlert?>,
        isShowingMacHandoffConfirm: Binding<Bool>,
        macHandoffErrorMessage: Binding<String?>,
        onDeclineApproval: @escaping (CodexApprovalRequest) -> Void,
        onApproveApproval: @escaping (CodexApprovalRequest) -> Void,
        onApproveForSession: ((CodexApprovalRequest) -> Void)? = nil,
        onConfirmGitSyncAction: @escaping (TurnGitSyncAlertAction) -> Void,
        onDismissGitSyncAlert: @escaping () -> Void,
        onConfirmMacHandoff: @escaping () -> Void
    ) -> some View {
        modifier(
            TurnViewAlertModifier(
                alertApprovalRequest: alertApprovalRequest,
                isApprovalAlertPresented: isApprovalAlertPresented,
                isShowingNothingToCommitAlert: isShowingNothingToCommitAlert,
                gitSyncAlert: gitSyncAlert,
                isShowingMacHandoffConfirm: isShowingMacHandoffConfirm,
                macHandoffErrorMessage: macHandoffErrorMessage,
                onDeclineApproval: onDeclineApproval,
                onApproveApproval: onApproveApproval,
                onApproveForSession: onApproveForSession,
                onConfirmGitSyncAction: onConfirmGitSyncAction,
                onDismissGitSyncAlert: onDismissGitSyncAlert,
                onConfirmMacHandoff: onConfirmMacHandoff
            )
        )
    }
}
