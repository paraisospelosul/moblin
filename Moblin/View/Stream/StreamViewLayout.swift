import SwiftUI

struct StreamViewLayout {
    let size: CGSize
    let offset: CGSize

    init(metrics: GeometryProxy,
         aspectRatio: CGFloat,
         portraitOrientation: Bool,
         portraitStream: Bool,
         portraitVideoOffset: Double,
         fillScreen: Bool = false)
    {
        if !portraitOrientation {
            var size: CGSize
            if fillScreen {
                size = CGSize(width: metrics.size.width, height: metrics.size.width / aspectRatio)
                if size.height < metrics.size.height {
                    size = CGSize(width: metrics.size.height * aspectRatio, height: metrics.size.height)
                }
            } else {
                size = CGSize(width: metrics.size.height * aspectRatio, height: metrics.size.height)
                if size.width > metrics.size.width {
                    size = CGSize(width: metrics.size.width, height: metrics.size.width / aspectRatio)
                }
            }
            let x = (metrics.size.width - size.width) / 2
            let y = (metrics.size.height - size.height) / 2
            self.size = size
            offset = CGSize(width: x, height: y)
            return
        }

        let insets = metrics.safeAreaInsets
        let fullSize = CGSize(width: metrics.size.width + insets.leading + insets.trailing,
                              height: metrics.size.height + insets.top + insets.bottom)
        var size = CGSize(width: fullSize.width, height: fullSize.width / aspectRatio)
        if size.height > fullSize.height {
            size = CGSize(width: fullSize.height * aspectRatio, height: fullSize.height)
        }
        let x: CGFloat = if size.width <= metrics.size.width {
            (metrics.size.width - size.width) / 2
        } else {
            (fullSize.width - size.width) / 2 - insets.leading
        }
        let y: CGFloat = if !portraitStream {
            portraitVideoOffset * size.height * 2 - insets.top
        } else if size.height <= metrics.size.height {
            (metrics.size.height - size.height) / 2
        } else {
            fullSize.height - size.height - insets.top
        }
        self.size = size
        offset = CGSize(width: x, height: y)
    }
}

extension Model {
    func streamViewLayout(metrics: GeometryProxy) -> StreamViewLayout {
        StreamViewLayout(metrics: metrics,
                         aspectRatio: stream.dimensions().aspectRatio(),
                         portraitOrientation: orientation.isPortrait,
                         portraitStream: stream.portrait,
                         portraitVideoOffset: stream.portrait ? 0 : portraitVideoOffsetFromTop,
                         fillScreen: !orientation.isPortrait && hideQuickButtons)
    }
}
