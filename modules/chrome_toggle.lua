-- Chrome 呼出/隐藏 (Hotkey Window)
-- 快捷键: Ctrl+K
--
-- 行为（当前桌面优先，适配多窗口）:
--   1. 未运行 -> 启动
--   2. 当前桌面上有 Chrome 窗口:
--        - Chrome 在前台 -> 隐藏
--        - Chrome 不在前台 -> 聚焦当前桌面上的那个窗口
--   3. 当前桌面上没有 Chrome 窗口 -> 跳转到 Chrome 主窗口所在桌面
--
-- 注: 以前 bundle id 写成小写 "com.google.chrome"（实际是 com.google.Chrome），
--     导致 hs.application.get() 永远返回 nil、toggle 逻辑从未生效。

local M = {}

local logger = hs.logger.new("ChromeToggle", "info")
local chromeBundleID = "com.google.Chrome"

-- 判断窗口是否在指定 space 上
local function windowIsOnSpace(win, spaceID)
    local spaces = hs.spaces.windowSpaces(win:id())
    if not spaces then return false end
    for _, s in ipairs(spaces) do
        if s == spaceID then return true end
    end
    return false
end

-- 在当前桌面找第一个可用的 Chrome 窗口（标准窗口、可见、未最小化）
local function findWindowOnCurrentSpace(app, spaceID)
    local allWins = app:allWindows()
    for _, w in ipairs(allWins) do
        if w:isStandard() and w:isVisible() and not w:isMinimized()
            and windowIsOnSpace(w, spaceID) then
            return w
        end
    end
    return nil
end

local function toggleChrome()
    local app = hs.application.get(chromeBundleID)

    if not app then
        -- 未运行：启动即可（新窗口会自动出现在当前桌面）
        hs.application.launchOrFocusByBundleID(chromeBundleID)
        logger.i("Chrome 未运行，已启动")
        return
    end

    local currentSpace = hs.spaces.focusedSpace()
    local frontApp = hs.application.frontmostApplication()
    local isFrontmost = frontApp and frontApp:bundleID() == chromeBundleID

    local winHere = findWindowOnCurrentSpace(app, currentSpace)

    if winHere and isFrontmost then
        -- 当前桌面有窗口且 Chrome 在前台 -> 隐藏
        app:hide()
        logger.i("Chrome 已隐藏")
    elseif winHere then
        -- 当前桌面有窗口但 Chrome 不在前台 -> 聚焦当前桌面的窗口
        app:activate(true)
        winHere:focus()
        logger.i("已聚焦当前桌面上的 Chrome 窗口")
    else
        -- 当前桌面没有 Chrome 窗口 -> 跳到主窗口所在桌面
        local mw = app:mainWindow() or app:focusedWindow()
        if mw then
            if mw:isMinimized() then mw:unminimize() end
            app:activate(true)
            mw:focus()
            logger.i("当前桌面无 Chrome 窗口，已跳转到主窗口")
        end
    end
end

function M.start()
    hs.hotkey.bind({"ctrl"}, "k", toggleChrome)
    logger.i("Chrome 呼出/隐藏快捷键 (Ctrl+K) 已绑定")
end

return M
