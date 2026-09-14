--- modules/page_turner.lua
--- 蓝牙翻页器按键改造
---
--- 把蓝牙翻页器（HID 键盘设备）的按键重映射为 回车 / 换行 / 取消，
--- 用于在 WorkBuddy、CodeBuddy 等对话式 App 中脱离键盘操作。
---
--- 使用流程：
---   1. 连接翻页器，菜单栏 📖 → 「开始探测按键」，逐个按下翻页器按键
---   2. 探测结果会写入控制台并弹提示，记下 keyCode 与 deviceType
---   3. 菜单栏 📖 → 「编辑配置」，把键码填进 bindings
---   4. 菜单栏 📖 → 「启用映射」
---
--- 配置文件: config/page_turner.json（保存后自动热重载）

local M = {}

local logger = hs.logger.new("PageTurner", "info")
local configFile = hs.configdir .. "/config/page_turner.json"
-- 探测结果落盘，便于事后查看/排查（每次开启探测会清空）
local detectLogFile = "/tmp/page_turner_detect.log"

-- 合成事件的标记值，防止自己生成的事件被再次拦截造成死循环
local MAGIC = 0x50544E52 -- "PTNR"

------------------------------------------------------------
-- 动作预设
------------------------------------------------------------
-- 每个动作 = 一组修饰键 + 一个主键
local ACTIONS = {
    send      = { mods = {},                key = "return", label = "回车 / 发送" },
    newline   = { mods = { "shift" },       key = "return", label = "换行" },
    cancel    = { mods = {},                key = "escape", label = "取消 / 停止" },
    undo      = { mods = { "cmd" },         key = "z",      label = "撤销" },
    redo      = { mods = { "cmd", "shift" }, key = "z",     label = "重做" },
    -- 备用：部分编辑器用 Cmd+Enter 提交
    submitCmd = { mods = { "cmd" },         key = "return", label = "Cmd+回车" },
    -- 备用：新建对话
    newChat   = { mods = { "cmd", "shift" }, key = "n",     label = "新建对话" },
}

------------------------------------------------------------
-- 特殊动作（需要合成 fn 硬件修饰键，无法用 newKeyEvent 表达）
------------------------------------------------------------
-- voice: 点按一次 fn，触发微信输入法语音输入
--        （微信输入法已设置为「按一次 fn 开始接收，按其他键结束」，
--          因此这里只需一次完整的 fn 按下+抬起，无需维持按住状态）
local SPECIAL = {
    voice = { label = "🎤 语音输入" },
}

------------------------------------------------------------
-- 默认配置
------------------------------------------------------------
local DEFAULT_CONFIG = {
    enabled = false,
    -- 设备过滤：nil = 不限设备；填数字则只对该 keyboardType 生效（探测模式可查看）
    deviceType = nil,
    -- 只在这些 App 前台时生效（bundleID 或 App 名称均可）
    targetApps = {
        "com.tencent.workbuddy.mac",
        "com.tencent.codebuddycn",
    },
    restrictToTargetApps = true,
    -- 是否允许长按连发（默认关闭，避免误发多条）
    allowRepeat = false,
    -- 是否显示菜单栏图标
    showMenubar = true,
    -- 触发时是否弹出轻提示
    showFeedback = true,
    -- fn 点按的按下-抬起间隔（毫秒）。太短可能被输入法漏检，太长无意义
    fnTapGapMs = 40,
    -- 普通按键映射：keyCode(字符串) -> { action = ... }
    bindings = {},
    -- 媒体键映射（部分翻页器发音量键）：SOUND_UP / SOUND_DOWN / PLAY / NEXT / PREVIOUS
    systemBindings = {},
}

local cfg = {}
local tap = nil
local sysTap = nil
local detectTap = nil
local detectSysTap = nil
local detectTimer = nil
local menubar = nil
local configWatcher = nil
local swallowKeyUp = {} -- keyCode -> true，用于吞掉配对的 keyUp

------------------------------------------------------------
-- 工具函数
------------------------------------------------------------
local function shallowMerge(base, override)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(override or {}) do out[k] = v end
    return out
end

local function keyName(code)
    return hs.keycodes.map[code] or ("code#" .. tostring(code))
end

