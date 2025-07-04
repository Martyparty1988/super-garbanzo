import SwiftUI
import Combine
import Charts // Pro grafy (iOS 16+)

// Model pro časové záznamy s rozšířenými vlastnostmi
struct TimeEntry: Identifiable, Codable {
    var id = UUID()
    var person: String
    var activity: String
    var subcategory: String?
    var startTime: Date
    var endTime: Date?
    var note: String?
    var hourlyRate: Double
    var deductionRate: Double
    var isManualEntry: Bool = false
    
    var duration: TimeInterval {
        return endTime?.timeIntervalSince(startTime) ?? Date().timeIntervalSince(startTime)
    }
    
    var earnings: Double {
        let hours = duration / 3600
        return hours * hourlyRate
    }
    
    var deduction: Double {
        return earnings * deductionRate
    }
}

// Model pro finanční záznamy
struct FinanceEntry: Identifiable, Codable {
    var id = UUID()
    var type: EntryType
    var amount: Double
    var description: String
    var date: Date
    var category: String
    var currency: Currency
    
    enum EntryType: String, Codable, CaseIterable {
        case income = "Příjem"
        case expense = "Výdaj"
    }
    
    enum Currency: String, Codable, CaseIterable {
        case czk = "CZK"
        case eur = "EUR"
        case usd = "USD"
    }
}

// Model pro dluhy
struct DebtEntry: Identifiable, Codable {
    var id = UUID()
    var creditor: String
    var debtor: String
    var amount: Double
    var description: String
    var currency: Currency
    var dueDate: Date?
    var isCommonExpense: Bool = true
    var payments: [DebtPayment] = []
    
    enum Currency: String, Codable, CaseIterable {
        case czk = "CZK"
        case eur = "EUR"
        case usd = "USD"
    }
    
    var remainingAmount: Double {
        return amount - payments.reduce(0) { $0 + $1.amount }
    }
}

// Model pro splátky dluhu
struct DebtPayment: Identifiable, Codable {
    var id = UUID()
    var amount: Double
    var date: Date
    var isAutomatic: Bool = false
}

// Společný rozpočet
struct SharedBudget: Codable {
    var balance: Double = 0
    var balanceEUR: Double = 0
    var balanceUSD: Double = 0
}

// Hlavní model dat aplikace
class AppData: ObservableObject {
    @Published var timeEntries: [TimeEntry] = []
    @Published var financeEntries: [FinanceEntry] = []
    @Published var debtEntries: [DebtEntry] = []
    @Published var activeTimer: TimeEntry?
    @Published var isTimerRunning = false
    @Published var sharedBudget = SharedBudget()
    
    let defaultRates: [String: Double] = ["Maruška": 275, "Marty": 400]
    let defaultDeductions: [String: Double] = ["Maruška": 0.333, "Marty": 0.5]
    
    init() {
        loadData()
        checkAndAddMonthlyRent()
    }
    
    func startTimer(person: String, activity: String, subcategory: String? = nil, note: String? = nil) {
        if isTimerRunning {
            stopTimer()
        }
        
        let entry = TimeEntry(
            person: person,
            activity: activity,
            subcategory: subcategory,
            startTime: Date(),
            note: note,
            hourlyRate: defaultRates[person] ?? 0,
            deductionRate: defaultDeductions[person] ?? 0
        )
        activeTimer = entry
        isTimerRunning = true
    }
    
    func stopTimer() {
        guard var entry = activeTimer, isTimerRunning else { return }
        
        entry.endTime = Date()
        timeEntries.append(entry)
        activeTimer = nil
        isTimerRunning = false
        
        // Automatické srážky do společného rozpočtu
        addDeductionToSharedBudget(entry.deduction)
        
        saveData()
    }
    
    func addManualTimeEntry(person: String, activity: String, subcategory: String? = nil, note: String? = nil, startTime: Date, endTime: Date, hourlyRate: Double? = nil, deductionRate: Double? = nil) {
        let entry = TimeEntry(
            person: person,
            activity: activity,
            subcategory: subcategory,
            startTime: startTime,
            endTime: endTime,
            note: note,
            hourlyRate: hourlyRate ?? defaultRates[person] ?? 0,
            deductionRate: deductionRate ?? defaultDeductions[person] ?? 0,
            isManualEntry: true
        )
        timeEntries.append(entry)
        addDeductionToSharedBudget(entry.deduction)
        saveData()
    }
    
    func addFinanceEntry(type: FinanceEntry.EntryType, amount: Double, description: String, category: String, currency: FinanceEntry.Currency = .czk) {
        let entry = FinanceEntry(type: type, amount: amount, description: description, date: Date(), category: category, currency: currency)
        financeEntries.append(entry)
        
        // Odečítání příjmů pouze pro CZK
        if type == .income && currency == .czk {
            deductFromTodaysEarnings(amount: amount)
        }
        
        saveData()
    }
    
    func addDebtEntry(creditor: String, debtor: String, amount: Double, description: String, currency: DebtEntry.Currency = .czk, dueDate: Date? = nil, isCommonExpense: Bool = true) {
        let entry = DebtEntry(creditor: creditor, debtor: debtor, amount: amount, description: description, currency: currency, dueDate: dueDate, isCommonExpense: isCommonExpense)
        debtEntries.append(entry)
        saveData()
    }
    
    private func deductFromTodaysEarnings(amount: Double) {
        let today = Calendar.current.startOfDay(for: Date())
        let todaysEntries = timeEntries.filter { Calendar.current.startOfDay(for: $0.startTime) == today }
        let todaysEarnings = todaysEntries.reduce(0) { $0 + $1.earnings }
        
        if todaysEarnings >= amount {
            sharedBudget.balance -= amount
        }
    }
    
