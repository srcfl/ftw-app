#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import Charts

struct DistributionHeading: View {
    let title: String
    var subtitle = ""
    @Environment(DistributionModel.self) private var model
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.largeTitle.weight(.medium))
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(DistributionStyle.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            DistributionRobot(happy: model.happy, frozen: model.frozen).frame(width: 88)
        }.padding(24)
    }
}

struct DistributionPlan: View {
    @Environment(DistributionModel.self) private var model
    private var stopped: Bool { model.mode == "Stoppa batterierna" }
    private var manual: Bool { !model.mode.contains("arbitrage") }
    private var times: [String] { model.lastSource == .night ? ["00.00", "02.00", "06.00", "10.00"] : ["14.00", "18.00", "22.00", "02.00"] }
    private var headlines: [String] {
        if stopped { return Array(repeating: "Batterierna står stilla", count: 4) }
        if model.mode == "Ladda" { return Array(repeating: "Batterierna laddas", count: 4) }
        if manual { return Array(repeating: "Följer hemmets behov", count: 4) }
        return model.lastSource == .night ? ["Batteriet hjälper hemmet", "Ladda under billigare timmar", "Batteriet behåller sin reserv", "Solen kan ladda batteriet"] : ["Solen laddar bilen", "Batteriet hjälper hemmet", "Batteriet behåller sin reserv", "Ladda under billigare timmar"]
    }
    private var powers: [Double] {
        if stopped || (manual && model.mode != "Ladda") { return [0, 0, 0, 0] }
        if model.mode == "Ladda" { return [3, 3, 3, 3] }
        return model.lastSource == .night ? [-1, 3, 0, 2] : [0, -2, 0, 3]
    }
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            DistributionHeading(title: stopped ? "Batterierna står stilla." : manual ? model.mode + "." : "Energin följer din plan.", subtitle: "Prognos · boxen anpassar sig när läget ändras.")
                .background(LinearGradient(colors: [DistributionStyle.gold.opacity(0.45), DistributionStyle.cyan.opacity(0.35), DistributionStyle.ground], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 20) {
                Button { model.sheet = .mode } label: { HStack { Text(model.mode); Spacer(); Image(systemName: "slider.horizontal.3") } }
                    .disabled(!model.canControl || model.sending).accessibilityIdentifier("distribution.mode")
                Chart(Array(powers.enumerated()), id: \.offset) { point in
                    AreaMark(x: .value("Tid", point.offset), y: .value("Batterikraft", point.element))
                        .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.cyan.opacity(0.65).gradient)
                    RuleMark(y: .value("Vilar", 0)).foregroundStyle(DistributionStyle.line)
                }
                .chartYScale(domain: -3...4)
                .chartXAxis { AxisMarks(values: [0, 1, 2, 3]) { axis in AxisValueLabel { if let i = axis.as(Int.self) { Text(times[i]) } } } }
                .chartYAxis { AxisMarks(values: [-2, 0, 3]) { axis in AxisValueLabel { if let n = axis.as(Int.self) { Text(n == 0 ? "0" : "\(abs(n)) kW \(n > 0 ? "in" : "ut")") } } } }
                .frame(height: 195)
                .accessibilityLabel("Planerad batterikraft")
                let i = min(3, max(0, Int(model.moment.rounded())))
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(times[i]) · \(headlines[i])").font(.title3.weight(.medium)).contentTransition(.numericText())
                    Text(powers[i] == 0 ? "Batteriet vilar · 0 kW" : "\(DistributionStyle.number(abs(powers[i]))) kW \(powers[i] > 0 ? "till batteriet" : "från batteriet")").font(.subheadline).foregroundStyle(DistributionStyle.muted)
                }.frame(minHeight: 70, alignment: .topLeading)
                Slider(value: $model.moment, in: 0...3, step: 1).tint(DistributionStyle.purpleDeep).accessibilityLabel("Tid i planen")
                    .onChange(of: model.moment) { _, value in withAnimation(DistributionStyle.motion) { model.gaze = value / 3 - 0.5 } }
                NavigationLink("Elpriset bakom planen", value: DistributionScreen.prices)
                Divider()
                LabeledContent("\(times[1])", value: headlines[1])
                Button { model.sheet = .goal } label: {
                    LabeledContent("Bilen till \(model.clock)", value: model.goal > 0 ? "\(model.goal) %" : "Inget mål")
                }.disabled(!model.canControl || model.sending)
                Text("Planen är ett exempel, inte ett löfte om framtida mätvärden.").font(.caption).foregroundStyle(DistributionStyle.muted)
            }.padding(24)
        }
    }
}

