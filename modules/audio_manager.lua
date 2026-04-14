-- ============================================================
-- Audio Manager — 音频设备优先级自动管理 (降级版)
-- ============================================================
-- 变更记录:
--   v2 (2026-03-30): 降级方案 — 降低轮询频率、事件节流、
--                     减少 CoreAudio API 调用，避免干扰 screenpipe 等录音软件
-- 功能:
--   1. 按优先级列表自动选择输出/输入设备
--   2. 设备插拔时自动切换到最高优先级可用设备
--   3. 菜单栏实时显示当前设备 / 快速切换
--   4. 快捷键: Cmd+Shift+O/I/A
--   5. 手动切换后暂停自动管理 (30 分钟超时 / 设备拔插恢复)
-- ============================================================

local M = {}

local configDir  = hs.configdir
local configFile = configDir .. "/config/audio_devices.json"
local logger     = hs.logger.new("AudioMgr", "info")

-- 状态
local audioConfig     = {}
local menubar         = nil
local deviceWatcher   = nil
local configWatcher   = nil
local switchTimer     = nil
local pollTimer       = nil
local lastOutName     = nil
local lastInName      = nil
local manualOverride  = false
local overrideTimer   = nil

-- ============================================================
-- 降级参数
-- ============================================================
local POLL_INTERVAL    = 10   -- 轮询间隔 (秒)，原 3s → 10s
local SWITCH_DELAY     = 1.5  -- 切换延迟 (秒)，原 0.8s → 1.5s，给 CoreAudio 更多缓冲
local DEBOUNCE_WINDOW  = 2.0  -- 事件节流窗口 (秒)，连续事件只处理最后一个
local OVERRIDE_TIMEOUT = 30   -- 手动覆盖超时 (分钟)

-- ============================================================
-- 配置加载
-- ============================================================

local function loadConfig()
    local file = io.open(configFile, "r")
    if not file then
        logger.w("配置文件不存在: " .. configFile)
        audioConfig = {}
        return false
    end
    local content = file:read("*a")
    file:close()

    local ok, data = pcall(hs.json.decode, content)
    if ok and data then
        audioConfig = data
        logger.i("已加载音频配置")
        return true
    else
        logger.e("配置文件解析失败")
        audioConfig = {}
        return false
    end
end

-- ============================================================
-- 核心: 按优先级查找最佳设备
-- ============================================================

local function findHighestPriorityDevice(deviceType)
    local section = audioConfig[deviceType]
    if not section or not section.priority then return nil end

    local available
    if deviceType == "output" then
        available = hs.audiodevice.allOutputDevices()
    else
        available = hs.audiodevice.allInputDevices()
    end

    local nameMap = {}
    for _, dev in ipairs(available) do
        nameMap[dev:name()] = dev
    end

    for _, name in ipairs(section.priority) do
        if nameMap[name] then
            return nameMap[name]
        end
    end

    return nil
end

-- ============================================================
-- 自动切换 (带保护)
-- ============================================================

local function autoSwitchDevice(deviceType)
    local section = audioConfig[deviceType]
    if not section or not section.priority then return end

    local best = findHighestPriorityDevice(deviceType)
    if not best then return end

    local current
    if deviceType == "output" then
        current = hs.audiodevice.defaultOutputDevice()
    else
        current = hs.audiodevice.defaultInputDevice()
    end

    if current and current:name() == best:name() then
        logger.i("[" .. deviceType .. "] 已是最优: " .. best:name())
        return
    end

    local ok
    if deviceType == "output" then
        ok = best:setDefaultOutputDevice()
        if ok then best:setDefaultEffectDevice() end
    else
        ok = best:setDefaultInputDevice()
    end

    if ok then
        logger.i("[" .. deviceType .. "] ✅ 切换到: " .. best:name())
        hs.alert("🔊 " .. (deviceType == "output" and "输出" or "输入") .. ": " .. best:name(), 1.5)
    else
        logger.w("[" .. deviceType .. "] 切换失败: " .. best:name())
    end
