import SwiftUI

struct WidgetLivePixAlertSettingsView: View {
    let model: Model
    let widget: SettingsWidget
    @ObservedObject var alert: SettingsWidgetLivePixAlert

    var body: some View {
        Section {
            HStack {
                Text("Duration")
                Spacer()
                Text("\(Int(alert.duration))s")
                    .foregroundColor(.gray)
            }
            Slider(value: $alert.duration, in: 3...30, step: 1) {
                Text("Duration")
            }
        } header: {
            Text("General")
        } footer: {
            Text("How long the donation alert card stays visible on screen.")
        }
        Section {
            Button("Test alert on screen") {
                model.testLivePixAlert()
            }
        }
        WidgetEffectsView(model: model, widget: widget)
    }
}