    private func addDeductionToSharedBudget(_ amount: Double) {
        sharedBudget.balance += amount
        checkAndProcessDebts()
    }
    
    private func checkAndProcessDebts() {
        guard sharedBudget.balance > 24500 else { return } // Zachovat peníze na nájem
        
        let debtsSorted = debtEntries
            .filter { $0.isCommonExpense && $0.currency == .czk && $0.remainingAmount > 0 }
            .sorted { ($0.dueDate ?? Date.distantFuture, $0.remainingAmount) < ($1.dueDate ?? Date.distantFuture, $1.remainingAmount) }
        
        for index in debtsSorted.indices {
            let debt = debtsSorted[index]
            let availableAmount = sharedBudget.balance - 24500
            let paymentAmount = min(availableAmount, debt.remainingAmount)
            
            if paymentAmount > 0 {
                let payment = DebtPayment(amount: paymentAmount, date: Date(), isAutomatic: true)
                debtEntries[debtEntries.firstIndex(where: { $0.id == debt.id })!].payments.append(payment)
                sharedBudget.balance -= paymentAmount
            }
        }
    }
    
    private func checkAndAddMonthlyRent() {
        let today = Date()
        let calendar = Calendar.current
        
        if calendar.component(.day, from: today) == 1 {
            let monthYear = calendar.dateInterval(of: .month, for: today)!
            let rentDescription = "Nájem za \(DateFormatter.localizedString(from: monthYear.start, dateStyle: .long, timeStyle: .none))"
            
            // Kontrola, zda už není nájem pro tento měsíc zaplacen
            let existingRent = financeEntries.first {
                $0.type == .expense &&
                $0.description.contains("Nájem") &&
                calendar.isDate($0.date, inSameDayAs: today)
            }
            
            if existingRent == nil {
                let rentEntry = FinanceEntry(type: .expense, amount: 24500, description: rentDescription, date: today, category: "Nájem", currency: .czk)
                financeEntries.append(rentEntry)
                
                if sharedBudget.balance >= 24500 {
                    sharedBudget.balance -= 24500
                } else {
                    addDebtEntry(creditor: "Majitel", debtor: "Společný dluh", amount: 24500, description: rentDescription, currency: .czk, dueDate: today, isCommonExpense: true)
                }
                
                saveData()
            }
        }
    }
    
    private func saveData() {
        if let encodedTimeEntries = try? JSONEncoder().encode(timeEntries) {
            UserDefaults.standard.set(encodedTimeEntries, forKey: "timeEntries")
        }
        
        if let encodedFinanceEntries = try? JSONEncoder().encode(financeEntries) {
            UserDefaults.standard.set(encodedFinanceEntries, forKey: "financeEntries")
        }
        
        if let encodedDebtEntries = try? JSONEncoder().encode(debtEntries) {
            UserDefaults.standard.set(encodedDebtEntries, forKey: "debtEntries")
        }
        
        if let encodedSharedBudget = try? JSONEncoder().encode(sharedBudget) {
            UserDefaults.standard.set(encodedSharedBudget, forKey: "sharedBudget")
        }
    }
    
    private func loadData() {
        if let savedTimeEntries = UserDefaults.standard.data(forKey: "timeEntries"),
           let decodedTimeEntries = try? JSONDecoder().decode([TimeEntry].self, from: savedTimeEntries) {
            timeEntries = decodedTimeEntries
        }
        
        if let savedFinanceEntries = UserDefaults.standard.data(forKey: "financeEntries"),
           let decodedFinanceEntries = try? JSONDecoder().decode([FinanceEntry].self, from: savedFinanceEntries) {
            financeEntries = decodedFinanceEntries
        }
        
        if let savedDebtEntries = UserDefaults.standard.data(forKey: "debtEntries"),
           let decodedDebtEntries = try? JSONDecoder().decode([DebtEntry].self, from: savedDebtEntries) {
            debtEntries = decodedDebtEntries
        }
        
        if let savedSharedBudget = UserDefaults.standard.data(forKey: "sharedBudget"),
           let decodedSharedBudget = try? JSONDecoder().decode(SharedBudget.self, from: savedSharedBudget) {
            sharedBudget = decodedSharedBudget
        }
    }
}

extension Double {
    var formattedCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "Kč"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? "\(self) Kč"
    }
}

extension TimeInterval {
    var formattedTime: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60
        let seconds = Int(self) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// Univerzální karta pro zobrazení obsahu
struct ModernCardView<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let content: Content
    
    init(title: String, systemImage: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty || !systemImage.isEmpty {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.title2)
                        .foregroundColor(color)
                    Spacer()
                }
                .padding(.bottom, 5)
            }
            
            content
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color(.systemBackground))
                        .shadow(color: color.opacity(0.2), radius: 5, x: 0, y: 3)
                )
        }
        .padding(.horizontal)
    }
}

// Zobrazení dvouciferného čísla pro časovač
struct DigitGroup: View {
    let value: Int
    
    var body: some View {
        Text(String(format: "%02d", value))
            .font(.system(size: 48, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
            )
    }
}

// Hlavní navigace aplikace
struct ContentView: View {
    @StateObject var appData = AppData()
    
