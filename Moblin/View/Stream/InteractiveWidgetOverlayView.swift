import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Interactive Widget Overlay View
// This view overlays the video preview and allows users to select, drag, resize,
// and manage widgets using touch gestures (tap, drag, pinch).
//
// Architecture:
// - Tap to select/deselect widgets
// - Single-finger drag to move selected widget
// - Two-finger pinch to resize selected widget
// - Corner handles for precise resize
// - Snapping to edges and center guides with haptic feedback
// - HUD toolbar for z-ordering, locking, and deletion

struct InteractiveWidgetOverlayView: View {
    @ObservedObject var model: Model
    let previewSize: CGSize

    // Drag state
    @State private var activeDragWidgetId: UUID? = nil
    @State private var isDragging: Bool = false
    @State private var dragStartLayoutX: Double = 0.0
    @State private var dragStartLayoutY: Double = 0.0
    @State private var dragStartTranslationX: CGFloat = 0.0
    @State private var dragStartTranslationY: CGFloat = 0.0
    @State private var lastDragUpdate: Date = Date()

    // Pinch state
    @State private var pinchStartSize: Double = 0.0
    @State private var isPinching: Bool = false

    // Snapping states
    @State private var activeSnapX: CGFloat? = nil
    @State private var activeSnapY: CGFloat? = nil
    @State private var hasHapticedX: Bool = false
    @State private var hasHapticedY: Bool = false

    // Corner resizing states
    @State private var activeResizeHandle: String? = nil
    @State private var resizeStartRect: CGRect = .zero
    @State private var resizeStartSize: Double = 0.0
    @State private var resizeStartLayoutX: Double = 0.0
    @State private var resizeStartLayoutY: Double = 0.0

    private let snapThreshold: CGFloat = 12.0

    // MARK: - Haptic Feedback

    private func triggerHaptic() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    // MARK: - Coordinate Mapping

    private func getVideoBounds() -> CGRect {
        let streamAspect = model.stream.dimensions().aspectRatio()
        let previewAspect = previewSize.width / previewSize.height

        var videoWidth: CGFloat
        var videoHeight: CGFloat
        var videoX: CGFloat
        var videoY: CGFloat

        if previewAspect > streamAspect {
            videoHeight = previewSize.height
            videoWidth = videoHeight * streamAspect
            videoX = (previewSize.width - videoWidth) / 2
            videoY = 0
        } else {
            videoWidth = previewSize.width
            videoHeight = videoWidth / streamAspect
            videoX = 0
            videoY = (previewSize.height - videoHeight) / 2
        }

        return CGRect(x: videoX, y: videoY, width: videoWidth, height: videoHeight)
    }

    private func getWidgetRect(widgetInScene: WidgetInScene, videoBounds: CGRect) -> CGRect {
        let layout = widgetInScene.sceneWidget.layout
        let (wWidth, wHeight) = getWidgetDimensions(widgetInScene: widgetInScene, videoBounds: videoBounds)

        // Mirror the move logic from EffectUtils.swift
        var wX: CGFloat
        var wY: CGFloat

        if layout.alignment.isHorizontalCenter() {
            wX = videoBounds.minX + (videoBounds.width - wWidth) / 2
        } else if layout.alignment.isLeft() {
            wX = videoBounds.minX + CGFloat(layout.x / 100.0) * videoBounds.width
        } else { // Right
            wX = videoBounds.minX + videoBounds.width - CGFloat(layout.x / 100.0) * videoBounds.width - wWidth
        }

        if layout.alignment.isVerticalCenter() {
            wY = videoBounds.minY + (videoBounds.height - wHeight) / 2
        } else if layout.alignment.isTop() {
            wY = videoBounds.minY + CGFloat(layout.y / 100.0) * videoBounds.height
        } else { // Bottom
            wY = videoBounds.minY + videoBounds.height - CGFloat(layout.y / 100.0) * videoBounds.height - wHeight
        }

        return CGRect(x: wX, y: wY, width: wWidth, height: wHeight)
    }

    private func getWidgetAspectRatio(widget: SettingsWidget) -> CGFloat {
        switch widget.type {
        case .image:
            if let data = model.imageStorage.read(id: widget.id),
               let img = UIImage(data: data),
               img.size.height > 0 {
                return img.size.width / img.size.height
            }
            return 1.0
        case .qrCode:
            return 1.0
        case .browser:
            return CGFloat(max(widget.browser.width, 1)) / CGFloat(max(widget.browser.height, 1))
        case .videoSource:
            return 16.0 / 9.0
        case .text:
            return 4.0
        case .scoreboard:
            return 4.0
        default:
            return 1.0
        }
    }

