import SwiftUI
import CoreData

// Sikandar is a score tracker for group games with three or more players.
// Track every round, see running totals, and when the game ends, Sikandar
// shows the final settlement, so everyone knows exactly where they stand.
// No more pen and paper, no more arguments.
//
// Sikandar does not handle any payments or real money. It only keeps score.

enum AppInfo {
    static let name = "Sikandar"
    static let description = """
    Sikandar is a score tracker for group games with three or more players. \
    Track every round, see running totals, and when the game ends, Sikandar \
    shows the final settlement, so everyone knows exactly where they stand. \
    No more pen and paper, no more arguments.

    Sikandar does not handle any payments or real money. It only keeps score.
    """
}

// MARK: - Theme

// `Color.sikandarWine` / `.sikandarGold` are generated from Assets.xcassets
// (light + dark variants), as are the PlayerInk0…8 colors.
extension Color {
    /// Fixed wine for filled buttons with white text; the dynamic wine goes pink in Dark Mode.
    static let sikandarWineFill = Color(hex: 0x841448)

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF)/255,
                  green: Double((hex >> 8) & 0xFF)/255,
                  blue: Double(hex & 0xFF)/255)
    }
}

/// Muted player identity colors: a light fill with a darker label of the
/// same hue — full color without shouting over the red/green score signals.
/// `label` sits on `fill` (pills) and is fixed; `ink` is used standalone on
/// the screen background and flips to the pastel in Dark Mode.
struct PlayerColor {
    let fill: Color
    let label: Color
    let ink: Color

    static let palette: [PlayerColor] = [
        PlayerColor(fill: Color(hex: 0xECD9CF), label: Color(hex: 0x7A4A33), ink: Color("PlayerInk0")),  // terracotta
        PlayerColor(fill: Color(hex: 0xDBE4D5), label: Color(hex: 0x4A5F42), ink: Color("PlayerInk1")),  // sage
        PlayerColor(fill: Color(hex: 0xD6E0EA), label: Color(hex: 0x3D5A78), ink: Color("PlayerInk2")),  // powder blue
        PlayerColor(fill: Color(hex: 0xE6D7E3), label: Color(hex: 0x6E4A68), ink: Color("PlayerInk3")),  // mauve
        PlayerColor(fill: Color(hex: 0xECDFC6), label: Color(hex: 0x77602C), ink: Color("PlayerInk4")),  // sand
        PlayerColor(fill: Color(hex: 0xD0E1E0), label: Color(hex: 0x3A6360), ink: Color("PlayerInk5")),  // sea teal
        PlayerColor(fill: Color(hex: 0xEAD4DD), label: Color(hex: 0x7C2B4E), ink: Color("PlayerInk6")),  // dusty wine
        PlayerColor(fill: Color(hex: 0xE2E2CD), label: Color(hex: 0x5C5C31), ink: Color("PlayerInk7")),  // olive
        PlayerColor(fill: Color(hex: 0xDCDEE4), label: Color(hex: 0x4C5160), ink: Color("PlayerInk8")),  // slate
    ]
}

// MARK: - Core Data classes

@objc(Player)
public class Player: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Player> {
        NSFetchRequest<Player>(entityName: "Player")
    }
}

extension Player {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var colorIndex: Int16
    @NSManaged public var createdAt: Date
    @NSManaged public var games: NSSet?
    @NSManaged public var wonRounds: NSSet?

    var color: PlayerColor {
        PlayerColor.palette[Int(colorIndex) % PlayerColor.palette.count]
    }
}

/// Display name for fixed-width table columns only: full if 8 chars or
/// fewer, otherwise the shortest unique prefix (min 5) with an ellipsis.
/// Everywhere else shows the full name and lets it scale.
func shortDisplayName(_ name: String, among others: [String]) -> String {
    if name.count <= 8 { return name }
    let rivals = others.filter { $0 != name }
    for len in 5...8 {
        let prefix = String(name.prefix(len))
        let collides = rivals.contains { String($0.prefix(len)) == prefix }
        if !collides { return prefix + "…" }
    }
    return String(name.prefix(8)) + "…"
}

@objc(Game)
public class Game: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Game> {
        NSFetchRequest<Game>(entityName: "Game")
    }
}

extension Game {
    @NSManaged public var id: UUID
    @NSManaged public var startedAt: Date
    @NSManaged public var endedAt: Date?
    @NSManaged public var betAmount: Double
    @NSManaged public var players: NSSet
    @NSManaged public var rounds: NSSet?

    var bet: Int { Int(betAmount) }