    var body: some View {
        TabView {
            TimeTrackingView()
                .tabItem {
                    Label("Čas", systemImage: "clock.fill")
                }
            
            FinanceView()
                .tabItem {
                    Label("Finance", systemImage: "creditcard.fill")
                }
            
            DebtsView()
                .tabItem {
                    Label("Dluhy", systemImage: "doc.text.fill")
                }
            
            SummaryView()
                .tabItem {
                    Label("Přehled", systemImage: "chart.bar.fill")
                }
        }
        .accentColor(.blue)
        .environmentObject(appData)
    }
}

// Obrazovka pro sledování času
struct TimeTrackingView: View {
    @EnvironmentObject var appData: AppData
    @State private var selectedPerson = "Maruška"
    @State private var selectedActivity = "Wellness"
    @State private var subcategory = ""
    @State private var note = ""
    @State private var timerValue: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showManualEntry = false
    @State private var showEditEntry = false
    @State private var editingEntry: TimeEntry?
    
    let activities = ["Wellness", "Příprava vily", "Pracovní hovor", "Marketing", "Administrativa"]
    let people = ["Maruška", "Marty"]
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Časovač
                    ModernTimerCard()
                    
                    // Nastavení osoby
                    ModernCardView(title: "Nastavení osoby", systemImage: "person.fill", color: .orange) {
                        VStack(spacing: 15) {
                            HStack {
                                Text("Osoba:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Menu {
                                    ForEach(people, id: \.self) { person in
                                        Button {
                                            selectedPerson = person
                                        } label: {
                                            Text(person)
                                            if selectedPerson == person {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text("\(selectedPerson)")
                                        Image(systemName: "chevron.down")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                    .padding(8)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Hodinová sazba:")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                Text("\(appData.defaultRates[selectedPerson] ?? 0, specifier: "%.0f") Kč/h")
                                    .font(.headline)
                            }
                            
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Automatická srážka:")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                Text("\(Int((appData.defaultDeductions[selectedPerson] ?? 0) * 100))% výdělku → Společný rozpočet")
                                    .font(.headline)
                            }
                        }
                    }
                    
                    // Kategorizace práce
                    ModernCardView(title: "Kategorizace práce", systemImage: "folder.fill", color: .blue) {
                        VStack(spacing: 15) {
                            HStack {
                                Text("Aktivita:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Menu {
                                    ForEach(activities, id: \.self) { activity in
                                        Button {
                                            selectedActivity = activity
                                        } label: {
                                            Text(activity)
                                            if selectedActivity == activity {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedActivity)
                                        Image(systemName: "chevron.down")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                    .padding(8)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                }
                            }
                            
                            TextField("Podkategorie (volitelná)", text: $subcategory)
                                .padding(10)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            
                            TextField("Poznámka (volitelná)", text: $note)
                                .padding(10)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        }
                    }
                    
                    // Tlačítko pro manuální zadání
                    Button(action: {
                        showManualEntry = true
                    }) {
                        Label("Přidat manuální záznam", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(Color.green))
                            .foregroundColor(.white)
                            .shadow(color: Color.green.opacity(0.4), radius: 5, x: 0, y: 3)
                    }
                    .padding(.horizontal)
                    
                    // Poslední záznamy
                    RecentEntriesCard(showEdit: $showEditEntry, editingEntry: $editingEntry)
                }
                .padding(.vertical)
            }
            .navigationTitle("Sledování času")
            .sheet(isPresented: $showManualEntry) {
                ManualTimeEntryView()
            }
            .sheet(isPresented: $showEditEntry) {
                if let entry = editingEntry {
                    EditTimeEntryView(entry: entry)
                }
            }
        }
    }
}

// Komponenta pro časovač
struct ModernTimerCard: View {
    @EnvironmentObject var appData: AppData
    @State private var timerValue: TimeInterval = 0
    @State private var timer: Timer?
    
    var body: some View {
        ModernCardView(title: "Časovač", systemImage: "timer", color: appData.isTimerRunning ? .green : .blue) {
            VStack(alignment: .center, spacing: 15) {
                // Digitální časovač
                HStack(spacing: 0) {
                    DigitGroup(value: Int(timerValue) / 3600)
                    Text(":")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.7))
                        .offset(y: -4)
                    DigitGroup(value: (Int(timerValue) % 3600) / 60)
                    Text(":")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.7))
                        .offset(y: -4)
                    DigitGroup(value: Int(timerValue) % 60)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                
                if appData.isTimerRunning {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Aktuální výdělek:")
                            Spacer()
                            Text((timerValue / 3600 * (appData.activeTimer?.hourlyRate ?? 0)).formattedCurrency)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                        
                        HStack {
                            Text("Automatická srážka:")
                            Spacer()
                            Text(((timerValue / 3600 * (appData.activeTimer?.hourlyRate ?? 0)) * (appData.activeTimer?.deductionRate ?? 0)).formattedCurrency)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 5)
                }
                
                // Tlačítka pro ovládání časovače
                HStack(spacing: 20) {
                    Button(action: startTimer) {
                        Label("Start", systemImage: "play.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 25)
                            .frame(maxWidth: .infinity)
                    }
                    .background(Capsule().fill(Color.green))
                    .foregroundColor(.white)
                    .shadow(color: Color.green.opacity(0.4), radius: 5, x: 0, y: 3)
                    .disabled(appData.isTimerRunning)
                    .opacity(appData.isTimerRunning ? 0.6 : 1)
                    
                    Button(action: stopTimer) {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 25)
                            .frame(maxWidth: .infinity)
                    }
                    .background(Capsule().fill(Color.red))
                    .foregroundColor(.white)
                    .shadow(color: Color.red.opacity(0.4), radius: 5, x: 0, y: 3)
                    .disabled(!appData.isTimerRunning)
                    .opacity(appData.isTimerRunning ? 1 : 0.6)
                }
                .padding(.top, 10)
            }
        }
        .onAppear {
            if appData.isTimerRunning, let activeTimer = appData.activeTimer {
                timerValue = Date().timeIntervalSince(activeTimer.startTime)
                startTimerUpdates()
            }
        }
    }
    
    private func startTimer() {
        appData.startTimer(person: "Maruška", activity: "Wellness")
        timerValue = 0
        startTimerUpdates()
    }
    
    private func stopTimer() {
        appData.stopTimer()
        timer?.invalidate()
        timer = nil
    }
    
    private func startTimerUpdates() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let activeTimer = appData.activeTimer {
                timerValue = Date().timeIntervalSince(activeTimer.startTime)
            }
        }
    }
}

