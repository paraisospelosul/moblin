import CoreImage
import MetalPetal
import SwiftUI

struct LivePixAlertCardView: View {
    let author: String
    let formattedAmount: String
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.0, green: 0.8, blue: 0.45))
                    .frame(width: 46, height: 46)
                Image(systemName: "dollarsign")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(author)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(formattedAmount)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(Color(red: 0.1, green: 0.95, blue: 0.5))
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.08).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    Color(red: 0.0, green: 0.8, blue: 0.45).opacity(0.8),
                    lineWidth: 1.5
                )
        )
    }
}

@MainActor
func renderLivePixAlertImage(author: String, formattedAmount: String, message: String) -> CIImage? {
    let view = LivePixAlertCardView(
        author: author,
        formattedAmount: formattedAmount,
        message: message
    )
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2.0
    guard let cgImage = renderer.cgImage else {
        return nil
    }
    return CIImage(cgImage: cgImage)
}

final class LivePixAlertEffect: VideoEffect, @unchecked Sendable {
    private var sceneWidget: SettingsSceneWidget?
    private var currentAlert: EffectImageCiImage?
    private var hideAlertTime: Double?
    private var duration: Double

    init(duration: Double) {
        self.duration = duration
        super.init()
    }

    func setSceneWidget(sceneWidget: SettingsSceneWidget) {
        processorPipelineQueue.async {
            self.sceneWidget = sceneWidget
        }
    }

    func setSettings(duration: Double) {
        processorPipelineQueue.async {
            self.duration = duration
        }
    }

    func showDonation(image: CIImage, duration: Double? = nil) {
        processorPipelineQueue.async {
            self.currentAlert = image.toEffectImage(isOpaque: false)
            if let duration {
                self.duration = duration
            }
            self.hideAlertTime = nil
        }
    }

    override func execute(_ image: CIImage, _ info: VideoEffectInfo) -> CIImage {
        guard let sceneWidget else {
            return image
        }
        updateCurrentAlert(info: info)
        guard let currentAlert else {
            return image
        }
        return applyEffectsResizeMirrorMove(currentAlert.getCiImage(),
                                            sceneWidget,
                                            false,
                                            image.extent,
                                            info)
            .composited(over: image)
    }

    override func executeMetalPetal(_ image: MTIImage, _ info: VideoEffectInfo) -> MTIImage {
        guard let sceneWidget else {
            return image
        }
        updateCurrentAlert(info: info)
        guard let currentAlert else {
            return image
        }
        return applyEffectsResizeMirrorMoveMetalPetal(currentAlert.getMetalPetalImage(),
                                                      sceneWidget,
                                                      false,
                                                      image,
                                                      info)
    }

    override func isEnabled() -> Bool {
        currentAlert != nil
    }

    private func updateCurrentAlert(info: VideoEffectInfo) {
        if hideAlertTime == nil {
            hideAlertTime = info.presentationTimeStamp.seconds + duration
        }
        if let hideAlertTime, info.presentationTimeStamp.seconds > hideAlertTime {
            currentAlert = nil
            self.hideAlertTime = nil
        }
    }
}