    var sortedPlayers: [Player] {
        (players.allObjects as? [Player] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var sortedRounds: [GameRound] {
        ((rounds?.allObjects as? [GameRound]) ?? []).sorted { $0.index < $1.index }
    }

    /// Net balance per player, computed from rounds. Winner of a round gets
    /// (players-1) x bet, everyone else loses bet.
    var balances: [UUID: Int] {
        let ps = sortedPlayers
        var result: [UUID: Int] = [:]
        for p in ps { result[p.id] = 0 }
        let gain = (ps.count - 1) * bet
        for round in sortedRounds {
            for p in ps {
                result[p.id, default: 0] += (p.id == round.winner.id) ? gain : -bet
            }
        }
        return result
    }

    func wins(for player: Player) -> Int {
        sortedRounds.filter { $0.winner.id == player.id }.count
    }
}

@objc(GameRound)
public class GameRound: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<GameRound> {
        NSFetchRequest<GameRound>(entityName: "GameRound")
    }
}

extension GameRound {
    @NSManaged public var id: UUID
    @NSManaged public var index: Int32
    @NSManaged public var date: Date
    @NSManaged public var winner: Player
    @NSManaged public var game: Game
}

extension Player: Identifiable {}
extension Game: Identifiable {}
extension GameRound: Identifiable {}

// MARK: - Settlement

struct Settlement: Identifiable {
    let id = UUID()
    let from: Player
    let to: Player
    let amount: Int
}

/// Minimal-transaction settlement: greedily match biggest debtor to biggest creditor.
func settle(balances: [(Player, Int)]) -> [Settlement] {
    var creditors = balances.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    var debtors = balances.filter { $0.1 < 0 }.sorted { $0.1 < $1.1 }
    var result: [Settlement] = []
    var ci = 0, di = 0
    while ci < creditors.count && di < debtors.count {
        let pay = min(creditors[ci].1, -debtors[di].1)
        if pay > 0 {
            result.append(Settlement(from: debtors[di].0, to: creditors[ci].0, amount: pay))
        }
        creditors[ci].1 -= pay
        debtors[di].1 += pay
        if creditors[ci].1 == 0 { ci += 1 }
        if debtors[di].1 == 0 { di += 1 }
    }
    return result
}

func settlementSummary(_ count: Int) -> String {
    count == 1 ? "1 transfer settles everyone" : "\(count) transfers settle everyone"
}

/// One format for every balance: signed, grouped, plain "0" for zero.
func signedPoints(_ value: Int) -> String {
    value.formatted(.number.sign(strategy: .always(includingZero: false)))
}

func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map { String($0) } ?? name
}

/// Winner pills: scale down slightly on press so a tap is visibly taken.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - App

@main
struct SikandarApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 820)
        #endif
    }
}

struct PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Sikandar")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        let container = self.container
        container.loadPersistentStores { description, error in
            if let error = error {
                // Pre-release: model changed, throw the old store away and retry once.
                if let url = description.url {
                    try? container.persistentStoreCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType)
                    container.loadPersistentStores { _, retryError in
                        if let retryError = retryError {
                            fatalError("Unresolved Core Data error \(retryError)")
                        }
                    }
                } else {
                    fatalError("Unresolved Core Data error \(error)")
                }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}

func saveContext(_ context: NSManagedObjectContext) {
    guard context.hasChanges else { return }
    do { try context.save() } catch { print("Core Data save error: \(error)") }
}

// MARK: - Root tabs

struct ContentView: View {
    var body: some View {
        TabView {
            GameTab()
                .tabItem { Label("Game", systemImage: "square.grid.3x3.middle.filled") }
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock.fill") }
            StatsTab()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
        }
    }
}

// MARK: - Player chip

/// A small solid color dot marking a player's identity color. Used next to
/// full names; standalone contexts use the player's (short) name in their
/// color instead — two-letter initials proved cryptic.
struct PlayerDot: View {
    let player: Player
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(player.color.ink)
            .frame(width: size, height: size)
    }
}

// MARK: - Game tab

struct GameTab: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Game.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt == nil"),
        animation: .default)
    private var activeGames: FetchedResults<Game>

    var body: some View {
        NavigationStack {
            Group {
                if let game = activeGames.first {
                    ActiveGameView(game: game)
                } else {
                    NoGameView()
                }
            }
        }
    }
}

// MARK: - No active game

struct NoGameView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Game.endedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default)
    private var pastGames: FetchedResults<Game>

    @State private var showingStartSheet = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "crown.fill")
                .font(.system(size: 56))
                .foregroundColor(.sikandarGold)
            Text("No game in progress")
                .font(.title2).bold()

            if let last = pastGames.first {
                NavigationLink {
                    GameDetailView(game: last)
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Last game — \(last.endedAt!.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundColor(.secondary)
                        Text(lastGameSummary(last))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.primary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.sikandarWine.opacity(0.10))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            }

            Button {
                showingStartSheet = true
            } label: {
                Label("Start New Game", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.sikandarWineFill)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Sikandar")
        .sheet(isPresented: $showingStartSheet) {
            StartGameSheet()
        }
    }

    private func lastGameSummary(_ game: Game) -> String {
        let names = game.sortedPlayers.map { $0.name }
        return "\(names.joined(separator: ", ")) · \(game.sortedRounds.count) rounds"
    }
}

// MARK: - Start game sheet (roster management + selection)

