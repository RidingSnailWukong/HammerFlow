-- =====================================================
-- 屏幕画笔模块 (Screen Drawing)
-- 使用 webview 在屏幕上绘制，支持全屏应用
-- 支持：自由画、矩形、圆形、椭圆形、箭头 + 渐隐消失
-- =====================================================

local M = {}

-- ================= 配置 =================
local config = {
    toggleKey = { {"ctrl", "shift"}, "D" },  -- 切换绘图模式
    colors = {
        ["1"] = "#ff0000",  -- 红
        ["2"] = "#00ff00",  -- 绿
        ["3"] = "#0066ff",  -- 蓝
        ["4"] = "#ffff00",  -- 黄
        ["5"] = "#ffffff",  -- 白
    },
    defaultColor = "#ff0000",
    defaultLineWidth = 4,
    lineWidthStep = 2,
    minLineWidth = 1,
    maxLineWidth = 20,
    defaultAutoFade = 3,  -- 默认3秒后自动消失，0=不消失
}

-- ================= 状态变量 =================
local webviews = {}             -- 每个屏幕一个 webview
local isDrawingMode = false
local currentColor = config.defaultColor
local currentLineWidth = config.defaultLineWidth
local currentAutoFade = config.defaultAutoFade
local hotkeys = {}              -- 存储绑定的快捷键
local drawingHotkeys = {}       -- 绘图模式下的快捷键
local screenWatcher = nil
local logger = hs.logger.new("ScreenDraw", "info")

-- ================= 工具函数 =================
-- 封装 evaluateJavaScript，避免第二个参数传 nil 报错
local function evalJS(wv, js)
    if wv then
        wv:evaluateJavaScript(js, function(_) end)
    end
end

local function evalOnAll(js)
    for _, wv in pairs(webviews) do
        evalJS(wv, js)
    end
end

-- ================= HTML 模板 =================