end

local function autoSwitchAll()
    if not audioConfig.autoSwitch then return end
    if manualOverride then
        logger.i("[auto] 手动覆盖生效中，跳过自动切换")
        return
    end
    autoSwitchDevice("output")
    autoSwitchDevice("input")
end

-- ============================================================
-- 手动覆盖
-- ============================================================

local function updateMenubar() end  -- 前向声明，后面覆盖

local function activateManualOverride()
    manualOverride = true
    if overrideTimer then overrideTimer:stop() end
    overrideTimer = hs.timer.doAfter(OVERRIDE_TIMEOUT * 60, function()
        manualOverride = false
        logger.i("[override] 手动覆盖已超时，恢复自动切换")
        autoSwitchAll()
        updateMenubar()
    end)
    logger.i("[override] 手动覆盖激活 (" .. OVERRIDE_TIMEOUT .. " 分钟超时)")
end

local function clearManualOverride()
    if manualOverride then
        manualOverride = false
        if overrideTimer then overrideTimer:stop(); overrideTimer = nil end
        logger.i("[override] 设备变化，手动覆盖已清除")
    end
end

-- ============================================================
-- 手动循环切换
-- ============================================================

local function switchToNextDevice(deviceType)
    local available
    if deviceType == "output" then
        available = hs.audiodevice.allOutputDevices()
    else
        available = hs.audiodevice.allInputDevices()
    end

    if #available == 0 then return end

    local current
    if deviceType == "output" then
        current = hs.audiodevice.defaultOutputDevice()
    else
        current = hs.audiodevice.defaultInputDevice()
    end

    local currentName = current and current:name() or ""
    local currentIdx = 0

    for i, dev in ipairs(available) do
        if dev:name() == currentName then
            currentIdx = i
            break
        end
    end

    local nextIdx = (currentIdx % #available) + 1
    local nextDev = available[nextIdx]

    local ok
    if deviceType == "output" then
        ok = nextDev:setDefaultOutputDevice()
        if ok then nextDev:setDefaultEffectDevice() end
    else
        ok = nextDev:setDefaultInputDevice()
    end

    if ok then
        local label = deviceType == "output" and "🔊 输出" or "🎤 输入"
        hs.alert(label .. ": " .. nextDev:name(), 2)
        logger.i("[manual] " .. deviceType .. " -> " .. nextDev:name())
        activateManualOverride()
    end
end

-- ============================================================
-- 菜单栏
-- ============================================================

updateMenubar = function()
    if not menubar then return end

    local outDev = hs.audiodevice.defaultOutputDevice()
    local inDev  = hs.audiodevice.defaultInputDevice()
    local outName = outDev and outDev:name() or "?"
    local inName  = inDev  and inDev:name()  or "?"

    -- 缩写设备名映射，常见设备用短名
    local abbrevMap = {
        ["WH%-1000XM3"]     = "XM3",
        ["WH%-1000XM4"]     = "XM4",
        ["WH%-1000XM5"]     = "XM5",
        ["Jabra EVOLVE"]    = "Jabra",
        ["MacBook Pro"]     = "MBP",
        ["MacBook Air"]     = "MBA",
        ["Built%-in"]       = "内置",
        ["外置"]            = "外置",
    }
    local function shorten(name)
        for pattern, short in pairs(abbrevMap) do
            if name:find(pattern) then return short end
        end
        -- 兜底：取前 5 字符
        return #name > 5 and name:sub(1, 5) .. "…" or name
    end
    menubar:setTitle("🔊" .. shorten(outName) .. " 🎤" .. shorten(inName))

    local items = {}

    table.insert(items, { title = "🔊 输出: " .. outName, disabled = true })
    table.insert(items, { title = "🎤 输入: " .. inName,  disabled = true })
    table.insert(items, { title = "-" })

    table.insert(items, { title = "切换输出设备", disabled = true })
    for _, dev in ipairs(hs.audiodevice.allOutputDevices()) do
        local name = dev:name()
        local mark = (outDev and name == outName) and "  ● " or "    "
        table.insert(items, {
            title = mark .. name,
            fn = function()
                dev:setDefaultOutputDevice()
                dev:setDefaultEffectDevice()
                activateManualOverride()
                hs.alert("🔊 输出: " .. name, 1.5)
                updateMenubar()
            end,
        })
    end

    table.insert(items, { title = "-" })

    table.insert(items, { title = "切换输入设备", disabled = true })
    for _, dev in ipairs(hs.audiodevice.allInputDevices()) do
        local name = dev:name()
        local mark = (inDev and name == inName) and "  ● " or "    "
        table.insert(items, {
            title = mark .. name,
            fn = function()
                dev:setDefaultInputDevice()
                activateManualOverride()
                hs.alert("🎤 输入: " .. name, 1.5)
                updateMenubar()
            end,
        })
    end

    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "自动切换: " .. (audioConfig.autoSwitch and "✅ 开启" or "❌ 关闭"),
        fn = function()
            audioConfig.autoSwitch = not audioConfig.autoSwitch
            local file = io.open(configFile, "w")
            if file then
                file:write(hs.json.encode(audioConfig, true))
                file:close()
            end
            updateMenubar()
        end,
    })
    if manualOverride then
        table.insert(items, {
            title = "🔒 手动锁定中 (点击解除)",
            fn = function()
                clearManualOverride()
                autoSwitchAll()
                updateMenubar()
                hs.alert("🔓 已恢复自动切换", 1.5)
            end,
        })
    end
    table.insert(items, {
        title = "立即按优先级切换",
        fn = function()
            clearManualOverride()
            autoSwitchDevice("input")
            autoSwitchDevice("output")
            updateMenubar()
        end,
    })

    menubar:setMenu(items)
