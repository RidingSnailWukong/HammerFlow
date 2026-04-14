-- =============================================
-- 番茄钟模块 (Pomodoro Timer)
-- =============================================

local M = {}

-- 配置
local config = {
    workDuration = 25 * 60,      -- 工作时长（秒）
    breakDuration = 5 * 60,      -- 休息时长（秒）
    showNotification = true,
    playSound = true,
    autoStartBreak = false,      -- 工作结束后是否自动开始休息
}

-- 状态
local menubar = nil
local ticker = nil
local remainingTime = 0
local state = "idle"             -- idle, working, break, paused
local pausedState = nil          -- 暂停前的状态（working 或 break）
local todayCount = 0             -- 今日完成的番茄数
local logger = hs.logger.new("Pomodoro", "info")

-- 格式化时间 MM:SS
local function formatTime(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%02d:%02d", m, s)
end

-- 更新菜单栏显示
local function updateDisplay()
    if not menubar then return end

    if state == "idle" then
        menubar:setTitle("🍅")
    elseif state == "working" then
        menubar:setTitle("🍅 " .. formatTime(remainingTime))
    elseif state == "break" then
        menubar:setTitle("☕ " .. formatTime(remainingTime))
    elseif state == "paused" then
        menubar:setTitle("⏸ " .. formatTime(remainingTime))
    end
end

-- 弹窗相关
local alertWebview = nil
local alertHideTimer = nil

local function makeAlertHTML(emoji, title, subtitle)
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
.overlay {
    width: 100%%; height: 100%%;
    display: flex;
    align-items: center;
    justify-content: center;
}
.box {
    background: rgba(0, 0, 0, 0.82);
    border-radius: 20px;
    padding: 36px 48px 28px;
    text-align: center;
    font-family: -apple-system, "PingFang SC", sans-serif;
    animation: popIn 0.3s ease-out;
}
@keyframes popIn {
    0%% { transform: scale(0.7); opacity: 0; }
    100%% { transform: scale(1); opacity: 1; }
}
.emoji { font-size: 56px; margin-bottom: 12px; }
.title {
    font-size: 22px;
    font-weight: bold;
    color: rgba(255,255,255,0.95);
    margin-bottom: 8px;
}
.subtitle {
    font-size: 15px;
    color: rgba(255,255,255,0.6);
    margin-bottom: 24px;
}
.btn {
    display: inline-block;
    padding: 8px 36px;
    border-radius: 8px;
    border: none;
    background: rgba(255,255,255,0.18);
    color: white;
    font-size: 15px;
    cursor: pointer;
    transition: background 0.15s;
}
.btn:hover { background: rgba(255,255,255,0.28); }
</style></head>
<body>
<div class="overlay">
    <div class="box">
        <div class="emoji">%s</div>
        <div class="title">%s</div>
        <div class="subtitle">%s</div>
        <button class="btn" id="okBtn">确 定</button>
    </div>
</div>
<script>
document.getElementById('okBtn').addEventListener('click', function() {
    try { webkit.messageHandlers.Pomodoro.postMessage('dismiss'); } catch(e) {}
});
</script>
</body>
</html>
]], emoji, title, subtitle)
end

local function dismissAlert()
    if alertHideTimer then alertHideTimer:stop(); alertHideTimer = nil end
    if alertWebview then alertWebview:delete(); alertWebview = nil end
end

local function showAlert(emoji, title, subtitle)
    dismissAlert()

    local screen = hs.screen.mainScreen()
    if not screen then return end
    local frame = screen:fullFrame()
    local w, h = 380, 260
    local x = frame.x + (frame.w - w) / 2
    local y = frame.y + (frame.h - h) / 2

    local uc = hs.webview.usercontent.new("Pomodoro")
    uc:setCallback(function(msg)
        if msg and msg.body == "dismiss" then
            dismissAlert()
        end
    end)

    alertWebview = hs.webview.new({x = x, y = y, w = w, h = h}, { javaScriptEnabled = true }, uc)
    alertWebview:windowStyle(128 + 8192)  -- nonactivating + HUD
    alertWebview:level(2147483630)
    alertWebview:behavior(1 + 16 + 64 + 256)
    alertWebview:allowTextEntry(true)
    alertWebview:transparent(true)
    alertWebview:html(makeAlertHTML(emoji, title, subtitle))
    alertWebview:show()

    -- 30秒后自动关闭
    alertHideTimer = hs.timer.doAfter(30, dismissAlert)

    -- 播放提示音
    if config.playSound then
        hs.sound.getByName("Glass"):play()
    end
end

-- 发送通知
local function sendNotification(title, text)
    if not config.showNotification then return end
    local n = hs.notify.new({
        title = title,
        informativeText = text,
        soundName = config.playSound and "default" or nil,
        withdrawAfter = 10,
    })
    n:send()
end

