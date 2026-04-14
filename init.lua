-- 确保 IPC 模块加载
require("hs.ipc")

-- ================= 配置区域 =================
local config = {
    displayDuration = 1.5,          -- 显示时长 (秒)
    fontSize = 96,                  -- 字体大小（数字时）
    fontSizeName = 48,              -- 字体大小（文字名称时，自动缩小）
    size = 200,                     -- 正方形边长
    cornerRadius = 30,              -- 圆角
}
-- ===========================================

-- 外部配置文件路径
local configDir = hs.configdir
local spaceNamesFile = configDir .. "/config/space_names.json"

local overlay = nil
local hideTimer = nil
local debounceTimer = nil
local lastSpaceID = nil
local spaceNamesConfig = {}
local menubar = nil
local logger = hs.logger.new("SpaceSwitcher", "info")

-- 加载桌面名称配置文件
local function loadSpaceNames()
    local file = io.open(spaceNamesFile, "r")
    if not file then
        logger.w("[config] 配置文件不存在: " .. spaceNamesFile)
        spaceNamesConfig = {}
        return
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(hs.json.decode, content)
    if ok and data then
        spaceNamesConfig = data
        logger.i("[config] 已加载桌面名称配置")
    else
        logger.w("[config] 配置文件解析失败，请检查 JSON 格式")
        spaceNamesConfig = {}
    end
end

-- 根据屏幕名称和序号查找别名
local function getSpaceDisplayName(screenName, spaceIndex)
    if not screenName or not spaceIndex then return nil end

    local screenConfig = spaceNamesConfig[screenName]
    if not screenConfig then return nil end

    return screenConfig[tostring(spaceIndex)]
end

-- 获取当前 Space 的显示文本
local function getCurrentDisplayText(spaceID, spaceIndex, targetScreen)
    local screenName = targetScreen and targetScreen:name() or nil
    local alias = getSpaceDisplayName(screenName, spaceIndex)
    if alias then
        return alias
    elseif spaceIndex then
        return tostring(spaceIndex)
    else
        return tostring(spaceID)
    end
end

-- 监听配置文件变化，自动重载
local configWatcher = hs.pathwatcher.new(spaceNamesFile, function(files, flagTables)
    logger.i("[config] 检测到配置文件变化，重新加载")
    loadSpaceNames()
    -- 刷新菜单栏
    local spaceID, spaceIndex, targetScreen = getFocusedSpaceInfo()
    if spaceID then
        updateMenubar(spaceID, spaceIndex, targetScreen)
    end
    hs.notify.new({title="Hammerspoon", informativeText="桌面名称配置已更新"}):send()
end)

-- 生成 overlay HTML
local function makeHTML(text)
    local fontSize = config.fontSize
    if #text > 2 then
        fontSize = config.fontSizeName
    end

    return string.format([[
<!DOCTYPE html>
<html>
<head><style>
* { margin:0; padding:0; }
html, body {
    width: 100%%; height: 100%%;
    background: transparent;
    overflow: hidden;
}
.box {
    width: 100%%; height: 100%%;
    background: rgba(0, 0, 0, 0.6);
    border-radius: %dpx;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: "Helvetica Neue", "PingFang SC", sans-serif;
    font-weight: bold;
    font-size: %dpx;
    color: rgba(255, 255, 255, 0.9);
    text-align: center;
    padding: 10px;
    box-sizing: border-box;
}
</style></head>
<body><div class="box">%s</div></body>
</html>
]], config.cornerRadius, fontSize, text)
end

-- 核心函数：通过 focusedSpace 找到它所在的屏幕、序号
function getFocusedSpaceInfo()
    local focusedID = hs.spaces.focusedSpace()
    if not focusedID then return nil, nil, nil end

    local allSpaces = hs.spaces.allSpaces()
    for uuid, spaces in pairs(allSpaces) do
        for idx, spID in ipairs(spaces) do
            if spID == focusedID then
                local targetScreen = nil
                for _, scr in ipairs(hs.screen.allScreens()) do
                    if scr:getUUID() == uuid then
                        targetScreen = scr
                        break
                    end
                end
                return focusedID, idx, targetScreen
            end
        end
    end

    return focusedID, nil, nil
end