end

-- ============================================================
-- 设备变化监听 (带节流)
-- ============================================================

local function setupDeviceWatcher()
    deviceWatcher = hs.audiodevice.watcher.setCallback(function(event)
        logger.i("音频事件: " .. event)
        clearManualOverride()
        -- 节流: 连续事件只响应最后一个
        if switchTimer then switchTimer:stop() end
        switchTimer = hs.timer.doAfter(DEBOUNCE_WINDOW, function()
            autoSwitchAll()
            updateMenubar()
            -- 更新轮询基线
            local o = hs.audiodevice.defaultOutputDevice()
            local i = hs.audiodevice.defaultInputDevice()
            lastOutName = o and o:name() or ""
            lastInName  = i and i:name()  or ""
        end)
    end)
    hs.audiodevice.watcher.start()
end

-- ============================================================
-- 轮询补充 (降频版)
-- ============================================================

local function setupPollTimer()
    local outDev = hs.audiodevice.defaultOutputDevice()
    local inDev  = hs.audiodevice.defaultInputDevice()
    lastOutName = outDev and outDev:name() or ""
    lastInName  = inDev  and inDev:name()  or ""

    pollTimer = hs.timer.doEvery(POLL_INTERVAL, function()
        local curOut = hs.audiodevice.defaultOutputDevice()
        local curIn  = hs.audiodevice.defaultInputDevice()
        local curOutName = curOut and curOut:name() or ""
        local curInName  = curIn  and curIn:name()  or ""

        if curOutName ~= lastOutName or curInName ~= lastInName then
            logger.i("[poll] 检测到设备变化: 输出 " .. lastOutName .. " -> " .. curOutName
                     .. ", 输入 " .. lastInName .. " -> " .. curInName)
            lastOutName = curOutName
            lastInName  = curInName

            if manualOverride then
                logger.i("[poll] 手动覆盖生效中，仅更新显示")
                updateMenubar()
            else
                if switchTimer then switchTimer:stop() end
                switchTimer = hs.timer.doAfter(SWITCH_DELAY, function()
                    autoSwitchAll()
                    updateMenubar()
                    local o = hs.audiodevice.defaultOutputDevice()
                    local i = hs.audiodevice.defaultInputDevice()
                    lastOutName = o and o:name() or ""
                    lastInName  = i and i:name()  or ""
                end)
            end
        end
    end)