local function getDrawingHTML()
    return string.format([[
<!DOCTYPE html>
<html>
<head>
<style>
* { margin: 0; padding: 0; }
html, body {
    width: 100%%;
    height: 100%%;
    background: transparent;
    overflow: hidden;
    cursor: crosshair;
}
canvas {
    position: absolute;
    top: 0;
    left: 0;
}
#toolbar {
    position: fixed;
    top: 20px;
    left: 50%%;
    transform: translateX(-50%%);
    background: rgba(0, 0, 0, 0.85);
    border-radius: 12px;
    padding: 10px 20px;
    display: flex;
    gap: 12px;
    align-items: center;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: 13px;
    color: white;
    z-index: 1000;
    user-select: none;
    white-space: nowrap;
}
.color-btn {
    width: 22px;
    height: 22px;
    border-radius: 50%%;
    border: 2px solid transparent;
    cursor: pointer;
    transition: transform 0.1s;
}
.color-btn:hover { transform: scale(1.2); }
.color-btn.active {
    border-color: white;
    box-shadow: 0 0 8px rgba(255,255,255,0.5);
}
.sep { color: #444; font-size: 14px; }
.info { color: #aaa; font-size: 12px; }
.shape-btn {
    padding: 3px 8px;
    border-radius: 5px;
    cursor: pointer;
    background: rgba(255,255,255,0.1);
    border: 1px solid rgba(255,255,255,0.15);
    font-size: 13px;
    transition: all 0.15s;
}
.shape-btn:hover { background: rgba(255,255,255,0.2); }
.shape-btn.active {
    background: rgba(255,255,255,0.25);
    border-color: rgba(255,255,255,0.6);
}
.fade-display {
    color: #aaa;
    font-size: 12px;
    min-width: 60px;
    text-align: center;
}
.shortcut {
    color: #555;
    font-size: 10px;
    line-height: 1.4;
}
</style>
</head>
<body>
<div id="toolbar">
    <span>🖌️</span>

    <!-- 颜色 -->
    <div class="color-btn active" style="background: #ff0000" data-color="#ff0000" onclick="selectColor(this)"></div>
    <div class="color-btn" style="background: #00ff00" data-color="#00ff00" onclick="selectColor(this)"></div>
    <div class="color-btn" style="background: #0066ff" data-color="#0066ff" onclick="selectColor(this)"></div>
    <div class="color-btn" style="background: #ffff00" data-color="#ffff00" onclick="selectColor(this)"></div>
    <div class="color-btn" style="background: #ffffff" data-color="#ffffff" onclick="selectColor(this)"></div>

    <span class="sep">|</span>

    <!-- 图形样式 -->
    <span class="shape-btn active" data-shape="free" onclick="selectShape(this)">✏️ 自由</span>
    <span class="shape-btn" data-shape="rect" onclick="selectShape(this)">▭ 矩形</span>
    <span class="shape-btn" data-shape="circle" onclick="selectShape(this)">○ 圆形</span>
    <span class="shape-btn" data-shape="ellipse" onclick="selectShape(this)">⬭ 椭圆</span>
    <span class="shape-btn" data-shape="arrow" onclick="selectShape(this)">➜ 箭头</span>

    <span class="sep">|</span>

    <!-- 线宽 & 消失 -->
    <span class="info" id="lineWidthDisplay">线宽: %d</span>
    <span class="sep">|</span>
    <span class="fade-display" id="fadeDisplay">消失: %s</span>

    <span class="sep">|</span>
    <span class="shortcut">1-5:色 F/R/O/E/A:形状 -+:粗细 T:消失 C:清 Z:撤 Esc:退</span>
</div>
<canvas id="drawCanvas"></canvas>
<script>
const canvas = document.getElementById('drawCanvas');
const ctx = canvas.getContext('2d');

// ========== 状态 ==========
let currentColor = '#ff0000';
let lineWidth = %d;
let isDrawing = false;
let currentShape = 'free';  // free, rect, circle, ellipse, arrow
let autoFadeSeconds = %d;   // 0 = 不消失

// 绘制记录
let shapes = [];
let fadeEntries = [];
let animFrameId = null;

// 拖拽起始点
let startX = 0, startY = 0;

// 自由画的临时路径
let currentFreePath = null;

// 渐隐配置
const FADE_DURATION = 1000;  // 渐隐动画时长 1 秒

// ========== 画布初始化 ==========
function resizeCanvas() {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
    redrawAll();
}
resizeCanvas();
window.addEventListener('resize', resizeCanvas);

// ========== 事件绑定 ==========
canvas.addEventListener('mousedown', onMouseDown);
canvas.addEventListener('mousemove', onMouseMove);
canvas.addEventListener('mouseup', onMouseUp);
canvas.addEventListener('mouseleave', onMouseUp);

function onMouseDown(e) {
    isDrawing = true;
    startX = e.clientX;
    startY = e.clientY;

    if (currentShape === 'free') {
        currentFreePath = {
            type: 'free',
            color: currentColor,
            width: lineWidth,
            opacity: 1,
            points: [{x: e.clientX, y: e.clientY}],
            createdAt: Date.now()
        };
    }
}

function onMouseMove(e) {
    if (!isDrawing) return;

    if (currentShape === 'free') {
        const p = currentFreePath;
        if (!p) return;
        ctx.beginPath();
        const last = p.points[p.points.length - 1];
        ctx.moveTo(last.x, last.y);
        ctx.lineTo(e.clientX, e.clientY);
        ctx.strokeStyle = p.color;
        ctx.lineWidth = p.width;
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        ctx.stroke();
        p.points.push({x: e.clientX, y: e.clientY});
    } else {
        redrawAll();
        drawShapePreview(startX, startY, e.clientX, e.clientY);
    }
}

function onMouseUp(e) {
    if (!isDrawing) return;
    isDrawing = false;

    const endX = e.clientX;
    const endY = e.clientY;

    let newShape = null;

    if (currentShape === 'free') {
        if (currentFreePath && currentFreePath.points.length >= 2) {
            newShape = currentFreePath;
        }
        currentFreePath = null;
    } else {
        if (Math.abs(endX - startX) > 2 || Math.abs(endY - startY) > 2) {
            newShape = {
                type: currentShape,
                color: currentColor,
                width: lineWidth,
                opacity: 1,
                x1: startX, y1: startY,
                x2: endX, y2: endY,
                createdAt: Date.now()
            };
        }
    }

    if (newShape) {
        shapes.push(newShape);
        redrawAll();
        scheduleAutoFade(newShape);
    }
}

// ========== 箭头绘制辅助 ==========
function drawArrowhead(fromX, fromY, toX, toY, arrowWidth) {
    const headLen = Math.max(arrowWidth * 4, 16);
    const angle = Math.atan2(toY - fromY, toX - fromX);
    ctx.beginPath();
    ctx.moveTo(toX, toY);
    ctx.lineTo(
        toX - headLen * Math.cos(angle - Math.PI / 6),
        toY - headLen * Math.sin(angle - Math.PI / 6)
    );
    ctx.lineTo(
        toX - headLen * Math.cos(angle + Math.PI / 6),
        toY - headLen * Math.sin(angle + Math.PI / 6)
    );
    ctx.closePath();
    ctx.fill();
}

// ========== 自动渐隐消失 ==========
function scheduleAutoFade(shape) {
    if (autoFadeSeconds <= 0) return;

    const delayTimer = setTimeout(() => {
        shape._fadeStart = performance.now();
        startFadeAnimation();
    }, autoFadeSeconds * 1000);

    fadeEntries.push({ shape, delayTimer });
}

function startFadeAnimation() {
    if (animFrameId) return;
    animFrameId = requestAnimationFrame(fadeAnimLoop);
}

function fadeAnimLoop(now) {
    let hasActive = false;

    for (const shape of shapes) {
        if (shape._fadeStart) {
            const elapsed = now - shape._fadeStart;
            shape.opacity = Math.max(0, 1 - elapsed / FADE_DURATION);
            if (shape.opacity > 0) hasActive = true;
        }
    }

    const before = shapes.length;
    shapes = shapes.filter(s => s.opacity > 0);
    if (shapes.length !== before) {
        fadeEntries = fadeEntries.filter(e => shapes.includes(e.shape));
    }

    redrawAll();

    if (hasActive && shapes.some(s => s._fadeStart && s.opacity > 0)) {
        animFrameId = requestAnimationFrame(fadeAnimLoop);
    } else {
        animFrameId = null;
    }
}

function clearAllFadeTimers() {
    fadeEntries.forEach(e => clearTimeout(e.delayTimer));
    fadeEntries = [];
    if (animFrameId) {
        cancelAnimationFrame(animFrameId);
        animFrameId = null;
    }
}

// ========== 绘制图形 ==========
function drawOneShape(shape) {
    ctx.save();
    ctx.globalAlpha = shape.opacity !== undefined ? shape.opacity : 1;
    ctx.strokeStyle = shape.color;
    ctx.fillStyle = shape.color;
    ctx.lineWidth = shape.width;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    if (shape.type === 'free') {
        if (shape.points.length < 2) { ctx.restore(); return; }
        ctx.beginPath();
        ctx.moveTo(shape.points[0].x, shape.points[0].y);
        for (let i = 1; i < shape.points.length; i++) {
            ctx.lineTo(shape.points[i].x, shape.points[i].y);
        }
        ctx.stroke();
    } else if (shape.type === 'rect') {
        ctx.beginPath();
        ctx.strokeRect(
            Math.min(shape.x1, shape.x2),
            Math.min(shape.y1, shape.y2),
            Math.abs(shape.x2 - shape.x1),
            Math.abs(shape.y2 - shape.y1)
        );
    } else if (shape.type === 'circle') {
        const cx = (shape.x1 + shape.x2) / 2;
        const cy = (shape.y1 + shape.y2) / 2;
        const r = Math.sqrt(Math.pow(shape.x2 - shape.x1, 2) + Math.pow(shape.y2 - shape.y1, 2)) / 2;
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        ctx.stroke();
    } else if (shape.type === 'ellipse') {
        const cx = (shape.x1 + shape.x2) / 2;
        const cy = (shape.y1 + shape.y2) / 2;
        const rx = Math.abs(shape.x2 - shape.x1) / 2;
        const ry = Math.abs(shape.y2 - shape.y1) / 2;
        ctx.beginPath();
        ctx.ellipse(cx, cy, Math.max(rx, 1), Math.max(ry, 1), 0, 0, Math.PI * 2);
        ctx.stroke();
    } else if (shape.type === 'arrow') {
        // 画线段
        ctx.beginPath();
        ctx.moveTo(shape.x1, shape.y1);
        ctx.lineTo(shape.x2, shape.y2);
        ctx.stroke();
        // 画箭头
        drawArrowhead(shape.x1, shape.y1, shape.x2, shape.y2, shape.width);
    }

    ctx.restore();
}

function drawShapePreview(x1, y1, x2, y2) {
    ctx.save();
    ctx.strokeStyle = currentColor;
    ctx.fillStyle = currentColor;
    ctx.lineWidth = lineWidth;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.setLineDash([6, 4]);

    if (currentShape === 'rect') {
        ctx.beginPath();
        ctx.strokeRect(
            Math.min(x1, x2), Math.min(y1, y2),
            Math.abs(x2 - x1), Math.abs(y2 - y1)
        );
    } else if (currentShape === 'circle') {
        const cx = (x1 + x2) / 2;
        const cy = (y1 + y2) / 2;
        const r = Math.sqrt(Math.pow(x2 - x1, 2) + Math.pow(y2 - y1, 2)) / 2;
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        ctx.stroke();
    } else if (currentShape === 'ellipse') {
        const cx = (x1 + x2) / 2;
        const cy = (y1 + y2) / 2;
        const rx = Math.abs(x2 - x1) / 2;
        const ry = Math.abs(y2 - y1) / 2;
        ctx.beginPath();
        ctx.ellipse(cx, cy, Math.max(rx, 1), Math.max(ry, 1), 0, 0, Math.PI * 2);
        ctx.stroke();
    } else if (currentShape === 'arrow') {
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
        ctx.setLineDash([]);
        drawArrowhead(x1, y1, x2, y2, lineWidth);
    }

    ctx.restore();
}

function redrawAll() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    shapes.forEach(drawOneShape);
}

// ========== 工具栏交互 ==========
function selectColor(btn) {
    document.querySelectorAll('.color-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    currentColor = btn.dataset.color;
}

function selectShape(btn) {
    document.querySelectorAll('.shape-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    currentShape = btn.dataset.shape;
}

// ========== Lua 调用接口 ==========
function setColor(color) {
    currentColor = color;
    document.querySelectorAll('.color-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.color === color);
    });
}

function setShape(shape) {
    currentShape = shape;
    document.querySelectorAll('.shape-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.shape === shape);
    });
}

function setLineWidth(width) {
    lineWidth = width;
    document.getElementById('lineWidthDisplay').textContent = '线宽: ' + width;
}

function setAutoFade(seconds) {
    autoFadeSeconds = seconds;
    const display = seconds > 0 ? ('消失: ' + seconds + 's') : '消失: 关';
    document.getElementById('fadeDisplay').textContent = display;
}

function cycleAutoFade() {
    const options = [0, 2, 3, 5, 8];
    const idx = options.indexOf(autoFadeSeconds);
    const next = options[(idx + 1) %% options.length];
    setAutoFade(next);
    return next;
}

function clearCanvas() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    shapes = [];
    clearAllFadeTimers();
}

function undo() {
    if (shapes.length === 0) return;
    const removed = shapes.pop();
    const entryIdx = fadeEntries.findIndex(e => e.shape === removed);
    if (entryIdx !== -1) {
        clearTimeout(fadeEntries[entryIdx].delayTimer);
        fadeEntries.splice(entryIdx, 1);
    }
    redrawAll();
}

function getShapeCount() {
    return shapes.length;
}
</script>
</body>
</html>
]], config.defaultLineWidth,
    config.defaultAutoFade > 0 and (config.defaultAutoFade .. "s") or "关",
    config.defaultLineWidth,
    config.defaultAutoFade)