local function resolveAction(binding)
    if not binding then return nil end
    -- 特殊有状态动作（fn 语音）
    if binding.action and SPECIAL[binding.action] then
        return { special = binding.action, label = SPECIAL[binding.action].label }
    end
    -- 预设动作
    if binding.action and ACTIONS[binding.action] then
        return ACTIONS[binding.action]
    end
    -- 自定义 { mods = {...}, key = "..." }
    if binding.key then
        return { mods = binding.mods or {}, key = binding.key, label = binding.label or binding.key }
    end
    return nil
end

-- 注意：macOS 的 App 名称是本地化的（TextEdit 在中文系统下 name() 返回「文本编辑」），
-- 因此 targetApps 强烈建议填 bundleID。这里同时兼容名称匹配（忽略大小写）作为兜底。
local function isTargetAppFocused()
    if not cfg.restrictToTargetApps then return true end
    local app = hs.application.frontmostApplication()
    if not app then return false end
    local bundleID = app:bundleID()
    local name = app:name()
    for _, want in ipairs(cfg.targetApps or {}) do
        if want == bundleID then return true end
        if name and want and name:lower() == tostring(want):lower() then return true end
    end
    return false
end

local function isOwnEvent(e)
    local ud = e:getProperty(hs.eventtap.event.properties.eventSourceUserData)
    return ud == MAGIC
end

local function deviceMatches(e)
    if cfg.deviceType == nil then return true end
    local kt = e:getProperty(hs.eventtap.event.properties.keyboardEventKeyboardType)
    return kt == cfg.deviceType
end

-- 构造合成按键事件（带防循环标记）
--
-- 必须用 newKeyEventSequence 而不是 newKeyEvent：
--   newKeyEvent 只产生一个「附带修饰键 flag」的孤立 keyDown，
--   不会发出独立的 flagsChanged 事件，且 flag 只有通用位（如 alt=0x80000）。
--   而输入法/快捷键监听器（如微信输入法 ShortcutKeyMonitor.handleFlagsChanged(keyCode:flags:)）
--   依赖 flagsChanged 事件及其 keyCode 来判定「哪个修饰键、左还是右」，
--   收不到就不会匹配快捷键，事件会直接透传成字符（Option+P → π）。
--
-- newKeyEventSequence 产生完整的物理按键序列，并自带左键设备位：
--   flagsChanged(keyCode=58 左Option, flags=0x20080020)
--   keyDown(p) / keyUp(p)
--   flagsChanged(keyCode=58, flags=0x20000000)
local function buildKeyEvents(action)
    local seq = hs.eventtap.event.newKeyEventSequence(action.mods, action.key)

    -- 补齐修饰键 flag：newKeyEventSequence 生成的 keyDown/keyUp 不带修饰键位
    -- （它认为已由 flagsChanged 声明过），但真实物理按键的 keyDown 是带 flag 的。
    -- 不补的话应用会收到「裸键」——例如 Option+P 会退化成单独的 p。
    local modSet = {}
    local hasMods = false
    for _, m in ipairs(action.mods or {}) do
        modSet[m] = true
        hasMods = true
    end

    local kd = hs.eventtap.event.types.keyDown
    local ku = hs.eventtap.event.types.keyUp
    for _, e in ipairs(seq) do
        local t = e:getType()
        if hasMods and (t == kd or t == ku) then
            e:setFlags(modSet)
        end
        e:setProperty(hs.eventtap.event.properties.eventSourceUserData, MAGIC)
    end
    return seq
end

local function feedback(text, duration)
    if cfg.showFeedback then
        hs.alert.closeAll(0)
        hs.alert.show(text, { radius = 12, textSize = 15 }, duration or 0.45)
    end
end

------------------------------------------------------------
-- fn 修饰键合成（触发微信输入法语音输入）
------------------------------------------------------------
-- fn 是硬件级修饰键，hs.eventtap.event.newKeyEvent 无法表达，
-- 必须手工构造 flagsChanged 事件并设置 keyCode=63 才能注入 CGEvent 流。
-- 实测：合成的 fn down/up 均可被 eventtap 观测到，确认事件已进入系统事件流。
local FN_KEYCODE = 63

local function postFnFlag(down)
    local e = hs.eventtap.event.newKeyEvent({}, "a", true)
    e:setType(hs.eventtap.event.types.flagsChanged)
    e:setKeyCode(FN_KEYCODE)
    e:setFlags(down and { fn = true } or {})
    e:setProperty(hs.eventtap.event.properties.eventSourceUserData, MAGIC)
    e:post()
end

