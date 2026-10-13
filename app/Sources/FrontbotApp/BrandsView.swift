import SwiftUI
import FrontbotCore

struct BrandsView: View {
    @Bindable var model: AppModel
    @State private var showingNew = false

    var body: some View {
        List(selection: $model.selectedBrandId) {
            Section("Marcas") {
                ForEach(model.brands) { brand in
                    VStack(alignment: .leading) {
                        Text(brand.name)
                        Text(brand.networks.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(brand.id)
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
    }
}
