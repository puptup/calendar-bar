import CoreGraphics
import Foundation

enum PopoverMetrics {
    static let timelineWidth: CGFloat = 340
    static let detailWidth: CGFloat = 300
    static let height: CGFloat = 420

    static func totalWidth(showingDetail: Bool) -> CGFloat {
        showingDetail ? timelineWidth + detailWidth : timelineWidth
    }
}

extension Notification.Name {
    static let popoverSizeChanged = Notification.Name("popoverSizeChanged")
}