-- 点按一次 fn（按下 → 短暂间隔 → 抬起）
-- 间隔是必要的：down/up 背靠背发送可能被输入法当作抖动过滤掉
local function fnTap()
    postFnFlag(true)
    hs.timer.doAfter((cfg.fnTapGapMs or 40) / 1000, function()
        postFnFlag(false)
    end)
    logger.i("[fn] 已点按")
end

-- 兜底：手工清除可能残留的 fn 标志（正常流程用不到）
function M.releaseFn()
    postFnFlag(false)
    hs.alert.show("已清除 fn 标志", 1)
end

------------------------------------------------------------
-- 映射主逻辑
------------------------------------------------------------
local function handleKeyEvent(e)
    if isOwnEvent(e) then return false end

    local etype = e:getType()
    local code = e:getKeyCode()
    local binding = (cfg.bindings or {})[tostring(code)]
    local action = resolveAction(binding)

    -- keyUp：吞掉之前被映射的那个键，避免目标 App 收到孤立的 keyUp
    -- 必须同时校验设备，否则主键盘按下同一个键时其 keyUp 会被误吞
    if etype == hs.eventtap.event.types.keyUp then
        if swallowKeyUp[code] and deviceMatches(e) then
            swallowKeyUp[code] = nil
            return true
        end
        return false
    end

    if not action then return false end
    if not deviceMatches(e) then return false end
    if not isTargetAppFocused() then return false end

    local isRepeat = e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
    local repeating = (isRepeat and isRepeat ~= 0)

    ---------------------------------------------------------
    -- 特殊动作：点按 fn 触发语音输入
    ---------------------------------------------------------
    if action.special == "voice" then
        if repeating then return true end -- 吞掉长按连发，避免重复触发
        swallowKeyUp[code] = true
        fnTap()
        feedback("🎤 语音输入", 0.6)
        return true
    end

    ---------------------------------------------------------
    -- 普通动作：一次性击发 mods + key
    ---------------------------------------------------------
    if repeating and not cfg.allowRepeat then
        return true -- 吞掉重复事件，但不触发动作
    end

    swallowKeyUp[code] = true
    logger.i(string.format("[map] %s(%d) -> %s", keyName(code), code, action.label or action.key))
    feedback(action.label or action.key)
    return true, buildKeyEvents(action)
end

local function handleSystemEvent(e)
    if isOwnEvent(e) then return false end

    local data = e:systemKey()
    if not data or not data.key then return false end

    local binding = (cfg.systemBindings or {})[data.key]
    local action = resolveAction(binding)
    if not action then return false end
    if not isTargetAppFocused() then return false end

    -- 媒体键按下时触发，抬起时只吞掉
    if not data.down then return true end
    if data.repeatKey and not cfg.allowRepeat then return true end

    logger.i(string.format("[map] %s -> %s", data.key, action.label or action.key))
    feedback(action.label or action.key)
    return true, buildKeyEvents(action)
end

------------------------------------------------------------
-- 探测模式：只记录，不拦截
------------------------------------------------------------
-- 探测日志落盘：便于事后完整回看，不必依赖转瞬即逝的屏幕提示
local function detectLog(line)
    local f = io.open(detectLogFile, "a")
    if f then
        f:write(os.date("%H:%M:%S.") .. string.format("%03d", math.floor((hs.timer.secondsSinceEpoch() % 1) * 1000))
            .. "  " .. line .. "\n")
        f:close()
    end
end

local function detectReport(lines)
    local text = table.concat(lines, "\n")
    print("\n===== 翻页器按键探测 =====\n" .. text .. "\n=========================")
    hs.alert.closeAll(0)
    hs.alert.show(text, { radius = 12, textSize = 14 }, 2.2)
end