end

-- ================= webview 管理 =================

local function createOverlays()
    logger.i("创建绘图覆盖层")

    for _, wv in pairs(webviews) do
        if wv then wv:delete() end
    end
    webviews = {}

    for _, screen in ipairs(hs.screen.allScreens()) do
        local frame = screen:fullFrame()
        local screenName = screen:name() or "unknown"

        logger.i("为屏幕创建覆盖层: " .. screenName)

        local wv = hs.webview.new(frame)
        wv:windowStyle(128 + 8192)
        wv:level(2147483630)
        wv:behavior(1 + 16 + 64 + 256)
        wv:allowTextEntry(false)
        wv:transparent(true)
        wv:html(getDrawingHTML())

        -- 设置初始状态
        hs.timer.doAfter(0.1, function()
            if wv then
                evalJS(wv, string.format("setColor('%s')", currentColor))
                evalJS(wv, string.format("setLineWidth(%d)", currentLineWidth))
                evalJS(wv, string.format("setAutoFade(%d)", currentAutoFade))
            end
        end)

        webviews[screen:getUUID()] = wv
    end
end

local function showOverlays()
    for _, wv in pairs(webviews) do
        if wv then wv:show() end
    end
end

local function hideOverlays()
    for _, wv in pairs(webviews) do
        if wv then wv:hide() end
    end
