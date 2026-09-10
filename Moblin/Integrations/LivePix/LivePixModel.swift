import Foundation

// MARK: - Token Response
struct LivePixTokenResponse: Codable, Sendable {
    let token: String
}

// MARK: - Widget Metadata (da rota /widgets/{widgetId})
struct LivePixWidgetMetadata: Codable, Sendable {
    let id: String?
    let userId: String?
    let type: String?
}

// MARK: - Protocol Messages (PubSub wss://pubsub.livepix.gg/ws)
struct LivePixClientMessage<T: Codable & Sendable>: Codable, Sendable {
    let id: String?
    let message: LivePixEvent<T>

    init(event: LivePixEvent<T>, id: String? = nil) {
        self.id = id
        self.message = event
    }
}

struct LivePixEvent<T: Codable & Sendable>: Codable, Sendable {
    let type: Int
    let event: String
    let payload: T
    let time: Int
}

// MARK: - Notification Payload (Doação / Alerta)
struct LivePixNotificationPayload: Codable, Sendable {
    let alertId: String
    let data: LivePixAlertDataContainer?
    let receipt: String?
}

struct LivePixAlertDataContainer: Codable, Sendable {
    let config: LivePixAlertConfig?
    let data: LivePixDonationDetails?
    let parameters: LivePixParameters?
}

struct LivePixAlertConfig: Codable, Sendable {
    let maximumDuration: Double?
    let minimumDuration: Double?
    let audioEnabled: Bool?
    let audioUrl: String?
    let audioVolume: Double?
    let audioDuration: Double?
    let textToSpeechEnabled: Bool?
    let textToSpeechUrl: String?
    let textToSpeechVolume: Double?
}

struct LivePixDonationDetails: Codable, Sendable {
    let author: String?
    let message: String?
    let amount: LivePixAmount?
    let type: String?
}

struct LivePixAmount: Codable, Sendable {
    let currency: String?
    let formatted: String?
    let value: Double?
}

struct LivePixParameters: Codable, Sendable {
    let color: String?
}

// MARK: - Objeto de Domínio do Moblin
struct LivePixDonation: Identifiable, Sendable {
    let id: String
    let author: String
    let message: String
    let formattedAmount: String
    let value: Double
    let audioUrl: URL?
    let ttsUrl: URL?
    let color: String
    let createdAt: Date
}
