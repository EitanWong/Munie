// Munie modification: explicit nonisolated teardown for Swift 6.2 runtime compatibility.
// FILE: HapticFeedback.swift
// Purpose: Centralized haptic feedback utility for premium button interactions.
// Layer: Service
// Exports: HapticFeedback
// Depends on: UIKit

import UIKit

class HapticFeedback {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    static let shared = HapticFeedback()

    private init() {}

    // Uses the system notification generator for stateful success/failure cues.
    func triggerNotificationFeedback(type: UINotificationFeedbackGenerator.FeedbackType = .success) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }

    func triggerImpactFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}