    /// Calculates the maximum allowed layout.x and layout.y percentages for a widget
    /// to guarantee it never extends past the video stream frame or gets clipped.
    private func getMaxPositionPercent(widget: SettingsWidget, layout: SettingsWidgetLayout) -> (maxX: Double, maxY: Double) {
        if widget.type == .text {
            return (maxX: 90.0, maxY: 90.0)
        }
        let aspect = getWidgetAspectRatio(widget: widget)
        let streamAspect = model.stream.dimensions().aspectRatio()

        if streamAspect < aspect {
            let maxX = max(0.0, 100.0 - layout.size)
            let maxY = max(0.0, 100.0 - layout.size * (streamAspect / aspect))
            return (maxX, maxY)
        } else {
            let maxX = max(0.0, 100.0 - layout.size * (aspect / streamAspect))
            let maxY = max(0.0, 100.0 - layout.size)
            return (maxX, maxY)
        }
    }

    // MARK: - Layout Conversion

    /// Convert any alignment mode to topLeft for direct position manipulation during gestures.
    /// This ensures consistent coordinate math regardless of the widget's original alignment.
    private func convertToTopLeft(widgetInScene: WidgetInScene, rect: CGRect, videoBounds: CGRect) {
        var layout = widgetInScene.sceneWidget.layout
        guard layout.alignment != .topLeft else { return }

        let (maxPctX, maxPctY) = getMaxPositionPercent(widget: widgetInScene.widget, layout: layout)
        let currentXPercent = Double((rect.minX - videoBounds.minX) / videoBounds.width) * 100.0
        let currentYPercent = Double((rect.minY - videoBounds.minY) / videoBounds.height) * 100.0

        layout.alignment = .topLeft
        layout.x = currentXPercent.clamped(to: 0.0...maxPctX)
        layout.y = currentYPercent.clamped(to: 0.0...maxPctY)
        layout.updateXString()
        layout.updateYString()

        widgetInScene.sceneWidget.layout = layout
        model.updateWidgetLayoutDirectly(widgetId: widgetInScene.widget.id, sceneWidget: widgetInScene.sceneWidget)
    }

    // MARK: - Snapping Logic

    private func applySnapping(
        candidateMinX: inout CGFloat,
        candidateMinY: inout CGFloat,
        wWidth: CGFloat,
        wHeight: CGFloat,
        videoBounds: CGRect
    ) {
        // Vertical snap guides (left, center, right)
        var snapLineX: CGFloat? = nil
        let leftDiff = abs(candidateMinX - videoBounds.minX)
        let centerDiff = abs((candidateMinX + wWidth / 2) - videoBounds.midX)
        let rightDiff = abs((candidateMinX + wWidth) - videoBounds.maxX)
        
        if leftDiff < snapThreshold {
            candidateMinX = videoBounds.minX
            snapLineX = videoBounds.minX
        } else if centerDiff < snapThreshold {
            candidateMinX = videoBounds.midX - wWidth / 2
            snapLineX = videoBounds.midX
        } else if rightDiff < snapThreshold {
            candidateMinX = videoBounds.maxX - wWidth
            snapLineX = videoBounds.maxX
        }

        // Horizontal snap guides (top, center, bottom)
        var snapLineY: CGFloat? = nil
        let topDiff = abs(candidateMinY - videoBounds.minY)
        let centerVDiff = abs((candidateMinY + wHeight / 2) - videoBounds.midY)
        let bottomDiff = abs((candidateMinY + wHeight) - videoBounds.maxY)
        
        if topDiff < snapThreshold {
            candidateMinY = videoBounds.minY
            snapLineY = videoBounds.minY
        } else if centerVDiff < snapThreshold {
            candidateMinY = videoBounds.midY - wHeight / 2
            snapLineY = videoBounds.midY
        } else if bottomDiff < snapThreshold {
            candidateMinY = videoBounds.maxY - wHeight
            snapLineY = videoBounds.maxY
        }

        // Haptic feedback on snap engage/disengage
        if snapLineX != nil {
            if !hasHapticedX {
                triggerHaptic()
                hasHapticedX = true
            }
        } else {
            hasHapticedX = false
        }

        if snapLineY != nil {
            if !hasHapticedY {
                triggerHaptic()
                hasHapticedY = true
            }
        } else {
            hasHapticedY = false
        }

        activeSnapX = snapLineX
        activeSnapY = snapLineY
    }

