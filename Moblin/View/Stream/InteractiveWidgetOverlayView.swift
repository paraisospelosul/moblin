import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Interactive Widget Overlay View
//
// Allows users to select, drag, and resize widgets directly on the camera preview.
//
// Supported Gestures:
// - Tap to select / deselect
// - Single-finger drag to move smoothly
// - Two-finger pinch to resize (size / font size)

struct InteractiveWidgetOverlayView: View {
    @ObservedObject var model: Model
    let streamSize: CGSize

    // Gesture States
    @State private var activeDragWidgetId: UUID?
    @State private var dragStartLayoutX: Double = 0.0
    @State private var dragStartLayoutY: Double = 0.0
    @State private var dragStartTranslationX: CGFloat = 0.0
    @State private var dragStartTranslationY: CGFloat = 0.0
    @State private var lastDragUpdate: Date = .init()

    @State private var pinchStartSize: Double = 0.0
    @State private var isPinching: Bool = false

    private func triggerHaptic() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    // MARK: - Coordinate Mapping

    private func getWidgetRect(widgetInScene: WidgetInScene, streamSize: CGSize) -> CGRect {
        let layout = widgetInScene.sceneWidget.layout
        let (wWidth, wHeight) = getWidgetDimensions(widgetInScene: widgetInScene, streamSize: streamSize)

        var wX: CGFloat
        var wY: CGFloat

        if layout.alignment.isHorizontalCenter() {
            wX = (streamSize.width - wWidth) / 2
        } else if layout.alignment.isLeft() {
            wX = CGFloat(layout.x / 100.0) * streamSize.width
        } else {
            wX = streamSize.width - CGFloat(layout.x / 100.0) * streamSize.width - wWidth
        }

        if layout.alignment.isVerticalCenter() {
            wY = (streamSize.height - wHeight) / 2
        } else if layout.alignment.isTop() {
            wY = CGFloat(layout.y / 100.0) * streamSize.height
        } else {
            wY = streamSize.height - CGFloat(layout.y / 100.0) * streamSize.height - wHeight
        }

        return CGRect(x: wX, y: wY, width: wWidth, height: wHeight)
    }

    private func getWidgetAspectRatio(widget: SettingsWidget) -> CGFloat {
        switch widget.type {
        case .image:
            if let data = model.imageStorage.read(id: widget.id),
               let img = UIImage(data: data),
               img.size.height > 0
            {
                return img.size.width / img.size.height
            }
            return 1.0
        case .browser:
            return CGFloat(max(widget.browser.width, 1)) / CGFloat(max(widget.browser.height, 1))
        case .videoSource:
            return 16.0 / 9.0
        case .text:
            return 4.0
        default:
            return 1.0
        }
    }

    private func getWidgetDimensions(widgetInScene: WidgetInScene, streamSize: CGSize) -> (CGFloat, CGFloat) {
        if widgetInScene.widget.type == .text {
            let fontSize = CGFloat(widgetInScene.widget.text.fontSizeFloat)
            let scale = streamSize.width / 1920.0
            let estHeight = max(fontSize * scale * 1.3, 28)
            let estWidth = max(estHeight * 3.0, 70)
            return (estWidth, estHeight)
        }

        let layout = widgetInScene.sceneWidget.layout
        let aspect = getWidgetAspectRatio(widget: widgetInScene.widget)
        let streamAspect = model.stream.dimensions().aspectRatio()

        var wWidth: CGFloat
        var wHeight: CGFloat
        if streamAspect < aspect {
            wWidth = CGFloat(layout.size / 100.0) * streamSize.width
            wHeight = max(wWidth / aspect, 20)
        } else {
            wHeight = CGFloat(layout.size / 100.0) * streamSize.height
            wWidth = max(wHeight * aspect, 20)
        }
        return (wWidth, wHeight)
    }

    private func convertToTopLeft(widgetInScene: WidgetInScene, rect: CGRect, streamSize: CGSize) {
        var layout = widgetInScene.sceneWidget.layout
        let currentXPercent = (rect.minX / streamSize.width) * 100.0
        let currentYPercent = (rect.minY / streamSize.height) * 100.0

        layout.alignment = .topLeft
        layout.x = max(0.0, min(95.0, Double(currentXPercent)))
        layout.y = max(0.0, min(95.0, Double(currentYPercent)))
        layout.updateXString()
        layout.updateYString()

        widgetInScene.sceneWidget.layout = layout
    }

    // MARK: - Widget Item View

