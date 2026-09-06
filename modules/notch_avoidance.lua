-- =====================================
-- 刘海避让模块
-- =====================================
-- 功能：
-- 1. 检测 MacBook 刘海区域
-- 2. 提供安全区域信息
-- 3. 为菜单栏图标提供定位建议
-- =====================================

local M = {}
local logger = hs.logger.new("NotchAvoidance", "info")

-- 配置：不同机型的刘海宽度（单位：点 pt）
local NOTCH_CONFIGS = {
    ["MacBook Pro"] = {
        ["14-inch"] = 72,   -- 14 寸 MacBook Pro
        ["16-inch"] = 90,   -- 16 寸 MacBook Pro
        default = 80,       -- 默认值
    },
}

-- 当前刘海信息缓存
local currentNotch = {
    hasNotch = false,
    width = 0,
    leftSafeZone = 0,
    rightSafeZone = 0,
    screen = nil,
}

---
-- 检测屏幕是否有刘海
-- 判断依据：内置屏幕 + safeAreaInsets.top > 0
---
local function detectNotch(screen)
    if not screen then
        screen = hs.screen.mainScreen()
    end
    
    -- 检查是否是内置屏幕（MacBook 自带屏幕）
    local isBuiltIn = false
    local screenInfo = hs.screen.screenPositions()
    
    -- 通过屏幕信息判断（内置屏幕通常在主位置）
    for scr, _ in pairs(screenInfo) do
        if scr == screen then
            -- 内置屏幕的特征：没有外部连接、分辨率比较特殊
            local name = screen:name() or ""
            if name:match("Built%-in") or name:match("内建") then
                isBuiltIn = true
                break
            end
        end
    end
    
    -- 如果不是内置屏幕，肯定没有刘海
    if not isBuiltIn then
        logger.i("外接显示器，无刘海")
        return false, 0
    end
    
    -- 检查 safeAreaInsets（macOS 12.0+）
    local frame = screen:fullFrame()
    
    -- 尝试获取安全区域（如果有刘海，顶部会有 inset）
    -- 注意：Hammerspoon 可能没有直接的 API，我们用间接方法
    
    -- 方法1：通过屏幕尺寸判断机型
    -- 注意：需要获取原始分辨率，而不是缩放后的分辨率
    local screenSize = screen:currentMode()
    local scaledWidth = screenSize.w
    local scaledHeight = screenSize.h
    
    -- 获取原始物理分辨率（通过 scale 参数）
    local scale = screenSize.scale or 1
    local width = scaledWidth * scale
    local height = scaledHeight * scale
    
    -- 14 寸 MacBook Pro (3024×1964) 或 16 寸 (3456×2234)
    -- 这些机型在 2021 年后带刘海
    local hasNotch = false
    local notchWidth = 0
    
    if (width == 3024 and height == 1964) then
        -- 14 寸 MacBook Pro
        hasNotch = true
        notchWidth = NOTCH_CONFIGS["MacBook Pro"]["14-inch"]
        logger.i("检测到 14 寸 MacBook Pro，刘海宽度: " .. notchWidth)
    elseif (width == 3456 and height == 2234) then
        -- 16 寸 MacBook Pro
        hasNotch = true
        notchWidth = NOTCH_CONFIGS["MacBook Pro"]["16-inch"]
        logger.i("检测到 16 寸 MacBook Pro，刘海宽度: " .. notchWidth)
    else
        logger.i("未检测到刘海屏幕 (缩放分辨率: " .. scaledWidth .. "×" .. scaledHeight .. 
                 ", 原始分辨率: " .. width .. "×" .. height .. ")")
    end
    
    return hasNotch, notchWidth
end

---
-- 计算刘海安全区域
-- 返回：左侧安全区终点、右侧安全区起点（相对于屏幕坐标）
---
local function calculateSafeZones(screen, notchWidth)
    local frame = screen:frame()
    local centerX = frame.x + frame.w / 2
    
    local leftSafeEnd = centerX - notchWidth / 2 - 10  -- 左侧安全区（留 10pt 边距）
    local rightSafeStart = centerX + notchWidth / 2 + 10  -- 右侧安全区
    
    return leftSafeEnd, rightSafeStart
end

---
-- 更新刘海信息
---
function M.update(screen)
    if not screen then
        screen = hs.screen.mainScreen()
    end
    
    local hasNotch, notchWidth = detectNotch(screen)
    currentNotch.hasNotch = hasNotch
    currentNotch.width = notchWidth
    currentNotch.screen = screen
    
    if hasNotch then
        local leftSafe, rightSafe = calculateSafeZones(screen, notchWidth)
        currentNotch.leftSafeZone = leftSafe
        currentNotch.rightSafeZone = rightSafe
        
        logger.i(string.format(
            "刘海避让已激活 | 宽度: %dpt | 安全区: [屏幕左 -> %.0f] 和 [%.0f -> 屏幕右]",
            notchWidth, leftSafe, rightSafe
        ))
    else
        currentNotch.leftSafeZone = 0
        currentNotch.rightSafeZone = 0
        logger.i("当前屏幕无刘海")
    end
end

---
-- 获取刘海信息
-- @return table {hasNotch, width, leftSafeZone, rightSafeZone}
---
function M.getInfo()
    return currentNotch
end

---
-- 判断某个 X 坐标是否在刘海区域内
-- @param x number 屏幕绝对坐标
-- @return boolean
---
function M.isInNotchZone(x)
    if not currentNotch.hasNotch then
        return false
    end
    
    return x > currentNotch.leftSafeZone and x < currentNotch.rightSafeZone
end

---
-- 获取建议的菜单栏图标位置
-- @param preferLeft boolean 优先左侧（默认 false，即优先右侧）
-- @return string "left" 或 "right"
---
function M.getSuggestedPosition(preferLeft)
    if not currentNotch.hasNotch then
        return preferLeft and "left" or "right"
    end
    
    -- 如果有刘海，建议使用右侧（避开系统图标通常在右侧）
    -- 实际上 Hammerspoon 的 menubar 图标会自动排列，无法手动定位
    return "right"
end

---
-- 调试：显示刘海区域可视化
---
function M.visualize()
    if not currentNotch.hasNotch then
        hs.alert.show("当前屏幕无刘海")
        return
    end
    
    local screen = currentNotch.screen
    local frame = screen:frame()
    
    -- 绘制刘海区域（半透明红色）
    local notchRect = {
        x = currentNotch.leftSafeZone,
        y = frame.y,
        w = currentNotch.rightSafeZone - currentNotch.leftSafeZone,
        h = 30,  -- 菜单栏高度
    }
    
    local canvas = hs.canvas.new(notchRect)
    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = { red = 1, green = 0, blue = 0, alpha = 0.3 },
        roundedRectRadii = { xRadius = 15, yRadius = 15 },
    })
    canvas:show()
    
    hs.timer.doAfter(3, function()
        canvas:delete()
    end)
    
    hs.alert.show(string.format("刘海区域: %.0f - %.0f (宽度 %dpt)", 
        currentNotch.leftSafeZone, 
        currentNotch.rightSafeZone,
        currentNotch.width
    ))
end

---
-- 监听屏幕变化，自动更新刘海信息
---
function M.start()
    -- 初始检测
    M.update()
    
    -- 监听屏幕配置变化
    local screenWatcher = hs.screen.watcher.new(function()
        logger.i("屏幕配置变化，重新检测刘海")
        M.update()
    end)
    screenWatcher:start()
    
    logger.i("刘海避让模块已启动")
    
    return M
end

return M
