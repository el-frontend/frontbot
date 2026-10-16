import SwiftUI
import FrontbotCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            BrandsView(model: model)
        } detail: {
            switch model.section {
            case .brand(let id):
                // .id: cada marca tiene su propio estado (si no, el editor de guía de una marca se queda abierto en otra).
                if let brand = model.brand(id: id) { BrandDetailView(model: model, brand: brand).id(brand.id) }
            case .calendar:
                CalendarView(model: model)
            case .chat:
                ChatView(model: model)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .alert("Frontbot", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
