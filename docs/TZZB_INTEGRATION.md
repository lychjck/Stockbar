# StockBar × tzzb 联动配置

StockBar 现在支持从 [tzzb（投资账本）](https://github.com/lychjck/tzzb) 自动获取持仓信息，实现：
- ✅ 自动同步持仓到自选股列表
- ✅ 显示每只股票的成本价
- ✅ 实时显示浮盈浮亏
- ✅ tzzb 不运行时自动降级到本地 watchlist.json

---

## 快速开始

### 1. 启动 tzzb 服务

```bash
cd ~/github/touzizhangben

# 确保已经登录（配置 Cookie）
./tzzb login

# 启动 HTTP 服务
./tzzb serve --port 8080
```

服务启动后会监听 `http://127.0.0.1:8080`

### 2. 配置 StockBar

打开 StockBar 的偏好设置（点击菜单栏图标 → ⚙️），然后在 **UserDefaults** 中添加 tzzb API 地址。

或者使用命令行配置：

```bash
# 方式 1：通过 defaults 命令
defaults write com.stockbar.StockBar tzzbApiUrl "http://127.0.0.1:8080"

# 方式 2：直接编辑配置（需要重启 StockBar）
# AppConfig 存储在 UserDefaults 中
```

**临时方案**：由于当前 AppConfig 存储在 UserDefaults，我们可以通过代码添加 UI 配置入口，或者直接在启动时检测 tzzb 可用性。

### 3. 重启 StockBar

```bash
pkill -f 'StockBar.app/Contents/MacOS/StockBar'
open /Applications/StockBar.app
```

---

## 工作原理

### 数据流

```
tzzb serve :8080
       │
       │ GET /api/positions?type=stock
       ▼
  TzzbClient
       │
       │ [TzzbPosition] → [WatchItem]
       ▼
   watchlist
       │
       │ fetch quotes
       ▼
  PopoverController
       │
       │ 显示：成本价 + 浮盈浮亏
       ▼
  WatchlistRowView
```

### API 接口

StockBar 每次刷新行情时会调用：

```http
GET http://127.0.0.1:8080/api/positions?type=stock
```

返回格式（来自 tzzb）：

```json
{
  "positions": [
    {
      "account": "华宝证券",
      "category": "股票",
      "code": "159770",
      "name": "机器人ETF",
      "count": 1000,
      "cost": 1.234,
      "price": 1.345,
      "value": 1345.0,
      "hold_profit": 111.0,
      "hold_rate": 9.0,
      "day_profit": 10.0,
      "day_rate": 0.75
    }
  ],
  "summary": {
    "value": 1345.0,
    "hold_profit": 111.0,
    "day_profit": 10.0,
    "count": 1
  }
}
```

### 降级策略

```swift
if tzzb API 可用 {
    watchlist = 从 tzzb 获取持仓
} else {
    watchlist = 读取本地 ~/.config/stockbar/watchlist.json
}
```

---

## UI 变化

### 菜单栏 Popover

每个持仓股票现在显示：

```
机器人 159770              1.345  +9.00%  [sparkline]
成本 1.234  +111 (+9.0%)
```

- **第一行**：股票名称、代码、当前价、今日涨跌幅、分时图
- **第二行**（新增）：成本价、浮盈浮亏（金额 + 百分比）

颜色：
- 盈利显示红色（中国市场习惯）
- 亏损显示绿色

### Touch Bar

Touch Bar 目前仍显示行情列表，暂不显示成本和盈亏（空间有限）。后续可以在点击详情时显示。

---

## 常见问题

### Q: tzzb 不运行时 StockBar 能正常工作吗？

可以。StockBar 会自动回退到读取本地 `watchlist.json`，只是不会显示成本和盈亏信息。

### Q: 我想看持仓 + 额外关注的股票怎么办？

目前 tzzb 模式下只显示持仓。如果需要混合显示：

**方案 1（推荐）**：在 tzzb 账户里添加一个"观察账户"，手动记录关注的股票（份额设为 0）

**方案 2**：临时禁用 tzzb，切换回本地 watchlist.json：

```bash
defaults delete com.stockbar.StockBar tzzbApiUrl
```

### Q: 如何更新配置？

```bash
# 更改 tzzb API 地址
defaults write com.stockbar.StockBar tzzbApiUrl "http://127.0.0.1:8080"

# 禁用 tzzb 集成
defaults delete com.stockbar.StockBar tzzbApiUrl

# 查看当前配置
defaults read com.stockbar.StockBar
```

### Q: tzzb API 请求失败会怎样？

StockBar 设置了 5 秒超时，如果请求失败会静默降级到本地 watchlist，不会报错或卡顿。

---

## 开发信息

### 新增文件

- `Sources/StockCore/TzzbClient.swift` - tzzb HTTP API 客户端

### 修改文件

- `Sources/StockCore/Models.swift` - WatchItem 添加 `cost`、`shares`、`account` 字段
- `Sources/StockCore/AppConfig.swift` - 添加 `tzzbApiUrl` 配置项
- `Sources/StockBar/AppDelegate.swift` - 在 `refreshAll()` 中集成 tzzb API
- `Sources/StockBar/WatchlistRowView.swift` - UI 显示成本和盈亏

### 技术细节

- **异步请求**：使用 `async/await` + `URLSession`
- **超时控制**：5 秒超时避免卡顿
- **错误处理**：静默失败，返回 `nil` 触发降级
- **数据转换**：`TzzbPosition` → `WatchItem`，自动推断 sh/sz 前缀

---

## 未来改进

- [ ] 在 Preferences 窗口添加 tzzb API 配置 UI
- [ ] 支持自定义端口和主机地址
- [ ] 在 Touch Bar 详情视图显示成本和盈亏
- [ ] 支持混合模式（持仓 + 额外关注股票）
- [ ] 增加 tzzb 连接状态指示器

---

## 相关链接

- [tzzb 项目](https://github.com/lychjck/tzzb)
- [tzzb API 文档](../../../touzizhangben/docs/API.md)
- [StockBar 项目](https://github.com/lychjck/Stockbar)
