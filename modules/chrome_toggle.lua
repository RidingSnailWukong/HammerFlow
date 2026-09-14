-- Chrome 窗口管理（呼出/隐藏 + 跨屏循环切换）
--
-- 快捷键:
--   Ctrl+K         -> 呼出/隐藏（当前桌面优先）
--   Ctrl+`         -> 循环切换到下一个 Chrome 窗口（跨显示器）
--   Ctrl+Shift+`   -> 反向循环
--
-- 技术背景（排查结论，勿轻易改动枚举方式）:
--   1. macOS 自带的 Cmd+`（Move focus to next window）只在同一 Space 内循环，
--      不支持：其他显示器 / 其他桌面 / 全屏窗口 / 最小化窗口。
--      Chrome 自身也没有「循环所有窗口」的快捷键（其 Window 菜单不含窗口列表）。
--   2. Chromium 的 Accessibility 实现只把「当前 Space 的窗口」暴露给 AX，
--      所以 hs.application:allWindows() 在多屏场景下常常只返回 1 个窗口，
--      基于它做循环必然失效——这正是「点 Dock 图标只能跳到某一个」的底层原因。
--   3. hs.window.filter 走 CGWindowList 路径，能看到所有**位于屏幕上的**窗口
--      （含其他显示器上的窗口），因此本模块以它为主、app:allWindows() 为辅。
--   4. 局限：位于其他桌面(Space)、当前完全不可见的窗口，macOS 不向任何进程暴露，
--      无法纳入循环——需先切到该桌面。
--
-- 注: 以前 bundle id 写成小写 "com.google.chrome"（实际是 com.google.Chrome），
--     导致 hs.application.get() 永远返回 nil、toggle 逻辑从未生效。

local M = {}

local logger = hs.logger.new("ChromeToggle", "info")
local chromeBundleID = "com.google.Chrome"
local chromeAppNames = { "Google Chrome" }

-- 循环状态：focus 是异步生效的，快速连按时不能依赖 focusedWindow 的实时值
local cycleState = { index = 0, winID = nil }

-- 常驻 filter：复用以避免频繁创建导致的事件订阅泄漏
local chromeFilter = nil

-- ==================== 窗口枚举 ====================

-- 屏幕序号（用于稳定排序，主屏在前）
local function screenOrder(scr)
    if not scr then return 99 end
    local id = scr:id()
    for i, s in ipairs(hs.screen.allScreens()) do
        if s:id() == id then return i end
    end
    return 99
end

-- 收集所有 Chrome 标准窗口（跨屏），并做稳定排序
-- 排序键：屏幕序号 → x → y → 窗口 id
-- 稳定排序的意义：无论 API 返回顺序如何抖动，循环路径始终可预期
local function collectChromeWindows()
    local seen, list = {}, {}

    local function add(w)
        if not w then return end
        local id = w:id()
        if seen[id] then return end
        if not w:isStandard() then return end
        seen[id] = true
        list[#list + 1] = w
    end

    -- 来源 1: filter（CGWindowList 路径，可跨显示器）
    if chromeFilter then
        for _, w in ipairs(chromeFilter:getWindows()) do add(w) end
    end

    -- 来源 2: 应用自身窗口（AX 路径，兜底补齐当前 Space 的窗口）
    local app = hs.application.get(chromeBundleID)
    if app then
        for _, w in ipairs(app:allWindows()) do add(w) end
    end

    -- 稳定排序
    local key = {}
    for _, w in ipairs(list) do
        local f = w:frame()
        key[w:id()] = string.format("%02d_%08d_%08d_%08d",
            screenOrder(w:screen()), math.floor(f.x), math.floor(f.y), w:id())
    end
    table.sort(list, function(a, b)
        return key[a:id()] < key[b:id()]
    end)

    return list
end

-- 聚焦窗口（hs.window:focus() 会自动把应用带到前台，可跨显示器）
local function focusWindow(w)
    if not w then return end
    if w:isMinimized() then w:unminimize() end
    w:focus()
end

-- ==================== 呼出 / 隐藏 ====================
-- 行为（当前桌面优先）:
--   1. 未运行 -> 启动
--   2. 当前桌面上有 Chrome 窗口:
--        - Chrome 在前台 -> 隐藏
--        - Chrome 不在前台 -> 聚焦当前桌面上的那个窗口
--   3. 当前桌面上没有 Chrome 窗口 -> 跳转到主窗口所在桌面
local function toggleChrome()
    local app = hs.application.get(chromeBundleID)

    if not app then
        hs.application.launchOrFocusByBundleID(chromeBundleID)
        logger.i("Chrome 未运行，已启动")
        return
    end

    local frontApp = hs.application.frontmostApplication()
    local isFrontmost = frontApp and frontApp:bundleID() == chromeBundleID

    if isFrontmost then
        app:hide()
        logger.i("Chrome 已隐藏")
        return
    end

    -- 不在前台：聚焦当前聚焦窗口，否则退到第一个可用窗口
    local currentSpace = hs.spaces.focusedSpace()
    local wins = collectChromeWindows()

    local preferred
    for _, w in ipairs(wins) do
        local spaces = hs.spaces.windowSpaces(w:id())
        if spaces then
            for _, s in ipairs(spaces) do
                if s == currentSpace then preferred = w; break end
            end
        end
        if preferred then break end
    end

    focusWindow(preferred or wins[1] or app:mainWindow())
    logger.i(preferred and "已聚焦当前桌面上的 Chrome 窗口" or "已聚焦第一个可用 Chrome 窗口")
end

-- ==================== 跨屏循环切换 ====================
-- step = 1 下一个 / -1 上一个
local function cycleChrome(step)
    step = step or 1

    local app = hs.application.get(chromeBundleID)
    if not app then
        hs.application.launchOrFocusByBundleID(chromeBundleID)
        logger.i("Chrome 未运行，已启动")
        return
    end

    local wins = collectChromeWindows()
    local n = #wins

    -- 兜底：没有标准窗口时聚焦主窗口
    if n == 0 then
        focusWindow(app:mainWindow() or app:focusedWindow())
        logger.w("未枚举到 Chrome 标准窗口，回退到 mainWindow")
        return
    end

    -- 只有一个窗口：直接聚焦，无需循环
    if n == 1 then
        focusWindow(wins[1])
        cycleState.index = 1
        cycleState.winID = wins[1]:id()
        logger.i("仅 1 个 Chrome 窗口，已聚焦")
        return
    end

    local focused = hs.window.focusedWindow()
    local focusedID = focused and focused:id() or nil

    local idx = 0
    if cycleState.index > 0 and focusedID and focusedID == cycleState.winID then
        -- 快速连按：上一次的目标窗口仍是当前聚焦窗口 -> 在其基础上继续推进
        idx = cycleState.index
    elseif focusedID then
        -- 首次按下：以当前聚焦窗口为基准
        for i, w in ipairs(wins) do
            if w:id() == focusedID then idx = i; break end
        end
    end

    local nextIdx = ((idx - 1 + step) % n) + 1
    local target = wins[nextIdx]

    cycleState.index = nextIdx
    cycleState.winID = target:id()

    focusWindow(target)
    logger.i(string.format("循环 Chrome 窗口 %d/%d (step=%d) -> %s", nextIdx, n, step, target:title() or ""))
end

-- ==================== 生命周期 ====================

function M.start()
    chromeFilter = hs.window.filter.new(chromeAppNames)

    hs.hotkey.bind({"ctrl"}, "k", toggleChrome)
    hs.hotkey.bind({"ctrl"}, "`", function() cycleChrome(1) end)
    hs.hotkey.bind({"ctrl", "shift"}, "`", function() cycleChrome(-1) end)

    logger.i("Chrome 快捷键已绑定: Ctrl+K 呼出/隐藏 | Ctrl+` 下一个窗口 | Ctrl+Shift+` 上一个窗口")
end

-- ==================== 调试接口 ====================
function M.toggle() toggleChrome() end
function M.cycle(step) cycleChrome(step) end

-- 返回当前枚举到的 Chrome 窗口（按循环顺序），便于调试
function M.windows()
    local out = {}
    for i, w in ipairs(collectChromeWindows()) do
        local scr = w:screen()
        out[i] = {
            index = i,
            id = w:id(),
            title = w:title(),
            screen = scr and scr:name() or "nil",
            frame = w:frame(),
            minimized = w:isMinimized(),
        }
    end
    return out
end

-- 暴露到全局，便于通过 hs -c 调试
hs.chromeToggle = M

return M
