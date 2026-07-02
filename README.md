# StockBar

A native macOS menu-bar app that shows your A-share / ETF watchlist with **inline minute-level sparklines** (Stats-style), a per-symbol intraday chart on click, and **Touch Bar integration** for MacBook Pro users.

![Menu Bar Popover](docs/images/menubar-popover.png)

## Features

- **Menu Bar Integration** — Persistent status icon with expandable popover showing your full watchlist
- **Touch Bar Support** — Real-time quotes and intraday charts directly on your MacBook Pro's Touch Bar with intelligent scrolling and sorting
- **Inline Sparklines** — Stats-style minute-level trend visualization for each symbol
- **Interactive Charts** — Click any row to expand a full intraday chart (09:30–15:00)
- **Pure Swift + AppKit** — No Xcode project needed at runtime, no Electron, no Python
- **Lightweight** — ~80 MB RSS, runs as menu-bar agent (no Dock icon)
- **Trading-Session Aware** — Refreshes every 5s during live session, slows to 60s during lunch/pre-/post-market, and sleeps to 600s on weekends
- **Live Reload** — Watches `watchlist.json` for changes; any external edit triggers immediate refresh

---

## Screenshots

### Menu Bar Popover

The popover shows your full watchlist with:
- Current market phase indicator (盘前 / ● 上午盘 / 午休 / ● 下午盘 / 已收盘 / 周末休市)
- Per-symbol: alias · 6-digit code · price · today's % change · mini sparkline
- Click any row to expand the full intraday chart below
- Header buttons: `⟳` refresh, `📄` open watchlist.json, `⏻` quit

### Touch Bar

![Touch Bar - Quotes List](docs/images/touchbar-1.png)

Real-time quotes in a horizontal scrubber with intelligent scroll position preservation.

![Touch Bar - Intraday Chart](docs/images/touchbar-2.png)

Tap any symbol to see its full intraday chart directly on the Touch Bar.

![Touch Bar - Sorting](docs/images/touchbar-3.png)

Sort button cycles through: **list order** → **gainers first** → **losers first** → back to list order.

---

## Build

Requires the Xcode toolchain. The included script defaults to the external Xcode at `/Volumes/disk/Applications/Xcode.app`; override with `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` if yours lives elsewhere.

```bash
./scripts/make-app.sh           # release build → ./build/StockBar.app
./scripts/make-app.sh debug     # debug build (faster, larger)
```

Run:

```bash
open ./build/StockBar.app
```

Stop:

```bash
# either Quit (the ⏻ icon in the popover header), or:
pkill -f 'StockBar.app/Contents/MacOS/StockBar'
```

Install (optional):

```bash
cp -R ./build/StockBar.app /Applications/
```

To launch at login: drag `StockBar.app` into **System Settings → General → Login Items**.

---

## Interaction

### Menu Bar

- Click the menu-bar icon → popover opens with the full watchlist
- Each row shows: alias · 6-digit code · price · today's % change · mini sparkline
- **Click a row** → a full-size intraday chart for that symbol expands below the list. Click the same row again to collapse
- Click outside the popover (or anywhere in another app) → popover closes
- Header buttons:
  - `⟳` — force a refresh now
  - `📄` — open `watchlist.json` in your default editor
  - `⏻` — quit StockBar

### Touch Bar (MacBook Pro)

- **Scrubber** — Horizontal scrollable list showing all symbols with real-time prices and % changes
- **Tap any symbol** → opens a modal Touch Bar view with the full intraday chart
- **Sort button** — Cycles through three modes:
  1. **List order** — as defined in `watchlist.json`
  2. **Gainers first** — symbols sorted by % change descending (red on top)
  3. **Losers first** — symbols sorted by % change ascending (green on top)
- **Scroll position preservation** — The scrubber intelligently maintains your scroll position across refreshes, resetting only when you change sorting mode
- **System close button** — Native macOS close box on the left to exit chart view

The Touch Bar automatically appears when StockBar is running and updates in sync with the menu-bar popover.

---

## Configuration

By default, StockBar reads:

```text
~/.config/stockbar/watchlist.json
```

You can edit the JSON directly with any text editor. The menu-bar app **watches the file**: any external edit reloads the watchlist and triggers an immediate refresh — no app restart needed.