// Komponenta pro zobrazení posledních záznamů
struct RecentEntriesCard: View {
    @EnvironmentObject var appData: AppData
    @Binding var showEdit: Bool
    @Binding var editingEntry: TimeEntry?
    
    var body: some View {
        ModernCardView(title: "Poslední záznamy", systemImage: "list.bullet", color: .purple) {
            VStack(spacing: 15) {
                if appData.timeEntries.isEmpty {
                    Text("Zatím žádné záznamy")
                        .foregroundColor(.secondary)
                        .italic()
                        .padding()
                } else {
                    ForEach(appData.timeEntries.sorted(by: { $0.startTime > $1.startTime }).prefix(5)) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.activity + (entry.subcategory.map { " - \($0)" } ?? ""))
                                    .font(.headline)
                                
                                HStack {
                                    Label(entry.person, systemImage: "person")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(entry.duration.formattedTime)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack {
                                    Text(entry.startTime, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text("Srážka: \(entry.deduction.formattedCurrency)")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(entry.earnings.formattedCurrency)
                                    .font(.headline)
                                    .foregroundColor(.green)
                                Menu {
                                    Button {
                                        editingEntry = entry
                                        showEdit = true
                                    } label: {
                                        Label("Upravit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        deleteEntry(entry)
                                    } label: {
                                        Label("Smazat", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray6))
                        )
                    }
                }
            }
        }
    }
    
    private func deleteEntry(_ entry: TimeEntry) {
        if let index = appData.timeEntries.firstIndex(where: { $0.id == entry.id }) {
            appData.timeEntries.remove(at: index)
            appData.sharedBudget.balance -= entry.deduction
        }
    }
}

// Formulář pro manuální zadání času
struct ManualTimeEntryView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var appData: AppData
    
    @State private var selectedPerson = "Maruška"
    @State private var selectedActivity = "Wellness"
    @State private var subcategory = ""
    @State private var note = ""
    @State private var startDate = Date()
    @State private var startTime = Date()
    @State private var endDate = Date()
    @State private var endTime = Date()
    @State private var customRate = ""
    @State private var customDeduction = ""
    
    let activities = ["Wellness", "Příprava vily", "Pracovní hovor", "Marketing", "Administrativa"]
    let people = ["Maruška", "Marty"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Osoba")) {
                    Picker("Osoba", selection: $selectedPerson) {
                        ForEach(people, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                
                Section(header: Text("Detaily práce")) {
                    Picker("Aktivita", selection: $selectedActivity) {
                        ForEach(activities, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    
                    TextField("Podkategorie", text: $subcategory)
                    TextField("Poznámka", text: $note)
                }
                
                Section(header: Text("Časové údaje")) {
                    DatePicker("Den začátku", selection: $startDate, displayedComponents: .date)
                    DatePicker("Čas začátku", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Den konce", selection: $endDate, displayedComponents: .date)
                    DatePicker("Čas konce", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                
                Section(header: Text("Pokročilá nastavení")) {
                    HStack {
                        Text("Hodinová sazba")
                        Spacer()
                        TextField("Výchozí: \(appData.defaultRates[selectedPerson] ?? 0, specifier: "%.0f")", text: $customRate)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Text("Procento srážky")
                        Spacer()
                        TextField("Výchozí: \(Int((appData.defaultDeductions[selectedPerson] ?? 0) * 100))%", text: $customDeduction)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Manuální záznam")
            .navigationBarItems(
                leading: Button("Zrušit") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Uložit") {
                    saveEntry()
                }
            )
        }
    }
    
    private func saveEntry() {
        let calendar = Calendar.current
        let startDateTime = calendar.dateInterval(of: .day, for: startDate)!.start.addingTimeInterval(timeInterval(from: startTime))
        let endDateTime = calendar.dateInterval(of: .day, for: endDate)!.start.addingTimeInterval(timeInterval(from: endTime))
        
        let hourlyRate = Double(customRate.replacingOccurrences(of: ",", with: ".")) ?? appData.defaultRates[selectedPerson] ?? 0
        let deductionRate = Double(customDeduction) ?? ((appData.defaultDeductions[selectedPerson] ?? 0) * 100) / 100
        
        appData.addManualTimeEntry(
            person: selectedPerson,
            activity: selectedActivity,
            subcategory: subcategory.isEmpty ? nil : subcategory,
            note: note.isEmpty ? nil : note,
            startTime: startDateTime,
            endTime: endDateTime,
            hourlyRate: hourlyRate,
            deductionRate: deductionRate
        )
        
        presentationMode.wrappedValue.dismiss()
    }
    
    private func timeInterval(from date: Date) -> TimeInterval {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date))
        let minute = Double(calendar.component(.minute, from: date))
        return hour * 3600 + minute * 60
    }
}

// Formulář pro úpravu časového záznamu
struct EditTimeEntryView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var appData: AppData
    
    var entry: TimeEntry
    @State private var selectedPerson: String
    @State private var selectedActivity: String
    @State private var subcategory: String
    @State private var note: String
    @State private var startDate: Date
    @State private var startTime: Date
    @State private var endDate: Date
    @State private var endTime: Date
    @State private var customRate: String
    @State private var customDeduction: String
    
    let activities = ["Wellness", "Příprava vily", "Pracovní hovor", "Marketing", "Administrativa"]
    let people = ["Maruška", "Marty"]
    
    init(entry: TimeEntry) {
        self.entry = entry
        _selectedPerson = State(initialValue: entry.person)
        _selectedActivity = State(initialValue: entry.activity)
        _subcategory = State(initialValue: entry.subcategory ?? "")
        _note = State(initialValue: entry.note ?? "")
        _startDate = State(initialValue: entry.startTime)
        _startTime = State(initialValue: entry.startTime)
        _endDate = State(initialValue: entry.endTime ?? Date())
        _endTime = State(initialValue: entry.endTime ?? Date())
        _customRate = State(initialValue: String(entry.hourlyRate))
        _customDeduction = State(initialValue: String(Int(entry.deductionRate * 100)))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Osoba")) {
                    Picker("Osoba", selection: $selectedPerson) {
                        ForEach(people, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                
                Section(header: Text("Detaily práce")) {
                    Picker("Aktivita", selection: $selectedActivity) {
                        ForEach(activities, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    
                    TextField("Podkategorie", text: $subcategory)
                    TextField("Poznámka", text: $note)
                }
                
                Section(header: Text("Časové údaje")) {
                    DatePicker("Den začátku", selection: $startDate, displayedComponents: .date)
                    DatePicker("Čas začátku", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Den konce", selection: $endDate, displayedComponents: .date)
                    DatePicker("Čas konce", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                
                Section(header: Text("Pokročilá nastavení")) {
                    HStack {
                        Text("Hodinová sazba")
                        Spacer()
                        TextField("Výchozí: \(appData.defaultRates[selectedPerson] ?? 0, specifier: "%.0f")", text: $customRate)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Text("Procento srážky")
                        Spacer()
                        TextField("Výchozí: \(Int((appData.defaultDeductions[selectedPerson] ?? 0) * 100))%", text: $customDeduction)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Upravit záznam")
            .navigationBarItems(
                leading: Button("Zrušit") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Uložit") {
                    saveEntry()
                }
            )
        }
    }
    
    private func saveEntry() {
        if let index = appData.timeEntries.firstIndex(where: { $0.id == entry.id }) {
            let oldDeduction = appData.timeEntries[index].deduction
            appData.sharedBudget.balance -= oldDeduction
            appData.timeEntries.remove(at: index)
        }
        
        let calendar = Calendar.current
        let startDateTime = calendar.dateInterval(of: .day, for: startDate)!.start.addingTimeInterval(timeInterval(from: startTime))
        let endDateTime = calendar.dateInterval(of: .day, for: endDate)!.start.addingTimeInterval(timeInterval(from: endTime))
        
        let hourlyRate = Double(customRate.replacingOccurrences(of: ",", with: ".")) ?? appData.defaultRates[selectedPerson] ?? 0
        let deductionRate = Double(customDeduction) ?? ((appData.defaultDeductions[selectedPerson] ?? 0) * 100) / 100
        
        appData.addManualTimeEntry(
            person: selectedPerson,
            activity: selectedActivity,
            subcategory: subcategory.isEmpty ? nil : subcategory,
            note: note.isEmpty ? nil : note,
            startTime: startDateTime,
            endTime: endDateTime,
            hourlyRate: hourlyRate,
            deductionRate: deductionRate
        )
        
        presentationMode.wrappedValue.dismiss()
    }
    
    private func timeInterval(from date: Date) -> TimeInterval {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date))
        let minute = Double(calendar.component(.minute, from: date))
        return hour * 3600 + minute * 60
    }
}

// Obrazovka pro finance
struct FinanceView: View {
    @EnvironmentObject var appData: AppData
    @State private var showingAddSheet = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    SharedBudgetCard()
                    FinancialOverviewCard()
                    QuickActionButtons(showingAddSheet: $showingAddSheet)
                    FinanceRecordsCard()
                }
                .padding(.vertical)
            }
            .navigationTitle("Finance")
            .sheet(isPresented: $showingAddSheet) {
                AddFinanceEntryView()
            }
        }
    }
}

// Karta společného rozpočtu
struct SharedBudgetCard: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        ModernCardView(title: "Společný rozpočet", systemImage: "building.columns.fill", color: .blue) {
            VStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("CZK")
                            .font(.headline)
                        Spacer()
                        Text(appData.sharedBudget.balance.formattedCurrency)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(appData.sharedBudget.balance >= 24500 ? .green : .red)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    
                    HStack {
                        Text("EUR")
                            .font(.headline)
                        Spacer()
                        Text("€\(appData.sharedBudget.balanceEUR, specifier: "%.2f")")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    
                    HStack {
                        Text("USD")
                            .font(.headline)
                        Spacer()
                        Text("$\(appData.sharedBudget.balanceUSD, specifier: "%.2f")")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                
                Text("Priorita použití: Nájem (24 500 Kč) → Společné dluhy")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// Karta finančního přehledu
struct FinancialOverviewCard: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        ModernCardView(title: "Finanční přehled", systemImage: "chart.pie.fill", color: .green) {
            VStack(spacing: 15) {
                HStack(spacing: 20) {
                    FinanceStatItem(title: "Příjmy", amount: calculateTotalIncome(), color: .green, systemImage: "arrow.down.circle.fill")
                    FinanceStatItem(title: "Výdaje", amount: calculateTotalExpenses(), color: .red, systemImage: "arrow.up.circle.fill")
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dopad na společný rozpočet:")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Ze srážek:")
                        Spacer()
                        Text(getTotalDeductions().formattedCurrency)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.top, 5)
            }
        }
    }
    
    private func calculateTotalIncome() -> Double {
        appData.financeEntries
            .filter { $0.type == .income }
            .reduce(0) { $0 + ($1.currency == .czk ? $1.amount : 0) }
    }
    
    private func calculateTotalExpenses() -> Double {
        appData.financeEntries
            .filter { $0.type == .expense }
            .reduce(0) { $0 + ($1.currency == .czk ? $1.amount : 0) }
    }
    
    private func getTotalDeductions() -> Double {
        appData.timeEntries.reduce(0) { $0 + $1.deduction }
    }
}

// Komponenta pro statistické položky
struct FinanceStatItem: View {
    var title: String
    var amount: Double
    var color: Color
    var systemImage: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
            }
            Text(amount.formattedCurrency)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .cornerRadius(10)
    }
}

// Rychlá tlačítka
struct QuickActionButtons: View {
    @Binding var showingAddSheet: Bool
    
    var body: some View {
        Button(action: {
            showingAddSheet = true
        }) {
            Label("Přidat příjem/výdaj", systemImage: "plus.circle.fill")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Color.blue))
                .foregroundColor(.white)
                .shadow(color: Color.blue.opacity(0.4), radius: 5, x: 0, y: 3)
        }
        .padding(.horizontal)
    }
}

// Karta finančních záznamů
struct FinanceRecordsCard: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        ModernCardView(title: "Finanční záznamy", systemImage: "list.bullet.rectangle", color: .purple) {
            VStack(spacing: 15) {
                if appData.financeEntries.isEmpty {
                    Text("Zatím žádné záznamy")
                        .foregroundColor(.secondary)
                        .italic()
                        .padding()
                } else {
                    ForEach(appData.financeEntries.sorted(by: { $0.date > $1.date }).prefix(10)) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.description)
                                    .font(.headline)
                                HStack {
                                    Text(entry.date, style: .date)
                                    Text("•")
                                    Text(entry.category)
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(entry.amount, specifier: "%.2f") \(entry.currency.rawValue)")
                                    .font(.headline)
                                    .foregroundColor(entry.type == .income ? .green : .red)
                                if entry.type == .income && entry.currency == .czk {
                                    Text("Odečteno z výdělků")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray6))
                        )
                    }
                }
            }
        }
    }
}