struct DistributionPrices: View {
    @Environment(DistributionModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            DistributionHero(title: "Spotpris · SE3", value: model.tomorrow ? "—" : "\(model.prices[model.priceHour])", unit: "öre/kWh", detail: model.tomorrow ? "Priserna har inte publicerats än." : String(format: "%02d.00–%02d.00", model.priceHour, model.priceHour + 1), color: DistributionStyle.gold.opacity(0.55), ink: DistributionStyle.ink)
            VStack(alignment: .leading, spacing: 20) {
                Picker("Prisdag", selection: $model.tomorrow) { Text("I dag").tag(false); Text("I morgon").tag(true) }.pickerStyle(.segmented)
                if model.tomorrow {
                    ContentUnavailableView("Inte publicerat än", systemImage: "clock", description: Text("Dagens priser finns kvar. Morgondagens visas när de har kommit till boxen."))
                } else {
                    Chart(Array(model.prices.enumerated()), id: \.offset) { item in
                        BarMark(x: .value("Timme", item.offset), y: .value("Pris", item.element))
                            .cornerRadius(5).foregroundStyle(item.offset == model.priceHour ? DistributionStyle.ink : DistributionStyle.gold)
                    }.frame(height: 180).chartXScale(domain: -0.5...23.5).chartYAxisLabel("öre/kWh")
                        .chartXSelection(value: Binding(get: { Optional(model.priceHour) }, set: { if let value = $0 { model.priceHour = max(0, min(23, value)) } }))
                    Slider(value: Binding(get: { Double(model.priceHour) }, set: { model.priceHour = Int($0) }), in: 0...23, step: 1)
                        .accessibilityLabel("Välj pristimme")
                    LabeledContent("Billigaste två timmar", value: "01–03")
                    LabeledContent("Snitt under de timmarna", value: "18 öre/kWh")
                }
                Text("Exempelpriser. Spotpris utan moms, elnätsavgift och påslag.").font(.caption).foregroundStyle(DistributionStyle.muted)
            }.padding(24)
        }
    }
}