    // MARK: - Widget Dimensions Helper

    private func getWidgetDimensions(widgetInScene: WidgetInScene, videoBounds: CGRect) -> (CGFloat, CGFloat) {
        if widgetInScene.widget.type == .text {
            let fontSize = CGFloat(widgetInScene.widget.text.fontSizeFloat)
            // The text rendered height is roughly fontSize * scale.
            let scale = videoBounds.width / 1920.0
            let estHeight = max(fontSize * scale * 1.2, 24) // Minimum 24pt height
            let estWidth = max(estHeight * 2.5, 60) // Aspect 2.5:1 width
            return (estWidth, estHeight)
        }

        let layout = widgetInScene.sceneWidget.layout
        let aspect = getWidgetAspectRatio(widget: widgetInScene.widget)
        let streamAspect = model.stream.dimensions().aspectRatio()
        
        var wWidth: CGFloat
        var wHeight: CGFloat
        if streamAspect < aspect {
            wWidth = CGFloat(layout.size / 100.0) * videoBounds.width
            wHeight = wWidth / aspect
        } else {
            wHeight = CGFloat(layout.size / 100.0) * videoBounds.height
            wWidth = wHeight * aspect
        }
        return (wWidth, wHeight)
    }

    // MARK: - Corner Resize Handles