// Formulář pro přidání finančního záznamu
struct AddFinanceEntryView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var appData: AppData
    
    @State private var type: FinanceEntry.EntryType = .income
    @State private var amount: String = ""
    @State private var description: String = ""
    @State private var selectedCategory: String = ""
    @State private var currency: FinanceEntry.Currency = .czk
    
    let incomeCategories = ["Výdělek", "Investice", "Dar", "Ostatní příjmy"]
    let expenseCategories = ["Jídlo", "Doprava", "Bydlení", "Zábava", "Práce", "Nájem", "Ostatní"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Typ záznamu")) {
                    Picker("Typ", selection: $type) {
                        ForEach(FinanceEntry.EntryType.allCases, id: \.self) { type in
                            Text(type.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                Section(header: Text("Detaily")) {
                    HStack {
                        TextField("Částka", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("", selection: $currency) {
                            ForEach(FinanceEntry.Currency.allCases, id: \.self) { currency in
                                Text(currency.rawValue).tag(currency)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    
                    TextField("Popis", text: $description)
                    
                    Picker("Kategorie", selection: $selectedCategory) {
                        Text("Vyberte kategorii").tag("")
                        ForEach(type == .income ? incomeCategories : expenseCategories, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                
                if currency == .czk && type == .income {
                    Section(footer: Text("Příjem v CZK bude automaticky odečten z výdělků za dnešní den")) {
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Nový záznam")
            .navigationBarItems(
                leading: Button("Zrušit") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Uložit") {
                    saveEntry()
                }
                .disabled(amount.isEmpty || description.isEmpty || selectedCategory.isEmpty)
            )
        }
    }
    
    private func saveEntry() {
        guard let doubleAmount = Double(amount.replacingOccurrences(of: ",", with: ".")) else {
            return
        }
        
        appData.addFinanceEntry(
            type: type,
            amount: doubleAmount,
            description: description,
            category: selectedCategory,
            currency: currency
        )
        
        presentationMode.wrappedValue.dismiss()
    }
}

// Obrazovka pro správu dluhů
struct DebtsView: View {
    @EnvironmentObject var appData: AppData
    @State private var showingAddDebt = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    DebtsOverviewCard()
                    
                    Button(action: {
                        showingAddDebt = true
                    }) {
                        Label("Přidat nový dluh", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(Color.red))
                            .foregroundColor(.white)
                            .shadow(color: Color.red.opacity(0.4), radius: 5, x: 0, y: 3)
                    }
                    .padding(.horizontal)
                    
                    DebtsListCard()
                }
                .padding(.vertical)
            }
            .navigationTitle("Dluhy")
            .sheet(isPresented: $showingAddDebt) {
                AddDebtView()
            }
        }
    }
}

// Karta přehledu dluhů
struct DebtsOverviewCard: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        ModernCardView(title: "Přehled dluhů", systemImage: "exclamationmark.triangle.fill", color: .red) {
            VStack(spacing: 15) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Celkem dluhů")
                            .font(.headline)
                        Text(getTotalDebts().formattedCurrency)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Zbývá splatit")
                            .font(.headline)
                        Text(getRemainingDebts().formattedCurrency)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("Priorita splácení:")
                        .font(.headline)
                    Text("• Nájem (24 500 Kč)")
                        .font(.subheadline)
                    Text("• Společné dluhy dle termínu splatnosti")
                        .font(.subheadline)
                    Text("• Automatické splácení z přebytku v rozpočtu")
                        .font(.subheadline)
                }
                .padding(.top, 5)
            }
        }
    }
    
    private func getTotalDebts() -> Double {
        appData.debtEntries.filter { $0.isCommonExpense && $0.currency == .czk }.reduce(0) { $0 + $1.amount }
    }
    
    private func getRemainingDebts() -> Double {
        appData.debtEntries.filter { $0.isCommonExpense && $0.currency == .czk }.reduce(0) { $0 + $1.remainingAmount }
    }
}

// Karta seznamu dluhů
struct DebtsListCard: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        ForEach(appData.debtEntries.filter { $0.isCommonExpense }.sorted(by: { ($0.dueDate ?? Date.distantFuture) < ($1.dueDate ?? Date.distantFuture) })) { debt in
            DebtRowView(debt: debt)
        }
    }
}

