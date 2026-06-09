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

enum MailPopoverMetrics {
    static let listWidth: CGFloat = 390
    static let detailWidth: CGFloat = 320
    static let height: CGFloat = 420

    static func totalWidth(showingDetail: Bool) -> CGFloat {
        showingDetail ? listWidth + detailWidth : listWidth
    }
}

extension Notification.Name {
    static let popoverSizeChanged = Notification.Name("popoverSizeChanged")
    static let mailPopoverSizeChanged = Notification.Name("mailPopoverSizeChanged")
}