struct DistributionHistory: View {
    @Environment(DistributionModel.self) private var model
    let names = ["Från solen", "Använt hemma", "Köpt", "Sålt"]
    private var amounts: [Double] { [18.6, 15.2, 2.4, 5.8].map { $0 * [1.0, 6.7, 29.4, 340][model.historyRange] } }
    private var seriesColors: [Color] { [DistributionStyle.gold, DistributionStyle.home, DistributionStyle.cyan, DistributionStyle.green] }
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            DistributionHeading(title: "Över tid.")
            VStack(alignment: .leading, spacing: 20) {
                Picker("Historik", selection: $model.historyPower) { Text("Energi · kWh").tag(false); Text("Effekt · kW").tag(true) }.pickerStyle(.segmented)
                    .onChange(of: model.historyPower) { _, power in if !power && model.historyRange == 3 { model.historyRange = 2 } }
                Picker("Period", selection: $model.historyRange) {
                    Text(model.historyPower ? "24 h" : "I dag").tag(0); Text("7 dagar").tag(1); Text("30 dagar").tag(2)
                    if model.historyPower { Text("1 år").tag(3) }
                }.pickerStyle(.segmented)
                if model.historyPower { powerChart } else { energy }
            }.padding(.horizontal, 24)
        }
    }
    private var energy: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 4) {
                energyHalf(top: 0, bottom: 2, share: amounts[0] / (amounts[0] + amounts[2]), heading: "Varifrån")
                energyHalf(top: 1, bottom: 3, share: amounts[1] / (amounts[1] + amounts[3]), heading: "Vart")
            }
            Text(model.historyRange == 0 ? "I dag hittills" : "Summa för perioden · sista dagen pågår").font(.caption).foregroundStyle(DistributionStyle.muted)
            if model.historyRange == 0 {
                Divider()
                Text("\(DistributionStyle.number(amounts[model.energySeries])) kWh · \(names[model.energySeries].lowercased())").font(.title3.weight(.medium))
                Text("Båda sidor visar samma \(DistributionStyle.number(amounts[0] + amounts[2])) kWh. I det här exemplet är batteriets netto över dagen 0 kWh.").font(.caption).foregroundStyle(DistributionStyle.muted)
                Button("Se effekten över dagen") { model.historyPower = true }
            } else {
                let count = model.historyRange == 1 ? 7 : 30
                let weights = (0..<count).map { 0.8 + (1 + sin(Double($0) * 1.8)) * 0.45 }
                let sum = weights.reduce(0, +)
                Chart(Array(weights.enumerated()), id: \.offset) { item in
                    BarMark(x: .value("Dag", item.offset + 1), y: .value("Energi", item.element / sum * amounts[model.energySeries]))
                        .cornerRadius(4).foregroundStyle(seriesColors[model.energySeries])
                }.frame(height: 150).chartYAxisLabel("kWh").chartXAxisLabel("Dag i perioden")
            }
            Text("Yta = andel av energin på respektive sida.").font(.caption).foregroundStyle(DistributionStyle.muted)
        }
    }
    private func energyHalf(top: Int, bottom: Int, share: Double, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.caption).foregroundStyle(DistributionStyle.muted).padding(.leading, 10)
            GeometryReader { p in
                ZStack {
                    seriesColors[bottom]
                    EnergyHalfField(share: share).fill(seriesColors[top])
                    energyLabel(top).position(x: p.size.width / 2, y: p.size.height * share / 2)
                    energyLabel(bottom, compact: 1 - share < 0.18).position(x: p.size.width / 2, y: p.size.height * (share + (1 - share) / 2))
                }
            }.frame(height: 330)
        }
    }
    private func energyLabel(_ index: Int, compact: Bool = false) -> some View {
        let inks = [DistributionStyle.goldInk, DistributionStyle.homeInk, DistributionStyle.cyanInk, DistributionStyle.greenInk]
        return Button { model.energySeries = index } label: {
            VStack(spacing: compact ? 0 : 4) {
                Text(names[index]).font(.system(size: 11))
                Text("\(Text(DistributionStyle.number(amounts[index])).font(.system(size: compact ? 18 : 26, weight: .medium)))\(Text(" kWh").font(.system(size: 12)))")
                    .monospacedDigit().underline(model.energySeries == index)
            }.foregroundStyle(inks[index]).frame(maxWidth: .infinity, minHeight: 40)
        }.buttonStyle(.plain).accessibilityLabel("\(names[index]), \(DistributionStyle.number(amounts[index])) kilowattimmar")
    }
    private var powerChart: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.historyRange == 0 ? "Senaste 24 timmarna · exempel på timvärden" : "Glesa exempel på effekt under vald period").font(.caption).foregroundStyle(DistributionStyle.muted)
            Chart {
                ForEach(0..<24) { i in
                    let solar = max(0, 4.6 * sin(Double(i - 15) / 10 * .pi))
                    let load = 1.2 + 1.5 * (1 + sin(Double(i) * 0.5)) / 2
                    LineMark(x: .value("Tid", i), y: .value("kW", solar), series: .value("Serie", "Solen"))
                        .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.gold).lineStyle(StrokeStyle(lineWidth: 3))
                    LineMark(x: .value("Tid", i), y: .value("kW", load), series: .value("Serie", "Användning"))
                        .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.homeInk).lineStyle(StrokeStyle(lineWidth: 3))
                    LineMark(x: .value("Tid", i), y: .value("kW", load - solar), series: .value("Serie", "Elnätet"))
                        .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.greenInk).lineStyle(StrokeStyle(lineWidth: 2))
                }
                RuleMark(x: .value("Vald tid", model.historyHour)).foregroundStyle(DistributionStyle.muted)
            }.frame(height: 240).chartYAxisLabel("kW").chartXAxisLabel("Stickprov över perioden")
                .chartYAxis { AxisMarks(values: [-2, 0, 2, 4]) { axis in AxisValueLabel { if let n = axis.as(Int.self) { Text("\(abs(n))") } } } }
                .chartXSelection(value: Binding(get: { Optional(model.historyHour) }, set: { if let value = $0 { model.historyHour = max(0, min(23, value.rounded())) } }))
            Slider(value: Binding(get: { model.historyHour }, set: { model.historyHour = $0 }), in: 0...23, step: 1).accessibilityLabel("Tid i historiken")
            let solar = max(0, 4.6 * sin((model.historyHour - 15) / 10 * .pi))
            let load = 1.2 + 1.5 * (1 + sin(model.historyHour * 0.5)) / 2
            let grid = load - solar
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Solen", value: "\(DistributionStyle.number(solar)) kW")
                LabeledContent("Användning", value: "\(DistributionStyle.number(load)) kW")
                LabeledContent(grid >= 0 ? "Köper" : "Säljer", value: "\(DistributionStyle.number(abs(grid))) kW")
            }.monospacedDigit()
            Text("Solen · Användning · Elnätet").font(.caption)
            Text("Stickprov \(Int(model.historyHour) + 1) av 24. Användningen inkluderar bilen. Över noll är köpt el, under noll är såld.").font(.caption).foregroundStyle(DistributionStyle.muted)
        }
    }
}

