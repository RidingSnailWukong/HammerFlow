# 刘海避让模块使用说明

## 功能概述

此模块用于检测 MacBook Pro 的刘海（notch）区域，并提供安全区域信息，帮助其他功能避开刘海位置。

## 支持机型

- MacBook Pro 14 寸 (2021+)：刘海宽度 72pt
- MacBook Pro 16 寸 (2021+)：刘海宽度 90pt
- 其他无刘海机型：自动跳过

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Ctrl+Cmd+N` | 刷新刘海避让配置（切换屏幕后使用） |
| `Ctrl+Cmd+Shift+N` | 可视化显示刘海区域（调试用，显示 3 秒红色半透明区域） |

## API 使用

### 基本用法

```lua
local notchAvoidance = require("modules.notch_avoidance")

-- 启动模块（会自动监听屏幕变化）
notchAvoidance.start()

-- 获取刘海信息
local info = notchAvoidance.getInfo()
print("是否有刘海:", info.hasNotch)
print("刘海宽度:", info.width, "pt")
print("左侧安全区:", info.leftSafeZone)
print("右侧安全区:", info.rightSafeZone)
```

### 检查坐标是否在刘海区域

```lua
local x = 1000  -- 某个屏幕 X 坐标
if notchAvoidance.isInNotchZone(x) then
    print("这个位置在刘海下方，需要避让")
else
    print("这个位置安全")
end
```

### 手动更新刘海信息

```lua
-- 切换屏幕后手动更新
notchAvoidance.update()

-- 或指定特定屏幕
local screen = hs.screen.primaryScreen()
notchAvoidance.update(screen)
```

### 调试可视化

```lua
-- 在屏幕上显示刘海区域（红色半透明矩形，持续 3 秒）
notchAvoidance.visualize()
```

## 调试命令

在 Hammerspoon Console 中运行：

```lua
-- 查看刘海详细信息
hs.dumpNotch()

-- 输出示例：
-- === Notch Debug Info ===
-- Has Notch: true
-- Notch Width: 72 pt
-- Left Safe Zone: 855.0
-- Right Safe Zone: 945.0
-- Screen: Built-in Retina Display
```

## 工作原理

1. **机型检测**：通过屏幕分辨率识别是否为带刘海的 MacBook Pro
   - 14 寸：3024×1964
   - 16 寸：3456×2234

2. **安全区计算**：
   ```
   屏幕中心 ± (刘海宽度/2 + 10pt 边距) = 安全区边界
   ```

3. **自动监听**：屏幕配置变化时自动重新检测

## 注意事项

⚠️ **重要限制**

Hammerspoon **无法控制系统菜单栏图标的位置**。系统图标（电池、Wi-Fi、时间等）和第三方应用图标都由 macOS 系统管理，会自动避开刘海。

此模块的作用是：
- ✅ 提供刘海区域信息，供自定义窗口/覆盖层使用
- ✅ 检测坐标是否在刘海下方
- ✅ 监测刘海安全区域
- ❌ **不能**移动系统菜单栏图标
- ❌ **不能**强制改变第三方应用的菜单栏图标位置

## 实际应用场景

### 1. 自定义窗口定位

```lua
local info = notchAvoidance.getInfo()
if info.hasNotch then
    -- 将自定义窗口放在刘海左侧
    local frame = {
        x = info.leftSafeZone - 200,
        y = 0,
        w = 180,
        h = 30
    }
    -- 创建窗口...
end
```

### 2. 覆盖层避让

```lua
-- 创建顶部通知时避开刘海
local screen = hs.screen.mainScreen()
local screenFrame = screen:frame()
local info = notchAvoidance.getInfo()

local notificationX
if info.hasNotch then
    -- 放在刘海右侧
    notificationX = info.rightSafeZone + 20
else
    -- 居中显示
    notificationX = screenFrame.x + (screenFrame.w - 300) / 2
end
```

### 3. 检测冲突

```lua
-- 检查某个功能是否会与刘海冲突
local myFeatureX = 900
if notchAvoidance.isInNotchZone(myFeatureX) then
    print("警告：功能位置与刘海冲突，需要调整")
end
```

## 兼容性

- ✅ macOS 12.0+（刘海机型起始版本）
- ✅ 自动识别外接显示器（外接显示器自动跳过检测）
- ✅ 多屏幕支持（每个屏幕独立检测）

## 故障排除

### 问题：刘海检测不准确

**解决方法**：
1. 检查屏幕分辨率：
   ```lua
   local mode = hs.screen.mainScreen():currentMode()
   print(mode.w, mode.h)
   ```
2. 手动设置刘海宽度（修改 `notch_avoidance.lua` 中的 `NOTCH_CONFIGS`）

### 问题：切换屏幕后刘海信息未更新

**解决方法**：
- 按 `Ctrl+Cmd+N` 手动刷新
- 或等待自动检测（通常在 1 秒内）

## 更新日志

- **v1.0** (2026-03-07)
  - 初始版本
  - 支持 14/16 寸 MacBook Pro
  - 自动屏幕检测
  - 可视化调试功能