    @ViewBuilder
    private func widgetItemView(widgetInScene: WidgetInScene, rect: CGRect, streamSize: CGSize) -> some View {
        let isSelected = model.selectedWidgetForInteraction?.id == widgetInScene.id

        ZStack {
            // Invisible touch padding
            Color.black.opacity(0.001)

            // Outline Box
            Rectangle()
                .stroke(
                    isSelected ? Color.blue : Color.white.opacity(0.7),
                    style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isSelected ? [] : [4, 4])
                )
                .background(isSelected ? Color.blue.opacity(0.12) : Color.clear)

            // Small Badge Label
            VStack {
                HStack(spacing: 3) {
                    Image(systemName: widgetInScene.widget.image())
                        .font(.system(size: 9))
                    Text(widgetInScene.widget.name)
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isSelected ? Color.blue : Color.black.opacity(0.7))
                .cornerRadius(4)
                Spacer()
            }
            .padding(.top, -20)
        }
        .frame(width: max(rect.width, 44), height: max(rect.height, 44))
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !isPinching else { return }

                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = sqrt(dx * dx + dy * dy)

                    if distance > 4 {
                        if activeDragWidgetId != widgetInScene.id {
                            activeDragWidgetId = widgetInScene.id
                            convertToTopLeft(widgetInScene: widgetInScene, rect: rect, streamSize: streamSize)

                            let layout = widgetInScene.sceneWidget.layout
                            dragStartLayoutX = layout.x
                            dragStartLayoutY = layout.y
                            dragStartTranslationX = dx
                            dragStartTranslationY = dy
                        }

                        if model.selectedWidgetForInteraction?.id != widgetInScene.id {
                            triggerHaptic()
                            model.selectedWidgetForInteraction = widgetInScene
                        }

                        var layout = widgetInScene.sceneWidget.layout
                        let effectiveDx = dx - dragStartTranslationX
                        let effectiveDy = dy - dragStartTranslationY

                        let candidateX = (dragStartLayoutX / 100.0) * streamSize.width + effectiveDx
                        let candidateY = (dragStartLayoutY / 100.0) * streamSize.height + effectiveDy

                        layout.x = max(0.0, min(95.0, Double(candidateX / streamSize.width) * 100.0))
                        layout.y = max(0.0, min(95.0, Double(candidateY / streamSize.height) * 100.0))
                        layout.updateXString()
                        layout.updateYString()

                        widgetInScene.sceneWidget.layout = layout

                        let now = Date()
                        if now.timeIntervalSince(lastDragUpdate) > 0.033 {
                            model.updateWidgetLayoutDirectly(
                                widgetId: widgetInScene.widget.id,
                                sceneWidget: widgetInScene.sceneWidget
                            )
                            lastDragUpdate = now
                        }
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = sqrt(dx * dx + dy * dy)

                    if distance <= 4, !isPinching {
                        triggerHaptic()
                        if model.selectedWidgetForInteraction?.id == widgetInScene.id {
                            model.selectedWidgetForInteraction = nil
                        } else {
                            model.selectedWidgetForInteraction = widgetInScene
                        }
                    } else if distance > 4 {
                        model.updateWidgetLayoutDirectly(
                            widgetId: widgetInScene.widget.id,
                            sceneWidget: widgetInScene.sceneWidget
                        )
                    }

                    isPinching = false
                    activeDragWidgetId = nil
                    model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
                }
                .simultaneously(with:
                    MagnificationGesture()
                        .onChanged { scale in
                            isPinching = true
                            if model.selectedWidgetForInteraction?.id != widgetInScene.id {
                                triggerHaptic()
                                model.selectedWidgetForInteraction = widgetInScene
                            }

                            var layout = widgetInScene.sceneWidget.layout

                            if widgetInScene.widget.type == .text {
                                if pinchStartSize == 0 {
                                    pinchStartSize = Double(widgetInScene.widget.text.fontSizeFloat)
                                }
                                let newSize = (pinchStartSize * Double(scale)).clamped(to: 10 ... 300)
                                widgetInScene.widget.text.fontSizeFloat = Float(newSize)
                                widgetInScene.widget.text.fontSize = Int(newSize)
                                model.objectWillChange.send()
                                return
                            }

                            if pinchStartSize == 0 {
                                pinchStartSize = layout.size
                            }

                            let newSize = (pinchStartSize * Double(scale)).clamped(to: 1 ... 100)
                            layout.size = newSize
                            layout.updateSizeString()

                            widgetInScene.sceneWidget.layout = layout
                            model.updateWidgetLayoutDirectly(
                                widgetId: widgetInScene.widget.id,
                                sceneWidget: widgetInScene.sceneWidget
                            )
                        }
                        .onEnded { _ in
                            pinchStartSize = 0
                            model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
                        }
                )
        )
    }

    // MARK: - Body

    var body: some View {
        if model.editWidgetsMode {
            let widgets = model.widgetsInCurrentScene(onlyEnabled: false)

            ZStack {
                // Dimmed touchable backdrop to dismiss selection
                Color.black.opacity(0.10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectedWidgetForInteraction = nil
                    }

                ForEach(widgets) { widgetInScene in
                    let rect = getWidgetRect(widgetInScene: widgetInScene, streamSize: streamSize)
                    widgetItemView(widgetInScene: widgetInScene, rect: rect, streamSize: streamSize)
                }
            }
        }
    }
}