private struct EnergyHalfField: Shape {
    let share: Double
    func path(in r: CGRect) -> Path {
        let y = r.height * share, amplitude = min(y, r.height - y) * 0.45
        return Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: r.width, y: 0))
            for i in stride(from: 40, through: 0, by: -1) {
                let u = Double(i) / 40
                p.addLine(to: CGPoint(x: r.width * u, y: y + amplitude * sin(u * 2 * .pi)))
            }
            p.closeSubpath()
        }
    }
}

struct DistributionHome: View {
    @Environment(DistributionModel.self) private var model
    let rows: [(DistributionScreen, String, String, String)] = [
        (.connection, "antenna.radiowaves.left.and.right", "Anslutning & mätvärden", "Kontakt och ålder på data"),
        (.access, "key", "Åtkomst", "Telefoner som kan se hemmet"),
        (.notifications, "bell", "Notiser", "Välj vad du vill få veta"),
        (.recovery, "checkmark.shield", "Om du tappar telefonen", "Valfri förseglad kopia"),
        (.widgets, "rectangle.grid.1x2", "Widgetar", "Förhandsvisning på hemskärmen"),
        (.about, "info.circle", "Om FTW", "App, box, källkod och licenser")
    ]
    var body: some View {
        VStack(spacing: 0) {
            DistributionHeading(title: "Ditt hem.", subtitle: "FTW Box planerar och styr lokalt. Telefonen visar vad som händer.")
                .background(DistributionStyle.green.opacity(0.3).gradient)
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { row in
                    NavigationLink(value: row.0) {
                        HStack(spacing: 15) {
                            Image(systemName: row.1).frame(width: 22).foregroundStyle(DistributionStyle.muted)
                            VStack(alignment: .leading, spacing: 5) { Text(row.2); Text(row.3).font(.caption).foregroundStyle(DistributionStyle.muted) }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 16)
                    }.buttonStyle(.plain)
                    Divider()
                }
                NavigationLink("Anslut en annan box", value: DistributionScreen.pair).padding(.vertical, 20)
                Button("Ta bort från telefonen", role: .destructive) { model.sheet = .forget }.padding(.vertical, 10)
            }.padding(.horizontal, 24)
        }
    }
}