    private func cornerHandle(x: CGFloat, y: CGFloat, handle: String, widgetInScene: WidgetInScene, rect: CGRect, videoBounds: CGRect) -> some View {
        let handleSize: CGFloat = min(16, max(10, min(rect.width, rect.height) / 4.0))
        return Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(
                Circle()
                    .stroke(Color.blue, lineWidth: 2)
            )
            .contentShape(Circle().scale(1.2))
            .position(x: x, y: y)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        var layout = widgetInScene.sceneWidget.layout
                        guard !layout.positioningLock else { return }
                        
                        if activeResizeHandle != handle {
                            activeResizeHandle = handle
                            convertToTopLeft(widgetInScene: widgetInScene, rect: rect, videoBounds: videoBounds)
                            layout = widgetInScene.sceneWidget.layout
                            resizeStartRect = rect
                            resizeStartSize = layout.size
                            resizeStartLayoutX = layout.x
                            resizeStartLayoutY = layout.y
                        }
                        
                        let dx = value.translation.width
                        let dy = value.translation.height
                        let delta: CGFloat
                        switch handle {
                        case "bottomRight":
                            delta = (dx + dy) / 2.0
                        case "bottomLeft":
                            delta = (-dx + dy) / 2.0
                        case "topRight":
                            delta = (dx - dy) / 2.0
                        case "topLeft":
                            delta = (-dx - dy) / 2.0
                        default:
                            delta = 0
                        }
                        
                        let baseDim = max(resizeStartRect.width, resizeStartRect.height)
                        let scaleFactor = max(0.1, 1.0 + delta / max(baseDim, 30.0))
                        let newSize = (resizeStartSize * Double(scaleFactor)).clamped(to: 5.0...100.0)
                        layout.size = newSize
                        layout.updateSizeString()
                        
                        let (newW, newH) = getWidgetDimensions(widgetInScene: widgetInScene, videoBounds: videoBounds)
                        
                        switch handle {
                        case "bottomRight":
                            layout.x = resizeStartLayoutX
                            layout.y = resizeStartLayoutY
                        case "bottomLeft":
                            let newMinX = resizeStartRect.maxX - newW
                            layout.x = Double((newMinX - videoBounds.minX) / videoBounds.width) * 100.0
                            layout.y = resizeStartLayoutY
                        case "topRight":
                            layout.x = resizeStartLayoutX
                            let newMinY = resizeStartRect.maxY - newH
                            layout.y = Double((newMinY - videoBounds.minY) / videoBounds.height) * 100.0
                        case "topLeft":
                            let newMinX = resizeStartRect.maxX - newW
                            let newMinY = resizeStartRect.maxY - newH
                            layout.x = Double((newMinX - videoBounds.minX) / videoBounds.width) * 100.0
                            layout.y = Double((newMinY - videoBounds.minY) / videoBounds.height) * 100.0
                        default:
                            break
                        }
                        
                        let (maxPctX, maxPctY) = getMaxPositionPercent(widget: widgetInScene.widget, layout: layout)
                        layout.x = layout.x.clamped(to: 0.0...maxPctX)
                        layout.y = layout.y.clamped(to: 0.0...maxPctY)
                        layout.updateXString()
                        layout.updateYString()
                        
                        widgetInScene.sceneWidget.layout = layout
                        model.updateWidgetLayoutDirectly(widgetId: widgetInScene.widget.id, sceneWidget: widgetInScene.sceneWidget)
                    }
                    .onEnded { _ in
                        activeResizeHandle = nil
                        model.storeSettings()
                        model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
                    }
            )
    }

    // MARK: - Quick Alignment

    private func alignWidget(widgetInScene: WidgetInScene, alignment: SettingsAlignment) {
        triggerHaptic()
        var layout = widgetInScene.sceneWidget.layout
        guard !layout.positioningLock else { return }

        let (maxX, maxY) = getMaxPositionPercent(widget: widgetInScene.widget, layout: layout)
        layout.alignment = .topLeft

        switch alignment {
        case .topLeft:
            layout.x = 0.0
            layout.y = 0.0
        case .topRight:
            layout.x = maxX
            layout.y = 0.0
        case .bottomLeft:
            layout.x = 0.0
            layout.y = maxY
        case .bottomRight:
            layout.x = maxX
            layout.y = maxY
        case .center:
            layout.x = maxX / 2.0
            layout.y = maxY / 2.0
        case .topCenter:
            layout.x = maxX / 2.0
            layout.y = 0.0
        case .bottomCenter:
            layout.x = maxX / 2.0
            layout.y = maxY
        case .leftCenter:
            layout.x = 0.0
            layout.y = maxY / 2.0
        case .rightCenter:
            layout.x = maxX
            layout.y = maxY / 2.0
        }

        layout.updateXString()
        layout.updateYString()
        widgetInScene.sceneWidget.layout = layout
        model.updateWidgetLayoutDirectly(widgetId: widgetInScene.widget.id, sceneWidget: widgetInScene.sceneWidget)
        model.storeSettings()
        model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
    }

    // MARK: - HUD Toolbar

    private func hudToolbar(widgetInScene: WidgetInScene, rect: CGRect) -> some View {
        let isLocked = widgetInScene.sceneWidget.layout.positioningLock
        let toolbarHeight: CGFloat = 38
        
        let xPos = rect.midX
        let yPos = rect.minY < 60 ? (rect.maxY + toolbarHeight / 2 + 12) : (rect.minY - toolbarHeight / 2 - 12)
        
        return HStack(spacing: 12) {
            Menu {
                Button(action: {
                    alignWidget(widgetInScene: widgetInScene, alignment: .topLeft)
                }) {
                    Label("Top Left", systemImage: "arrow.up.left")
                }
                Button(action: {
                    alignWidget(widgetInScene: widgetInScene, alignment: .topRight)
                }) {
                    Label("Top Right", systemImage: "arrow.up.right")
                }
                Button(action: {
                    alignWidget(widgetInScene: widgetInScene, alignment: .center)
                }) {
                    Label("Center", systemImage: "plus")
                }
                Button(action: {
                    alignWidget(widgetInScene: widgetInScene, alignment: .bottomLeft)
                }) {
                    Label("Bottom Left", systemImage: "arrow.down.left")
                }
                Button(action: {
                    alignWidget(widgetInScene: widgetInScene, alignment: .bottomRight)
                }) {
                    Label("Bottom Right", systemImage: "arrow.down.right")
                }
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Divider()
                .frame(width: 1, height: 18)
                .background(Color.white.opacity(0.3))

            Button(action: {
                triggerHaptic()
                model.sendWidgetToBack(widgetId: widgetInScene.widget.id)
            }) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Button(action: {
                triggerHaptic()
                model.bringWidgetToFront(widgetId: widgetInScene.widget.id)
            }) {
                Image(systemName: "arrow.up.to.line.compact")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Divider()
                .frame(width: 1, height: 18)
                .background(Color.white.opacity(0.3))
            
            Button(action: {
                triggerHaptic()
                model.objectWillChange.send()
                widgetInScene.sceneWidget.layout.positioningLock.toggle()
                model.storeSettings()
                model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
            }) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isLocked ? .red : .white)
            }
            
            Divider()
                .frame(width: 1, height: 18)
                .background(Color.white.opacity(0.3))
            
            Button(action: {
                triggerHaptic()
                model.deleteWidgetFromScene(widgetId: widgetInScene.widget.id)
            }) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: toolbarHeight)
        .background(Color.black.opacity(0.85))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
        .position(x: xPos, y: yPos)
    }

    // MARK: - Widget Item View

    @ViewBuilder
    private func widgetItemView(widgetInScene: WidgetInScene, rect: CGRect, videoBounds: CGRect) -> some View {
        let isSelected = model.selectedWidgetForInteraction?.id == widgetInScene.id
        let isLocked = widgetInScene.sceneWidget.layout.positioningLock

        // Widget bounding box with visual feedback
        ZStack {
            // Transparent fill covering the minimum 44x44 touch area
            Color.black.opacity(0.001)

            // Selection outline and content sized to the actual widget rect
            ZStack {
                Rectangle()
                    .stroke(
                        isSelected ? Color.blue : Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isSelected ? [] : [5, 3])
                    )
                    .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
                
                // Widget name label
                VStack(spacing: 2) {
                    let labelText: String = {
                        var text = widgetInScene.widget.name
                        if isLocked {
                            text += " (Locked)"
                        }
                        return text
                    }()
                    Text(labelText)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isLocked ? Color.red : (isSelected ? Color.blue : Color.black.opacity(0.7)))
                        .cornerRadius(4)
                    Spacer()
                }
                .padding(.top, -22)
            }
            .frame(width: max(rect.width, 10), height: max(rect.height, 10))
        }
        .frame(width: max(rect.width, 44), height: max(rect.height, 44))
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(true)
        // Unified gesture handling both TAP and DRAG + PINCH
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard !isPinching else { return }

                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = sqrt(dx*dx + dy*dy)

                    // Only move if we exceed the drag threshold of 5 points
                    if distance > 5 {
                        isDragging = true

                        // Initialize drag state on actual drag start
                        if activeDragWidgetId != widgetInScene.id {
                            activeDragWidgetId = widgetInScene.id
                            // Convert to topLeft alignment for consistent math
                            convertToTopLeft(widgetInScene: widgetInScene, rect: rect, videoBounds: videoBounds)
                            let layout = widgetInScene.sceneWidget.layout
                            dragStartLayoutX = layout.x
                            dragStartLayoutY = layout.y
                            dragStartTranslationX = dx
                            dragStartTranslationY = dy
                        }

                        // Auto-select on drag start
                        if model.selectedWidgetForInteraction?.id != widgetInScene.id {
                            triggerHaptic()
                            model.selectedWidgetForInteraction = widgetInScene
                        }
                        
                        var layout = widgetInScene.sceneWidget.layout
                        guard !layout.positioningLock else { return }

                        let (wWidth, wHeight) = getWidgetDimensions(widgetInScene: widgetInScene, videoBounds: videoBounds)
                        let (maxPctX, maxPctY) = getMaxPositionPercent(widget: widgetInScene.widget, layout: layout)

                        let effectiveDx = dx - dragStartTranslationX
                        let effectiveDy = dy - dragStartTranslationY

                        var candidateMinX = videoBounds.minX + CGFloat(dragStartLayoutX / 100.0) * videoBounds.width + effectiveDx
                        var candidateMinY = videoBounds.minY + CGFloat(dragStartLayoutY / 100.0) * videoBounds.height + effectiveDy

                        // Snapping with guide lines
                        var snapLineX: CGFloat? = nil
                        let leftDiff = abs(candidateMinX - videoBounds.minX)
                        let centerHDiff = abs((candidateMinX + wWidth / 2) - videoBounds.midX)
                        let rightDiff = abs((candidateMinX + wWidth) - videoBounds.maxX)

                        if leftDiff < snapThreshold {
                            candidateMinX = videoBounds.minX
                            snapLineX = videoBounds.minX
                        } else if centerHDiff < snapThreshold {
                            candidateMinX = videoBounds.midX - wWidth / 2
                            snapLineX = videoBounds.midX
                        } else if rightDiff < snapThreshold {
                            candidateMinX = videoBounds.maxX - wWidth
                            snapLineX = videoBounds.maxX
                        }

                        var snapLineY: CGFloat? = nil
                        let topDiff = abs(candidateMinY - videoBounds.minY)
                        let centerVDiff = abs((candidateMinY + wHeight / 2) - videoBounds.midY)
                        let bottomDiff = abs((candidateMinY + wHeight) - videoBounds.maxY)

                        if topDiff < snapThreshold {
                            candidateMinY = videoBounds.minY
                            snapLineY = videoBounds.minY
                        } else if centerVDiff < snapThreshold {
                            candidateMinY = videoBounds.midY - wHeight / 2
                            snapLineY = videoBounds.midY
                        } else if bottomDiff < snapThreshold {
                            candidateMinY = videoBounds.maxY - wHeight
                            snapLineY = videoBounds.maxY
                        }

                        // Haptics
                        if snapLineX != nil {
                            if !hasHapticedX {
                                triggerHaptic()
                                hasHapticedX = true
                            }
                        } else {
                            hasHapticedX = false
                        }

                        if snapLineY != nil {
                            if !hasHapticedY {
                                triggerHaptic()
                                hasHapticedY = true
                            }
                        } else {
                            hasHapticedY = false
                        }

                        activeSnapX = snapLineX
                        activeSnapY = snapLineY

                        // Strict clamping to video bounds so widget never extends past frame
                        let minAllowedX = videoBounds.minX
                        let maxAllowedX = max(videoBounds.minX, videoBounds.maxX - wWidth)
                        let minAllowedY = videoBounds.minY
                        let maxAllowedY = max(videoBounds.minY, videoBounds.maxY - wHeight)

                        candidateMinX = candidateMinX.clamped(to: minAllowedX...maxAllowedX)
                        candidateMinY = candidateMinY.clamped(to: minAllowedY...maxAllowedY)

                        // Convert to layout percentage with exact snap bounds
                        if snapLineX == videoBounds.minX {
                            layout.x = 0.0
                        } else if snapLineX == videoBounds.maxX {
                            layout.x = maxPctX
                        } else if snapLineX == videoBounds.midX {
                            layout.x = maxPctX / 2.0
                        } else {
                            let xPercent = Double((candidateMinX - videoBounds.minX) / videoBounds.width) * 100.0
                            layout.x = xPercent.clamped(to: 0.0...maxPctX)
                        }

                        if snapLineY == videoBounds.minY {
                            layout.y = 0.0
                        } else if snapLineY == videoBounds.maxY {
                            layout.y = maxPctY
                        } else if snapLineY == videoBounds.midY {
                            layout.y = maxPctY / 2.0
                        } else {
                            let yPercent = Double((candidateMinY - videoBounds.minY) / videoBounds.height) * 100.0
                            layout.y = yPercent.clamped(to: 0.0...maxPctY)
                        }

                        layout.updateXString()
                        layout.updateYString()

                        widgetInScene.sceneWidget.layout = layout
                        
                        let now = Date()
                        if now.timeIntervalSince(lastDragUpdate) > 0.033 {
                            model.updateWidgetLayoutDirectly(widgetId: widgetInScene.widget.id, sceneWidget: widgetInScene.sceneWidget)
                            lastDragUpdate = now
                        }
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = sqrt(dx*dx + dy*dy)

                    // If user tapped without dragging, toggle selection (and we were not pinching)
                    if distance <= 5 && !isPinching {
                        triggerHaptic()
                        if model.selectedWidgetForInteraction?.id == widgetInScene.id {
                            model.selectedWidgetForInteraction = nil
                        } else {
                            model.selectedWidgetForInteraction = widgetInScene
                        }
                    } else if distance > 5 {
                        // Force final layout sync
                        model.updateWidgetLayoutDirectly(widgetId: widgetInScene.widget.id, sceneWidget: widgetInScene.sceneWidget)
                        model.storeSettings()
                    }

                    isDragging = false
                    isPinching = false
                    activeDragWidgetId = nil
                    activeSnapX = nil
                    activeSnapY = nil
                    hasHapticedX = false
                    hasHapticedY = false
                    model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
                }
                .simultaneously(with:
                    MagnificationGesture()
                        .onChanged { scale in
                            // Guard against accidental pinch during drag or single touch
                            guard !isDragging && activeDragWidgetId == nil else { return }

                            if !isPinching {
                                if abs(scale - 1.0) > 0.08 {
                                    isPinching = true
                                    pinchStartSize = widgetInScene.sceneWidget.layout.size
                                } else {
                                    return
                                }
                            }

                            // Auto-select on pinch
                            if model.selectedWidgetForInteraction?.id != widgetInScene.id {
                                triggerHaptic()
                                model.selectedWidgetForInteraction = widgetInScene
                            }
                            
                            var layout = widgetInScene.sceneWidget.layout
                            guard !layout.positioningLock else { return }
                            
                            if widgetInScene.widget.type == .text {
                                if pinchStartSize == 0 {
                                    pinchStartSize = Double(widgetInScene.widget.text.fontSizeFloat)
                                }
                                let newSize = (pinchStartSize * Double(scale)).clamped(to: 10...300)
                                widgetInScene.widget.text.fontSizeFloat = Float(newSize)
                                widgetInScene.widget.text.fontSize = Int(newSize)
                                model.objectWillChange.send()
                                return
                            }
                            
                            if pinchStartSize == 0 {
                                pinchStartSize = layout.size
                            }
                            
                            let newSize = (pinchStartSize * Double(scale)).clamped(to: 5...100)
                            layout.size = newSize
                            layout.updateSizeString()
                            
                            // Re-clamp position so growing widget does not exceed frame
                            let (maxPctX, maxPctY) = getMaxPositionPercent(widget: widgetInScene.widget, layout: layout)
                            layout.x = layout.x.clamped(to: 0.0...maxPctX)
                            layout.y = layout.y.clamped(to: 0.0...maxPctY)
                            layout.updateXString()
                            layout.updateYString()

                            widgetInScene.sceneWidget.layout = layout
                            model.updateWidgetLayoutDirectly(widgetId: widgetInScene.widget.id, sceneWidget: widgetInScene.sceneWidget)
                        }
                        .onEnded { _ in
                            isPinching = false
                            pinchStartSize = 0
                            model.storeSettings()
                            model.sceneUpdated(attachCamera: false, updateRemoteScene: true)
                        }
                )
        )
    }

    // MARK: - Body

    var body: some View {
        if model.editWidgetsMode {
            let videoBounds = getVideoBounds()
            let widgets = model.widgetsInCurrentScene(onlyEnabled: true)

            ZStack {
                // Background overlay to deselect when tapping empty space
                Color.black.opacity(0.15)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectedWidgetForInteraction = nil
                    }

                // Snap guide lines (yellow dashed)
                if let snapX = activeSnapX {
                    Path { path in
                        path.move(to: CGPoint(x: snapX, y: 0))
                        path.addLine(to: CGPoint(x: snapX, y: previewSize.height))
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
                }
                if let snapY = activeSnapY {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: snapY))
                        path.addLine(to: CGPoint(x: previewSize.width, y: snapY))
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
                }

                // Widget interaction areas
                ForEach(widgets) { widgetInScene in
                    let rect = getWidgetRect(widgetInScene: widgetInScene, videoBounds: videoBounds)
                    widgetItemView(widgetInScene: widgetInScene, rect: rect, videoBounds: videoBounds)
                }

                // Corner handles and HUD for the selected widget (rendered on top of all widgets)
                if let selected = model.selectedWidgetForInteraction,
                   let selectedInScene = widgets.first(where: { $0.id == selected.id }) {
                    let rect = getWidgetRect(widgetInScene: selectedInScene, videoBounds: videoBounds)
                    Group {
                        cornerHandle(x: rect.minX, y: rect.minY, handle: "topLeft", widgetInScene: selectedInScene, rect: rect, videoBounds: videoBounds)
                        cornerHandle(x: rect.maxX, y: rect.minY, handle: "topRight", widgetInScene: selectedInScene, rect: rect, videoBounds: videoBounds)
                        cornerHandle(x: rect.minX, y: rect.maxY, handle: "bottomLeft", widgetInScene: selectedInScene, rect: rect, videoBounds: videoBounds)
                        cornerHandle(x: rect.maxX, y: rect.maxY, handle: "bottomRight", widgetInScene: selectedInScene, rect: rect, videoBounds: videoBounds)
                    }

                    hudToolbar(widgetInScene: selectedInScene, rect: rect)
                }
            }
        }
    }
}