end

local function destroyOverlays()
    logger.i("销毁绘图覆盖层")
    for _, wv in pairs(webviews) do
        if wv then wv:delete() end
    end
    webviews = {}
end

-- ================= 绘图控制 =================

local function setColorOnAll(color)
    currentColor = color
    evalOnAll(string.format("setColor('%s')", color))
    logger.i("设置颜色: " .. color)
end

local function setShapeOnAll(shape)
    evalOnAll(string.format("setShape('%s')", shape))
    logger.i("设置形状: " .. shape)
end

local function setLineWidthOnAll(width)
    width = math.max(config.minLineWidth, math.min(config.maxLineWidth, width))
    currentLineWidth = width
    evalOnAll(string.format("setLineWidth(%d)", width))
    logger.i("设置线宽: " .. width)
end

local function cycleAutoFadeOnAll()
    for _, wv in pairs(webviews) do
        if wv then
            wv:evaluateJavaScript("cycleAutoFade()", function(result)
                if result then
                    currentAutoFade = tonumber(result) or 0
                    logger.i("自动消失: " .. currentAutoFade .. "s")
                end
            end)
        end
    end
end

local function clearAllCanvas()
    evalOnAll("clearCanvas()")
    logger.i("清除所有绘制")
end

local function undoLast()
    evalOnAll("undo()")
    logger.i("撤销")
