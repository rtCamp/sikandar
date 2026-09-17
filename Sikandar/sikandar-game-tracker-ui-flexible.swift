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

extension Color {
    static let sikandarWine  = Color(red: 0x84/255, green: 0x14/255, blue: 0x48/255)
    static let sikandarGold  = Color(red: 0xE9/255, green: 0xB4/255, blue: 0x4C/255)
    static let sikandarCream = Color(red: 0xF5/255, green: 0xEF/255, blue: 0xE2/255)

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF)/255,
                  green: Double((hex >> 8) & 0xFF)/255,
                  blue: Double(hex & 0xFF)/255)
    }
}

/// Muted player identity colors: a light fill with a darker label of the
/// same hue — full color without shouting over the red/green money signals.
struct PlayerColor {
    let fill: Color
    let label: Color

    static let palette: [PlayerColor] = [
        PlayerColor(fill: Color(hex: 0xECD9CF), label: Color(hex: 0x7A4A33)),  // terracotta
        PlayerColor(fill: Color(hex: 0xDBE4D5), label: Color(hex: 0x4A5F42)),  // sage
        PlayerColor(fill: Color(hex: 0xD6E0EA), label: Color(hex: 0x3D5A78)),  // powder blue
        PlayerColor(fill: Color(hex: 0xE6D7E3), label: Color(hex: 0x6E4A68)),  // mauve
        PlayerColor(fill: Color(hex: 0xECDFC6), label: Color(hex: 0x77602C)),  // sand
        PlayerColor(fill: Color(hex: 0xD0E1E0), label: Color(hex: 0x3A6360)),  // sea teal
        PlayerColor(fill: Color(hex: 0xEAD4DD), label: Color(hex: 0x7C2B4E)),  // dusty wine
        PlayerColor(fill: Color(hex: 0xE2E2CD), label: Color(hex: 0x5C5C31)),  // olive
        PlayerColor(fill: Color(hex: 0xDCDEE4), label: Color(hex: 0x4C5160)),  // slate
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

/// Display name for tight spaces: full if 8 chars or fewer, otherwise the
/// shortest prefix that stays unique among `others`, with an ellipsis.
func shortDisplayName(_ name: String, among others: [String]) -> String {
    if name.count <= 8 { return name }
    let rivals = others.filter { $0 != name }
    for len in 3...8 {
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
            .fill(player.color.label)
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
                    .background(Color.sikandarWine)
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
        let shorts = names.map { shortDisplayName($0, among: names) }
        return "\(shorts.joined(separator: ", ")) · \(game.sortedRounds.count) rounds"
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
    @State private var bet = 100
    @State private var renaming: Player?
    @State private var renameText = ""
    @State private var deleteBlockedName: String?
    @State private var didPrefill = false

    private let minPlayers = 2
    private let maxPlayers = 9

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Players (select \(minPlayers) to \(maxPlayers))")) {
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

                Section {
                    HStack {
                        Text("Points per round")
                        Spacer()
                        TextField("100", value: $bet, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .font(.body.monospacedDigit())
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                    }
                }

                Section {
                    Button {
                        startGame()
                    } label: {
                        Text(selected.count >= minPlayers
                             ? "Start Game with \(selected.count) Players"
                             : "Select at least \(minPlayers) players (max \(maxPlayers))")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                            .padding(.vertical, 12)
                            .background(selected.count >= minPlayers ? Color.sikandarWine : Color.gray.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(selected.count < minPlayers)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("New Game")
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 560)
            #endif
            .onAppear {
                // Prefill with the previous game's players and bet
                guard !didPrefill else { return }
                didPrefill = true
                if let last = previousGames.first {
                    let rosterIDs = Set(roster.map { $0.id })
                    selected = Set(last.sortedPlayers.map { $0.id }).intersection(rosterIDs)
                    bet = last.bet
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
                        if !t.isEmpty { p.name = t; saveContext(viewContext) }
                    }
                }
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

    private func addPlayer() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
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
        let game = Game(context: viewContext)
        game.id = UUID()
        game.startedAt = Date()
        game.betAmount = Double(max(1, bet))
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

    /// True when iPadOS's floating tab bar overlays the content top edge.
    private var needsTabBarClearance: Bool {
        #if os(iOS)
        return hSizeClass == .regular
        #else
        return false
        #endif
    }

    var body: some View {
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
                        Button("Undo Last Round") { confirmUndo = true }
                            .disabled(game.sortedRounds.isEmpty)
                        Button("End Game") { showingEndSheet = true }
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
        .confirmationDialog("Undo the last round?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo Last Round", role: .destructive) { undoLastRound() }
        }
        .sheet(isPresented: $showingEndSheet) {
            EndGameSheet(game: game)
        }
    }

    private func recordRound(winner: Player) {
        let round = GameRound(context: viewContext)
        round.id = UUID()
        round.index = Int32(game.sortedRounds.count + 1)
        round.date = Date()
        round.winner = winner
        round.game = game
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
                Text("Won").frame(width: 44, alignment: .trailing)
                Text("Lost").frame(width: 44, alignment: .trailing)
                Text("Balance").frame(width: 80, alignment: .trailing)
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
                        .frame(width: 44, alignment: .trailing)
                    Text("\(totalRounds - wins)")
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(bal.formatted())
                        .foregroundColor(bal < 0 ? .red : (bal > 0 ? .green : .primary))
                        .bold()
                        .frame(width: 80, alignment: .trailing)
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
        let names = players.map { $0.name }
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
                            Text(shortDisplayName(player.name, among: names))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .foregroundColor(player.color.label)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(player.color.fill)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Round table (pinned # / winner, scrollable player columns)

struct RoundTable: View {
    @ObservedObject var game: Game
    var rowHeight: CGFloat = 28

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
                            Text("#").frame(width: 34, alignment: .trailing)
                            Text("Winner").frame(width: 76, alignment: .leading)
                        }
                        .font(.headline)
                        .frame(height: rowHeight)
                        ForEach(rows, id: \.round.id) { row in
                            HStack {
                                Text("\(row.round.index)")
                                    .frame(width: 34, alignment: .trailing)
                                Text(row.round.winner.name)
                                    .lineLimit(1)
                                    .frame(width: 76, alignment: .leading)
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
                                        .foregroundColor(p.color.label)
                                        .frame(width: 64, height: rowHeight, alignment: .trailing)
                                }
                            }
                            ForEach(rows, id: \.round.id) { row in
                                HStack(spacing: 0) {
                                    ForEach(players) { p in
                                        let bal = row.balances[p.id] ?? 0
                                        Text(bal == 0 ? "0" : String(format: "%+d", bal))
                                            .font(.callout.monospacedDigit())
                                            .foregroundColor(bal == 0 ? .primary : (bal < 0 ? .red : .green))
                                            .frame(width: 64, height: rowHeight, alignment: .trailing)
                                    }
                                }
                                .id(row.round.id)
                            }
                        }
                    }
                    // Cap at content width so the table centers instead of
                    // stretching; grows with player count until it must scroll.
                    .frame(maxWidth: CGFloat(players.count) * 64)
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
                            Text(bal.formatted())
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
                            .background(Color.sikandarWine)
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
        let names = game.sortedPlayers.map { $0.name }
        return names.map { shortDisplayName($0, among: names) }.joined(separator: ", ")
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
            HStack(spacing: 5) {
                Text(playerList)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                if let top = top, let bal = balances[top.id], bal > 0 {
                    Text("\(top.name) +\(bal)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)
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
    let playerNames: [String]

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
                        Text(shortDisplayName(t.from.name, among: playerNames))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(shortDisplayName(t.to.name, among: playerNames))
                            .bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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

/// Shared column metrics for the detail rounds table.
enum RoundsTableMetrics {
    static let indexWidth: CGFloat = 30
    static let winnerWidth: CGFloat = 76
    static let cellWidth: CGFloat = 56
    static let rowHeight: CGFloat = 28

    static func tableWidth(players: Int) -> CGFloat {
        indexWidth + 8 + winnerWidth + CGFloat(players) * cellWidth
    }
}

/// Header row of the detail rounds table (player names in their colors).
struct DetailRoundsHeader: View {
    @ObservedObject var game: Game

    var body: some View {
        let players = game.sortedPlayers
        let names = players.map { $0.name }
        HStack(spacing: 0) {
            Text("#").frame(width: RoundsTableMetrics.indexWidth, alignment: .trailing)
            Text("Winner")
                .frame(width: RoundsTableMetrics.winnerWidth, alignment: .leading)
                .padding(.leading, 8)
            ForEach(players) { p in
                Text(shortDisplayName(p.name, among: names))
                    .lineLimit(1)
                    .foregroundColor(p.color.label)
                    .frame(width: RoundsTableMetrics.cellWidth, alignment: .trailing)
            }
        }
        .font(.caption.weight(.bold))
        .frame(height: RoundsTableMetrics.rowHeight)
    }
}

/// Body rows of the detail rounds table, zebra striped.
struct DetailRoundRows: View {
    @ObservedObject var game: Game

    var body: some View {
        let players = game.sortedPlayers
        let names = players.map { $0.name }
        let rows = roundBalanceRows(for: game)
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    Text("\(row.round.index)")
                        .foregroundColor(.secondary)
                        .frame(width: RoundsTableMetrics.indexWidth, alignment: .trailing)
                    Text(shortDisplayName(row.round.winner.name, among: names))
                        .lineLimit(1)
                        .frame(width: RoundsTableMetrics.winnerWidth, alignment: .leading)
                        .padding(.leading, 8)
                    ForEach(players) { p in
                        let bal = row.balances[p.id] ?? 0
                        Text(bal == 0 ? "0" : String(format: "%+d", bal))
                            .foregroundColor(bal == 0 ? .primary : (bal < 0 ? .red : .green))
                            .frame(width: RoundsTableMetrics.cellWidth, alignment: .trailing)
                    }
                }
                .font(.callout.monospacedDigit())
                .frame(height: RoundsTableMetrics.rowHeight)
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

    var body: some View {
        let players = game.sortedPlayers
        let names = players.map { $0.name }
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
            let tableFits = RoundsTableMetrics.tableWidth(players: players.count) <= contentWidth - 28

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
                                    SettlementRows(transfers: transfers, playerNames: names)
                                }
                                .frame(width: (contentWidth - 14) / 3)
                            }
                        } else {
                            VStack(spacing: 14) {
                                DetailCard(title: "SCORECARD") {
                                    ScoreboardGrid(game: game, tintLeader: true)
                                }
                                DetailCard(title: "SETTLEMENT") {
                                    SettlementRows(transfers: transfers, playerNames: names)
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

    var body: some View {
        let players = game.sortedPlayers
        let names = players.map { $0.name }
        let rows = roundBalanceRows(for: game)
        let h = RoundsTableMetrics.rowHeight
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("#").frame(width: RoundsTableMetrics.indexWidth, alignment: .trailing)
                    Text("Winner")
                        .frame(width: RoundsTableMetrics.winnerWidth, alignment: .leading)
                        .padding(.leading, 8)
                }
                .font(.caption.weight(.bold))
                .frame(height: h)
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text("\(row.round.index)")
                            .foregroundColor(.secondary)
                            .frame(width: RoundsTableMetrics.indexWidth, alignment: .trailing)
                        Text(shortDisplayName(row.round.winner.name, among: names))
                            .lineLimit(1)
                            .frame(width: RoundsTableMetrics.winnerWidth, alignment: .leading)
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
                                .foregroundColor(p.color.label)
                                .frame(width: RoundsTableMetrics.cellWidth, alignment: .trailing)
                        }
                    }
                    .font(.caption.weight(.bold))
                    .frame(height: h)
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            ForEach(players) { p in
                                let bal = row.balances[p.id] ?? 0
                                Text(bal == 0 ? "0" : String(format: "%+d", bal))
                                    .foregroundColor(bal == 0 ? .primary : (bal < 0 ? .red : .green))
                                    .frame(width: RoundsTableMetrics.cellWidth, alignment: .trailing)
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
        let names = players.map { $0.name }
        let balancePairs = players.map { ($0, game.balances[$0.id] ?? 0) }
        let transfers = settle(balances: balancePairs)
        let tableWidth = RoundsTableMetrics.tableWidth(players: players.count)
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
                    SettlementRows(transfers: transfers, playerNames: names)
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
                                Text("Games").frame(width: 48, alignment: .trailing)
                                Text("Rounds").frame(width: 54, alignment: .trailing)
                                Text("Wins").frame(width: 40, alignment: .trailing)
                                Text("Net").frame(width: 60, alignment: .trailing)
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
                                        .frame(width: 48, alignment: .trailing)
                                    Text("\(s.rounds)")
                                        .foregroundColor(.secondary)
                                        .frame(width: 54, alignment: .trailing)
                                    Text("\(s.wins)")
                                        .frame(width: 40, alignment: .trailing)
                                    Text(s.net.formatted())
                                        .bold()
                                        .foregroundColor(s.net < 0 ? .red : (s.net > 0 ? .green : .primary))
                                        .frame(width: 60, alignment: .trailing)
                                }
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                }
            }
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
