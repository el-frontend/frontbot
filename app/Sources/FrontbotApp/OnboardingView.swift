import SwiftUI
import FrontbotCore

/// Bienvenida de una instalación nueva: conectar Claude, crear la primera marca y lanzar el primer pedido.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = Step.claude
    @State private var key = ""
    @State private var name = ""
    @State private var industry = ""
    @State private var website = ""
    @State private var instagram = true
    @State private var linkedin = false
    @State private var brandName: String?
    @State private var brandWebsite: String?

    private enum Step: Int, CaseIterable { case claude, brand, start }

    var body: some View {
        ZStack {
            Theme.background.opacity(0.97).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                progress
                switch step {
                case .claude: claudeStep
                case .brand: brandStep
                case .start: startStep
                }
            }
            .padding(32)
            .frame(width: 520, alignment: .leading)
            .panel(radius: 16, fill: Theme.sidebar)
        }
        .foregroundStyle(Theme.text)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? Theme.accent : Theme.border).frame(height: 3)
            }
        }
    }

    // MARK: Pasos

    private var claudeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Bienvenido a Frontbot", "Un equipo de agentes que escribe tus posts, investiga temas y te ayuda con tus tareas. Primero, conéctalo a Claude.")
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("API key de Anthropic")
                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 34)
                    .panel(radius: 8, fill: Theme.raised)
                    .onSubmit(saveKey)
                HStack(spacing: 4) {
                    Text("¿No tienes una?").foregroundStyle(Theme.muted)
                    Link("Créala en la consola de Anthropic", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .foregroundStyle(Theme.inFlight)
                }
                .font(.system(size: 12))
                Text("Se guarda en tu llavero y se cobra por uso en tu cuenta de Anthropic.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            HStack {
                Button("Ya uso Claude Code en este Mac") { step = .brand }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .help("Frontbot usará tu sesión de Claude Code en lugar de una API key")
                Spacer()
                Button("Continuar", action: saveKey)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var brandStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Tu primera marca", "Para quién escribe Frontbot. Si tiene web, la leerá para aprender su tono y de qué habla.")
            field("Nombre", "Café Sol", $name)
            field("Rubro", "Cafetería de especialidad", $industry)
            field("Web (opcional)", "https://cafesol.com", $website)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Redes")
                HStack(spacing: 16) {
                    Toggle("Instagram", isOn: $instagram).toggleStyle(.checkbox)
                    Toggle("LinkedIn", isOn: $linkedin).toggleStyle(.checkbox)
                }
            }
            HStack {
                Button("Saltar por ahora") { model.errorMessage = nil; step = .start }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Crear marca", action: createBrand)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!instagram && !linkedin))
            }
        }
    }

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("¿Por dónde empezamos?", "Elige un primer pedido o escribe el tuyo en el chat. Todo lo que el agente crea queda en borrador hasta que lo apruebes.")
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button { model.finishOnboarding(prompt: prompt) } label: {
                        HStack(spacing: 10) {
                            Text(prompt).font(.system(size: 13)).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel(radius: 10, fill: Theme.raised)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Ir al chat") { model.finishOnboarding() }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Con marca, los pedidos hablan de ella; con web, el primero es aprender de ella.
    private var suggestions: [String] {
        guard let brandName else {
            return ["Investiga las tendencias de esta semana en mi sector y resúmelas",
                    "Recuérdame cada lunes a las 9 revisar mis pendientes",
                    "Busca 3 oportunidades de negocio en mi ciudad"]
        }
        var list: [String] = []
        if let brandWebsite { list.append("Lee \(brandWebsite) y escribe la guía de marca de \(brandName)") }
        list.append("Propón 3 posts para \(brandName) para esta semana")
        list.append("Investiga qué publica la competencia de \(brandName) y qué podemos hacer distinto")
        return list
    }

    // MARK: Acciones

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.errorMessage = nil
        if model.saveApiKey(key) { key = ""; step = .brand }
    }

    private func createBrand() {
        model.errorMessage = nil
        let networks = [instagram ? Network.instagram : nil, linkedin ? Network.linkedin : nil].compactMap { $0 }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.createBrand(name: trimmed, industry: industry.trimmingCharacters(in: .whitespacesAndNewlines), networks: networks)
        guard model.errorMessage == nil else { return }
        brandName = trimmed
        let web = website.trimmingCharacters(in: .whitespacesAndNewlines)
        brandWebsite = web.isEmpty ? nil : web
        step = .start
    }

    // MARK: Piezas

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 22, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            TextField(placeholder, text: text).textFieldStyle(.plain)
                .padding(.horizontal, 10).frame(height: 34).panel(radius: 8, fill: Theme.raised)
        }
    }
}