struct DistributionSettings: View {
    let screen: DistributionScreen
    @Environment(DistributionModel.self) private var model
    @State private var confirmingMember: UUID?
    @State private var confirmingRecovery = false
    @State private var connecting = false
    @State private var testNotice = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            if screen == .pair { welcome } else {
                DistributionHeading(title: heading)
                VStack(alignment: .leading, spacing: 24) {
                    switch screen {
                    case .connection:
                        LabeledContent("Kontakt med boxen", value: model.scenario == .offline ? "Saknas" : "Ansluten")
                        LabeledContent("Boxens mätvärden", value: model.frozen ? "Sparade" : "Färska i exemplet")
                        Text(model.scenario == .offline ? "Telefonen söker kontakt automatiskt. Boxen fortsätter lokalt. Du ser sparade värden tills kontakten är tillbaka." : model.scenario == .stale ? "Telefonen har kontakt, men boxen får inga färska mätvärden. Styrningen väntar." : "Den här prototypen använder bara exempeldata och ansluter inte till en box.")
                        NavigationLink("Anslut telefonen på nytt", value: DistributionScreen.pair)
                    case .access:
                        if model.scenario == .viewer { Text("Du har läsbehörighet. Ägaren ändrar åtkomsten.") } else {
                            LabeledContent("Den här telefonen", value: "Ägare")
                            ForEach(Array(model.members.enumerated()), id: \.element) { item in
                                HStack { VStack(alignment: .leading) { Text("Telefon \(item.offset + 1)"); Text("Läsbehörighet").font(.caption).foregroundStyle(DistributionStyle.muted) }; Spacer(); Button("Ta bort", role: .destructive) { confirmingMember = item.element } }
                            }
                            NavigationLink("Bjud in en läsare", value: DistributionScreen.invite).buttonStyle(DistributionActionStyle())
                            Text("En läsare kan se mätvärden men inte ändra mål eller styra.").font(.caption).foregroundStyle(DistributionStyle.muted)
                        }
                    case .invite:
                        Image(systemName: "qrcode").resizable().scaledToFit().frame(width: 175, height: 175).overlay { Text("DEMO").font(.headline).padding(12).background(DistributionStyle.ground) }.frame(maxWidth: .infinity)
                        Text("Ogiltig demokod. I appen gäller en inbjudan en gång och har en sluttid.").font(.caption).foregroundStyle(DistributionStyle.muted)
                        if model.invited { Label("Läsare ansluten i exemplet", systemImage: "checkmark.circle") } else {
                            Button("Simulera att en läsare ansluter") { model.members.append(UUID()); model.invited = true }.buttonStyle(DistributionActionStyle())
                        }
                    case .notifications:
                        Toggle("Tillåt notiser", isOn: $model.notifications).disabled(!model.canControl)
                        if model.notifications {
                            ForEach(0..<3) { i in Toggle(["Bilen är laddad", "Om laddningen avbryts", "Boxen har uppdaterats"][i], isOn: $model.notificationRules[i]).disabled(!model.canControl) }
                            Text("Att boxen inte går att nå ingår alltid när notiser är på.").font(.caption).foregroundStyle(DistributionStyle.muted)
                            Button("Visa en testnotis") { testNotice = true }.buttonStyle(DistributionActionStyle(prominent: false))
                        }
                        Text("Demo · inställningarna ändrar bara förhandsvisningen. Inga notiser skickas.").font(.caption).foregroundStyle(DistributionStyle.muted)
                    case .recovery:
                        Text(model.recovery ? "Förseglad kopia vald i exemplet." : "Ingen kopia sparad.").font(.title3.weight(.medium))
                        Text("Sourceful kan lagra en förseglad kopia utan att kunna öppna den. Din passnyckel räcker då för att komma in på en ny telefon.")
                        Text("Det innebär också att en enhet som kan använda din passnyckel kan öppna hemmet.")
                        Button(model.recovery ? "Ta bort kopian" : "Välj förseglad kopia") { confirmingRecovery = true }.buttonStyle(DistributionActionStyle())
                        Text("Demo · ingen kopia skapas eller skickas.").font(.caption).foregroundStyle(DistributionStyle.muted)
                    case .about:
                        LabeledContent("Design", value: "Se fördelningen")
                        LabeledContent("App", value: AppInfo.version)
                        LabeledContent("Box", value: "Exempelhem")
                        LabeledContent("Tidszon", value: "Europe/Stockholm")
                        Text("En native-prototyp med exempeldata. Sourceful utvecklar och underhåller FTW.").font(.subheadline).foregroundStyle(DistributionStyle.muted)
                        NavigationLink("Källkod & licenser", value: DistributionScreen.licenses)
                    case .licenses:
                        Text("Sourceful Labs AB och bidragsgivare. Dokumenten öppnas från appens källkod på GitHub.")
                        Link("Källkod", destination: URL(string: "https://github.com/srcfl/ftw-app")!)
                        Link("Licens", destination: URL(string: "https://github.com/srcfl/ftw-app/blob/main/LICENSE")!)
                        Link("Meddelanden", destination: URL(string: "https://github.com/srcfl/ftw-app/blob/main/NOTICE")!)
                        Link("Licenser i korthet", destination: URL(string: "https://github.com/srcfl/ftw-app/blob/main/LICENSING.md")!)
                    case .widgets: widgets
                    case .scan:
                        Image(systemName: "viewfinder").font(.system(size: 90, weight: .ultraLight)).frame(maxWidth: .infinity).padding(15)
                        Text("1. Öppna boxens lokala sida på hemnätverket.\n\n2. Gå till Inställningar → FTW app.\n\n3. Visa parkopplingskoden och skanna den här.")
                        NavigationLink("Simulera skanning", value: DistributionScreen.offer).buttonStyle(DistributionActionStyle())
                        Text("Mockupen använder inte kameran.").font(.caption).foregroundStyle(DistributionStyle.muted)
                    case .offer:
                        Text("4F2A · 98C1").font(.title.monospaced()).frame(maxWidth: .infinity).padding(.vertical, 18)
                        Text("Exempel på boxens identitet. Fortsätt om du just visade koden på din egen box.")
                        Button {
                            connecting = true
                            Task { try? await Task.sleep(for: .seconds(1.2)); model.paired = true; model.tab = .now; model.startScreen = nil; connecting = false }
                        } label: { Text(connecting ? "Ansluter exempelboxen…" : "Anslut exempelboxen") }
                            .buttonStyle(DistributionActionStyle()).disabled(connecting).accessibilityIdentifier("distribution.connect")
                        if model.paired { Text("Du kan också öppna exempelhemmet från Nu.").font(.caption).foregroundStyle(DistributionStyle.muted) }
                    default: EmptyView()
                    }
                }.padding(.horizontal, 24)
            }
        }
        .confirmationDialog("Ta bort åtkomsten?", isPresented: Binding(get: { confirmingMember != nil }, set: { if !$0 { confirmingMember = nil } })) {
            Button("Ta bort", role: .destructive) { if let id = confirmingMember { Task { await model.submit(.revoke(id)) }; confirmingMember = nil } }
        } message: { Text("Telefonen kommer inte längre kunna läsa hemmet.") }
        .confirmationDialog(model.recovery ? "Ta bort kopian?" : "Välj en förseglad kopia?", isPresented: $confirmingRecovery) {
            Button(model.recovery ? "Ta bort" : "Välj kopia") { model.recovery.toggle() }
        } message: { Text("Detta ändrar bara exemplet. Inga nycklar eller data skickas.") }
        .alert("Bilen är laddad", isPresented: $testNotice) { Button("OK", role: .cancel) {} } message: { Text("Förhandsvisning av en notis.") }
    }
    private var heading: String {
        switch screen {
        case .connection: "Kontakt och mätvärden."
        case .access: "Vem kan se hemmet?"
        case .invite: "Visa koden."
        case .notifications: "Det du vill få veta."
        case .recovery: "Om du tappar telefonen."
        case .widgets: "En blick på hemmet."
        case .scan: "Anslut din FTW Box."
        case .offer: "Är det din box?"
        default: screen.title + "."
        }
    }
    private var welcome: some View {
        VStack(spacing: 24) {
            DistributionRobot(happy: model.happy).frame(width: 170).padding(.top, 35)
            Text("Se vart energin tar vägen.").font(.largeTitle.weight(.medium)).multilineTextAlignment(.center)
            Text("Sol, hem, bil och batteri. Se hur de hänger ihop och välj vad du vill ska hända.").multilineTextAlignment(.center).foregroundStyle(DistributionStyle.muted)
            NavigationLink("Anslut min box", value: DistributionScreen.scan).buttonStyle(DistributionActionStyle())
            Button("Prova exempelhemmet") { model.paired = true; model.tab = .now; model.startScreen = nil }.buttonStyle(DistributionActionStyle(prominent: false))
            Text("Din box fortsätter lokalt när telefonen är borta.").font(.caption).foregroundStyle(DistributionStyle.muted)
        }.padding(24)
    }
    private var widgets: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 15) {
                widget("Solen", "4,2 kW", "Senast 13.42")
                widget("Bilen", "\(model.level) %", "\(model.goal) % till \(model.clock)")
            }
            VStack(alignment: .leading, spacing: 15) {
                Text("Exempelhem").font(.caption)
                Text("Solen driver hemmet.").font(.title2.weight(.medium))
                Capsule().fill(DistributionStyle.purple).frame(width: 180, height: 35)
                Text("Sparat 13.42 · öppna appen för senaste läget").font(.caption)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DistributionStyle.gold.opacity(0.6), in: RoundedRectangle(cornerRadius: 25))
            Text("Förhandsvisning. Lägg till riktiga widgetar från hemskärmen. De visar sparade värden med tid.").font(.caption).foregroundStyle(DistributionStyle.muted)
        }
    }
    private func widget(_ label: String, _ number: String, _ foot: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(label).font(.caption); Text(number).font(.title2).minimumScaleFactor(0.6); Text(foot).font(.caption2).foregroundStyle(DistributionStyle.muted) }
            .padding(18).frame(maxWidth: .infinity, minHeight: 140, alignment: .leading).background(DistributionStyle.raised, in: RoundedRectangle(cornerRadius: 25))
    }
}