end

-- ================= 绘图模式切换 =================

local function bindDrawingHotkeys()
    -- 颜色快捷键 1-5
    for key, color in pairs(config.colors) do
        local hk = hs.hotkey.new({}, key, function()
            setColorOnAll(color)
        end)
        hk:enable()
        table.insert(drawingHotkeys, hk)
    end

    -- 形状快捷键: F=自由, R=矩形, O=圆形, E=椭圆, A=箭头
    local shapeKeys = {
        F = "free",
        R = "rect",
        O = "circle",
        E = "ellipse",
        A = "arrow",
    }
    for key, shape in pairs(shapeKeys) do
        local hk = hs.hotkey.new({}, key, function()
            setShapeOnAll(shape)
        end)
        hk:enable()
        table.insert(drawingHotkeys, hk)
    end

    -- 线宽调整 - =
    local hkDecrease = hs.hotkey.new({}, "-", function()
        setLineWidthOnAll(currentLineWidth - config.lineWidthStep)
    end)
    hkDecrease:enable()
    table.insert(drawingHotkeys, hkDecrease)

    local hkIncrease = hs.hotkey.new({}, "=", function()
        setLineWidthOnAll(currentLineWidth + config.lineWidthStep)
    end)
    hkIncrease:enable()
    table.insert(drawingHotkeys, hkIncrease)

    -- 自动消失切换 T
    local hkFade = hs.hotkey.new({}, "T", function()
        cycleAutoFadeOnAll()
    end)
    hkFade:enable()
    table.insert(drawingHotkeys, hkFade)

    -- 清除 C
    local hkClear = hs.hotkey.new({}, "C", function()
        clearAllCanvas()
    end)
    hkClear:enable()
    table.insert(drawingHotkeys, hkClear)

    -- 撤销 Z
    local hkUndo = hs.hotkey.new({}, "Z", function()
        undoLast()
    end)
    hkUndo:enable()
    table.insert(drawingHotkeys, hkUndo)

    -- 退出 Escape
    local hkEscape = hs.hotkey.new({}, "escape", function()
        M.toggleDrawingMode()
    end)
    hkEscape:enable()
    table.insert(drawingHotkeys, hkEscape)