// Řádek pro zobrazení dluhu
struct DebtRowView: View {
    @EnvironmentObject var appData: AppData
    var debt: DebtEntry
    @State private var showPaymentHistory = false
    
    var body: some View {
        ModernCardView(title: "", systemImage: "", color: .clear) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(debt.description)
                        .font(.headline)
                    Spacer()
                    Text(debt.remainingAmount.formattedCurrency)
                        .font(.headline)
                        .foregroundColor(debt.remainingAmount > 0 ? .red : .green)
                }
                
                HStack {
                    Text("Od: \(debt.debtor)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let dueDate = debt.dueDate {
                        Text("Splatnost: \(dueDate, style: .date)")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
                
                if debt.isCommonExpense {
                    Text("Společný dluh")
                        .font(.caption)
                        .padding(4)
                        .background(Capsule().fill(Color.blue.opacity(0.2)))
                        .foregroundColor(.blue)
                }
                
                if !debt.payments.isEmpty {
                    Button(action: {
                        showPaymentHistory.toggle()
                    }) {
                        Label("Historie splátek", systemImage: showPaymentHistory ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    
                    if showPaymentHistory {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(debt.payments) { payment in
                                HStack {
                                    Text(payment.date, style: .date)
                                    Spacer()
                                    Text(payment.amount.formattedCurrency)
                                        .foregroundColor(.green)
                                    if payment.isAutomatic {
                                        Image(systemName: "gearshape.fill")
                                            .foregroundColor(.blue)
                                            .font(.caption)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.top, 5)
                    }
                }
            }
        }
    }
}

// Formulář pro přidání dluhu
struct AddDebtView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var appData: AppData
    
    @State private var creditor: String = ""
    @State private var debtor: String = "Společný dluh"
    @State private var amount: String = ""
    @State private var description: String = ""
    @State private var currency: DebtEntry.Currency = .czk
    @State private var dueDate = Date()
    @State private var hasDeadline = false
    @State private var isCommonExpense = true
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Detaily dluhu")) {
                    TextField("Věřitel", text: $creditor)
                    TextField("Dlužník", text: $debtor)
                    TextField("Popis", text: $description)
                }
                
                Section(header: Text("Částka")) {
                    HStack {
                        TextField("Částka", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("", selection: $currency) {
                            ForEach(DebtEntry.Currency.allCases, id: \.self) { currency in
                                Text(currency.rawValue).tag(currency)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                }
                
                Section {
                    Toggle("Termín splatnosti", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Splatnost", selection: $dueDate, displayedComponents: .date)
                    }
                }
                
                Section {
                    Toggle("Společný dluh", isOn: $isCommonExpense)
                }
            }
            .navigationTitle("Nový dluh")
            .navigationBarItems(
                leading: Button("Zrušit") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Uložit") {
                    saveDebt()
                }
                .disabled(creditor.isEmpty || debtor.isEmpty || amount.isEmpty || description.isEmpty)
            )
        }
    }
    
    private func saveDebt() {
        guard let doubleAmount = Double(amount.replacingOccurrences(of: ",", with: ".")) else {
            return
        }
        
        appData.addDebtEntry(
            creditor: creditor,
            debtor: debtor,
            amount: doubleAmount,
            description: description,
            currency: currency,
            dueDate: hasDeadline ? dueDate : nil,
            isCommonExpense: isCommonExpense
        )
        
        presentationMode.wrappedValue.dismiss()
    }
}

// Přehledová obrazovka s grafy
struct SummaryView: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Shrnutí času
                    ModernCardView(title: "Shrnutí času", systemImage: "clock.fill", color: .blue) {
                        VStack(spacing: 10) {
                            HStack {
                                Text("Celkový čas:")
                                Spacer()
                                Text(totalDuration().formattedTime)
                                    .fontWeight(.bold)
                            }
                            HStack {
                                Text("Celkový výdělek:")
                                Spacer()
                                Text(totalEarnings().formattedCurrency)
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                            }
                            HStack {
                                Text("Celkové srážky:")
                                Spacer()
                                Text(totalDeductions().formattedCurrency)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    
                    // Graf výdělků podle osoby
                    ModernCardView(title: "Výdělky podle osoby", systemImage: "person.2.fill", color: .purple) {
                        EarningsByPersonChart()
                            .frame(height: 200)
                            .padding()
                    }
                    
                    // Shrnutí financí
                    ModernCardView(title: "Shrnutí financí", systemImage: "creditcard.fill", color: .green) {
                        VStack(spacing: 10) {
                            HStack {
                                Text("Příjmy:")
                                Spacer()
                                Text(totalIncome().formattedCurrency)
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                            }
                            HStack {
                                Text("Výdaje:")
                                Spacer()
                                Text(totalExpenses().formattedCurrency)
                                    .fontWeight(.bold)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    // Graf příjmů a výdajů
                    ModernCardView(title: "Příjmy vs. Výdaje", systemImage: "chart.bar.fill", color: .orange) {
                        IncomeVsExpensesChart()
                            .frame(height: 200)
                            .padding()
                    }
                    
                    // Shrnutí dluhů
                    ModernCardView(title: "Shrnutí dluhů", systemImage: "exclamationmark.triangle.fill", color: .red) {
                        VStack(spacing: 10) {
                            HStack {
                                Text("Celkem dluhů:")
                                Spacer()
                                Text(totalDebts().formattedCurrency)
                                    .fontWeight(.bold)
                                    .foregroundColor(.red)
                            }
                            HStack {
                                Text("Zbývá splatit:")
                                Spacer()
                                Text(remainingDebts().formattedCurrency)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    
                    // Graf zbývajících dluhů
                    ModernCardView(title: "Zbývající dluhy", systemImage: "exclamationmark.triangle.fill", color: .red) {
                        RemainingDebtsChart()
                            .frame(height: 200)
                            .padding()
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Přehled")
        }
    }
    
    private func totalDuration() -> TimeInterval {
        appData.timeEntries.reduce(0) { $0 + $1.duration }
    }
    
    private func totalEarnings() -> Double {
        appData.timeEntries.reduce(0) { $0 + $1.earnings }
    }
    
    private func totalDeductions() -> Double {
        appData.timeEntries.reduce(0) { $0 + $1.deduction }
    }
    
    private func totalIncome() -> Double {
        appData.financeEntries
            .filter { $0.type == .income && $0.currency == .czk }
            .reduce(0) { $0 + $1.amount }
    }
    
    private func totalExpenses() -> Double {
        appData.financeEntries
            .filter { $0.type == .expense && $0.currency == .czk }
            .reduce(0) { $0 + $1.amount }
    }
    
    private func totalDebts() -> Double {
        appData.debtEntries
            .filter { $0.isCommonExpense && $0.currency == .czk }
            .reduce(0) { $0 + $1.amount }
    }
    
    private func remainingDebts() -> Double {
        appData.debtEntries
            .filter { $0.isCommonExpense && $0.currency == .czk }
            .reduce(0) { $0 + $1.remainingAmount }
    }
}

// Graf výdělků podle osoby
struct EarningsByPersonChart: View {
    @EnvironmentObject var appData: AppData
    
    struct EarningsData: Identifiable {
        let id = UUID()
        let person: String
        let earnings: Double
    }
    
    var data: [EarningsData] {
        let grouped = Dictionary(grouping: appData.timeEntries, by: { $0.person })
        return grouped.map { person, entries in
            EarningsData(person: person, earnings: entries.reduce(0) { $0 + $1.earnings })
        }
    }
    
    var body: some View {
        if data.isEmpty {
            Text("Žádné údaje k zobrazení")
                .foregroundColor(.secondary)
                .padding()
        } else {
            Chart(data) { item in
                BarMark(
                    x: .value("Osoba", item.person),
                    y: .value("Výdělek", item.earnings)
                )
                .foregroundStyle(.purple)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel(format: .currency(code: "CZK"))
                }
            }
        }
    }
}

// Graf příjmů vs. výdajů
struct IncomeVsExpensesChart: View {
    @EnvironmentObject var appData: AppData
    
    struct FinanceData: Identifiable {
        let id = UUID()
        let type: String
        let amount: Double
    }
    
    var data: [FinanceData] {
        let income = appData.financeEntries
            .filter { $0.type == .income && $0.currency == .czk }
            .reduce(0) { $0 + $1.amount }
        let expenses = appData.financeEntries
            .filter { $0.type == .expense && $0.currency == .czk }
            .reduce(0) { $0 + $1.amount }
        
        return [
            FinanceData(type: "Příjmy", amount: income),
            FinanceData(type: "Výdaje", amount: expenses)
        ]
    }
    
    var body: some View {
        if data.allSatisfy({ $0.amount == 0 }) {
            Text("Žádné údaje k zobrazení")
                .foregroundColor(.secondary)
                .padding()
        } else {
            Chart(data) { item in
                BarMark(
                    x: .value("Typ", item.type),
                    y: .value("Částka", item.amount)
                )
                .foregroundStyle(item.type == "Příjmy" ? .green : .red)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel(format: .currency(code: "CZK"))
                }
            }
        }
    }
}

// Graf zbývajících dluhů
struct RemainingDebtsChart: View {
    @EnvironmentObject var appData: AppData
    
    struct DebtData: Identifiable {
        let id = UUID()
        let description: String
        let remainingAmount: Double
    }
    
    var data: [DebtData] {
        appData.debtEntries
            .filter { $0.isCommonExpense && $0.currency == .czk }
            .map { DebtData(description: $0.description, remainingAmount: $0.remainingAmount) }
    }
    
    var body: some View {
        if data.isEmpty {
            Text("Žádné dluhy k zobrazení")
                .foregroundColor(.secondary)
                .padding()
        } else {
            Chart(data) { item in
                BarMark(
                    x: .value("Popis", item.description),
                    y: .value("Zbývá", item.remainingAmount)
                )
                .foregroundStyle(.red)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.caption)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel(format: .currency(code: "CZK"))
                }
            }
        }
    }
}

// Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppData())
    }
}