function M.startDetect(seconds)
    seconds = seconds or 60
    M.stopDetect()

    -- 每次开启探测清空日志，避免多次探测结果混淆
    local f = io.open(detectLogFile, "w")
    if f then
        f:write("===== 翻页器按键探测 " .. os.date("%Y-%m-%d %H:%M:%S") .. " =====\n")
        f:close()
    end

    detectTap = hs.eventtap.new(
        { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
        function(e)
            if isOwnEvent(e) then return false end
            local isDown = (e:getType() == hs.eventtap.event.types.keyDown)
            local code = e:getKeyCode()
            local kt = e:getProperty(hs.eventtap.event.properties.keyboardEventKeyboardType)
            local rep = e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
            local mods = {}
            for m, on in pairs(e:getFlags()) do
                if on == true then table.insert(mods, m) end
            end
            local app = hs.application.frontmostApplication()

            -- 完整记录 down 与 up，用于判断设备是否发出成对事件
            detectLog(string.format(
                "%-7s keyCode=%-4d keyName=%-12s deviceType=%-6s repeat=%-3s mods=%-12s app=%s",
                isDown and "[DOWN]" or "[UP]",
                code, keyName(code), tostring(kt),
                tostring(rep or 0),
                (#mods > 0 and table.concat(mods, "+") or "-"),
                (app and tostring(app:bundleID()) or "?")
            ))

            -- 屏幕提示只在按下时弹，避免刷屏
            if isDown then
                detectReport({
                    "键码 keyCode: " .. tostring(code),
                    "键名: " .. keyName(code),
                    "设备 deviceType: " .. tostring(kt),
                    "修饰键: " .. (#mods > 0 and table.concat(mods, "+") or "无"),
                    "前台 App bundleID: " .. (app and tostring(app:bundleID()) or "未知"),
                })
            end
            return false
        end
    )
    detectTap:start()

    detectSysTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
        if isOwnEvent(e) then return false end
        local data = e:systemKey()
        if data and data.key then
            detectLog(string.format("[SYS]   systemKey=%s down=%s repeat=%s",
                tostring(data.key), tostring(data.down), tostring(data.repeatKey)))
            if data.down then
                detectReport({
                    "媒体键 systemKey: " .. tostring(data.key),
                    "（填入 systemBindings）",
                })
            end
        end
        return false
    end)
    detectSysTap:start()

    detectTimer = hs.timer.doAfter(seconds, function()
        M.stopDetect()
        hs.alert.show("翻页器探测已自动结束", 1.2)
    end)

    logger.i("探测模式已开启，持续 " .. seconds .. " 秒")
    hs.alert.show("翻页器探测中：请逐个按下按键\n（" .. seconds .. " 秒后自动结束）", 2.5)
    M.refreshMenubar()
end

function M.stopDetect()
    if detectTap then detectTap:stop(); detectTap = nil end
    if detectSysTap then detectSysTap:stop(); detectSysTap = nil end
    if detectTimer then detectTimer:stop(); detectTimer = nil end
    M.refreshMenubar()
end

function M.isDetecting()
    return detectTap ~= nil
end

------------------------------------------------------------
-- 启停
------------------------------------------------------------
local function startTaps()
    if tap then return end
    tap = hs.eventtap.new(
        { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
        handleKeyEvent
    )
    tap:start()

    sysTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, handleSystemEvent)
    sysTap:start()
    logger.i("映射已启动")
end

local function stopTaps()
    if tap then tap:stop(); tap = nil end
    if sysTap then sysTap:stop(); sysTap = nil end
    swallowKeyUp = {}
    logger.i("映射已停止")
end

function M.enable()
    cfg.enabled = true
    startTaps()
    M.saveConfig()
    M.refreshMenubar()
    hs.alert.show("翻页器映射已启用", 1)
end

function M.disable()
    cfg.enabled = false
    stopTaps()
    M.saveConfig()
    M.refreshMenubar()
    hs.alert.show("翻页器映射已停用", 1)
end

function M.toggle()
    if cfg.enabled then M.disable() else M.enable() end
end

------------------------------------------------------------
-- 配置加载
------------------------------------------------------------
local function writeDefaultConfig()
    local f = io.open(configFile, "w")
    if not f then
        logger.e("无法创建配置文件: " .. configFile)
        return
    end
    f:write(hs.json.encode(DEFAULT_CONFIG, true))
    f:close()
    logger.i("已生成默认配置: " .. configFile)
end

local function loadConfig()
    local f = io.open(configFile, "r")
    if not f then
        logger.w("配置文件不存在，生成默认配置")
        writeDefaultConfig()
        cfg = shallowMerge(DEFAULT_CONFIG, {})
        return
    end

    local content = f:read("*a")
    f:close()

    local ok, data = pcall(hs.json.decode, content)
    if not ok or type(data) ~= "table" then
        logger.e("配置解析失败，使用默认值。请检查 JSON 格式: " .. configFile)
        cfg = shallowMerge(DEFAULT_CONFIG, {})
        return
    end

    cfg = shallowMerge(DEFAULT_CONFIG, data)
    logger.i("配置已加载，enabled=" .. tostring(cfg.enabled))
end

-- 把当前内存配置写回磁盘（用于菜单栏操作的持久化，重启后不丢）
function M.saveConfig()
    local f = io.open(configFile, "w")
    if not f then
        logger.e("无法写入配置文件: " .. configFile)
        return false
    end
    local ok, encoded = pcall(hs.json.encode, cfg, true)
    if not ok then
        f:close()
        logger.e("配置序列化失败: " .. tostring(encoded))
        return false
    end
    f:write(encoded)
    f:close()
    logger.i("配置已保存")
    return true
end

local function applyConfig()
    if cfg.enabled then startTaps() else stopTaps() end
    M.refreshMenubar()
end

------------------------------------------------------------
-- 菜单栏
------------------------------------------------------------
local function bindingSummary()
    local items = {}
    for code, binding in pairs(cfg.bindings or {}) do
        local action = resolveAction(binding)
        if action then
            table.insert(items, {
                title = string.format("    %s  →  %s", keyName(tonumber(code) or -1), action.label or action.key),
                disabled = true,
            })
        end
    end
    for key, binding in pairs(cfg.systemBindings or {}) do
        local action = resolveAction(binding)
        if action then
            table.insert(items, {
                title = string.format("    %s  →  %s", key, action.label or action.key),
                disabled = true,
            })
        end
    end
    if #items == 0 then
        table.insert(items, { title = "    （尚未配置，请先探测按键）", disabled = true })
    end
    return items
end

function M.refreshMenubar()
    if not menubar then return end

    menubar:setTitle(cfg.enabled and "📖" or "📕")

    local items = {
        {
            title = cfg.enabled and "✅ 映射已启用" or "⭕️ 映射已停用",
            fn = function() M.toggle() end,
        },
        { title = "-" },
        {
            title = M.isDetecting() and "⏹ 停止探测按键" or "🔍 开始探测按键",
            fn = function()
                if M.isDetecting() then M.stopDetect() else M.startDetect(60) end
            end,
        },
        { title = "-" },
        { title = "当前映射", disabled = true },
    }

    for _, item in ipairs(bindingSummary()) do
        table.insert(items, item)
    end

    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "仅在 WorkBuddy / CodeBuddy 生效",
        checked = cfg.restrictToTargetApps,
        fn = function()
            cfg.restrictToTargetApps = not cfg.restrictToTargetApps
            M.saveConfig()
            M.refreshMenubar()
            hs.alert.show(cfg.restrictToTargetApps and "已限定目标 App" or "已改为全局生效", 1)
        end,
    })
    table.insert(items, {
        title = "把当前前台 App 加入白名单",
        fn = function()
            local app = hs.application.frontmostApplication()
            local bid = app and app:bundleID()
            if not bid then
                hs.alert.show("无法获取当前 App 的 bundleID", 1.5)
                return
            end
            for _, want in ipairs(cfg.targetApps or {}) do
                if want == bid then
                    hs.alert.show(bid .. "\n已在白名单中", 1.5)
                    return
                end
            end
            table.insert(cfg.targetApps, bid)
            M.saveConfig()
            M.refreshMenubar()
            hs.alert.show("已加入白名单:\n" .. bid, 1.8)
        end,
    })
    table.insert(items, {
        title = "编辑配置...",
        fn = function() hs.execute("open -t " .. configFile) end,
    })
    table.insert(items, {
        title = "重新加载配置",
        fn = function()
            loadConfig()
            applyConfig()
            hs.alert.show("翻页器配置已重载", 1)
        end,
    })

    menubar:setMenu(items)
end

------------------------------------------------------------
-- 入口
------------------------------------------------------------
function M.start()
    loadConfig()

    if cfg.showMenubar and not menubar then
        menubar = hs.menubar.new()
    end

    configWatcher = hs.pathwatcher.new(configFile, function()
        logger.i("检测到配置变化，重新加载")
        loadConfig()
        applyConfig()
    end)
    configWatcher:start()

    applyConfig()

    -- 控制台调试入口
    hs.pageTurner = M
end

function M.stop()
    stopTaps()
    M.stopDetect()
    if configWatcher then configWatcher:stop(); configWatcher = nil end
    if menubar then menubar:delete(); menubar = nil end
end

function M.status()
    print("=== 翻页器映射状态 ===")
    print("启用:", cfg.enabled)
    print("探测中:", M.isDetecting())
    print("限定 App:", cfg.restrictToTargetApps, hs.inspect(cfg.targetApps))
    print("设备过滤 deviceType:", tostring(cfg.deviceType))
    print("按键映射:", hs.inspect(cfg.bindings))
    print("媒体键映射:", hs.inspect(cfg.systemBindings))
end

return M
