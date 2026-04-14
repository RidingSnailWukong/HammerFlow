-- ===============================================
-- 专注度提醒模块 (Focus Alert)
-- 由 WorkBuddy 自动化调用，提醒用户回到工作状态
-- ===============================================

local M = {}
local logger = hs.logger.new("FocusAlert", "info")

-- 配置
local config = {
    width = 480,
    height = 320,
    breakWidth = 420,           -- 休息提醒宽度（稍窄，更友好）
    breakHeight = 380,          -- 休息提醒高度（稍高，放健康建议）
    cornerRadius = 16,
    displayDuration = 8,        -- 普通提醒显示秒数
    urgentDuration = 15,        -- 紧急提醒显示秒数
    breakDuration = 20,         -- 休息提醒显示秒数（多留点时间看）
    soundName = "Purr",         -- 普通提醒声音
    urgentSoundName = "Sosumi", -- 紧急提醒声音
    breakSoundName = "Glass",   -- 休息提醒声音（温和）
}

local alertWebview = nil
local alertTimer = nil

-- 生成提醒 HTML（支持 3 种模式：普通/紧急/休息）
local function makeAlertHTML(title, tasks, distraction, isUrgent, isBreakReminder)
    local bgColor, accentColor, iconEmoji

    if isBreakReminder then
        bgColor = "rgba(16, 85, 67, 0.94)"   -- 深绿，友好温暖
        accentColor = "#6ee7b7"
        iconEmoji = "🌿"
    elseif isUrgent then
        bgColor = "rgba(220, 38, 38, 0.95)"
        accentColor = "#fca5a5"
        iconEmoji = "🚨"
    else
        bgColor = "rgba(30, 30, 30, 0.92)"
        accentColor = "#60a5fa"
        iconEmoji = "⏰"
    end

    local bodyHTML = ""

    if isBreakReminder then
        -- 休息提醒：显示成绩总结 + 健康建议
        local achievementsHTML = ""
        if tasks and #tasks > 0 then
            for _, task in ipairs(tasks) do
                achievementsHTML = achievementsHTML .. string.format(
                    '<div style="padding:3px 0;font-size:13px;color:#d1fae5;">✅ %s</div>',
                    task
                )
            end
        end

        local summaryText = distraction or ""

        bodyHTML = string.format([[
            <div style="font-size:11px;font-weight:600;color:%s;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">已连续工作成绩</div>
            <div style="flex:1;overflow-y:auto;">%s</div>
            <div style="margin-top:10px;padding:10px 12px;background:rgba(255,255,255,0.08);border-radius:10px;border-left:3px solid %s;">
                <div style="font-size:13px;color:#fde68a;line-height:1.6;">
                    💧 喝杯水，补充能量<br>
                    🙆 活动肩颈，转转脖子<br>
                    👀 远眺窗外，放松眼睛
                </div>
            </div>
            <div style="margin-top:8px;font-size:12px;color:#a7f3d0;text-align:center;font-style:italic;">%s</div>
        ]], accentColor, achievementsHTML, accentColor, summaryText)
    else
        -- 原有逻辑：任务列表 + 偏离检测
        local taskListHTML = ""
        if tasks and #tasks > 0 then
            for _, task in ipairs(tasks) do
                taskListHTML = taskListHTML .. string.format(
                    '<div style="padding:4px 0;font-size:13px;color:#e5e7eb;">• %s</div>',
                    task
                )
            end
        else
            taskListHTML = '<div style="padding:4px 0;font-size:13px;color:#9ca3af;">暂无任务</div>'
        end

        local distractionHTML = ""
        if distraction and distraction ~= "" then
            distractionHTML = string.format([[
                <div style="margin-top:12px;padding:8px 12px;background:rgba(255,255,255,0.1);border-radius:8px;border-left:3px solid %s;">
                    <div style="font-size:11px;color:#9ca3af;margin-bottom:2px;">检测到偏离</div>
                    <div style="font-size:13px;color:#fbbf24;">%s</div>
                </div>
            ]], accentColor, distraction)
        end

        bodyHTML = string.format([[
            <div style="font-size:11px;font-weight:600;color:%s;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">今日任务</div>
            <div style="flex:1;overflow-y:auto;">%s</div>
            %s
        ]], accentColor, taskListHTML, distractionHTML)
    end

    return string.format([[
<!DOCTYPE html>
<html>
<head><style>
* { margin:0; padding:0; box-sizing:border-box; }
html, body { width:100%%; height:100%%; background:transparent; overflow:hidden; }
.card {
    width:100%%; height:100%%; padding:24px;
    background: %s;
    border-radius: %dpx;
    font-family: "SF Pro Display", "PingFang SC", -apple-system, sans-serif;
    display:flex; flex-direction:column;
    backdrop-filter: blur(20px);
    border: 1px solid rgba(255,255,255,0.15);
    box-shadow: 0 25px 50px rgba(0,0,0,0.5);
    position: relative;
}
.close-btn {
    position:absolute; top:12px; right:14px;
    width:28px; height:28px;
    border-radius:50%%;
    background:rgba(255,255,255,0.12);
    border:1px solid rgba(255,255,255,0.2);
    color:#d1d5db; font-size:15px; font-weight:500;
    display:flex; align-items:center; justify-content:center;
    cursor:pointer; transition:all 0.15s ease;
    -webkit-app-region: no-drag;
}
.close-btn:hover {
    background:rgba(255,255,255,0.25);
    color:#fff;
    transform:scale(1.1);
}
.close-btn:active {
    transform:scale(0.95);
}
.header {
    display:flex; align-items:center; gap:8px;
    margin-bottom:16px;
    padding-right:32px;
}
.icon { font-size:24px; }
.title { font-size:16px; font-weight:700; color:#fff; }
.footer {
    margin-top:12px; padding-top:8px;
    border-top:1px solid rgba(255,255,255,0.1);
    font-size:11px; color:#6b7280; text-align:right;
}
</style></head>
<body>
<div class="card">
    <div class="close-btn" onclick="dismissMe()">✕</div>
    <div class="header">
        <span class="icon">%s</span>
        <span class="title">%s</span>
    </div>
    %s
    <div class="footer">WorkBuddy 专注助手</div>
</div>
<script>
function dismissMe() {
    try {
        webkit.messageHandlers.focusAlertController.postMessage("close");
    } catch(e) {}
}
</script>
</body>
</html>
]], bgColor, config.cornerRadius, iconEmoji, title, bodyHTML)
end

-- 关闭提醒
local function dismissAlert()
    if alertWebview then
        alertWebview:delete()
        alertWebview = nil
    end
    if alertTimer then
        alertTimer:stop()
        alertTimer = nil
    end
end

-- 显示提醒弹窗
function M.showAlert(params)
    -- params: { title, tasks, distraction, urgent, breakReminder }
    dismissAlert()

    local title = params.title or "回到工作！"
    local tasks = params.tasks or {}
    local distraction = params.distraction or ""
    local isUrgent = params.urgent or false
    local isBreakReminder = params.breakReminder or false

    local duration, soundName, w, h

    if isBreakReminder then
        duration = config.breakDuration
        soundName = config.breakSoundName
        w = config.breakWidth
        h = config.breakHeight
    elseif isUrgent then
        duration = config.urgentDuration
        soundName = config.urgentSoundName
        w = config.width
        h = config.height
    else
        duration = config.displayDuration
        soundName = config.soundName
        w = config.width
        h = config.height
    end

    -- 播放声音
    local sound = hs.sound.getByName(soundName)
    if sound then sound:play() end

    -- 在主屏幕居中显示
    local screen = hs.screen.mainScreen()
    local frame = screen:fullFrame()
    local x = frame.x + (frame.w - w) / 2
    local y = frame.y + (frame.h - h) / 2

    local uc = hs.webview.usercontent.new("focusAlertController")
    uc:setCallback(function(msg)
        if msg and msg.body == "close" then
            dismissAlert()
        end
    end)

    alertWebview = hs.webview.new({x = x, y = y, w = w, h = h}, { javaScriptEnabled = true }, uc)
    alertWebview:windowStyle(128 + 8192)  -- borderless + nonactivating
    alertWebview:level(2147483630)         -- 最高层
    alertWebview:behavior(1 + 16 + 64 + 256) -- 所有桌面可见
    alertWebview:allowTextEntry(true)       -- 允许点击交互
    alertWebview:transparent(true)
    alertWebview:html(makeAlertHTML(title, tasks, distraction, isUrgent, isBreakReminder))
    alertWebview:show()

    -- 自动关闭
    alertTimer = hs.timer.doAfter(duration, dismissAlert)

    logger.i("[FocusAlert] 显示提醒: " .. title .. " (urgent=" .. tostring(isUrgent) .. ", break=" .. tostring(isBreakReminder) .. ")")
end

-- Esc 键关闭
local escTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    if alertWebview and event:getKeyCode() == 53 then -- 53 = Escape
        dismissAlert()
        return true
    end
    return false
end)
escTap:start()

-- 注册 CLI 命令（供 hs 命令行调用）
-- 用法: hs -c 'focusAlert({title="回到工作！", tasks={"任务1","任务2"}, distraction="在刷B站", urgent=false})'
_G.focusAlert = function(params)
    M.showAlert(params)
    return "alert shown"
end

-- 简化版：直接传 JSON 字符串
-- 用法: hs -c 'focusAlertJSON([[{"title":"回到工作！","tasks":["任务1"],"distraction":"在刷B站","urgent":false}]])'
_G.focusAlertJSON = function(jsonStr)
    local ok, params = pcall(hs.json.decode, jsonStr)
    if ok and params then
        M.showAlert(params)
        return "alert shown"
    else
        logger.e("[FocusAlert] JSON 解析失败: " .. tostring(jsonStr))
        return "error: invalid json"
    end
end

logger.i("[FocusAlert] 专注度提醒模块已加载")

return M