------------------------------------------------------------
-- 菜单栏
------------------------------------------------------------
function updateMenubar(spaceID, spaceIndex, targetScreen)
    if not menubar then return end

    local displayText = getCurrentDisplayText(spaceID, spaceIndex, targetScreen)
    menubar:setTitle("🖥 " .. displayText)

    -- 构建下拉菜单：显示主屏幕的所有桌面
    local primaryScreen = hs.screen.primaryScreen()
    local primaryUUID = primaryScreen and primaryScreen:getUUID() or nil
    local primaryName = primaryScreen and primaryScreen:name() or nil
    local allSpaces = hs.spaces.allSpaces()
    local menuItems = {}

    -- 当前屏幕信息
    local screenName = targetScreen and targetScreen:name() or "未知"
    table.insert(menuItems, {
        title = "当前: " .. screenName .. " #" .. tostring(spaceIndex or "?"),
        disabled = true,
    })
    table.insert(menuItems, { title = "-" })

    -- 列出所有屏幕的所有桌面
    for _, scr in ipairs(hs.screen.allScreens()) do
        local uuid = scr:getUUID()
        local sname = scr:name()
        local spaces = allSpaces[uuid]
        local activeOnScreen = hs.spaces.activeSpaceOnScreen(uuid)

        table.insert(menuItems, {
            title = "📺 " .. sname,
            disabled = true,
        })

        if spaces then
            for i, spID in ipairs(spaces) do
                local alias = getSpaceDisplayName(sname, i)
                local label = alias or tostring(i)
                local spType = hs.spaces.spaceType(spID)
                if spType == "fullscreen" then
                    label = label .. " (全屏)"
                end
                local isActive = (spID == activeOnScreen)

                table.insert(menuItems, {
                    title = (isActive and "  ● " or "    ") .. label,
                    disabled = true,
                })
            end
        end

        table.insert(menuItems, { title = "-" })
    end

    -- 底部操作
    table.insert(menuItems, {
        title = "编辑桌面名称...",
        fn = function()
            hs.execute("open " .. spaceNamesFile)
        end,
    })
    table.insert(menuItems, {
        title = "重新加载配置",
        fn = function()
            hs.reload()
        end,
    })

    menubar:setMenu(menuItems)
end

local function showSpaceOverlay(spaceID, spaceIndex, targetScreen)
    local displayText = getCurrentDisplayText(spaceID, spaceIndex, targetScreen)

    if displayText == "" then return end

    -- 清理旧元素
    if overlay then overlay:delete(); overlay = nil end
    if hideTimer then hideTimer:stop(); hideTimer = nil end

    if not targetScreen then
        targetScreen = hs.screen.mainScreen()
    end
    if not targetScreen then return end

    local frame = targetScreen:fullFrame()
    local boxSize = config.size
    local bgX = frame.x + (frame.w - boxSize) / 2
    local bgY = frame.y + (frame.h - boxSize) / 2

    logger.i("[showOverlay] text=" .. displayText .. " screen=" .. (targetScreen:name() or "nil"))

    overlay = hs.webview.new({x = bgX, y = bgY, w = boxSize, h = boxSize})
    overlay:windowStyle(128 + 8192)
    overlay:level(2147483630)
    overlay:behavior(1 + 16 + 64 + 256)
    overlay:allowTextEntry(false)
    overlay:transparent(true)
    overlay:html(makeHTML(displayText))
    overlay:show()

    hideTimer = hs.timer.doAfter(config.displayDuration, function()
        if overlay then overlay:delete(); overlay = nil end
        hideTimer = nil
    end)
end

-- 防抖处理
local function scheduleSpaceCheck()
    if debounceTimer then
        debounceTimer:stop()
        debounceTimer = nil
    end

    debounceTimer = hs.timer.doAfter(0.35, function()
        debounceTimer = nil
        local spaceID, spaceIndex, targetScreen = getFocusedSpaceInfo()

        if spaceID and spaceID ~= lastSpaceID then
            logger.i("[spaceCheck] Space 切换: " .. tostring(lastSpaceID) .. " -> " .. tostring(spaceID) .. " (index=" .. tostring(spaceIndex) .. ")")
            lastSpaceID = spaceID
            showSpaceOverlay(spaceID, spaceIndex, targetScreen)
            updateMenubar(spaceID, spaceIndex, targetScreen)
        end
    end)
end

-- 方法1: hs.spaces.watcher
local spaceWatcher = hs.spaces.watcher.new(function()
    scheduleSpaceCheck()
end)
spaceWatcher:start()

-- 方法2: 系统级通知
local distNotifWatcher = hs.distributednotifications.new(function()
    scheduleSpaceCheck()
end, "com.apple.spaces.ActiveSpaceDidChange")
distNotifWatcher:start()

-- 方法3: 窗口焦点变化
local windowFilter = hs.window.filter.new(nil)
windowFilter:subscribe(hs.window.filter.windowFocused, function()
    scheduleSpaceCheck()
end)

