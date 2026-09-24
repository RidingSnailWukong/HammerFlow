--- modules/macro_keypad.lua
--- 6 键 USB 宏键盘映射
---
--- 设备实测：VID 0x413D / PID 0x553A，Hammerspoon keyboardType = 40。
--- 输入信号：Ctrl+C / Ctrl+V / Ctrl+S / Ctrl+A / Ctrl+F / Fn+ForwardDelete。
---
--- 设计边界：
---   1. 只处理 keyboardType=40，主键盘（本机实测 keyboardType=91）不受影响。
---   2. 精确匹配源修饰键，避免只按 keyCode 导致误触。
---   3. 吞掉设备自身的 flagsChanged/keyDown/keyUp，再注入目标事件。
---   4. 合成事件带 MAGIC，防止递归触发。
---
--- 配置文件：config/macro_keypad.json（保存后自动热重载）

local M = {}

local logger = hs.logger.new("MacroKeypad", "info")
local configFile = hs.configdir .. "/config/macro_keypad.json"
local MAGIC = 0x4D4B5044 -- "MKPD"

local DEFAULT_CONFIG = {
    enabled = false,
    deviceType = 40,
    strictModifiers = true,
    allowRepeat = false,
    showFeedback = false,
    doubleClickInterval = 0.4,
    bindings = {},
}

local cfg = {}
local tap = nil
local configWatcher = nil
local swallowKeyUp = {}
local pendingClicks = {}

local function shallowMerge(base, override)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(override or {}) do out[k] = v end
    return out
end

local function readConfig()
    local loaded = hs.json.read(configFile)
    if type(loaded) ~= "table" then
        logger.w("配置读取失败，使用停用状态: " .. configFile)
        loaded = {}
    end
    cfg = shallowMerge(DEFAULT_CONFIG, loaded)
end

local function isOwnEvent(e)
    return e:getProperty(hs.eventtap.event.properties.eventSourceUserData) == MAGIC
end

local function keyboardType(e)
    return e:getProperty(hs.eventtap.event.properties.keyboardEventKeyboardType)
end

local function deviceMatches(e)
    return cfg.deviceType == nil or keyboardType(e) == cfg.deviceType
end

local function normalizedFlags(e)
    local out = {}
    for name, enabled in pairs(e:getFlags() or {}) do
        if enabled then out[name] = true end
    end
    return out
end

local function modifiersMatch(e, required)
    local actual = normalizedFlags(e)
    local expected = {}
    for _, name in ipairs(required or {}) do expected[name] = true end

    for name in pairs(expected) do
        if not actual[name] then return false end
    end
    if cfg.strictModifiers then
        for name in pairs(actual) do
            if not expected[name] then return false end
        end
    end
    return true
end

local function buildKeyEvents(action)
    local mods = action.mods or {}
    local down = hs.eventtap.event.newKeyEvent(mods, action.key, true)
    local up = hs.eventtap.event.newKeyEvent(mods, action.key, false)
    down:setProperty(hs.eventtap.event.properties.eventSourceUserData, MAGIC)
    up:setProperty(hs.eventtap.event.properties.eventSourceUserData, MAGIC)
    return { down, up }
end

local function feedback(label)
    if not cfg.showFeedback or not label then return end
    hs.alert.closeAll(0)
    hs.alert.show(label, { radius = 10, textSize = 14 }, 0.35)
end

local function toggleApp(action)
    local bundleID = action.bundleID
    local appName = action.app
    local app = bundleID and hs.application.get(bundleID) or (appName and hs.application.get(appName))

    if app then
        if app:isFrontmost() then
            app:hide()
        else
            app:activate(true)
        end
        return
    end

    if bundleID then
        hs.application.launchOrFocusByBundleID(bundleID)
    elseif appName then
        hs.application.launchOrFocus(appName)
    end
end