struct DistributionEditor: View {
    let sheet: DistributionSheet
    @Environment(DistributionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var goal = 80.0
    @State private var level = 60
    @State private var time = Date()
    @State private var days = "Vardagar"
    @State private var removeGoal = false
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                switch sheet {
                case .goal:
                    Section("Ladda till") {
                        LabeledContent("Mål", value: "\(Int(goal)) %").font(.title2)
                        Slider(value: $goal, in: 10...100, step: 5).accessibilityLabel("Laddmål")
                    }
                    Section("Klar senast") {
                        DatePicker("Tid", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel)
                            .environment(\.timeZone, TimeZone(identifier: "Europe/Stockholm")!)
                    }
                    Section("Upprepa") { Picker("Dagar", selection: $days) { ForEach(["Vardagar", "Varje dag", "Helger", "En gång"], id: \.self) { Text($0) } } }
                    if model.goal > 0 { Button("Ta bort målet", role: .destructive) { removeGoal = true } }
                    receipt
                case .level:
                    Section("Bilens nivå just nu") {
                        Text("Välj nivån bilen visar. Boxen använder den för planeringen.")
                        HStack { ForEach([20, 40, 60, 80], id: \.self) { n in Button("\(n) %") { level = n }.buttonStyle(.bordered).tint(DistributionStyle.purpleDeep) } }
                        Stepper("\(level) %", value: $level, in: 0...100, step: 5).font(.title2)
                    }
                    receipt
                case .mode:
                    ForEach(Array(model.modes.enumerated()), id: \.offset) { item in
                        Button { Task { await model.submit(.mode(item.element)) } } label: {
                            HStack { VStack(alignment: .leading, spacing: 6) { Text(item.element); Text(model.modeHelp[item.offset]).font(.caption).foregroundStyle(DistributionStyle.muted) }; Spacer(); Image(systemName: model.mode == item.element ? "checkmark.circle.fill" : "circle") }
                        }.disabled(!model.canControl || model.sending)
                    }
                    receipt
                case .demo:
                    Section("Exempelhem") {
                        Picker("Läge", selection: Binding(get: { model.scenario }, set: { value in withAnimation(reduceMotion ? nil : DistributionStyle.motion) { model.choose(value) } })) {
                            ForEach(DistributionScenario.allCases) { Text($0.title).tag($0) }
                        }
                        Button(model.playing ? "Stoppa förlopp" : "Spela förlopp") {
                            if model.playing { model.stop() } else {
                                model.choose(.sun); model.tab = .now; model.playbackGeneration += 1; model.playing = true
                            }
                            dismiss()
                        }.disabled(reduceMotion)
                        Text("Fälten visar andel av effekten. Rörelsen pausar när appen lämnar skärmen och när minskad rörelse är på.").font(.caption)
                    }
                    Section {
                        Button("Från första start") { model.stop(); model.paired = false; dismiss() }
                        Text("Detta är en separat simulering. Inga kommandon, nycklar eller mätvärden lämnar appen.").font(.caption)
                    }
                case .forget:
                    Text("Telefonen skulle glömma hemmet och sin nyckel. Boxen fortsätter lokalt. I mockupen återgår du till första start.")
                    Button("Ta bort i mockupen", role: .destructive) { model.paired = false; model.stop(); dismiss() }
                }
            }
            .scrollContentBackground(.hidden).background(DistributionStyle.ground)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Stäng") { dismiss() }.disabled(model.sending) }
                if sheet == .goal || sheet == .level {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Spara") { Task { await model.submit(sheet == .goal ? .goal(Int(goal), time, days) : .level(level)) } }
                            .disabled(!model.canControl || model.sending).accessibilityIdentifier("distribution.save")
                    }
                }
            }
            .confirmationDialog("Ta bort laddmålet?", isPresented: $removeGoal) {
                Button("Ta bort målet", role: .destructive) { Task { await model.submit(.goal(0, time, days)) } }
            } message: { Text("Bilen får ingen sparad tid eller nivå att planera mot.") }
        }
        .tint(DistributionStyle.ink)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.sending)
        .onAppear { goal = Double(model.goal == 0 ? 80 : model.goal); level = model.level; time = model.readyAt; days = model.days }
    }
    private var receipt: some View { Text(model.receipt.isEmpty ? "Hemmets tid · Europe/Stockholm" : model.receipt).font(.caption).foregroundStyle(DistributionStyle.muted).accessibilityIdentifier("distribution.editor.receipt") }
    private var title: String {
        switch sheet { case .goal: "Bilens mål"; case .level: "Bilens nivå"; case .mode: "Så körs hemmet"; case .demo: "Se fördelningen"; case .forget: "Ta bort från telefonen?" }
    }
}
#endif