-- 方法4: 轮询兜底
local pollTimer = hs.timer.new(0.5, function()
    local spaceID = hs.spaces.focusedSpace()
    if spaceID and spaceID ~= lastSpaceID then
        scheduleSpaceCheck()
    end
end)
pollTimer:start()

-- 初始化
loadSpaceNames()
configWatcher:start()

-- 创建菜单栏
menubar = hs.menubar.new()
lastSpaceID = hs.spaces.focusedSpace()
local initID, initIdx, initScreen = getFocusedSpaceInfo()
updateMenubar(initID or lastSpaceID, initIdx, initScreen)

-- ================= Option+数字 切换桌面 =================
-- Option+1~9 切换到多桌面屏幕的第 N 个桌面（只有1个桌面的屏幕不受影响）
local function findMultiSpaceScreen()
    -- 找到拥有多个桌面的屏幕（优先当前聚焦的屏幕）
    local allSpaces = hs.spaces.allSpaces()
    local focusedID = hs.spaces.focusedSpace()

    -- 先检查当前聚焦空间所在的屏幕
    for uuid, spaces in pairs(allSpaces) do
        for _, spID in ipairs(spaces) do
            if spID == focusedID and #spaces > 1 then
                return uuid, spaces
            end
        end
    end

    -- 如果当前屏幕只有1个桌面，找其他有多桌面的屏幕
    for uuid, spaces in pairs(allSpaces) do
        if #spaces > 1 then
            return uuid, spaces
        end
    end

    return nil, nil
end

local function switchToSpace(targetIndex)
    local uuid, spaces = findMultiSpaceScreen()

    if not uuid or not spaces then
        logger.i("[switchSpace] 没有找到多桌面屏幕")
        return
    end

    if targetIndex > #spaces then
        logger.i("[switchSpace] 桌面 " .. targetIndex .. " 不存在，该屏幕只有 " .. #spaces .. " 个桌面")
        return
    end

    local targetSpaceID = spaces[targetIndex]
    local activeOnScreen = hs.spaces.activeSpaceOnScreen(uuid)

    if targetSpaceID == activeOnScreen then
        logger.i("[switchSpace] 该屏幕已在桌面 " .. targetIndex)
        return
    end

    hs.spaces.gotoSpace(targetSpaceID)
    logger.i("[switchSpace] 切换到桌面 " .. targetIndex .. " (ID=" .. targetSpaceID .. ")")
end

for i = 1, 9 do
    hs.hotkey.bind({"alt"}, tostring(i), function()
        switchToSpace(i)
    end)
end
logger.i("Option+1~9 桌面切换快捷键已绑定")

-- ================= 加载扩展模块 =================
-- 番茄钟
local pomodoro = require("modules.pomodoro")
pomodoro.start()

-- 屏幕画笔 (Ctrl+Shift+D 切换)
local screenDraw = require("modules.screen_draw")
screenDraw.start()

-- 圆环启动器 (Cmd+Shift+Space 唤起)
require("modules.circle_launcher")

-- 专注度提醒 (由 WorkBuddy 自动化调用)
require("modules.focus_alert")

-- 音频设备优先级管理（降级模式: 低频轮询 + 事件节流）
local audioManager = require("modules.audio_manager")
audioManager.start()

hs.notify.new({title="Hammerspoon", informativeText="所有模块已加载"}):send()

-- 调试工具
function hs.dumpSpaces()
    print("=== Space Debug Info ===")
    local sid, sidx, scr = getFocusedSpaceInfo()
    print("Focused Space ID:", sid)
    print("Focused Space Index:", sidx)
    print("Focused Screen:", scr and scr:name() or "nil")
    print("lastSpaceID:", lastSpaceID)
    print("")
    print("--- 配置文件内容 ---")
    print(hs.inspect(spaceNamesConfig))
    print("")
    print("--- Spaces 布局 ---")
    local allSpaces = hs.spaces.allSpaces()
    for uuid, spaces in pairs(allSpaces) do
        local sname = "?"
        for _, s in ipairs(hs.screen.allScreens()) do
            if s:getUUID() == uuid then sname = s:name(); break end
        end
        local active = hs.spaces.activeSpaceOnScreen(uuid)
        print(sname .. " (uuid=" .. uuid .. ")  active=" .. tostring(active))
        for i, id in ipairs(spaces) do
            local marker = (id == active) and " <-- ACTIVE" or ""
            local alias = getSpaceDisplayName(sname, i) or ""
            if alias ~= "" then alias = ' "' .. alias .. '"' end
            print(string.format("  %d: ID %d (%s)%s%s", i, id, hs.spaces.spaceType(id), alias, marker))
        end
    end
end
