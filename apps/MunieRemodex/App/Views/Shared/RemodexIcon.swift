// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
import SwiftUI
import UIKit

enum RemodexIcon {
    private static func symbol(_ name: String) -> String {
        let aliases = [
            "remodex.agent": "person.crop.circle", "remodex.automation": "clock",
            "remodex.auto-review": "checkmark.shield", "remodex.branch": "arrow.triangle.branch",
            "remodex.changes": "doc.text", "remodex.plan-mode": "list.bullet.clipboard",
            "remodex.skill": "square.stack.3d.up", "remodex.worktree": "arrow.triangle.branch",
            "remodex.fork": "arrow.branch", "remodex.github": "chevron.left.forwardslash.chevron.right",
            "remodex.git-branch": "arrow.triangle.branch", "remodex.goal": "target"
        ]
        return aliases[name] ?? name
    }
    static func assetName(for systemName: String) -> String? { nil }
    static func image(systemName: String, size: CGFloat? = nil, weight: Font.Weight? = nil, relativeTo textStyle: Font.TextStyle = .body) -> some View {
        Image(systemName: symbol(systemName)).font(size.map { .system(size: $0, weight: weight ?? .regular) }).fontWeight(weight)
    }
    static func label(_ title: String, systemName: String) -> some View { Label(title, systemImage: symbol(systemName)) }
    static func menuLabel(_ title: String, systemName: String) -> some View { Label(title, systemImage: symbol(systemName)) }
    static func uiImage(systemName: String, withConfiguration configuration: UIImage.Configuration? = nil) -> UIImage? {
        UIImage(systemName: symbol(systemName), withConfiguration: configuration)
    }
    static func menuUIImage(systemName: String) -> UIImage? { uiImage(systemName: systemName) }
}
