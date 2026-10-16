import SwiftUI
import FrontbotCore

struct BrandsView: View {
    @Bindable var model: AppModel
    @State private var showingNew = false

    var body: some View {
        List {
            Section {
                Button { model.section = .chat } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .buttonStyle(.plain).bold(model.section == .chat)
                Button { model.section = .calendar } label: { Label("Calendario", systemImage: "calendar") }
                    .buttonStyle(.plain).bold(model.section == .calendar)
                Button { model.section = .tasks } label: { Label("Tareas", systemImage: "checklist") }
                    .buttonStyle(.plain).bold(model.section == .tasks)
                Button { model.section = .ideas } label: { Label("Ideas", systemImage: "lightbulb") }
                    .buttonStyle(.plain).bold(model.section == .ideas)
            }
            Section("Marcas") {
                ForEach(model.brands) { brand in
                    Button { model.select(brandId: brand.id) } label: {
                        VStack(alignment: .leading) {
                            Text(brand.name).bold(model.section == .brand(brand.id))
                            Text(brand.networks.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .toolbar { Button("Nueva marca", systemImage: "plus") { showingNew = true } }
        .sheet(isPresented: $showingNew) { NewBrandSheet(model: model) }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

struct NewBrandSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var industry = ""
    @State private var instagram = true
    @State private var linkedin = false

    var body: some View {
        Form {
            TextField("Nombre", text: $name)
            TextField("Rubro", text: $industry)
            Toggle("Instagram", isOn: $instagram)
            Toggle("LinkedIn", isOn: $linkedin)
            // La alerta de la ventana no se ve mientras hay una hoja abierta: el error va aquí.
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Crear") {
                    model.errorMessage = nil
                    let networks = [instagram ? Network.instagram : nil, linkedin ? Network.linkedin : nil].compactMap { $0 }
                    model.createBrand(name: name, industry: industry, networks: networks)
                    if model.errorMessage == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!instagram && !linkedin)
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }
}
