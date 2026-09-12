import Foundation
import SwiftUI

extension Model: @preconcurrency LivePixDelegate {
    func setupLivePix() {
        livePix = LivePix(delegate: self)
        reloadLivePix()
    }

    func reloadLivePix() {
        let settings = database.livePix
        guard settings.enabled else {
            livePix?.stop()
            return
        }
        livePix?.start(widgetInput: settings.widgetUrl)
    }

    func livePixDidReceiveDonation(_ donation: LivePixDonation) {
        DispatchQueue.main.async {
            // 1. Notificação Toast no topo da tela do streamer
            self.makeToast(title: "💸 \(donation.author): \(donation.formattedAmount)")

            // 2. Insere a mensagem formatada no chat nativo do Moblin
            var id = 0
            let donationText = donation.message.isEmpty
                ? donation.formattedAmount
                : "\(donation.formattedAmount) - \(donation.message)"
            self.appendChatMessage(
                platform: .livePix,
                messageId: donation.id,
                displayName: donation.author,
                user: donation.author,
                userId: nil,
                userColor: nil,
                userBadges: [],
                segments: makeChatPostTextSegments(text: donationText, id: &id),
                timestamp: self.statusOther.digitalClock,
                timestampTime: .now,
                isAction: false,
                isSubscriber: false,
                isModerator: false,
                isOwner: false,
                bits: nil,
                highlight: .init(
                    kind: .redemption,
                    barColor: Color.green,
                    image: "dollarsign.circle",
                    titleSegments: makeChatPostTextSegments(text: "LivePix (\(donation.formattedAmount))")
                ),
                live: self.isLive
            )

            // 3. Exibe o card de alerta na cena (se o widget LivePix alert estiver ativo)
            self.showLivePixAlertOnScreen(donation: donation)
        }
    }

    func showLivePixAlertOnScreen(donation: LivePixDonation) {
        guard !livePixAlertEffects.isEmpty else {
            return
        }
        guard let ciImage = renderLivePixAlertImage(
            author: donation.author,
            formattedAmount: donation.formattedAmount,
            message: donation.message
        ) else {
            return
        }
        for effect in livePixAlertEffects.values {
            effect.showDonation(image: ciImage)
        }
    }

    func testLivePixAlert() {
        let sample = LivePixDonation(
            id: UUID().uuidString,
            author: "Apoiador LivePix",
            message: "Parabéns pela live! Continue com o ótimo trabalho! 🚀",
            formattedAmount: "R$ 15,00",
            value: 15.0,
            audioUrl: nil,
            ttsUrl: nil,
            color: "#22c55e",
            createdAt: .init()
        )
        livePixDidReceiveDonation(sample)
    }

    func livePixStatusChanged(connected: Bool) {
        DispatchQueue.main.async {
            logger.info("livepix: Status connected: \(connected)")
        }
    }
}
