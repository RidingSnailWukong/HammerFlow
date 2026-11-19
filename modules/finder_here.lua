--- modules/finder_here.lua
--- 在当前屏幕/桌面唤出访达（Finder），避免点 Dock 图标跳到别的桌面导致无法拖放
---
--- 背景：访达窗口在别的桌面时，点 Dock 图标会切换桌面；拖放必须两个窗口同屏。
---
--- 设计边界（macOS 26 实测）：
---   1. hs.spaces.moveWindowToSpace 已失效（返回 true 但窗口不动），不能靠它搬窗口。
---   2. hs.window:moveToScreen() 可用，且会把窗口带到目标屏幕的当前桌面 —— 这是本模块的立足点。
---   3. 对访达调用 hs.window:focus() / :raise() 会把焦点弹回上一个 App，
---      只能用 app:activate()，提升具体窗口交给 AppleScript「set index」。
---   4. hs.window 无窗口层级接口，无法让访达置顶；本模块只解决"出现在当前桌面"。
---
--- 行为：
---   1. 当前屏幕已有访达窗口 → 激活它
---   2. 有窗口但都在别的屏幕 → 把最前面那个搬到当前屏幕
---   3. 完全没有窗口 → 新建窗口（新窗口落在访达上次所在屏幕）→ 搬到当前屏幕
---
--- 依赖：为让窗口在该屏幕的每个桌面都可见，建议 Dock 右键访达 → 选项 → 所有桌面。
---       未开启时窗口只属于单个桌面，切桌面后仍会"找不到"，此时模块会提示。
---
--- 配置文件：config/finder_here.json（保存后自动热重载）

local M = {}

local logger = hs.logger.new("FinderHere", "info")
local configFile = hs.configdir .. "/config/finder_here.json"

local FINDER_BUNDLE = "com.apple.finder"

local DEFAULT_CONFIG = {
    enabled = true,
    hotkey = { mods = { "cmd", "alt" }, key = "f" },
    defaultPath = nil,   -- 新建窗口时的目标目录，留空则用访达默认位置
    frame = nil,         -- 可选：{x,y,w,h} 相对当前屏幕的比例，用于与目标 App 并排
    hintAllDesktops = true,
    alertOnFail = true,
}

local cfg = {}
local hotkey = nil
local configWatcher = nil
local pendingTimer = nil   -- 模块级常驻，避免被 GC
local winMoveTimer = nil

local function shallowMerge(base, override)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(override or {}) do out[k] = v end
    return out
end

local function readConfig()
    local loaded = hs.json.read(configFile)
    if type(loaded) ~= "table" then
        logger.i("无配置文件，使用默认配置: " .. configFile)
        loaded = {}
    end
    cfg = shallowMerge(DEFAULT_CONFIG, loaded)
    if type(cfg.hotkey) ~= "table" or type(cfg.hotkey.key) ~= "string" then
        cfg.hotkey = DEFAULT_CONFIG.hotkey
    end
    if type(cfg.hotkey.mods) ~= "table" then
        cfg.hotkey.mods = DEFAULT_CONFIG.hotkey.mods
    end
end

local function alert(msg, seconds)
    logger.w(msg)
    if cfg.alertOnFail then
        hs.alert.show(msg, { radius = 10, textSize = 14 }, seconds or 1.5)
    end
end

--- 目标屏幕：键盘焦点窗口所在屏 → 鼠标所在屏 → 主屏
local function targetScreen()
    local fw = hs.window.focusedWindow()
    if fw then
        local ok, scr = pcall(function() return fw:screen() end)
        if ok and scr then return scr end
    end
    local ok2, mouse = pcall(function() return hs.mouse.getCurrentScreen() end)
    if ok2 and mouse then return mouse end
    return hs.screen.mainScreen()
end

local function isRealWindow(w)
    if not w then return false end
    local id = w:id()
    if not id or id == 0 then return false end
    local ok, std = pcall(function() return w:isStandard() end)
    return not ok or std
end

