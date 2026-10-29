import SwiftUI
import FrontbotCore

/// Tarjeta de una propuesta de trade (en el chat y en Trades).
struct ProposalCard: View {
    let model: AppModel
    let proposal: TradeProposal

    private var sideColor: Color { proposal.side == .long ? Theme.approved : Theme.danger }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(proposal.side == .long ? "LONG" : "SHORT").font(.system(size: 11, weight: .bold)).foregroundStyle(sideColor)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(sideColor.opacity(0.14)))
                Text(proposal.coin).font(.system(size: 15, weight: .semibold))
                Text("\(proposal.leverage)x").font(Theme.mono()).foregroundStyle(Theme.muted)
                NetworkBadge(network: proposal.network)
                if proposal.auto { Text("auto").font(Theme.mono(10)).foregroundStyle(Theme.inFlight) }
                Spacer()
                TradeStatusPill(status: proposal.status)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    field("Tamaño", "\(Int(proposal.sizeUsd)) USD")
                    field("Entrada", proposal.entryType == .market ? String(localized: "mercado (~\(fmt(proposal.referencePrice)))") : fmt(proposal.entryPrice ?? 0))
                    field("Stop loss", fmt(proposal.stopLoss), color: Theme.danger)
                    field("Take profit", proposal.takeProfit.map(fmt) ?? "—", color: Theme.approved)
                    field("Riesgo", String(format: "%.2f USD", proposal.riskUsd))
                }
            }
            Text(proposal.rationale).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).lineLimit(8).textSelection(.enabled)
            if let error = proposal.error {
                Text(error).font(.system(size: 12)).foregroundStyle(proposal.status == .open ? Theme.muted : Theme.danger)
            }
            if let filled = proposal.filledSize, let avg = proposal.avgPrice {
                Text("Ejecutado: \(filled) \(proposal.coin) a \(avg)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            actions
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 12, fill: proposal.network == .mainnet ? Theme.danger.opacity(0.05) : Theme.surface)
    }

    @ViewBuilder
    private var actions: some View {
        let busy = model.busyProposalId == proposal.id
        switch proposal.status {
        case .proposed:
            HStack {
                Text("Nada se envía sin tu aprobación. La app vuelve a validar con el precio actual.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Rechazar") { model.rejectProposal(proposal) }.buttonStyle(OutlineButtonStyle()).disabled(busy)
                Button(busy ? String(localized: "Enviando…") : String(localized: "Aprobar y enviar")) { model.approveProposal(proposal) }
                    .buttonStyle(AccentButtonStyle()).disabled(model.busyProposalId != nil)
            }
        case .open:
            HStack {
                Spacer()
                Button(busy ? String(localized: "Cerrando…") : String(localized: "Cerrar posición")) { model.closeTrade(proposal) }
                    .buttonStyle(OutlineButtonStyle(prominent: true)).foregroundStyle(Theme.danger).disabled(model.busyProposalId != nil)
            }
        default:
            EmptyView()
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).textCase(.uppercase).font(.system(size: 9)).tracking(0.5).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(12)).foregroundStyle(color)
        }
    }

    private func fmt(_ value: Double) -> String { value.formatted(.number.precision(.significantDigits(1...6))) }
}

struct NetworkBadge: View {
    let network: TradeNetwork
    var body: some View {
        let mainnet = network == .mainnet
        Text(mainnet ? "MAINNET" : "TESTNET").font(.system(size: 9, weight: .bold)).tracking(0.5)
            .foregroundStyle(mainnet ? Theme.danger : Theme.muted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(mainnet ? Theme.danger : Theme.borderStrong))
    }
}