struct StartGameSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Player.name, ascending: true)],
        animation: .default)
    private var roster: FetchedResults<Player>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Game.startedAt, ascending: false)],
        animation: .default)
    private var previousGames: FetchedResults<Game>

    @State private var selected: Set<UUID> = []
    @State private var newName = ""
    @FocusState private var newNameFocused: Bool
    @State private var betText = "100"
    @FocusState private var betFocused: Bool
    @State private var renaming: Player?
    @State private var renameText = ""
    @State private var deleteBlockedName: String?
    @State private var duplicateName: String?
    @State private var didPrefill = false

    private let minPlayers = 2
    private let maxPlayers = 9
    private let maxPoints = 100_000

    private var betValue: Int? { Int(betText) }
    private var betValid: Bool { (betValue ?? 0) >= 1 }
    private var canStart: Bool { selected.count >= minPlayers && betValid }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Players · \(selected.count) of \(maxPlayers) selected"),
                        footer: selected.count < minPlayers ? Text("Select at least \(minPlayers) players.") : nil) {
                    ForEach(roster) { player in
                        HStack {
                            PlayerDot(player: player)
                            Text(player.name)
                            Spacer()
                            if selected.contains(player.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.sikandarWine)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selected.contains(player.id) {
                                selected.remove(player.id)
                            } else if selected.count < maxPlayers {
                                selected.insert(player.id)
                            }
                        }
                        .opacity(!selected.contains(player.id) && selected.count >= maxPlayers ? 0.4 : 1)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(player) }
                            Button("Rename") {
                                renaming = player
                                renameText = player.name
                            }
                            .tint(.sikandarGold)
                        }
                    }

                    HStack {
                        TextField("New player name", text: $newName)
                            .focused($newNameFocused)
                            .submitLabel(.next)
                            .onSubmit {
                                // Return adds the player and keeps the field
                                // focused for the next name; an empty Return
                                // just dismisses the keyboard.
                                let hasName = !newName.trimmingCharacters(in: .whitespaces).isEmpty
                                addPlayer()
                                if hasName {
                                    DispatchQueue.main.async { newNameFocused = true }
                                }
                            }
                        Button("Add") { addPlayer() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section(footer: betValid ? nil : Text("Enter 1 to \(maxPoints.formatted()) points.")) {
                    HStack {
                        Text("Points per round")
                        Spacer()
                        TextField("100", text: $betText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .font(.body.monospacedDigit())
                            .focused($betFocused)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .onChange(of: betText) {
                                // Digits only, clamped to maxPoints; the field shows the clamped value.
                                var t = String(betText.filter(\.isNumber).prefix(7))
                                if let v = Int(t), v > maxPoints { t = String(maxPoints) }
                                if t != betText { betText = t }
                            }
                    }
                }
            }
            .navigationTitle("New Game")
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 560)
            #endif
            .onAppear {
                // Prefill with the previous game's players and points
                guard !didPrefill else { return }
                didPrefill = true
                if let last = previousGames.first {
                    let rosterIDs = Set(roster.map { $0.id })
                    selected = Set(last.sortedPlayers.map { $0.id }).intersection(rosterIDs)
                    betText = String(last.bet)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { startGame() }
                        .disabled(!canStart)
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { betFocused = false; newNameFocused = false }
                }
                #endif
            }
            .alert("Rename Player", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let p = renaming {
                        let t = renameText.trimmingCharacters(in: .whitespaces)
                        if isNameTaken(t, excluding: p) {
                            DispatchQueue.main.async { duplicateName = t }
                        } else if !t.isEmpty {
                            p.name = t; saveContext(viewContext)
                        }
                    }
                }
            }
            .alert("Name Already Used", isPresented: Binding(
                get: { duplicateName != nil },
                set: { if !$0 { duplicateName = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A player named \(duplicateName ?? "") already exists. Use a different name so scores stay separate.")
            }
            .alert("Cannot Delete", isPresented: Binding(
                get: { deleteBlockedName != nil },
                set: { if !$0 { deleteBlockedName = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(deleteBlockedName ?? "") has game history. Players with recorded games cannot be deleted.")
            }
        }
    }

    private func isNameTaken(_ name: String, excluding: Player? = nil) -> Bool {
        roster.contains { $0 != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func addPlayer() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if isNameTaken(name) { duplicateName = name; return }
        let p = Player(context: viewContext)
        p.id = UUID()
        p.name = name
        p.createdAt = Date()
        // Pick the least-used palette color
        var counts = [Int](repeating: 0, count: PlayerColor.palette.count)
        for player in roster { counts[Int(player.colorIndex) % counts.count] += 1 }
        p.colorIndex = Int16(counts.firstIndex(of: counts.min() ?? 0) ?? 0)
        saveContext(viewContext)
        if selected.count < maxPlayers { selected.insert(p.id) }
        newName = ""
    }

    private func delete(_ player: Player) {
        if (player.games?.count ?? 0) > 0 || (player.wonRounds?.count ?? 0) > 0 {
            deleteBlockedName = player.name
            return
        }
        selected.remove(player.id)
        viewContext.delete(player)
        saveContext(viewContext)
    }

    private func startGame() {
        guard canStart, let points = betValue else { return }
        let game = Game(context: viewContext)
        game.id = UUID()
        game.startedAt = Date()
        game.betAmount = Double(min(maxPoints, max(1, points)))
        game.players = NSSet(array: roster.filter { selected.contains($0.id) })
        saveContext(viewContext)
        dismiss()
    }
}

// MARK: - Active game

enum GameViewMode: Hashable {
    case rounds, scoreboard
}

struct ActiveGameView: View {
    @Environment(\.managedObjectContext) private var viewContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    @ObservedObject var game: Game

    @State private var mode: GameViewMode = .rounds
    @State private var showingEndSheet = false
    @State private var confirmUndo = false
    @State private var confirmDiscard = false
    @State private var roundStamp = 0
    @State private var toast: String?
    @State private var lastTap = Date.distantPast

    /// True when iPadOS's floating tab bar overlays the content top edge.
    private var needsTabBarClearance: Bool {
        #if os(iOS)
        return hSizeClass == .regular
        #else
        return false
        #endif
    }

    var body: some View {
        // Discarding deletes `game`; don't touch its properties after that.
        if game.isDeleted || game.managedObjectContext == nil {
            Color.clear
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("View", selection: $mode) {
                Text("Rounds · \(game.sortedRounds.count)").tag(GameViewMode.rounds)
                Text("Scoreboard").tag(GameViewMode.scoreboard)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            // On iPad the floating tab bar overlays the top edge; drop below it
            .padding(.top, needsTabBarClearance ? 56 : 4)

            switch mode {
            case .rounds:
                RoundTable(game: game)
            case .scoreboard:
                ScrollView {
                    ScoreboardGrid(game: game)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                }
            }

            WinnerBar(
                game: game,
                onWin: { player in recordRound(winner: player) },
                menu: {
                    Menu {
                        if game.sortedRounds.isEmpty {
                            Button("Discard Game", role: .destructive) { confirmDiscard = true }
                        } else {
                            Button("Undo Last Round") { confirmUndo = true }
                            Button("End Game") { showingEndSheet = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 22))
                            .foregroundColor(.sikandarWine)
                            .frame(width: 44, height: 44)
                    }
                }
            )
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 14)
        }
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.sikandarWine.opacity(0.35)))
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.success, trigger: roundStamp)
        .confirmationDialog("Undo the last round?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo Last Round", role: .destructive) { undoLastRound() }
        }
        .confirmationDialog("Discard this game?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Game", role: .destructive) { discardGame() }
        } message: {
            Text("No rounds were recorded. The game will not appear in History or Stats.")
        }
        .sheet(isPresented: $showingEndSheet) {
            EndGameSheet(game: game)
        }
    }

    private func recordRound(winner: Player) {
        // Ignore a second tap within 400 ms — a double-tap must not record two rounds.
        let now = Date()
        guard now.timeIntervalSince(lastTap) > 0.4 else { return }
        lastTap = now

        let round = GameRound(context: viewContext)
        round.id = UUID()
        round.index = Int32(game.sortedRounds.count + 1)
        round.date = now
        round.winner = winner
        round.game = game
        saveContext(viewContext)

        roundStamp += 1
        showToast("Round \(round.index) · \(winner.name) wins")
    }

    private func showToast(_ text: String) {
        withAnimation(.snappy) { toast = text }
        let stamp = roundStamp
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if stamp == roundStamp { withAnimation(.easeOut) { toast = nil } }
        }
    }

    private func discardGame() {
        viewContext.delete(game)
        saveContext(viewContext)
    }

    private func undoLastRound() {
        guard let last = game.sortedRounds.last else { return }
        viewContext.delete(last)
        saveContext(viewContext)
    }
}

