--- modules/lock_screen.lua
--- 锁屏并关闭显示器（Ctrl+Alt+L）
---
--- 做法：hs.caffeinate.lockScreen() 走系统锁屏，随后 pmset displaysleepnow 立刻关屏。
--- 顺序不能反：先锁屏再关屏，避免「屏幕黑了但会话未锁」的空窗。
--- 说明：macOS 的「锁定屏幕」快捷键是 Ctrl+Cmd+Q，这里单独占用 Ctrl+Alt+L，
---       以免覆盖系统自带组合键；如需改键，改 HOTKEY 即可。

local M = {}

local logger = hs.logger.new("LockScreen", "info")

local HOTKEY = { mods = { "ctrl", "alt" }, key = "l" }
local DISPLAY_SLEEP_DELAY = 0.35   -- 等锁屏生效后再关屏

local hotkey = nil
local sleepTimer = nil

--- 锁屏 + 关显示器
function M.lockAndBlank()
    hs.caffeinate.lockScreen()

    if sleepTimer then sleepTimer:stop() end
    sleepTimer = hs.timer.doAfter(DISPLAY_SLEEP_DELAY, function()
        sleepTimer = nil
        local ok, out, err = hs.execute("/usr/bin/pmset displaysleepnow")
        if ok then
            logger.i("已锁屏并关闭显示器")
        else
            logger.w(string.format("关闭显示器失败: %s / %s", tostring(out), tostring(err)))
        end
    end)
end

function M.start()
    if hotkey then hotkey:delete(); hotkey = nil end
    local mods, key = HOTKEY.mods, HOTKEY.key
    local ok, err = pcall(function()
        hotkey = hs.hotkey.bind(mods, key, function() M.lockAndBlank() end)
    end)
    if not ok then
        logger.w(string.format("绑定快捷键失败 %s+%s: %s",
            table.concat(mods, "+"), key, tostring(err)))
        return
    end
    logger.i(string.format("已绑定：%s+%s 锁屏并关闭显示器", table.concat(mods, "+"), key))
end

function M.stop()
    if hotkey then hotkey:delete(); hotkey = nil end
    if sleepTimer then sleepTimer:stop(); sleepTimer = nil end
end

return M
