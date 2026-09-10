import SwiftUI

struct LivePixSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var livePix: SettingsLivePix

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: Binding(
                    get: { livePix.enabled },
                    set: { value in
                        livePix.enabled = value
                        model.reloadLivePix()
                    }
                ))
            }
            Section {
                TextEditNavigationView(
                    title: String(localized: "Widget URL or ID"),
                    value: livePix.widgetUrl,
                    onSubmit: { value in
                        livePix.widgetUrl = value
                        model.reloadLivePix()
                    }
                )
            } footer: {
                Text("Paste your LivePix alert widget URL (e.g. https://widget.livepix.gg/embed/...) or widget ID.")
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Como substituir seus 3 widgets web atuais:", systemImage: "lightbulb.fill")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("1. **Mensagens e Voz (TTS):** Já integrado nativamente! Pode remover o Browser Widget do LivePix de alertas. O áudio com a voz de IA original do LivePix tocará sem gastar bateria.")
                        .font(.footnote)

                    Text("2. **QR Code Pix:** Adicione um widget nativo de QR Code do Moblin com `https://livepix.gg/seu_usuario`. O Moblin renderiza em Metal nativo sem navegador web.")
                        .font(.footnote)

                    Text("3. **Metas / Ranking:** Use os widgets nativos de Texto/Ticker do Moblin para manter o iPhone frio.")
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Dica de Desempenho e Bateria")
            }
        }
        .navigationTitle("LivePix")
    }
}