// MARK: - Scoreboard grid (Player / Won / Lost / Balance)

struct ScoreboardGrid: View {
    @ObservedObject var game: Game
    /// Detail/share views tint the leader's row; the live scoreboard stays flat.
    var tintLeader: Bool = false
    @ScaledMetric(relativeTo: .body) private var narrowCol: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var balanceCol: CGFloat = 80

    var body: some View {
        let balances = game.balances
        let totalRounds = game.sortedRounds.count
        // Leaderboard order: balance first, name as tiebreak
        let ranked = game.sortedPlayers.sorted {
            let a = balances[$0.id] ?? 0, b = balances[$1.id] ?? 0
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let topBalance = ranked.first.flatMap { balances[$0.id] } ?? 0
        let rowPadding: CGFloat = tintLeader ? 8 : 0
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                Text("Won").frame(width: narrowCol, alignment: .trailing)
                Text("Lost").frame(width: narrowCol, alignment: .trailing)
                Text("Balance").frame(width: balanceCol, alignment: .trailing)
            }
            .font(.headline)
            .padding(.vertical, 8)
            .padding(.horizontal, rowPadding)
            ForEach(ranked) { player in
                let wins = game.wins(for: player)
                let bal = balances[player.id] ?? 0
                let isLeader = bal == topBalance && bal > 0
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        PlayerDot(player: player)
                        Text(player.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isLeader {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.sikandarGold)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(wins)")
                        .frame(width: narrowCol, alignment: .trailing)
                    Text("\(totalRounds - wins)")
                        .foregroundColor(.secondary)
                        .frame(width: narrowCol, alignment: .trailing)
                    Text(signedPoints(bal))
                        .foregroundColor(bal < 0 ? .red : (bal > 0 ? .green : .primary))
                        .bold()
                        .frame(width: balanceCol, alignment: .trailing)
                }
                .font(.body.monospacedDigit())
                .padding(.vertical, 8)
                .padding(.horizontal, rowPadding)
                .background {
                    if tintLeader && isLeader {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.sikandarGold.opacity(0.16))
                    }
                }
            }
        }
    }
}

// MARK: - Winner bar (balanced rows of subtle full-color pills)

/// Splits `count` items into balanced rows of at most 3, rows differing by
/// at most one: 4 -> [2,2], 5 -> [3,2], 7 -> [3,2,2], 9 -> [3,3,3].
func balancedRows(_ count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let rows = Int(ceil(Double(count) / 3.0))
    let base = count / rows
    let extra = count % rows
    return (0..<rows).map { $0 < extra ? base + 1 : base }
}

struct WinnerBar<MenuContent: View>: View {
    @ObservedObject var game: Game
    let onWin: (Player) -> Void
    @ViewBuilder let menu: MenuContent