local function cycleAppWindow(action)
    local bundleID = action.bundleID
    local appName = action.app
    local app = bundleID and hs.application.get(bundleID) or (appName and hs.application.get(appName))

    if not app then
        if bundleID then
            hs.application.launchOrFocusByBundleID(bundleID)
        elseif appName then
            hs.application.launchOrFocus(appName)
        end
        return
    end

    local windows = {}
    for _, window in ipairs(app:allWindows()) do
        if window:isStandard() then windows[#windows + 1] = window end
    end

    if #windows == 0 then
        app:activate(true)
        return
    end

    if #windows == 1 then
        windows[1]:focus()
        hs.alert.show(
            action.singleWindowHint or "当前只有 1 个可切换窗口",
            { radius = 10, textSize = 14 },
            1.2
        )
        logger.i("[cycle-window] 只有 1 个标准窗口，保持当前窗口")
        return
    end

    local focused = hs.window.focusedWindow()
    local focusedID = focused and focused:id() or nil
    local currentIndex = nil
    for index, window in ipairs(windows) do
        if window:id() == focusedID then
            currentIndex = index
            break
        end
    end

    local nextIndex = currentIndex and ((currentIndex % #windows) + 1) or 1
    local target = windows[nextIndex]
    if target:isMinimized() then target:unminimize() end
    target:focus()
end

local function cycleAppMenuWindow(action)
    local bundleID = action.bundleID
    local appName = action.app
    local app = bundleID and hs.application.get(bundleID) or (appName and hs.application.get(appName))

    if not app then
        if bundleID then
            hs.application.launchOrFocusByBundleID(bundleID)
        elseif appName then
            hs.application.launchOrFocus(appName)
        end
        return
    end

    app:activate(true)
    local menuItems = app:getMenuItems()
    local windowMenu = nil
    for _, item in ipairs(menuItems or {}) do
        if item.AXTitle == "窗口" or item.AXTitle == "Window" then
            windowMenu = item
            break
        end
    end

    local items = windowMenu and (windowMenu.AXChildren or {})[1] or nil
    if type(items) ~= "table" then
        logger.w("[cycle-menu-window] 找不到窗口菜单")
        return
    end

    local lastSeparator = 0
    for index, item in ipairs(items) do
        if item.AXTitle == "" then lastSeparator = index end
    end

    local windows = {}
    local currentIndex = nil
    for index = lastSeparator + 1, #items do
        local item = items[index]
        if item.AXEnabled and item.AXTitle and item.AXTitle ~= "" then
            windows[#windows + 1] = item.AXTitle
            if item.AXMenuItemMarkChar and item.AXMenuItemMarkChar ~= "" then
                currentIndex = #windows
            end
        end
    end

    if #windows < 2 then
        hs.alert.show(
            action.singleWindowHint or "当前只有 1 个可切换窗口",
            { radius = 10, textSize = 14 },
            1.2
        )
        logger.i("[cycle-menu-window] 可切换窗口不足 2 个")
        return
    end

    local nextIndex = currentIndex and ((currentIndex % #windows) + 1) or 1
    local targetTitle = windows[nextIndex]
    if not app:selectMenuItem({ windowMenu.AXTitle, targetTitle }) then
        logger.w("[cycle-menu-window] 选择窗口失败: " .. tostring(targetTitle))
        return
    end
    logger.i(string.format("[cycle-menu-window] %s -> %s",
        tostring(currentIndex and windows[currentIndex] or "?"), targetTitle))
end

local function switchAdjacentDesktop(action, context)
    local direction = action.direction
    local delta = direction == "left" and -1 or (direction == "right" and 1 or nil)
    if not delta then
        logger.w("[switch-desktop] 未知方向: " .. tostring(direction))
        return
    end

    -- immediateSingle 可能先把焦点带到 App 所在桌面；双击时仍应以第一次按下前的桌面为基准。
    local focusedSpace = context and context.initialSpace or hs.spaces.focusedSpace()
    local allSpaces = hs.spaces.allSpaces()
    for _, spaces in pairs(allSpaces) do
        for index, spaceID in ipairs(spaces) do
            if spaceID == focusedSpace then
                local targetIndex = index + delta
                local targetSpace = spaces[targetIndex]
                if not targetSpace then
                    local side = direction == "left" and "左边" or "右边"
                    hs.alert.show(
                        action.edgeHint or ("已经没有" .. side .. "的桌面"),
                        { radius = 10, textSize = 14 },
                        1.0
                    )
                    logger.i(string.format("[switch-desktop] 当前桌面 %d 已在%s边界", index, side))
                    return
                end
                hs.spaces.gotoSpace(targetSpace)
                logger.i(string.format("[switch-desktop] %d -> %d (%s)",
                    index, targetIndex, direction))
                return
            end
        end
    end

    logger.w("[switch-desktop] 找不到当前桌面: " .. tostring(focusedSpace))
end

local function runAction(action, context)
    if type(action) ~= "table" then return false, nil end

    if action.type == "keystroke" and action.key then
        return true, buildKeyEvents(action)
    end

    if action.type == "toggleApp" and (action.bundleID or action.app) then
        hs.timer.doAfter(0, function() toggleApp(action) end)
        return true, nil
    end

    if action.type == "launchApp" and (action.bundleID or action.app) then
        hs.timer.doAfter(0, function()
            if action.bundleID then
                hs.application.launchOrFocusByBundleID(action.bundleID)
            else
                hs.application.launchOrFocus(action.app)
            end
        end)
        return true, nil
    end

    if action.type == "cycleAppWindow" and (action.bundleID or action.app) then
        hs.timer.doAfter(0, function() cycleAppWindow(action) end)
        return true, nil
    end

    if action.type == "cycleAppMenuWindow" and (action.bundleID or action.app) then
        hs.timer.doAfter(0, function() cycleAppMenuWindow(action) end)
        return true, nil
    end

    if action.type == "switchDesktop" and action.direction then
        hs.timer.doAfter(0, function() switchAdjacentDesktop(action, context) end)
        return true, nil
    end

    logger.w("未知动作类型: " .. tostring(action.type))
    return false, nil
end

local function postEvents(events)
    for _, event in ipairs(events or {}) do event:post() end
end

local function performDeferredAction(action, label, context)
    local handled, events = runAction(action, context)
    if not handled then return false end
    postEvents(events)
    feedback(label)
    return true
end

local function closePendingHint(state)
    if state and state.alertID then
        hs.alert.closeSpecific(state.alertID, 0.05)
        state.alertID = nil
    end
end

local function stopPendingClicks()
    for code, state in pairs(pendingClicks) do
        if state.timer then state.timer:stop() end
        closePendingHint(state)
        pendingClicks[code] = nil
    end
end

local function handleSingleOrDoubleClick(code, binding)
    local state = pendingClicks[code]
    if state and state.timer then
        state.timer:stop()
        closePendingHint(state)
        pendingClicks[code] = nil
        local label = binding.doubleLabel or binding.label or "双击"
        local handled = performDeferredAction(binding.doubleAction, label, state)
        if handled then
            logger.i(string.format("[double] keyCode=%d -> %s", code, label))
        end
        return handled
    end

    if type(binding.singleAction) ~= "table" then return false end

    local interval = binding.doubleClickInterval or cfg.doubleClickInterval or 0.75
    local timer = nil
    local pendingState = {
        timer = nil,
        alertID = nil,
        initialSpace = hs.spaces.focusedSpace(),
    }
    if binding.pendingHint then
        pendingState.alertID = hs.alert.show(
            binding.pendingHint,
            { radius = 10, textSize = 14 },
            interval
        )
    end

    if binding.immediateSingle then
        local label = binding.singleLabel or binding.label or "单击"
        if not performDeferredAction(binding.singleAction, label) then
            closePendingHint(pendingState)
            return false
        end
        logger.i(string.format("[single-immediate] keyCode=%d -> %s", code, label))
        timer = hs.timer.doAfter(interval, function()
            local current = pendingClicks[code]
            if not current or current.timer ~= timer then return end
            closePendingHint(current)
            pendingClicks[code] = nil
        end)
    else
        timer = hs.timer.doAfter(interval, function()
            local current = pendingClicks[code]
            if not current or current.timer ~= timer then return end
            closePendingHint(current)
            pendingClicks[code] = nil
            local label = binding.singleLabel or binding.label or "单击"
            if performDeferredAction(binding.singleAction, label) then
                logger.i(string.format("[single] keyCode=%d -> %s", code, label))
            end
        end)
    end

    pendingState.timer = timer
    pendingClicks[code] = pendingState
    return true
end

local function handleEvent(e)
    if isOwnEvent(e) or not deviceMatches(e) then return false end

    local eventType = e:getType()
    local code = e:getKeyCode()

    -- 这把宏键盘会先发送 Ctrl flagsChanged，再发送字母键。
    -- 设备已经由 keyboardType 唯一识别，因此吞掉它的修饰键变化，避免 Ctrl 泄漏到前台 App。
    if eventType == hs.eventtap.event.types.flagsChanged then
        return true
    end

    if eventType == hs.eventtap.event.types.keyUp then
        if swallowKeyUp[code] then
            swallowKeyUp[code] = nil
            return true
        end
        return false
    end

    local binding = (cfg.bindings or {})[tostring(code)]
    if type(binding) ~= "table" then return false end
    if not modifiersMatch(e, binding.sourceMods or {}) then return false end

    local isRepeat = e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
    if isRepeat and isRepeat ~= 0 and not cfg.allowRepeat then
        return true
    end

    if binding.singleAction or binding.doubleAction then
        local handled = handleSingleOrDoubleClick(code, binding)
        if not handled then return false end
        swallowKeyUp[code] = true
        return true
    end

    local handled, events = runAction(binding.action)
    if not handled then return false end

    swallowKeyUp[code] = true
    logger.i(string.format("[map] type=%s keyCode=%d -> %s",
        tostring(keyboardType(e)), code, binding.label or (binding.action and binding.action.type) or "?"))
    feedback(binding.label)

    if events then return true, events end
    return true
end

local function stopTap()
    if tap then
        tap:stop()
        tap = nil
    end
    stopPendingClicks()
    swallowKeyUp = {}
end

local function tableSize(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function applyConfig()
    stopTap()
    readConfig()

    if not cfg.enabled then
        logger.i("映射已停用")
        return
    end

    tap = hs.eventtap.new({
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.keyUp,
        hs.eventtap.event.types.flagsChanged,
    }, handleEvent)
    tap:start()
    logger.i(string.format("映射已启用：deviceType=%s，bindings=%d",
        tostring(cfg.deviceType), tableSize(cfg.bindings)))
end

function M.start()
    applyConfig()
    if configWatcher then configWatcher:stop() end
    configWatcher = hs.pathwatcher.new(configFile, function()
        hs.timer.doAfter(0.15, applyConfig)
    end)
    configWatcher:start()
end

function M.stop()
    stopTap()
    if configWatcher then
        configWatcher:stop()
        configWatcher = nil
    end
end

function M.reload()
    applyConfig()
end

function M.isEnabled()
    return cfg.enabled == true and tap ~= nil
end

function M.deviceType()
    return cfg.deviceType
end

return M
