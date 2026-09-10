import AVFoundation
import Foundation

protocol LivePixDelegate: AnyObject {
    func livePixDidReceiveDonation(_ donation: LivePixDonation)
    func livePixStatusChanged(connected: Bool)
}

final class LivePix: NSObject, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var widgetId: String = ""
    private var isRunning = false
    private weak var delegate: (any LivePixDelegate)?

    // Áudio
    private var audioPlayer: AVPlayer?
    private var ttsPlayer: AVPlayer?

    // Deduplicação de alertas
    private var seenAlertIds: Set<String> = []
    private var seenAlertOrder: [String] = []
    private let maxSeenIds = 500

    // Reconexão
    private var reconnectDelay: TimeInterval = 3.0
    private let maxReconnectDelay: TimeInterval = 30.0

    init(delegate: any LivePixDelegate) {
        self.delegate = delegate
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        self.urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
    }

    /// Extrai o ID do widget a partir de qualquer formato de URL do LivePix
    /// Suporta:
    /// - https://widget.livepix.gg/embed/a1b2c3d4-e5f6...
    /// - https://livepix.gg/widget/a1b2c3d4-e5f6...
    /// - a1b2c3d4-e5f6...
    static func extractWidgetId(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if let embedIdx = pathComponents.firstIndex(of: "embed"), embedIdx + 1 < pathComponents.count {
                return pathComponents[embedIdx + 1]
            }
            if let widgetIdx = pathComponents.firstIndex(of: "widget"), widgetIdx + 1 < pathComponents.count {
                return pathComponents[widgetIdx + 1]
            }
            if let last = pathComponents.last, last.count >= 8 {
                return last
            }
        }
        return trimmed
    }

    func start(widgetInput: String) {
        let id = Self.extractWidgetId(from: widgetInput)
        guard !id.isEmpty else { return }

        stop()
        self.widgetId = id
        self.isRunning = true
        self.reconnectDelay = 3.0

        Task {
            await connect()
        }
    }

    func stop() {
        isRunning = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.audioPlayer?.pause()
            self.audioPlayer = nil
            self.ttsPlayer?.pause()
            self.ttsPlayer = nil
            self.delegate?.livePixStatusChanged(connected: false)
        }
    }

    private func connect() async {
        guard isRunning else { return }

        // 1. Busca metadados do widget (para pegar userId e tópicos extras)
        var topics = ["widget:\(widgetId)"]
        if let metadataUrl = URL(string: "https://webservice.livepix.gg/widgets/\(widgetId)") {
            if let (data, resp) = try? await urlSession.data(from: metadataUrl),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let meta = try? JSONDecoder().decode(LivePixWidgetMetadata.self, from: data),
               let userId = meta.userId {
                topics.append("user:widgets:notification:\(userId)")
            }
        }

        // 2. Busca token temporário do PubSub
        guard let tokenUrl = URL(string: "https://webservice.livepix.gg/pubsub/widget/\(widgetId)") else { return }

        do {
            let (data, response) = try await urlSession.data(from: tokenUrl)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                scheduleReconnect()
                return
            }

            let tokenResponse = try JSONDecoder().decode(LivePixTokenResponse.self, from: data)
            openWebSocket(token: tokenResponse.token, topics: topics)
            reconnectDelay = 3.0
        } catch {
            scheduleReconnect()
        }
    }

    private func openWebSocket(token: String, topics: [String]) {
        guard let wsUrl = URL(string: "wss://pubsub.livepix.gg/ws") else { return }
        var request = URLRequest(url: wsUrl)
        request.timeoutInterval = 30.0

        let task = urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        let now = Int(Date().timeIntervalSince1970)

        // Handshake 1: Autenticação com o token do widget
        let authMsg = LivePixClientMessage(event: LivePixEvent(type: 1, event: "auth", payload: token, time: now))
        sendJson(authMsg)

        // Handshake 2: Inscrição nos tópicos
        for topic in topics {
            let subMsg = LivePixClientMessage(event: LivePixEvent(type: 1, event: "subscribe", payload: topic, time: now))
            sendJson(subMsg)
        }

        listen()
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isRunning else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingText(text)
                    }
                @unknown default:
                    break
                }
                self.listen()

            case .failure:
                DispatchQueue.main.async {
                    self.delegate?.livePixStatusChanged(connected: false)
                }
                self.scheduleReconnect()
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // Sucesso de autenticação
        if text.contains("\"event\":\"auth:success\"") {
            DispatchQueue.main.async {
                self.delegate?.livePixStatusChanged(connected: true)
            }
            return
        }

        // Heartbeat: Ping -> Pong
        if text.contains("\"event\":\"ping\"") {
            if let pingMsg = try? JSONDecoder().decode(LivePixClientMessage<Int>.self, from: data) {
                let now = Int(Date().timeIntervalSince1970)
                let pongMsg = LivePixClientMessage(event: LivePixEvent(type: 1, event: "pong", payload: pingMsg.message.payload, time: now))
                sendJson(pongMsg)
            }
            return
        }

        // Notificação de Alerta: notification:show
        if text.contains("\"event\":\"notification:show\"") {
            guard let notif = try? JSONDecoder().decode(LivePixClientMessage<LivePixNotificationPayload>.self, from: data) else {
                return
            }

            let payload = notif.message.payload
            let alertId = payload.alertId

            // Confirmação para o servidor LivePix não reenviar
            if let messageId = notif.id {
                let now = Int(Date().timeIntervalSince1970)
                let confMsg = LivePixClientMessage(event: LivePixEvent(type: 1, event: "confirmation", payload: messageId, time: now))
                sendJson(confMsg)
            }

            // Deduplicação
            guard recordSeen(alertId) else { return }

            let details = payload.data?.data
            let config = payload.data?.config

            let donation = LivePixDonation(
                id: alertId,
                author: details?.author ?? "Anônimo",
                message: details?.message ?? "",
                formattedAmount: details?.amount?.formatted ?? "Pix",
                value: details?.amount?.value ?? 0.0,
                audioUrl: config?.audioUrl.flatMap(URL.init),
                ttsUrl: config?.textToSpeechUrl.flatMap(URL.init),
                color: payload.data?.parameters?.color ?? "#ff6600",
                createdAt: Date()
            )

            // 1. Toca os áudios originais (sino + voz IA)
            if let config {
                playAlertAudio(config: config)
            }

            // 2. Notifica o Moblin para atualizar UI / chat
            DispatchQueue.main.async {
                self.delegate?.livePixDidReceiveDonation(donation)
            }
        }
    }

    /// Toca o áudio de efeito sonoro seguido da voz de IA pré-sintetizada pelo LivePix
    private func playAlertAudio(config: LivePixAlertConfig) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let soundDelay = config.audioDuration ?? 2.0

            if let audioUrl = config.audioUrl.flatMap(URL.init), config.audioEnabled != false {
                self.audioPlayer = AVPlayer(url: audioUrl)
                self.audioPlayer?.volume = Float((config.audioVolume ?? 100.0) / 100.0)
                self.audioPlayer?.play()
            }

            if let ttsUrl = config.textToSpeechUrl.flatMap(URL.init), config.textToSpeechEnabled != false {
                DispatchQueue.main.asyncAfter(deadline: .now() + soundDelay) { [weak self] in
                    guard let self else { return }
                    self.ttsPlayer = AVPlayer(url: ttsUrl)
                    self.ttsPlayer?.volume = Float((config.textToSpeechVolume ?? 100.0) / 100.0)
                    self.ttsPlayer?.play()
                }
            }
        }
    }

    private func recordSeen(_ id: String) -> Bool {
        if seenAlertIds.contains(id) { return false }
        seenAlertIds.insert(id)
        seenAlertOrder.append(id)
        if seenAlertOrder.count > maxSeenIds {
            let removed = seenAlertOrder.removeFirst()
            seenAlertIds.remove(removed)
        }
        return true
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 1.5, maxReconnectDelay)
            if isRunning {
                await connect()
            }
        }
    }

    private func sendJson<T: Codable>(_ obj: T) {
        guard let data = try? JSONEncoder().encode(obj),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { _ in }
    }
}
