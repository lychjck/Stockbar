# StockBar

A native macOS menu-bar app that shows your A-share / ETF watchlist with
**inline minute-level sparklines** (Stats-style) and a per-symbol intraday
chart on click.

- Pure Swift + AppKit, no Xcode project needed at runtime, no Electron, no Python.
- Direct calls to Tencent's free quote endpoints (`qt.gtimg.cn` for snapshots,
  `web.ifzq.gtimg.cn` for today's minute series).
- Shares the watchlist JSON with the
  [`stockline`](https://github.com/liyanran/stock-statusline) terminal tool, so you
  manage your codes in **one place**.
- ~80 MB RSS, agent process (no Dock icon).
- **Trading-session aware**: refreshes 5 s during the live session, slows to 60 s
  during lunch / pre-/post-market, and sleeps to 600 s on weekends.

```text
       ┌─────┐
       │ ⤴⤵ │  ◀ menu-bar icon (single SF Symbol)
       └──┬──┘
          │  click
          ▼
  ┌───────────────────────────────────────────────────┐
  │ Updated 14:21:08    ● 下午盘     ⟳   📄  ⏻       │
  ├───────────────────────────────────────────────────┤
  │  沪指    000001         4117.79   +0.17%   ▁▂▄▆█  │
  │  红利    512890           1.092   -0.64%   █▇▆▅▄  │
  │  恒科    513130           0.551   -1.78%   █▆▄▂▁  │
  │  机器人  159770           1.193   +0.59%   ▁▃▅▇█  │ ◀ click a row
  │  ...                                              │
  ├───────────────────────────────────────────────────┤
  │  机器人  159770                                   │
  │  1.193   +0.59%   prev 1.186                      │
  │  ┌────────────────────────────────────────────┐   │
  │  │  ╱╲       ╱╲╱╲              ╱╲             │   │  ◀ today's intraday chart
  │  │ ╱  ╲___  ╱      ╲____  ____╱  ╲___ ╱╲     │   │     (09:30–15:00, prev-close baseline)
  │  │─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─    │   │
  │  │                                            │   │
  │  └────────────────────────────────────────────┘   │
  │  09:30      11:30 13:00              15:00       │
  └───────────────────────────────────────────────────┘
```

Up = **red**, down = **green** (CN market convention).

---

## Build

Requires the Xcode toolchain. The included script defaults to the external
Xcode at `/Volumes/disk/Applications/Xcode.app`; override with
`DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` if yours lives elsewhere.

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

To launch at login: drag `StockBar.app` into **System Settings → General →
Login Items**.

---

## Interaction

- Click the menu-bar icon → popover opens with the full watchlist.
- Each row shows: alias · 6-digit code · price · today's % change · mini sparkline.
- **Click a row** → a full-size intraday chart for that symbol expands below
  the list. Click the same row again to collapse.
- Click outside the popover (or anywhere in another app) → popover closes.
- Header buttons:
  - `⟳` — force a refresh now
  - `📄` — open `watchlist.json` in your default editor
  - `⏻` — quit StockBar

The popover also displays the current market phase:
**盘前 / ● 上午盘 / 午休 / ● 下午盘 / 已收盘 / 周末休市**.

---

## Configuration

By default, StockBar reads:

```text
~/plugins/stock-statusline/config/watchlist.json
```

If that file doesn't exist, it falls back to:

```text
~/.config/stockbar/watchlist.json
```

You can edit the JSON directly, or use the `stockline` CLI to manage it:

```bash
stockline add 159770 机器人
stockline remove 512100
stockline set max-items 6
```

The menu-bar app **watches the file**: any external edit reloads the watchlist
and triggers an immediate refresh — no app restart needed.

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

- `refresh_seconds` — base polling interval during the live session.
  StockBar automatically stretches this to 60 s during lunch / pre-/post-market
  and 600 s on weekends.
- `code` — 6-digit code. Prefix is auto-inferred (`5/6/9 → sh`, else `sz`).
- `symbol` — optional explicit prefix override, e.g. `"sh000001"`.
- `alias` — short label shown on the row.
- `max_items` — legacy field used by the `stockline` terminal tool; ignored
  here because the popover always shows the full list.

---

## How it works

```
       ┌──────────────────────────┐
       │  watchlist.json          │ ◀── stockline CLI / your editor
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
```

- Tencent's snapshot endpoint returns **GBK**-encoded text. We decode with
  `CFStringConvertEncodingToNSStringEncoding(GB_18030_2000)` and parse the
  `~`-separated payload.
- The minute endpoint returns plain JSON; lines look like
  `"0930 4117.79 5811064 16173033562.60"`. We compress the lunch break
  (11:30–13:00) on the x-axis so the chart reads naturally.
- `MarketHours` decides the refresh cadence so the app is quiet outside
  trading hours.
- Everything UI-side is `@MainActor`; fetchers are `async` over an ephemeral
  `URLSession`.

---

## Layout

```
stock-desktop/
├── Package.swift                       # SPM manifest
├── Sources/StockBar/
│   ├── AppDelegate.swift               # NSStatusItem, NSPopover, refresh loops
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
└── build/                              # output (gitignored)
    └── StockBar.app/
```

---

## Future ideas (not yet implemented)

- 5-day / 20-day k-line tab in the detail area.
- Holiday calendar (skip Chinese holidays in addition to weekends).
- Per-row drag-to-reorder in the popover (already supported by `stockline reorder`).
- Notarized signed `.app` for distribution.

---

## License

Personal toy project. No warranty — quote data is Tencent's.
