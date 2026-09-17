<p align="center">
  <img src="Sikandar/Assets.xcassets/AppIcon.appiconset/icon-256.png" width="128" alt="Sikandar app icon">
</p>

<h1 align="center">Sikandar</h1>

<p align="center"><em>A score tracker for group games with two or more players.</em></p>

Sikandar keeps score for table games where everyone antes and one person wins each round — think teen patti nights with friends. Track every round, see running totals, and when the game ends, Sikandar shows the final settlement so everyone knows exactly where they stand. No more pen and paper, no more arguments.

**Sikandar does not handle any payments or real money. It only keeps score.**

## Screenshots

| New Game | Live Rounds | Scoreboard |
|:---:|:---:|:---:|
| ![New game](screenshots/new-game.png) | ![Rounds](screenshots/game-rounds.png) | ![Scoreboard](screenshots/game-scoreboard.png) |

| Settlement | History | Game Detail | Stats |
|:---:|:---:|:---:|:---:|
| ![End game](screenshots/end-game.png) | ![History](screenshots/history.png) | ![Detail](screenshots/game-detail.png) | ![Stats](screenshots/stats.png) |

## Features

- **One-tap scoring** — tap the round winner's pill and the table updates. The winner gains `(players − 1) × points`, everyone else loses the round's points.
- **Two views, one switch** — a segmented control flips between the round-by-round table (with cumulative balances per player) and a balance-sorted scoreboard with a crown on the leader.
- **2 to 9 players** — winner pills lay out in balanced rows of at most three, so the bar stays tidy at any size. Long names shorten to their shortest unique prefix; names of 8 characters or fewer always show in full.
- **Player colors** — each player gets a muted identity color used consistently across the winner bar, table headers, and history.
- **Deliberate game flow** — starting a game goes through a roster sheet (add, rename, select players; set points per round), and ending one shows the settlement before saving. No accidental taps.
- **Minimal settlement** — game end computes the fewest transfers that square everyone up ("Sameer → Maitri 200").
- **History** — every finished game is archived by date with its full scoreboard, settlement, and round table.
- **Stats** — per-player games, wins, and net across Today / Week / Month / All Time.
- **Undo** — the last round can be undone (with confirmation) at any point; balances are always recomputed from rounds, so totals can never drift.

## Building

Open `Sikandar.xcodeproj` in Xcode and run. The app targets iOS (primary), with macOS and visionOS also enabled. No dependencies beyond SwiftUI and Core Data.

The data model (`Player`, `Game`, `GameRound`) lives in `Sikandar/Sikandar.xcdatamodeld`; all UI is in a single SwiftUI file, `Sikandar/sikandar-game-tracker-ui-flexible.swift`.

## Notes

- Player roster is global; a player with recorded games cannot be deleted.
- The New Game sheet pre-selects the previous game's players and points.
- Scores are abstract points with no currency — settle however your table likes.
