// Munie modification: localize the primary task journey in English and Simplified Chinese.
// FILE: MyDevicesSettingsSheet.swift
// Purpose: Connections sheet — three blocks:
//          1) Active device switcher (UIKit menu, switch only)
//          2) All paired devices with visibility toggles
//          3) Add connection
// Layer: View
// Exports: MyDevicesSettingsSheet, DeviceSwitchingOverlayView
// Depends on: SwiftUI, UIKit, CodexService, MyDevicesPresentation, RemodexIcon, UIKitMenuButton

import SwiftUI
import UIKit

struct MyDevicesSettingsSheet: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss

    let isSwitchingMac: Bool
    let switchingDeviceId: String?
    let switchNotice: String?
    let onSelectDevice: (String) -> Void
    let onForgetDevice: (String) -> Void
    let onAddConnection: () -> Void
    let onPairWithCode: () -> Void
    let onCancelSwitch: () -> Void

    @State private var pendingForgetDeviceId: String?
    @State private var pendingSwitchDeviceId: String?
    @State private var visibilityPreferenceRevision = 0

    private var devices: [MyDeviceRowModel] {
        _ = visibilityPreferenceRevision
        return MyDevicesPresentation.rowModels(from: codex, switchingDeviceId: switchingDeviceId)
    }

    private var pickerDevices: [MyDeviceRowModel] {
        devices.filter { $0.isVisibleInMenu || $0.isCurrent || $0.isSwitching }
    }

    private var currentDevice: MyDeviceRowModel? {
        devices.first(where: \.isCurrent)
    }

    private var showsSwitcher: Bool {
        pickerDevices.count > 1
    }

    var body: some View {
        NavigationStack {
            List {
                if let switchNotice, !switchNotice.isEmpty {
                    Section {
                        Text(switchNotice)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }

                if showsSwitcher, let currentDevice {
                    Section {
                        activeDeviceRow(currentDevice)
                    } header: {
                        sectionHeader(String(localized: "Active device"))
                    }
                }

                Section {
                    if devices.isEmpty {
                        Text(String(localized: "No paired devices yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(devices) { device in
                            deviceToggleRow(device)
                        }
                    }
                } header: {
                    sectionHeader(String(localized: "Devices"))
                }

                Section {
                    addConnectionRow
                    Button(String(localized: "Advanced: Pair with Code"), systemImage: "keyboard", action: handlePairWithCode)
                        .disabled(isSwitchingMac)
                }
            }
            .listStyle(.insetGrouped)
            .font(AppFont.body())
            .navigationTitle(String(localized: "Connections"))
            .navigationBarTitleDisplayMode(.inline)
            .tint(.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                        .tint(.secondary)
                }
            }
            .overlay {
                if isSwitchingMac {
                    switchingOverlay
                }
            }
        }
        .confirmationDialog(
            String(localized: "Switch device?"),
            isPresented: pendingSwitchDialogBinding,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Switch"), role: .destructive, action: confirmPendingSwitch)
            Button(String(localized: "Cancel"), role: .cancel, action: cancelPendingSwitch)
        } message: {
            Text(String(localized: "This stops in-progress runs and reloads chats for the other device."))
        }
        .alert(
            String(localized: "Forget this device?"),
            isPresented: pendingForgetAlertBinding,
            actions: {
                Button(String(localized: "Forget"), role: .destructive, action: confirmPendingForget)
                Button(String(localized: "Cancel"), role: .cancel, action: cancelPendingForget)
            },
            message: {
                Text(String(localized: "The paired device will be removed from this iPhone. Find your Mac nearby to pair again."))
            }
        )
    }

    // MARK: - Active device (switch only)

    @ViewBuilder
    private func activeDeviceRow(_ device: MyDeviceRowModel) -> some View {
        UIKitMenuButton(
            label: {
                HStack(spacing: 12) {
                    deviceAvatar(for: device, diameter: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.compactDisplayName)
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        statusLine(for: device)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            },
            menu: { buildActiveDeviceSwitchMenu() }
        )
        .disabled(isSwitchingMac)
        .accessibilityLabel(String(localized: "Active device, \(device.compactDisplayName)"))
        .accessibilityHint(String(localized: "Opens device switcher"))
    }

    private func buildActiveDeviceSwitchMenu() -> UIMenu {
        let switchActions: [UIMenuElement] = pickerDevices
            .map { candidate in
                UIAction(
                    title: candidate.compactDisplayName,
                    subtitle: candidate.menuSubtitle.isEmpty ? nil : candidate.menuSubtitle,
                    image: RemodexIcon.menuUIImage(systemName: MyDevicesPresentation.macIconSystemName),
                    attributes: (candidate.isCurrent || candidate.isSwitching || isSwitchingMac) ? [.disabled] : [],
                    state: candidate.isCurrent ? .on : .off
                ) { _ in
                    guard !candidate.isCurrent else { return }
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    handleChooseDevice(candidate)
                }
            }

        return UIMenu(
            title: "",
            children: [
                UIMenu(title: String(localized: "Switch to"), options: [.displayInline], children: switchActions),
            ]
        )
    }

    // MARK: - Device toggles (all paired devices)

    @ViewBuilder
    private func deviceToggleRow(_ device: MyDeviceRowModel) -> some View {
        // Swipe must sit on the row container, not on Toggle — attaching it to
        // Toggle causes the blank white destructive tile in inset-grouped lists.
        HStack(spacing: 12) {
            deviceAvatar(for: device, diameter: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.compactDisplayName)
                        .font(AppFont.body())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if device.isCurrent {
                        Text(String(localized: "Active"))
                            .font(AppFont.caption2(weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                }

                Text(device.menuSubtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !device.isCurrent {
                Toggle("", isOn: visibilityBinding(for: device))
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .padding(.vertical, 2)
        .disabled(isSwitchingMac)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                handleScanQRCode()
            } label: {
                Label(String(localized: "Find My Mac"), systemImage: "laptopcomputer")
                    .labelStyle(.iconOnly)
            }
            .tint(.blue)

            Button {
                handlePairWithCode()
            } label: {
                Label(String(localized: "Advanced: Pair with Code"), systemImage: "keyboard")
                    .labelStyle(.iconOnly)
            }
            .tint(.gray)

            Button(role: .destructive) {
                pendingForgetDeviceId = device.deviceId
            } label: {
                Label(String(localized: "Forget"), systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .tint(.red)
        }
    }

    // MARK: - Add connection

    private var addConnectionRow: some View {
        Button(action: handleAddConnection) {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, alignment: .center)

                Text(String(localized: "Add connection"))
                    .foregroundStyle(Color.accentColor)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .disabled(isSwitchingMac)
    }

    // MARK: - Shared UI

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    @ViewBuilder
    private func deviceAvatar(for device: MyDeviceRowModel, diameter: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RemodexIcon.image(
                systemName: MyDevicesPresentation.macIconSystemName,
                size: diameter * 0.42,
                weight: .medium
            )
            .foregroundStyle(.secondary)
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(Color.primary.opacity(0.07))
            )

            if device.isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
            }
        }
    }

    @ViewBuilder
    private func statusLine(for device: MyDeviceRowModel) -> some View {
        HStack(spacing: 6) {
            if device.isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(String(localized: "Connected"))
                    .foregroundStyle(.green)
            } else if device.isSwitching {
                Text(String(localized: "Switching…"))
                    .foregroundStyle(.secondary)
            } else {
                Text(device.status)
                    .foregroundStyle(.secondary)
            }

            if let detail = device.detail, !detail.isEmpty, !device.isSwitching {
                Text("· \(detail)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(AppFont.caption())
        .lineLimit(1)
    }

    private func visibilityBinding(for device: MyDeviceRowModel) -> Binding<Bool> {
        Binding(
            get: {
                if device.isCurrent { return true }
                return MyDeviceMenuVisibilityStore.isVisible(device.deviceId)
            },
            set: { isOn in
                guard !device.isCurrent else { return }
                updateMenuVisibility(isOn, for: device)
            }
        )
    }

    private var switchingOverlay: some View {
        DeviceSwitchingOverlayView(
            title: String(localized: "Switching device…"),
            primaryStatus: nil,
            secondaryStatus: nil,
            deviceName: devices.first(where: \.isSwitching)?.compactDisplayName,
            cancelTitle: String(localized: "Cancel"),
            isCancelDisabled: false,
            onCancel: onCancelSwitch
        )
    }

    // MARK: - Bindings & actions

    private var pendingForgetAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingForgetDeviceId != nil },
            set: { isPresented in
                if !isPresented { pendingForgetDeviceId = nil }
            }
        )
    }

    private var pendingSwitchDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingSwitchDeviceId != nil },
            set: { isPresented in
                if !isPresented { pendingSwitchDeviceId = nil }
            }
        )
    }

    private func handleAddConnection() {
        guard !isSwitchingMac else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        dismiss()
        onAddConnection()
    }

    private func handleScanQRCode() {
        guard !isSwitchingMac else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        dismiss()
        onAddConnection()
    }

    private func handlePairWithCode() {
        guard !isSwitchingMac else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        dismiss()
        onPairWithCode()
    }

    private func updateMenuVisibility(_ isVisible: Bool, for device: MyDeviceRowModel) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        MyDeviceMenuVisibilityStore.setVisible(isVisible, for: device.deviceId)
        visibilityPreferenceRevision += 1
    }

    private var requiresSwitchConfirmation: Bool {
        !codex.runningThreadIDs.isEmpty
            || !codex.protectedRunningFallbackThreadIDs.isEmpty
            || !codex.activeTurnIdByThread.isEmpty
    }

    private func handleChooseDevice(_ device: MyDeviceRowModel) {
        guard !device.isCurrent, !isSwitchingMac else { return }

        if requiresSwitchConfirmation {
            pendingSwitchDeviceId = device.deviceId
            return
        }

        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        onSelectDevice(device.deviceId)
    }

    private func confirmPendingSwitch() {
        if let pendingSwitchDeviceId {
            onSelectDevice(pendingSwitchDeviceId)
        }
        pendingSwitchDeviceId = nil
    }

    private func cancelPendingSwitch() {
        pendingSwitchDeviceId = nil
    }

    private func confirmPendingForget() {
        if let pendingForgetDeviceId {
            MyDeviceMenuVisibilityStore.removePreference(for: pendingForgetDeviceId)
            onForgetDevice(pendingForgetDeviceId)
        }
        pendingForgetDeviceId = nil
    }

    private func cancelPendingForget() {
        pendingForgetDeviceId = nil
    }
}

struct DeviceSwitchingOverlayView: View {
    let title: String
    let primaryStatus: String?
    let secondaryStatus: String?
    let deviceName: String?
    let cancelTitle: String
    let isCancelDisabled: Bool
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()

                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                if let primaryStatus {
                    Text(primaryStatus)
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let secondaryStatus {
                    Text(secondaryStatus)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let deviceName {
                    Text(deviceName)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                Button(cancelTitle, action: onCancel)
                    .font(AppFont.body(weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(isCancelDisabled)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 48)
        }
        .transition(.opacity)
        .zIndex(20)
    }
}