end

local function unbindDrawingHotkeys()
    for _, hk in ipairs(drawingHotkeys) do
        if hk then hk:delete() end
    end
    drawingHotkeys = {}
end

function M.toggleDrawingMode()
    isDrawingMode = not isDrawingMode

    if isDrawingMode then
        logger.i("进入绘图模式")
        createOverlays()
        showOverlays()
        bindDrawingHotkeys()

        hs.notify.new({
            title = "🖌️ 屏幕画笔",
            informativeText = "绘图模式已开启\nF:自由 R:矩形 O:圆 E:椭圆 A:箭头\n1-5:色 -+:粗细 T:消失 C:清 Z:撤 Esc:退",
            withdrawAfter = 3,
        }):send()
    else
        logger.i("退出绘图模式")
        unbindDrawingHotkeys()
        destroyOverlays()

        hs.notify.new({
            title = "🖌️ 屏幕画笔",
            informativeText = "绘图模式已关闭",
            withdrawAfter = 2,
        }):send()
    end
end

-- ================= 屏幕变化处理 =================

local function onScreenChange()
    if isDrawingMode then
        logger.i("检测到屏幕变化，重建覆盖层")
        destroyOverlays()
        createOverlays()
        showOverlays()
    end
end

-- ================= 模块生命周期 =================

function M.start()
    logger.i("屏幕画笔模块启动")

    local toggleHotkey = hs.hotkey.new(config.toggleKey[1], config.toggleKey[2], function()
        M.toggleDrawingMode()
    end)
    toggleHotkey:enable()
    table.insert(hotkeys, toggleHotkey)

    screenWatcher = hs.screen.watcher.new(onScreenChange)
    screenWatcher:start()

    logger.i("屏幕画笔模块已加载，按 Ctrl+Shift+D 切换绘图模式")
end

function M.stop()
    logger.i("屏幕画笔模块停止")

    if isDrawingMode then
        unbindDrawingHotkeys()
        destroyOverlays()
        isDrawingMode = false
    end

    for _, hk in ipairs(hotkeys) do
        if hk then hk:delete() end
    end
    hotkeys = {}

    if screenWatcher then
        screenWatcher:stop()
        screenWatcher = nil
    end
end

-- ================= 调试接口 =================

function M.isActive()
    return isDrawingMode
end

function M.setColor(color)
    if isDrawingMode then setColorOnAll(color) end
end

function M.setShape(shape)
    if isDrawingMode then setShapeOnAll(shape) end
end

function M.setLineWidth(width)
    if isDrawingMode then setLineWidthOnAll(width) end
end

function M.clear()
    if isDrawingMode then clearAllCanvas() end
end

return M