    private func rowSlices(_ players: [Player]) -> [[Player]] {
        var index = 0
        return balancedRows(players.count).map { size in
            defer { index += size }
            return Array(players[index..<(index + size)])
        }
    }

    var body: some View {
        let players = game.sortedPlayers
        let rowSlices = rowSlices(players)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TAP THE WINNER")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .kerning(0.4)
                Spacer()
                menu
            }

            ForEach(0..<rowSlices.count, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rowSlices[r]) { player in
                        Button {
                            onWin(player)
                        } label: {
                            Text(player.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundColor(player.color.label)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(player.color.fill)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Round table (pinned # / winner, scrollable player columns)

struct RoundTable: View {
    @ObservedObject var game: Game
    // Scaled with Dynamic Type so cells never clip at accessibility sizes.
    @ScaledMetric(relativeTo: .callout) private var rowHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .callout) private var indexW: CGFloat = 34
    @ScaledMetric(relativeTo: .callout) private var winnerW: CGFloat = 76
    @ScaledMetric(relativeTo: .callout) private var cellW: CGFloat = 64

    var body: some View {
        let players = game.sortedPlayers
        let rounds = game.sortedRounds
        let bet = game.bet
        // Cumulative balances per round
        var running: [UUID: Int] = Dictionary(uniqueKeysWithValues: players.map { ($0.id, 0) })
        let gain = (players.count - 1) * bet
        let rows: [(round: GameRound, balances: [UUID: Int])] = rounds.map { round in
            for p in players {
                running[p.id]! += (p.id == round.winner.id) ? gain : -bet
            }
            return (round, running)
        }

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    // Pinned columns: # and Winner
                    VStack(spacing: 0) {
                        HStack {
                            Text("#").frame(width: indexW, alignment: .trailing)
                            Text("Winner").frame(width: winnerW, alignment: .leading)
                        }
                        .font(.headline)
                        .frame(height: rowHeight)
                        ForEach(rows, id: \.round.id) { row in
                            HStack {
                                Text("\(row.round.index)")
                                    .frame(width: indexW, alignment: .trailing)
                                Text(row.round.winner.name)
                                    .lineLimit(1)
                                    .frame(width: winnerW, alignment: .leading)
                            }
                            .frame(height: rowHeight)
                        }
                    }

                    // Scrollable player columns
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(players) { p in
                                    Text(shortDisplayName(p.name, among: players.map { $0.name }))
                                        .font(.caption.weight(.bold))
                                        .lineLimit(1)
                                        .foregroundColor(p.color.ink)
                                        .frame(width: cellW, height: rowHeight, alignment: .trailing)
                                }
                            }
                            ForEach(rows, id: \.round.id) { row in
                                HStack(spacing: 0) {
                                    ForEach(players) { p in
                                        let bal = row.balances[p.id] ?? 0
                                        Text(signedPoints(bal))
                                            .font(.callout.monospacedDigit())
                                            .foregroundColor(bal == 0 ? .primary : (bal < 0 ? .red : .green))
                                            .frame(width: cellW, height: rowHeight, alignment: .trailing)
                                    }
                                }
                                .id(row.round.id)
                            }
                        }
                    }
                    // Cap at content width so the table centers instead of
                    // stretching; grows with player count until it must scroll.
                    .frame(maxWidth: CGFloat(players.count) * cellW)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: rows.count) {
                if let lastID = rows.last?.round.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - End game sheet (settlement)

struct EndGameSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var game: Game

    var body: some View {
        NavigationStack {
            let balancePairs = game.sortedPlayers.map { ($0, game.balances[$0.id] ?? 0) }
            let transfers = settle(balances: balancePairs)
            List {
                Section(header: Text("Final balances — \(game.sortedRounds.count) rounds")) {
                    ForEach(balancePairs, id: \.0.id) { player, bal in
                        HStack {
                            PlayerDot(player: player)
                            Text(player.name)
                            Spacer()
                            Text(signedPoints(bal))
                                .bold()
                                .foregroundColor(bal < 0 ? .red : (bal > 0 ? .green : .primary))
                        }
                    }
                }
                if !transfers.isEmpty {
                    Section(header: Text("Settlement"),
                            footer: Text(settlementSummary(transfers.count))) {
                        ForEach(transfers) { t in
                            HStack(spacing: 8) {
                                PlayerDot(player: t.from)
                                Text(t.from.name)
                                Image(systemName: "arrow.right")
                                    .foregroundColor(.secondary)
                                PlayerDot(player: t.to)
                                Text(t.to.name).bold()
                                Spacer()
                                Text(t.amount.formatted()).bold()
                                    .foregroundColor(.sikandarWine)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        game.endedAt = Date()
                        saveContext(viewContext)
                        dismiss()
                    } label: {
                        Text("Finish & Save Game")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                            .padding(.vertical, 12)
                            .background(Color.sikandarWineFill)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("End Game")
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Playing") { dismiss() }
                }
            }
        }
    }
}

// MARK: - History tab

struct HistoryTab: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Game.endedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default)
    private var games: FetchedResults<Game>

    private var grouped: [(day: String, games: [Game])] {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        var order: [String] = []
        var dict: [String: [Game]] = [:]
        for g in games {
            let key = fmt.string(from: g.endedAt ?? g.startedAt)
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(g)
        }
        return order.map { ($0, dict[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if games.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No finished games yet")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(grouped, id: \.day) { section in
                            Section(header: Text(section.day)) {
                                ForEach(section.games) { game in
                                    NavigationLink {
                                        GameDetailView(game: game)
                                    } label: {
                                        GameHistoryRow(game: game)
                                    }
                                    .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("History")
        }
    }
}

struct GameHistoryRow: View {
    @ObservedObject var game: Game

    private var playerList: String {
        game.sortedPlayers.map { $0.name }.joined(separator: ", ")
    }

    var body: some View {
        let balances = game.balances
        let top = game.sortedPlayers.max { (balances[$0.id] ?? 0) < (balances[$1.id] ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((game.endedAt ?? game.startedAt).formatted(date: .omitted, time: .shortened))
                    .font(.headline)
                Text("· \(game.sortedRounds.count) rounds · \(game.bet) pts/round")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(playerList)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let top = top, let bal = balances[top.id], bal > 0 {
                    Text("\(firstName(top.name)) \(signedPoints(bal))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Game detail (read-only)

/// Cumulative per-player balances after each round, plus zebra striping.
struct RoundBalanceRow: Identifiable {
    let round: GameRound
    let balances: [UUID: Int]
    let zebra: Bool
    var id: UUID { round.id }
}

func roundBalanceRows(for game: Game) -> [RoundBalanceRow] {
    let players = game.sortedPlayers
    let gain = (players.count - 1) * game.bet
    var running: [UUID: Int] = Dictionary(uniqueKeysWithValues: players.map { ($0.id, 0) })
    return game.sortedRounds.enumerated().map { i, round in
        for p in players {
            running[p.id]! += (p.id == round.winner.id) ? gain : -game.bet
        }
        return RoundBalanceRow(round: round, balances: running, zebra: i % 2 == 1)
    }
}

/// Opaque card background for the rounds section, split into a rounded top
/// (the pinned header) and rounded bottom (the rows). Opaque on purpose:
/// the pinned header must occlude rows scrolling beneath it.
struct RoundsCardBackground: View {
    var top: Bool

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top ? 14 : 0,
            bottomLeadingRadius: top ? 0 : 14,
            bottomTrailingRadius: top ? 0 : 14,
            topTrailingRadius: top ? 14 : 0)
        ZStack {
            shape.fill(.background)
            shape.fill(Color.primary.opacity(0.05))
        }
    }
}

/// Rounded card with a small caps title, used on the game detail screen.
struct DetailCard<Content: View>: View {
    let title: String
    var fill: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)
                .kerning(0.4)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(fill ?? Color.primary.opacity(0.05))
        )
    }
}

/// Settlement transfers: payer plain, receiver bold, amount in wine,
/// with a transfer-count summary underneath.
struct SettlementRows: View {
    let transfers: [Settlement]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transfers.isEmpty {
                Text("Everyone is even — nothing to settle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(transfers) { t in
                    HStack(spacing: 6) {
                        Text(t.from.name)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(t.to.name)
                            .bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 8)
                        Text(t.amount.formatted())
                            .bold()
                            .monospacedDigit()
                            .foregroundColor(.sikandarWine)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 6)
                }
                Divider().padding(.top, 4)
                Text(settlementSummary(transfers.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

/// Column metrics for the detail rounds tables, scaled with Dynamic Type.
struct RoundsTableMetrics {
    var scale: CGFloat = 1
    var indexWidth: CGFloat { 30 * scale }
    var winnerWidth: CGFloat { 76 * scale }
    var cellWidth: CGFloat { 56 * scale }
    var rowHeight: CGFloat { 28 * scale }

    func tableWidth(players: Int) -> CGFloat {
        indexWidth + 8 + winnerWidth + CGFloat(players) * cellWidth
    }
}

/// Header row of the detail rounds table (player names in their colors).
struct DetailRoundsHeader: View {
    @ObservedObject var game: Game
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    var body: some View {
        let m = RoundsTableMetrics(scale: scale)
        let players = game.sortedPlayers
        let names = players.map { $0.name }
        HStack(spacing: 0) {
            Text("#").frame(width: m.indexWidth, alignment: .trailing)
            Text("Winner")
                .frame(width: m.winnerWidth, alignment: .leading)
                .padding(.leading, 8)
            ForEach(players) { p in
                Text(shortDisplayName(p.name, among: names))
                    .lineLimit(1)
                    .foregroundColor(p.color.ink)
                    .frame(width: m.cellWidth, alignment: .trailing)
            }
        }
        .font(.caption.weight(.bold))
        .frame(height: m.rowHeight)
    }
}

/// Body rows of the detail rounds table, zebra striped.
struct DetailRoundRows: View {
    @ObservedObject var game: Game
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    var body: some View {
        let m = RoundsTableMetrics(scale: scale)
        let players = game.sortedPlayers
        let names = players.map { $0.name }
        let rows = roundBalanceRows(for: game)
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    Text("\(row.round.index)")
                        .foregroundColor(.secondary)
                        .frame(width: m.indexWidth, alignment: .trailing)
                    Text(shortDisplayName(row.round.winner.name, among: names))
                        .lineLimit(1)
                        .frame(width: m.winnerWidth, alignment: .leading)
                        .padding(.leading, 8)
                    ForEach(players) { p in
                        let bal = row.balances[p.id] ?? 0
                        Text(signedPoints(bal))
                            .foregroundColor(bal == 0 ? .primary : (bal < 0 ? .red : .green))
                            .frame(width: m.cellWidth, alignment: .trailing)
                    }
                }
                .font(.callout.monospacedDigit())
                .frame(height: m.rowHeight)
                .background {
                    if row.zebra {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.04))
                    }
                }
            }
        }
    }
}

struct GameDetailView: View {
    @ObservedObject var game: Game
    @State private var shareImage: Image?
    @ScaledMetric(relativeTo: .callout) private var tableScale: CGFloat = 1

    var body: some View {
        let players = game.sortedPlayers
        let balancePairs = players.map { ($0, game.balances[$0.id] ?? 0) }
        let transfers = settle(balances: balancePairs)
        let shareTitle = "Sikandar — \((game.endedAt ?? game.startedAt).formatted(date: .abbreviated, time: .shortened))"

        GeometryReader { geo in
            let contentWidth = max(300, min(geo.size.width - 32, 880))
            // Scorecard 2/3 beside Settlement 1/3 when there is room;
            // stacked on compact widths (iPhone portrait, narrow splits).
            let sideBySide = contentWidth >= 560
            // The table now lives inside the rounds card, so it must fit
            // within the card's content area (card width minus padding).
            let tableFits = RoundsTableMetrics(scale: tableScale).tableWidth(players: players.count) <= contentWidth - 28

            ScrollView {
                // spacing: 0 so the rounds card's pinned header and its rows
                // join without a seam; gaps are explicit paddings instead.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Text("\(game.sortedRounds.count) rounds · \(game.bet) pts/round · \(players.count) players")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 14)

                    Group {
                        if sideBySide {
                            HStack(alignment: .top, spacing: 14) {
                                DetailCard(title: "SCORECARD") {
                                    ScoreboardGrid(game: game, tintLeader: true)
                                }
                                .frame(width: (contentWidth - 14) * 2 / 3)
                                DetailCard(title: "SETTLEMENT") {
                                    SettlementRows(transfers: transfers)
                                }
                                .frame(width: (contentWidth - 14) / 3)
                            }
                        } else {
                            VStack(spacing: 14) {
                                DetailCard(title: "SCORECARD") {
                                    ScoreboardGrid(game: game, tintLeader: true)
                                }
                                DetailCard(title: "SETTLEMENT") {
                                    SettlementRows(transfers: transfers)
                                }
                            }
                            .frame(width: contentWidth)
                        }
                    }
                    .padding(.bottom, 14)

                    Section {
                        Group {
                            if tableFits {
                                DetailRoundRows(game: game)
                            } else {
                                // Too wide for the screen: pinned #/Winner columns,
                                // player columns scroll sideways.
                                SplitRoundsTable(game: game)
                                    .frame(width: contentWidth - 28)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .frame(width: contentWidth)
                        .background(RoundsCardBackground(top: false))
                    } header: {
                        VStack(spacing: 6) {
                            Text("ROUNDS")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                                .kerning(0.4)
                                .frame(maxWidth: .infinity)
                            if tableFits {
                                DetailRoundsHeader(game: game)
                            }
                        }
                        .padding(.top, 14)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                        .frame(width: contentWidth)
                        .background(RoundsCardBackground(top: true))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle((game.endedAt ?? game.startedAt).formatted(date: .abbreviated, time: .shortened))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let image = shareImage {
                    ShareLink(item: image,
                              preview: SharePreview(shareTitle, image: image)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { renderShareImage() }
    }

    /// Renders the entire game (scorecard, settlement, every round) as one
    /// image, so sharing never depends on what is scrolled into view.
    @MainActor
    private func renderShareImage() {
        let renderer = ImageRenderer(content: GameShareView(game: game))
        renderer.scale = 2
        #if os(iOS)
        if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
        #else
        if let ns = renderer.nsImage { shareImage = Image(nsImage: ns) }
        #endif
    }
}

/// Rounds table for widths where the full table cannot fit: the # and
/// Winner columns stay pinned, player columns scroll horizontally.
struct SplitRoundsTable: View {
    @ObservedObject var game: Game
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    var body: some View {
        let m = RoundsTableMetrics(scale: scale)
        let players = game.sortedPlayers
        let names = players.map { $0.name }
        let rows = roundBalanceRows(for: game)
        let h = m.rowHeight
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("#").frame(width: m.indexWidth, alignment: .trailing)
                    Text("Winner")
                        .frame(width: m.winnerWidth, alignment: .leading)
                        .padding(.leading, 8)
                }
                .font(.caption.weight(.bold))
                .frame(height: h)
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text("\(row.round.index)")
                            .foregroundColor(.secondary)
                            .frame(width: m.indexWidth, alignment: .trailing)
                        Text(shortDisplayName(row.round.winner.name, among: names))
                            .lineLimit(1)
                            .frame(width: m.winnerWidth, alignment: .leading)
                            .padding(.leading, 8)
                    }
                    .font(.callout.monospacedDigit())
                    .frame(height: h)
                    .background { if row.zebra { Rectangle().fill(Color.primary.opacity(0.04)) } }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(players) { p in
                            Text(shortDisplayName(p.name, among: names))
                                .lineLimit(1)
                                .foregroundColor(p.color.ink)
                                .frame(width: m.cellWidth, alignment: .trailing)
                        }
                    }
                    .font(.caption.weight(.bold))
                    .frame(height: h)
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            ForEach(players) { p in
                                let bal = row.balances[p.id] ?? 0
                                Text(signedPoints(bal))
                                    .foregroundColor(bal == 0 ? .primary : (bal < 0 ? .red : .green))
                                    .frame(width: m.cellWidth, alignment: .trailing)
                            }
                        }
                        .font(.callout.monospacedDigit())
                        .frame(height: h)
                        .background { if row.zebra { Rectangle().fill(Color.primary.opacity(0.04)) } }
                    }
                }
            }
        }
    }
}

/// Fixed-size, always-light rendition of a finished game for sharing:
/// header, scorecard + settlement side by side, and the complete rounds
/// table with no scrolling.
struct GameShareView: View {
    @ObservedObject var game: Game

    var body: some View {
        let players = game.sortedPlayers
        let balancePairs = players.map { ($0, game.balances[$0.id] ?? 0) }
        let transfers = settle(balances: balancePairs)
        let tableWidth = RoundsTableMetrics().tableWidth(players: players.count)
        let width = max(640, tableWidth + 96)
        let cardsWidth = width - 40

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sikandar")
                    .font(.title2.bold())
                    .foregroundColor(.sikandarWine)
                Image(systemName: "crown.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.sikandarGold)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text((game.endedAt ?? game.startedAt).formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                    Text("\(game.sortedRounds.count) rounds · \(game.bet) pts/round")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                DetailCard(title: "SCORECARD", fill: .white) {
                    ScoreboardGrid(game: game, tintLeader: true)
                }
                .frame(width: (cardsWidth - 14) * 2 / 3)
                DetailCard(title: "SETTLEMENT", fill: .white) {
                    SettlementRows(transfers: transfers)
                }
                .frame(width: (cardsWidth - 14) / 3)
            }
            DetailCard(title: "ROUNDS", fill: .white) {
                VStack(spacing: 0) {
                    DetailRoundsHeader(game: game)
                    DetailRoundRows(game: game)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: width)
        .background(Color(hex: 0xF6F4F1))
        .environment(\.colorScheme, .light)
        // Fixed-size render: pin text size so the table metrics match.
        .environment(\.dynamicTypeSize, .large)
    }
}

// MARK: - Stats tab

enum StatsRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "Week", month = "Month", allTime = "All Time"
    var id: String { rawValue }

    var startDate: Date? {
        switch self {
        case .today: return Calendar.current.startOfDay(for: Date())
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: return Calendar.current.date(byAdding: .month, value: -1, to: Date())
        case .allTime: return nil
        }
    }
}

struct StatsTab: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    private var needsTabBarClearance: Bool {
        #if os(iOS)
        return hSizeClass == .regular
        #else
        return false
        #endif
    }

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Game.endedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default)
    private var games: FetchedResults<Game>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Player.name, ascending: true)],
        animation: .default)
    private var players: FetchedResults<Player>

    @State private var range: StatsRange = .allTime
    @ScaledMetric(relativeTo: .body) private var gamesCol: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var roundsCol: CGFloat = 54
    @ScaledMetric(relativeTo: .body) private var winsCol: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var netCol: CGFloat = 60

    private var filteredGames: [Game] {
        guard let start = range.startDate else { return Array(games) }
        return games.filter { ($0.endedAt ?? $0.startedAt) >= start }
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.top, needsTabBarClearance ? 56 : 10)

                let stats = computeStats()
                if stats.isEmpty {
                    Spacer()
                    Text("No games in this period")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        Section {
                            // Header as a row so its columns share the rows' insets
                            HStack {
                                Text("Player")
                                Spacer()
                                Text("Games").frame(width: gamesCol, alignment: .trailing)
                                Text("Played").frame(width: roundsCol, alignment: .trailing)
                                Text("Wins").frame(width: winsCol, alignment: .trailing)
                                Text("Net").frame(width: netCol, alignment: .trailing)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .listRowSeparator(.hidden)
                            ForEach(stats, id: \.player.id) { s in
                                HStack {
                                    PlayerDot(player: s.player)
                                    Text(s.player.name).lineLimit(1)
                                    Spacer()
                                    Text("\(s.games)")
                                        .frame(width: gamesCol, alignment: .trailing)
                                    Text("\(s.rounds)")
                                        .foregroundColor(.secondary)
                                        .frame(width: roundsCol, alignment: .trailing)
                                    Text("\(s.wins)")
                                        .frame(width: winsCol, alignment: .trailing)
                                    Text(signedPoints(s.net))
                                        .bold()
                                        .foregroundColor(s.net < 0 ? .red : (s.net > 0 ? .green : .primary))
                                        .frame(width: netCol, alignment: .trailing)
                                }
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    // Own background so the grouped grey doesn't stop at the width cap on iPad.
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
            }
            #if os(iOS)
            .background(Color(uiColor: .systemGroupedBackground))
            #endif
            .navigationTitle("Stats")
        }
    }

    private struct PlayerStats {
        let player: Player
        var games = 0
        var rounds = 0
        var wins = 0
        var net = 0
    }

    private func computeStats() -> [PlayerStats] {
        var byPlayer: [UUID: PlayerStats] = [:]
        for game in filteredGames {
            let balances = game.balances
            for p in game.sortedPlayers {
                var s = byPlayer[p.id] ?? PlayerStats(player: p)
                s.games += 1
                s.rounds += game.sortedRounds.count
                s.wins += game.wins(for: p)
                s.net += balances[p.id] ?? 0
                byPlayer[p.id] = s
            }
        }
        return byPlayer.values.sorted { $0.net > $1.net }
    }
}