### Schema

```json
{
  "refresh_seconds": 5,
  "active_group": "default",
  "groups": {
    "default": [
      { "code": "000001", "alias": "沪指" },
      { "code": "159770", "alias": "机器人" }
    ]
  }
}
```

- `refresh_seconds` — base polling interval during the live session. StockBar automatically stretches this to 60s during lunch / pre-/post-market and 600s on weekends
- `code` — 6-digit code. Prefix is auto-inferred (`5/6/9 → sh`, else `sz`)
- `symbol` — optional explicit prefix override, e.g. `"sh000001"`
- `alias` — short label shown on the row

---

## How it works

```
       ┌──────────────────────────┐
       │  watchlist.json          │ ◀── your editor
       └──────────┬───────────────┘
                  │  DispatchSource file watcher
                  ▼
       ┌──────────────────────────┐
       │  AppDelegate (MainActor) │
       └──┬───────────────┬───────┘
          │ symbols       │ on selection / on open
          ▼               ▼
   ┌─────────────┐  ┌──────────────────┐
   │QuoteFetcher │  │  MinuteFetcher   │
   │qt.gtimg.cn  │  │ web.ifzq.gtimg…  │
   │   (GBK)     │  │     (JSON)       │
   └──────┬──────┘  └────────┬─────────┘
          │ Quote             │ [MinutePoint]
          ▼                   ▼
       ┌──────────────────────────┐
       │   PopoverController       │
       │  (rows + ChartView .mini  │
       │   inline + ChartView .full│
       │   for the selected row)   │
       └──────────────────────────┘
                  │
                  ▼
       ┌──────────────────────────┐
       │   TouchBarController      │
       │  (scrubber + modal chart) │
       └──────────────────────────┘
```

- Tencent's snapshot endpoint returns **GBK**-encoded text. We decode with `CFStringConvertEncodingToNSStringEncoding(GB_18030_2000)` and parse the `~`-separated payload
- The minute endpoint returns plain JSON; lines look like `"0930 4117.79 5811064 16173033562.60"`. We compress the lunch break (11:30–13:00) on the x-axis so the chart reads naturally
- `MarketHours` decides the refresh cadence so the app is quiet outside trading hours
- Touch Bar scrubber intelligently preserves scroll position across refreshes — only resets when sorting mode changes
- Everything UI-side is `@MainActor`; fetchers are `async` over an ephemeral `URLSession`

---

## Layout

```
stock-desktop/
├── Package.swift                       # SPM manifest
├── Sources/StockBar/
│   ├── AppDelegate.swift               # NSStatusItem, NSPopover, Touch Bar, refresh loops
│   ├── PopoverController.swift         # NSViewController for the popover content
│   ├── WatchlistRowView.swift          # one row: labels + mini sparkline
│   ├── ChartView.swift                 # NSBezierPath line/area chart (mini & full)
│   ├── QuoteFetcher.swift              # Tencent snapshot endpoint + GBK + regex parse
│   ├── MinuteFetcher.swift             # Tencent intraday minute endpoint + JSON
│   ├── MarketHours.swift               # CN A-share session phases
│   ├── WatchlistStore.swift            # JSON load + DispatchSource watcher
│   └── Models.swift                    # WatchItem / Watchlist / Quote / MinutePoint
├── Resources/
│   └── Info.plist                      # LSUIElement=true (menu-bar only)
├── scripts/
│   └── make-app.sh                     # swift build + assemble .app + ad-hoc sign
├── docs/
│   └── images/                         # screenshots
└── build/                              # output (gitignored)
    └── StockBar.app/
```

---

## Color Convention

Up = **red**, down = **green** (CN market convention).

---

## Data Source

Direct calls to Tencent's free quote endpoints:
- `qt.gtimg.cn` — real-time snapshots (GBK-encoded)
- `web.ifzq.gtimg.cn` — today's minute series (JSON)

---

## Future ideas (not yet implemented)

- 5-day / 20-day k-line tab in the detail area
- Holiday calendar (skip Chinese holidays in addition to weekends)
- Per-row drag-to-reorder in the popover (already supported by `stockline reorder`)
- Notarized signed `.app` for distribution

---

## License

Personal toy project. No warranty — quote data is Tencent's.
