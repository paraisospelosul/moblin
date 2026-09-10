import Foundation

class SettingsLivePix: Codable, ObservableObject {
    @Published var enabled: Bool = false
    @Published var widgetUrl: String = ""

    init() {}

    enum CodingKeys: CodingKey {
        case enabled
        case widgetUrl
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(.enabled, enabled)
        try container.encode(.widgetUrl, widgetUrl)
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.decode(.enabled, Bool.self, false)
        widgetUrl = container.decode(.widgetUrl, String.self, "")
    }

    func clone() -> SettingsLivePix {
        let new = SettingsLivePix()
        new.enabled = enabled
        new.widgetUrl = widgetUrl
        return new
    }
}