struct TradeStatusPill: View {
    let status: TradeStatus
    var body: some View {
        let (label, color): (LocalizedStringKey, Color) = switch status {
        case .proposed: ("Por aprobar", Theme.draft)
        case .rejected: ("Rechazada por el mandato", Theme.danger)
        case .sending: ("Enviando", Theme.inFlight)
        case .open: ("Abierta", Theme.approved)
        case .failed: ("Falló", Theme.danger)
        case .closed: ("Cerrada", Theme.published)
        case .cancelled: ("Descartada", Theme.muted)
        }
        Text(label).font(.system(size: 11)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Propuestas, posiciones abiertas e historial de todos los agentes con trading.
struct TradesView: View {
    @Bindable var model: AppModel
    @State private var tab = 0
    @State private var overviews: [String: (JSONValue?, String?)] = [:]
    @State private var confirmingPause = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Trades").font(.system(size: 17, weight: .semibold))
                Picker("", selection: $tab) {
                    Text("Propuestas (\(model.pendingProposals.count))").tag(0)
                    Text("Abiertas").tag(1)
                    Text("Historial").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                Spacer()
                Button { confirmingPause = true } label: { Label("Pausar trading", systemImage: "pause.octagon") }
                    .buttonStyle(OutlineButtonStyle(prominent: true)).foregroundStyle(Theme.danger)
                    .help("Pausa el trading de todos los agentes (también el modo automático)")
            }
            .padding(.horizontal, 20).frame(height: 56)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case 0: list(model.pendingProposals, empty: "No hay propuestas pendientes. Pídele a tu agente de trading que analice el mercado.")
                    case 1: open
                    default: list(model.proposals.filter { $0.status != .proposed }, empty: "Aún no hay historial.")
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .confirmationDialog("¿Pausar el trading de todos los agentes?", isPresented: $confirmingPause) {
            Button("Pausar todo", role: .destructive) { model.pauseAllTrading() }
        } message: {
            Text("Ningún agente podrá enviar órdenes, ni con aprobación ni en automático, hasta que lo reactives en su página. Las posiciones abiertas no se cierran.")
        }
        .task(id: tab) { if tab == 1 { await loadOverviews() } }
    }

    private func list(_ items: [TradeProposal], empty: LocalizedStringKey) -> some View {
        Group {
            if items.isEmpty { Text(empty).foregroundStyle(Theme.muted) }
            ForEach(items) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let agent = model.agent(id: p.agentId) { AgentAvatar(agent: agent, size: 14); Text(agent.name).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                        Text(p.createdAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                    ProposalCard(model: model, proposal: p)
                }
            }
        }
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 16) {
            let tracked = model.proposals.filter { $0.status == .open }
            if !tracked.isEmpty {
                SectionLabel("Trades de Frontbot")
                ForEach(tracked) { ProposalCard(model: model, proposal: $0) }
            }
            ForEach(model.agents.filter(\.trading)) { agent in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, size: 18)
                        Text("Cuenta de \(agent.name)").font(.system(size: 13, weight: .semibold))
                        NetworkBadge(network: model.mandate(agentId: agent.id).network)
                        Spacer()
                        Button("Actualizar") { Task { await loadOverviews() } }.buttonStyle(OutlineButtonStyle())
                    }
                    accountBox(overviews[agent.id])
                }
                .padding(14).panel(radius: 12)
            }
        }
    }

    @ViewBuilder
    private func accountBox(_ data: (JSONValue?, String?)?) -> some View {
        if let error = data?.1 {
            Text(error).font(.system(size: 12)).foregroundStyle(Theme.muted)
        } else if let o = data?.0 {
            Text("Valor de la cuenta: \(String(format: "%.2f", o["account_value"]?.doubleValue ?? 0)) USD · disponible \(String(format: "%.2f", o["withdrawable"]?.doubleValue ?? 0)) USD")
                .font(Theme.mono(12))
            let positions = o["positions"]?.arrayValue ?? []
            if positions.isEmpty { Text("Sin posiciones abiertas.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            ForEach(Array(positions.enumerated()), id: \.offset) { _, p in
                let size = p["size"]?.doubleValue ?? 0
                let pnl = p["unrealized_pnl"]?.doubleValue ?? 0
                HStack(spacing: 14) {
                    Text(size >= 0 ? "LONG" : "SHORT").font(.system(size: 10, weight: .bold)).foregroundStyle(size >= 0 ? Theme.approved : Theme.danger)
                    Text(p["coin"]?.stringValue ?? "").font(.system(size: 13, weight: .semibold))
                    Text("\(abs(size).formatted()) @ \(p["entry_price"]?.doubleValue?.formatted() ?? "—")").font(Theme.mono(11))
                    Text("liq. \(p["liquidation_price"]?.doubleValue?.formatted() ?? "—")").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(String(format: "%+.2f USD", pnl)).font(Theme.mono(12)).foregroundStyle(pnl >= 0 ? Theme.approved : Theme.danger)
                }
            }
            let orders = o["orders"]?.arrayValue ?? []
            if !orders.isEmpty {
                let summary = orders.map { "\($0["coin"]?.stringValue ?? "") \($0["type"]?.stringValue ?? "") \($0["trigger_price"]?.doubleValue?.formatted() ?? $0["limit_price"]?.doubleValue?.formatted() ?? "")" }.joined(separator: " · ")
                Text("Órdenes abiertas: \(summary)")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func loadOverviews() async {
        for agent in model.agents where agent.trading {
            overviews[agent.id] = await model.accountOverview(agentId: agent.id)
        }
    }
}

/// Conexión con Hyperliquid y mandato de un agente (en su página).
struct TradingSettings: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var mandate: TradingMandate
    @State private var key = ""
    @State private var coins: String
    @State private var confirmText = ""
    @State private var pendingChange: PendingChange?

    enum PendingChange: Identifiable { case mainnet, autoMainnet; var id: Int { self == .mainnet ? 0 : 1 } }

    init(model: AppModel, agent: Agent) {
        self.model = model
        self.agent = agent
        let m = model.mandate(agentId: agent.id)
        _mandate = State(initialValue: m)
        _coins = State(initialValue: m.coins.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Trading en Hyperliquid").font(.system(size: 14, weight: .semibold))
                NetworkBadge(network: mandate.network)
                if mandate.paused { Text("PAUSADO").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger) }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Conexión")
                Text("Crea una API wallet en Hyperliquid (More → API, con tu wallet principal conectada) y pega aquí su clave privada. Una API wallet puede operar pero no retirar ni transferir fondos. Nunca pegues la frase semilla ni la clave de tu wallet principal.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                labeled("Dirección de tu wallet principal (0x…)") {
                    TextField("0x…", text: Binding(get: { mandate.address ?? "" }, set: { mandate.address = $0.trimmingCharacters(in: .whitespaces) }))
                        .font(Theme.mono(12))
                }
                HStack(spacing: 8) {
                    labeled("Clave privada de la API wallet (\(mandate.network.rawValue))") {
                        SecureField(model.hasTradingKey(agentId: agent.id, network: mandate.network) ? String(localized: "•••• guardada en el llavero") : "0x…", text: $key)
                            .font(Theme.mono(12))
                    }
                    Button("Guardar clave") {
                        if model.saveTradingKey(agentId: agent.id, network: mandate.network, key: key) { key = "" }
                    }
                    .buttonStyle(OutlineButtonStyle(prominent: true)).disabled(key.isEmpty).padding(.top, 18)
                    if model.hasTradingKey(agentId: agent.id, network: mandate.network) {
                        Button("Quitar") { model.removeTradingKey(agentId: agent.id, network: mandate.network) }
                            .buttonStyle(OutlineButtonStyle()).padding(.top, 18)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Mandato")
                HStack(spacing: 16) {
                    Picker("Red", selection: Binding(get: { mandate.network }, set: { new in
                        if new == .mainnet { pendingChange = .mainnet } else { mandate.network = .testnet }
                    })) {
                        Text("Testnet").tag(TradeNetwork.testnet)
                        Text("Mainnet").tag(TradeNetwork.mainnet)
                    }
                    .pickerStyle(.segmented).frame(width: 200)
                    Picker("Modo", selection: Binding(get: { mandate.mode }, set: { new in
                        if new == .auto && mandate.network == .mainnet { pendingChange = .autoMainnet } else { mandate.mode = new }
                    })) {
                        Text("Aprobación").tag(TradeMode.approval)
                        Text("Automático").tag(TradeMode.auto)
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                    Toggle("Pausado", isOn: $mandate.paused).toggleStyle(.checkbox)
                }
                HStack(spacing: 12) {
                    labeled("Riesgo máx. por trade (%)") { TextField("1", value: $mandate.maxRiskPct, format: .number) }.frame(width: 170)
                    labeled("Apalancamiento máx.") { TextField("3", value: $mandate.maxLeverage, format: .number) }.frame(width: 140)
                    labeled("Trades por día") { TextField("3", value: $mandate.maxTradesPerDay, format: .number) }.frame(width: 120)
                    labeled("Monedas") { TextField("BTC, ETH", text: $coins) }
                }
                (mandate.mode == .auto
                     ? Text("Automático: la app envía sola las propuestas que cumplan todo el mandato, con stop loss siempre. Lo demás espera tu aprobación.")
                     : Text("Aprobación: cada trade espera tu clic en «Aprobar y enviar»."))
                    .font(.system(size: 12)).foregroundStyle(mandate.mode == .auto ? Theme.draft : Theme.muted)
                HStack {
                    if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                    Spacer()
                    Button("Guardar mandato") {
                        mandate.coins = coins.split(separator: ",").map { String($0) }
                        model.saveMandate(mandate)
                        mandate = model.mandate(agentId: agent.id)
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 12, fill: mandate.network == .mainnet ? Theme.danger.opacity(0.04) : Theme.surface)
        .sheet(item: $pendingChange) { change in confirmSheet(change) }
    }

    private func confirmSheet(_ change: PendingChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            (change == .mainnet ? Text("Operar con dinero real") : Text("Modo automático con dinero real")).font(.system(size: 16, weight: .semibold))
            (change == .mainnet
                 ? Text("En mainnet las órdenes usan fondos reales de tu cuenta de Hyperliquid. Escribe MAINNET para confirmar.")
                 : Text("La app enviará sin preguntarte las propuestas que cumplan el mandato, con dinero real. Escribe MAINNET para confirmar."))
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            TextField("MAINNET", text: $confirmText).font(Theme.mono(13)).textFieldStyle(.plain)
                .padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            HStack {
                Spacer()
                Button("Cancelar") { confirmText = ""; pendingChange = nil }.buttonStyle(OutlineButtonStyle())
                Button("Confirmar") {
                    if change == .mainnet { mandate.network = .mainnet; mandate.mode = .approval } else { mandate.mode = .auto }
                    confirmText = ""
                    pendingChange = nil
                }
                .buttonStyle(AccentButtonStyle()).disabled(confirmText != "MAINNET")
            }
        }
        .padding(22).frame(width: 440).background(Theme.sidebar)
    }

    private func labeled(_ label: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            content().textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 30).panel(radius: 7, fill: Theme.raised)
        }
    }
}