local function finderWindows()
    local app = hs.application.get(FINDER_BUNDLE)
    if not app then return {} end
    local out = {}
    for _, w in ipairs(app:allWindows() or {}) do
        if isRealWindow(w) then out[#out + 1] = w end
    end
    return out
end

--- 按 z 序返回（最前面的排第一）
local function orderedFinderWindows()
    local ranked = {}
    for _, w in ipairs(hs.window.orderedWindows() or {}) do
        local ok, bundle = pcall(function() return w:application():bundleID() end)
        if ok and bundle == FINDER_BUNDLE and isRealWindow(w) then
            ranked[#ranked + 1] = w
        end
    end
    if #ranked > 0 then return ranked end
    return finderWindows()
end

local function spacesOf(w)
    local ok, spaces = pcall(function() return hs.spaces.windowSpaces(w) end)
    if not ok or type(spaces) ~= "table" then return {} end
    return spaces
end

local function screenSpaces(scr)
    local ok, spaces = pcall(function() return hs.spaces.spacesForScreen(scr) end)
    if not ok or type(spaces) ~= "table" then return {} end
    return spaces
end

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

--- 窗口是否出现在该屏幕的任一桌面上
local function onScreen(w, scr)
    local spaces = spacesOf(w)
    if #spaces == 0 then return false end
    for _, s in ipairs(spaces) do
        if contains(screenSpaces(scr), s) then return true end
    end
    return false
end

local function applyFrame(w)
    if type(cfg.frame) ~= "table" then return end
    local scr = (w and w:screen()) or hs.screen.mainScreen()
    local f = scr:frame()
    local ok, err = pcall(function()
        w:setFrame({
            x = f.x + f.w * (cfg.frame.x or 0),
            y = f.y + f.h * (cfg.frame.y or 0),
            w = f.w * (cfg.frame.w or 0.5),
            h = f.h * (cfg.frame.h or 0.8),
        })
    end)
    if not ok then logger.w("设置窗口位置失败: " .. tostring(err)) end
end

--- 激活访达并把目标窗口提到最前
local function activateWindow(w, scr)
    local app = hs.application.get(FINDER_BUNDLE)
    if not app then
        hs.application.launchOrFocusByBundleID(FINDER_BUNDLE)
        return
    end
    app:activate()
    local id = w:id()
    if id then
        if winMoveTimer then winMoveTimer:stop(); winMoveTimer = nil end
        winMoveTimer = hs.timer.doAfter(0.12, function()
            winMoveTimer = nil
            local ok = hs.osascript.applescript(string.format(
                'tell application "Finder" to set index of (first window whose id is %d) to 1', id))
            if not ok then logger.w(string.format("提升窗口 #%d 失败", id)) end
        end)
    end

    -- 未开启「所有桌面」时，窗口只属于单个桌面，切桌面后仍会丢失
    if cfg.hintAllDesktops and scr then
        local owned, total = #spacesOf(w), #screenSpaces(scr)
        if total > 1 and owned > 0 and owned < total then
            alert("访达窗口只属于单个桌面，建议 Dock 右键访达 → 选项 → 所有桌面", 3)
        end
    end
    applyFrame(w)
end

--- 把窗口搬到目标屏幕
local function moveToScreen(w, scr)
    local ok, err = pcall(function() w:moveToScreen(scr) end)
    if not ok then
        alert("搬动访达窗口失败：" .. tostring(err))
        return false
    end
    logger.i(string.format("[move] #%d -> %s", w:id(), scr:name()))
    return true
end

local function createWindow(path, completion)
    local script
    if type(path) == "string" and path ~= "" then
        script = string.format(
            'tell application "Finder" to make new Finder window to (POSIX file "%s")', path)
    else
        script = 'tell application "Finder" to make new Finder window'
    end
    local ok, res, err = hs.osascript.applescript(script)
    if not ok then
        alert("新建访达窗口失败")
        logger.w(string.format("AppleScript 失败: %s / %s", tostring(res), tostring(err)))
        return
    end
    if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
    pendingTimer = hs.timer.doAfter(0.3, function()
        pendingTimer = nil
        local newest = nil
        for _, w in ipairs(finderWindows()) do
            if not newest or w:id() > newest:id() then newest = w end
        end
        if not newest then
            alert("新建访达窗口后未找到窗口")
            return
        end
        completion(newest)
    end)
end

--- 在当前屏幕/桌面唤出访达
--- @param path string|nil 可选：新建窗口时定位到该目录
function M.bring(path)
    if not cfg.enabled then return end

    local scr = targetScreen()
    local onThis = nil
    local anyOther = nil
    for _, w in ipairs(orderedFinderWindows()) do
        if onScreen(w, scr) then
            onThis = w
            break
        elseif not anyOther then
            anyOther = w
        end
    end

    if onThis then
        activateWindow(onThis, scr)
        logger.i(string.format("[bring] 复用当前屏幕窗口 #%d (%s)", onThis:id(), scr:name()))
        return
    end

    if anyOther then
        if moveToScreen(anyOther, scr) then
            hs.timer.doAfter(0.35, function() activateWindow(anyOther, scr) end)
        end
        logger.i(string.format("[bring] 搬运窗口 #%d 到 %s", anyOther:id(), scr:name()))
        return
    end

    createWindow(path or cfg.defaultPath, function(w)
        moveToScreen(w, scr)
        hs.timer.doAfter(0.35, function() activateWindow(w, scr) end)
        logger.i(string.format("[bring] 新建窗口 #%d 并搬到 %s", w:id(), scr:name()))
    end)
end

local function bindHotkey()
    if hotkey then hotkey:delete(); hotkey = nil end
    local mods, key = cfg.hotkey.mods, cfg.hotkey.key
    local ok, err = pcall(function()
        hotkey = hs.hotkey.bind(mods, key, function() M.bring() end)
    end)
    if not ok then
        logger.w(string.format("绑定快捷键失败 %s+%s: %s", table.concat(mods, "+"), key, tostring(err)))
        return
    end
    logger.i(string.format("已绑定：%s+%s 在当前桌面唤出访达", table.concat(mods, "+"), key))
end

function M.start()
    readConfig()
    bindHotkey()
    if configWatcher then configWatcher:stop(); configWatcher = nil end
    configWatcher = hs.pathwatcher.new(configFile, function()
        hs.timer.doAfter(0.15, function()
            readConfig()
            bindHotkey()
            logger.i("配置已热重载")
        end)
    end):start()
end

function M.stop()
    if hotkey then hotkey:delete(); hotkey = nil end
    if configWatcher then configWatcher:stop(); configWatcher = nil end
    if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
    if winMoveTimer then winMoveTimer:stop(); winMoveTimer = nil end
end

return M
