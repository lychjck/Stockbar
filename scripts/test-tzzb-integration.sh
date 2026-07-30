#!/bin/bash

echo "======================================"
echo "StockBar × tzzb 集成测试脚本"
echo "======================================"
echo ""

# 检查 tzzb 是否运行
echo "1. 检查 tzzb 服务状态..."
if curl -s --connect-timeout 2 http://127.0.0.1:8080/api/positions?type=stock > /dev/null 2>&1; then
    echo "   ✓ tzzb 正在运行 (http://127.0.0.1:8080)"

    # 获取持仓数量
    positions_count=$(curl -s http://127.0.0.1:8080/api/positions?type=stock | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data['positions']))" 2>/dev/null)
    echo "   ✓ 当前持仓: $positions_count 只股票"
    echo ""
    echo "   示例持仓数据:"
    curl -s http://127.0.0.1:8080/api/positions?type=stock | python3 -m json.tool 2>/dev/null | head -20
else
    echo "   ✗ tzzb 未运行"
    echo ""
    echo "   启动方法:"
    echo "   cd ~/github/touzizhangben"
    echo "   ./tzzb login        # 首次需要登录"
    echo "   ./tzzb serve --port 8080"
    echo ""
    exit 1
fi

echo ""
echo "======================================"
echo "2. 检查 StockBar 配置..."

# 检查 StockBar 是否在运行
if pgrep -f 'StockBar.app/Contents/MacOS/StockBar' > /dev/null; then
    echo "   ✓ StockBar 正在运行"
else
    echo "   ✗ StockBar 未运行"
    echo "   启动方法: open /Applications/StockBar.app"
fi

# 检查配置
api_url=$(defaults read com.stockbar.StockBar tzzbApiUrl 2>/dev/null)
if [ -n "$api_url" ]; then
    echo "   ✓ tzzb API 已配置: $api_url"
else
    echo "   ✗ tzzb API 未配置"
    echo ""
    echo "   配置方法:"
    echo "   1. 点击 StockBar 菜单栏图标"
    echo "   2. 点击 ⚙️ 设置按钮"
    echo "   3. 在「投资账本集成」区域输入: http://127.0.0.1:8080"
    echo "   4. 点击「测试」按钮验证连接"
fi

echo ""
echo "======================================"
echo "3. 使用说明"
echo "======================================"
echo ""
echo "✓ 配置完成后，StockBar 将自动:"
echo "  - 从 tzzb 同步持仓到自选股列表"
echo "  - 显示每只股票的成本价"
echo "  - 实时计算浮盈浮亏"
echo ""
echo "✓ UI 显示:"
echo "  第一行: 股票名称 代码 当前价 涨跌幅 [分时图]"
echo "  第二行: 成本 X.XXX  +/-金额 (+/-百分比)"
echo ""
echo "✓ tzzb 不运行时:"
echo "  - StockBar 自动降级到本地 watchlist.json"
echo "  - 不显示成本和盈亏信息"
echo ""
echo "======================================"
