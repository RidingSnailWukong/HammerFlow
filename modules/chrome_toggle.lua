-- Chrome 呼出/隐藏 (Hotkey Window)
-- 快捷键: Ctrl+K
-- 未运行 -> 启动并显示；已显示在前台 -> 隐藏；隐藏/在其他桌面/最小化 -> 拉到当前桌面并聚焦

local M = {}

local logger = hs.logger.new("ChromeToggle", "info")
local chromeBundleID = "com.google.chrome"

-- 将窗口移动到当前桌面并聚焦
local function bringToCurrentSpace(app, win)
    if win:isMinimized() then
        win:unminimize()
    end
    local currentSpace = hs.spaces.focusedSpace()
    if currentSpace then
        hs.spaces.moveWindowToSpace(win:id(), currentSpace)
    end
    app:activate(true)
    win:focus()
end

-- 等待应用启动后出现主窗口，再拉到当前桌面
local function waitForWindowAndShow(app, retries)
    retries = retries or 0
    local win = app:mainWindow()
    if win then
        bringToCurrentSpace(app, win)
        return
    end
    if retries >= 30 then  -- 最多等 3 秒
        logger.w("等待 Chrome 窗口超时")
        return
    end
    hs.timer.doAfter(0.1, function()
        waitForWindowAndShow(app, retries + 1)
    end)
end

local function toggleChrome()
    local app = hs.application.get(chromeBundleID)

    if not app then
        -- Chrome 未运行：启动并等待窗口出现
        hs.application.launchOrFocusByBundleID(chromeBundleID)
        hs.timer.doAfter(0.2, function()
            local newApp = hs.application.get(chromeBundleID)
            if newApp then
                waitForWindowAndShow(newApp)
            end
        end)
        return
    end

    local win = app:mainWindow()

    if not win then
        -- 已运行但没有窗口（比如全部关闭了）：新建窗口
        app:activate(true)
        hs.eventtap.keyStroke({"cmd"}, "n", 0, app)
        return
    end

    local frontApp = hs.application.frontmostApplication()
    local isFrontmost = frontApp and frontApp:bundleID() == chromeBundleID
    local isVisibleHere = win:isVisible() and not win:isMinimized()

    if isVisibleHere and isFrontmost then
        -- 当前正显示在前台 -> 隐藏
        app:hide()
        logger.i("Chrome 已隐藏")
    else
        -- 隐藏中 / 在其他桌面 / 已最小化 -> 拉到当前桌面并聚焦
        bringToCurrentSpace(app, win)
        logger.i("Chrome 已呼出到当前桌面")
    end
end

function M.start()
    hs.hotkey.bind({"ctrl"}, "k", toggleChrome)
    logger.i("Chrome 呼出/隐藏快捷键 (Ctrl+K) 已绑定")
end

return M
