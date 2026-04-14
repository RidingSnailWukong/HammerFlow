-- 圆环启动器 (Circle Launcher)
-- 快捷键: Command + Shift + Space 唤起

local CircleLauncher = {}
CircleLauncher.__index = CircleLauncher

-- 配置参数
local configDir = hs.configdir
local launcherAppsFile = configDir .. "/config/launcher_apps.json"
local logger = hs.logger.new("CircleLauncher", "info")

-- 从 JSON 加载 apps 列表
local function loadApps()
    local file = io.open(launcherAppsFile, "r")
    if not file then
        logger.w("配置文件不存在: " .. launcherAppsFile .. "，使用空列表")
        return {}
    end
    local content = file:read("*a")
    file:close()

    local ok, data = pcall(hs.json.decode, content)
    if ok and type(data) == "table" then
        logger.i("已加载 " .. #data .. " 个启动器应用")
        return data
    else
        logger.e("launcher_apps.json 解析失败，请检查 JSON 格式")
        return {}
    end
end

local config = {
    apps = loadApps(),

    outerRadius = 220,
    innerRadius = 130,
    iconSize = 72,
    clickRadius = 48,  -- 点击命中区域半径（大于图标半径，更易点中）

    bgColor = {red=0.15, green=0.15, blue=0.25, alpha=0.92},
}

function CircleLauncher:new()
    local obj = setmetatable({}, self)
    obj.canvas = nil
    obj.isVisible = false
    obj.appButtons = {}
    return obj
end

-- 获取应用图标（通过 bundle ID，最可靠的方式）
function CircleLauncher:getAppIcon(bundleID)
    local icon = hs.image.imageFromAppBundle(bundleID)
    return icon
end

-- 计算图标位置
function CircleLauncher:calculatePosition(index, total)
    local radius = (config.outerRadius + config.innerRadius) / 2
    local angle = (2 * math.pi / total) * (index - 1) - math.pi / 2
    return math.cos(angle) * radius, math.sin(angle) * radius
end

-- 创建画布
function CircleLauncher:createCanvas()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    self.canvas = hs.canvas.new(frame)
    local cx, cy = frame.w / 2, frame.h / 2

    -- 背景遮罩
    self.canvas[1] = {
        type = "rectangle",
        action = "fill",
        fillColor = {red=0, green=0, blue=0, alpha=0.4},
        frame = {x=0, y=0, w=frame.w, h=frame.h},
        trackMouseDown = true,
    }

    -- 外圆
    self.canvas[2] = {
        type = "circle",
        action = "fill",
        fillColor = config.bgColor,
        center = {x=cx, y=cy},
        radius = config.outerRadius,
    }

    -- 内圆
    self.canvas[3] = {
        type = "circle",
        action = "fill",
        fillColor = {red=0.1, green=0.1, blue=0.2, alpha=0.6},
        center = {x=cx, y=cy},
        radius = config.innerRadius,
    }

    -- 添加应用图标
    self.appButtons = {}
    local total = #config.apps
    local canvasIdx = 3

    for i, appInfo in ipairs(config.apps) do
        local icon = self:getAppIcon(appInfo.bundleID)

        if icon then
            local ox, oy = self:calculatePosition(i, total)
            local x = cx + ox - config.iconSize / 2
            local y = cy + oy - config.iconSize / 2

            canvasIdx = canvasIdx + 1
            self.canvas[canvasIdx] = {
                type = "image",
                image = icon,
                frame = {x=x, y=y, w=config.iconSize, h=config.iconSize},
                imageScaling = "scaleProportionally",
                trackMouseDown = true,
            }

            table.insert(self.appButtons, {
                app = appInfo.name,
                cmd = appInfo.cmd,
                x = cx + ox,
                y = cy + oy,
                radius = config.clickRadius,
            })
        end
    end

    -- 设置画布属性
    self.canvas:level(hs.canvas.windowLevels.floating)
    self.canvas:clickActivating(false)

    -- 鼠标回调
    local launcher = self
    local buttons = self.appButtons

    self.canvas:mouseCallback(function(c, event, id, x, y)
        if event == "mouseDown" then
            for _, btn in ipairs(buttons) do
                local dist = math.sqrt((x - btn.x)^2 + (y - btn.y)^2)
                if dist <= btn.radius then
                    if btn.cmd then
                        os.execute(btn.cmd .. " &")
                    else
                        hs.application.launchOrFocus(btn.app)
                    end
                    launcher:hide()
                    return
                end
            end
            launcher:hide()
        end
    end)
end

-- 显示
function CircleLauncher:show()
    if self.isVisible then return end
    if not self.canvas then self:createCanvas() end
    self.canvas:show()
    self.isVisible = true
end

-- 隐藏
function CircleLauncher:hide()
    if not self.isVisible then return end
    if self.canvas then self.canvas:hide() end
    self.isVisible = false
end

-- 切换
function CircleLauncher:toggle()
    if self.isVisible then self:hide() else self:show() end
end

-- 销毁
function CircleLauncher:destroy()
    if self.canvas then
        self.canvas:delete()
        self.canvas = nil
    end
    self.isVisible = false
end

-- 初始化
if circleLauncher then circleLauncher:destroy() end
circleLauncher = CircleLauncher:new()

-- 快捷键: Command + Shift + Space
hs.hotkey.bind({"cmd", "shift"}, "space", function()
    circleLauncher:toggle()
end)

-- ESC 关闭
local escKey = nil
local originalShow = circleLauncher.show
circleLauncher.show = function(self)
    originalShow(self)
    if not escKey then
        escKey = hs.hotkey.bind({}, "escape", function()
            if circleLauncher.isVisible then circleLauncher:hide() end
        end)
    end
end

local originalHide = circleLauncher.hide
circleLauncher.hide = function(self)
    originalHide(self)
    if escKey then
        escKey:delete()
        escKey = nil
    end
end

return CircleLauncher