end

local function setupConfigWatcher()
    configWatcher = hs.pathwatcher.new(configFile, function()
        logger.i("配置文件变化，重新加载")
        loadConfig()
        autoSwitchAll()
        updateMenubar()
    end)
    configWatcher:start()
end

-- ============================================================
-- 快捷键
-- ============================================================

local hotkeys = {}

local function setupHotkeys()
    table.insert(hotkeys, hs.hotkey.bind({"cmd", "shift"}, "O", function()
        switchToNextDevice("output")
        updateMenubar()
    end))

    table.insert(hotkeys, hs.hotkey.bind({"cmd", "shift"}, "I", function()
        switchToNextDevice("input")
        updateMenubar()
    end))

    table.insert(hotkeys, hs.hotkey.bind({"cmd", "shift"}, "A", function()
        local outDev = hs.audiodevice.defaultOutputDevice()
        local inDev  = hs.audiodevice.defaultInputDevice()
        local msg = "🔊 " .. (outDev and outDev:name() or "无") .. "\n"
                 .. "🎤 " .. (inDev and inDev:name() or "无")
        hs.alert(msg, 3)
    end))
end

-- ============================================================
-- 调试: hs.dumpAudioDevices()
-- ============================================================

function hs.dumpAudioDevices()
    print("=== Audio Devices ===")
    print("\n--- Output ---")
    local outDev = hs.audiodevice.defaultOutputDevice()
    for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
        local mark = (outDev and d:uid() == outDev:uid()) and " ★" or ""
        print(string.format("  %s [uid=%s vol=%s muted=%s]%s",
            d:name(), d:uid(), tostring(d:volume()), tostring(d:muted()), mark))
    end
    print("\n--- Input ---")
    local inDev = hs.audiodevice.defaultInputDevice()
    for _, d in ipairs(hs.audiodevice.allInputDevices()) do
        local mark = (inDev and d:uid() == inDev:uid()) and " ★" or ""
        print(string.format("  %s [uid=%s vol=%s muted=%s]%s",
            d:name(), d:uid(), tostring(d:volume()), tostring(d:muted()), mark))
    end
    print("\n--- Config ---")
    print(hs.inspect(audioConfig))
    print("\n--- Degradation Params ---")
    print(string.format("  POLL_INTERVAL=%ds  SWITCH_DELAY=%.1fs  DEBOUNCE_WINDOW=%.1fs",
        POLL_INTERVAL, SWITCH_DELAY, DEBOUNCE_WINDOW))
end

-- ============================================================
-- 启动 / 停止
-- ============================================================

function M.start()
    loadConfig()
    menubar = hs.menubar.new()
    setupDeviceWatcher()
    setupPollTimer()
    setupConfigWatcher()
    setupHotkeys()

    -- 启动时延迟首次自动切换，给系统音频子系统一些缓冲
    hs.timer.doAfter(SWITCH_DELAY, function()
        autoSwitchAll()
        updateMenubar()
    end)

    logger.i("Audio Manager 已启动 (降级模式: poll=" .. POLL_INTERVAL .. "s)")
end

function M.stop()
    if deviceWatcher then hs.audiodevice.watcher.stop() end
    if configWatcher then configWatcher:stop() end
    if switchTimer   then switchTimer:stop() end
    if pollTimer     then pollTimer:stop() end
    if overrideTimer then overrideTimer:stop() end
    manualOverride = false
    for _, hk in ipairs(hotkeys) do hk:delete() end
    hotkeys = {}
    if menubar then menubar:delete(); menubar = nil end
    logger.i("Audio Manager 已停止")
end

return M