-- 定时器回调：每秒执行一次
local function tick()
    remainingTime = remainingTime - 1

    if remainingTime <= 0 then
        -- 时间到
        if state == "working" then
            todayCount = todayCount + 1
            sendNotification("🍅 番茄完成！", "已完成 " .. todayCount .. " 个番茄，休息一下吧！")
            showAlert("🍅", "番茄完成！", "已完成 " .. todayCount .. " 个番茄，休息一下吧")
            logger.i("番茄完成，今日第 " .. todayCount .. " 个")

            if config.autoStartBreak then
                state = "break"
                remainingTime = config.breakDuration
            else
                state = "idle"
                if ticker then ticker:stop() end
            end
        elseif state == "break" then
            sendNotification("☕ 休息结束", "休息时间到，准备开始下一个番茄！")
            showAlert("☕", "休息结束", "准备开始下一个番茄吧！")
            logger.i("休息结束")
            state = "idle"
            if ticker then ticker:stop() end
        end
    end

    updateDisplay()
end

-- 开始工作
local function startWork()
    state = "working"
    remainingTime = config.workDuration
    pausedState = nil

    if ticker then ticker:stop() end
    ticker = hs.timer.new(1, tick)
    ticker:start()

    updateDisplay()
    logger.i("开始工作 " .. formatTime(config.workDuration))
end

-- 开始休息
local function startBreak()
    state = "break"
    remainingTime = config.breakDuration
    pausedState = nil

    if ticker then ticker:stop() end
    ticker = hs.timer.new(1, tick)
    ticker:start()

    updateDisplay()
    logger.i("开始休息 " .. formatTime(config.breakDuration))
end

-- 暂停
local function pause()
    if state ~= "working" and state ~= "break" then return end
    pausedState = state
    state = "paused"
    if ticker then ticker:stop() end
    updateDisplay()
    logger.i("已暂停")
end

-- 继续
local function resume()
    if state ~= "paused" or not pausedState then return end
    state = pausedState
    pausedState = nil

    if ticker then ticker:stop() end
    ticker = hs.timer.new(1, tick)
    ticker:start()

    updateDisplay()
    logger.i("已继续")
end

-- 停止/重置
local function reset()
    state = "idle"
    remainingTime = 0
    pausedState = nil
    if ticker then ticker:stop(); ticker = nil end
    updateDisplay()
    logger.i("已停止")
end

-- 构建下拉菜单
local function buildMenu()
    local items = {}

    if state == "idle" then
        table.insert(items, {
            title = "🍅 开始工作 (" .. math.floor(config.workDuration / 60) .. " 分钟)",
            fn = startWork,
        })
        table.insert(items, {
            title = "☕ 开始休息 (" .. math.floor(config.breakDuration / 60) .. " 分钟)",
            fn = startBreak,
        })
    else
        if state == "working" or state == "break" then
            table.insert(items, { title = "⏸ 暂停", fn = pause })
        elseif state == "paused" then
            table.insert(items, { title = "▶ 继续", fn = resume })
        end
        table.insert(items, { title = "⏹ 停止", fn = reset })
    end

    table.insert(items, { title = "-" })

    -- 设置工作时长子菜单
    local workOptions = {15, 20, 25, 30, 45, 60}
    local workSubMenu = {}
    for _, minutes in ipairs(workOptions) do
        local isSelected = (config.workDuration == minutes * 60)
        table.insert(workSubMenu, {
            title = (isSelected and "● " or "   ") .. minutes .. " 分钟",
            fn = function()
                config.workDuration = minutes * 60
                logger.i("工作时长设置为 " .. minutes .. " 分钟")
            end,
        })
    end
    table.insert(items, { title = "设置工作时长", menu = workSubMenu })

    -- 设置休息时长子菜单
    local breakOptions = {3, 5, 10, 15}
    local breakSubMenu = {}
    for _, minutes in ipairs(breakOptions) do
        local isSelected = (config.breakDuration == minutes * 60)
        table.insert(breakSubMenu, {
            title = (isSelected and "● " or "   ") .. minutes .. " 分钟",
            fn = function()
                config.breakDuration = minutes * 60
                logger.i("休息时长设置为 " .. minutes .. " 分钟")
            end,
        })
    end
    table.insert(items, { title = "设置休息时长", menu = breakSubMenu })

    table.insert(items, { title = "-" })

    -- 自动开始休息
    table.insert(items, {
        title = (config.autoStartBreak and "✓ " or "   ") .. "工作结束自动休息",
        fn = function()
            config.autoStartBreak = not config.autoStartBreak
        end,
    })

    table.insert(items, { title = "-" })

    -- 今日统计
    table.insert(items, {
        title = "今日番茄: " .. todayCount .. " 个",
        disabled = true,
    })
    table.insert(items, {
        title = "重置计数",
        fn = function()
            todayCount = 0
            logger.i("今日计数已重置")
        end,
    })

    return items
end

-- 启动模块
function M.start()
    menubar = hs.menubar.new()
    menubar:setMenu(buildMenu)
    updateDisplay()
    logger.i("番茄钟模块已启动")
end

-- 停止模块
function M.stop()
    if ticker then ticker:stop(); ticker = nil end
    if menubar then menubar:delete(); menubar = nil end
    dismissAlert()
    logger.i("番茄钟模块已停止")
end

return M
