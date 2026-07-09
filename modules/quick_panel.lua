-- =============================================
-- 快捷面板模块 (Quick Panel)
-- 菜单栏常驻，点击弹出紧凑面板：
--   1. TODO 待办管理（创建 / 完成 / 删除）
--   2. 快速粘贴（点击常用文本，自动粘贴到当前输入框）
-- =============================================

local M = {}

local configDir = hs.configdir
local todosFile = configDir .. "/config/todos.json"
local snippetsFile = configDir .. "/config/snippets.json"
local logger = hs.logger.new("QuickPanel", "info")

-- 面板尺寸（高度按内容自适应，这里只是兜底默认值/最小高度）
local config = {
    width = 340,
    minHeight = 160,
}

-- 状态
local menubar = nil
local panel = nil          -- hs.webview
local isVisible = false
local escKey = nil
local clickWatcher = nil    -- 监听面板外点击，自动关闭
local pendingFirstShow = false -- 首次弹出：等待内容测高完成后再 show，避免尺寸跳动
local prevApp = nil        -- 记录弹出面板前的前台应用（用于粘贴时恢复焦点）
local todos = {}
local snippets = {}
local nextTodoId = 1
local DEFAULT_GROUP = "常用"

------------------------------------------------------------
-- 数据读写
------------------------------------------------------------
local function readJSON(path, fallback)
    local file = io.open(path, "r")
    if not file then return fallback end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(hs.json.decode, content)
    if ok and type(data) == "table" then return data end
    logger.w("解析失败: " .. path)
    return fallback
end

local function writeJSON(path, data)
    local ok, encoded = pcall(hs.json.encode, data, true)
    if not ok then logger.e("编码失败: " .. path); return end
    local file = io.open(path, "w")
    if not file then logger.e("无法写入: " .. path); return end
    file:write(encoded)
    file:close()
end

local function loadData()
    todos = readJSON(todosFile, {})
    snippets = readJSON(snippetsFile, {})
    -- 兼容旧数据：没有 group 字段的，归到默认分组
    for _, s in ipairs(snippets) do
        if not s.group or s.group == "" then s.group = DEFAULT_GROUP end
    end
    -- 计算下一个 todo id
    nextTodoId = 1
    for _, t in ipairs(todos) do
        if type(t.id) == "number" and t.id >= nextTodoId then
            nextTodoId = t.id + 1
        end
    end
end

local function saveTodos() writeJSON(todosFile, todos) end
local function saveSnippets() writeJSON(snippetsFile, snippets) end

------------------------------------------------------------
-- HTML 渲染（紧凑风格）
------------------------------------------------------------
local function renderHTML()
    local todosJson = hs.json.encode(todos)
    local snippetsJson = hs.json.encode(snippets)

    local head = [[
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><style>
* { margin:0; padding:0; box-sizing:border-box; -webkit-user-select:none; }
html,body { width:100%; background:transparent; overflow:hidden;
    font-family:-apple-system,"PingFang SC",sans-serif; }
.panel { width:100%; background:rgba(28,28,34,0.97);
    border-radius:14px; padding:14px; display:flex; flex-direction:column; color:#e8e8ec; }
.sec-title { font-size:12px; color:rgba(255,255,255,0.45); font-weight:600;
    letter-spacing:0.5px; margin:2px 0 8px; display:flex; justify-content:space-between; align-items:center; }
.sec-title .add { color:#4db6a4; cursor:pointer; font-size:16px; line-height:1; padding:0 4px; }
.sec-title .add:hover { color:#63d6c0; }

.todo-input { width:100%; background:rgba(255,255,255,0.08); border:none; border-radius:8px;
    padding:8px 10px; color:#fff; font-size:13px; margin-bottom:8px; outline:none; }
.todo-input::placeholder { color:rgba(255,255,255,0.3); }

.todo-list { margin-bottom:6px; }
.todo { display:flex; align-items:center; padding:6px 4px; border-radius:6px; font-size:13px; }
.todo:hover { background:rgba(255,255,255,0.05); }
.todo .dot { width:15px; height:15px; border-radius:50%; border:1.5px solid rgba(255,255,255,0.35);
    margin-right:9px; cursor:pointer; flex:0 0 auto; }
.todo.done .dot { background:#4db6a4; border-color:#4db6a4; position:relative; }
.todo.done .dot::after { content:"✓"; color:#1c1c22; font-size:10px; position:absolute;
    left:2px; top:-1px; font-weight:bold; }
.todo .txt { flex:1; cursor:pointer; word-break:break-all; }
.todo.done .txt { color:rgba(255,255,255,0.35); text-decoration:line-through; }
.todo .del { color:rgba(255,255,255,0.25); cursor:pointer; padding:0 4px; font-size:14px; opacity:0; }
.todo:hover .del { opacity:1; }
.todo .del:hover { color:#e06c6c; }
.empty { color:rgba(255,255,255,0.25); font-size:12px; text-align:center; padding:12px 0; }

.divider { height:1px; background:rgba(255,255,255,0.08); margin:8px 0 10px; }

.snip-form { background:rgba(255,255,255,0.05); border-radius:8px; padding:8px; margin-bottom:8px; }
.snip-input { width:100%; background:rgba(255,255,255,0.08); border:none; border-radius:6px;
    padding:7px 9px; color:#fff; font-size:12.5px; margin-bottom:6px; outline:none; }
.snip-input:last-of-type { margin-bottom:8px; }
.snip-input::placeholder { color:rgba(255,255,255,0.3); }
.snip-form-actions { display:flex; justify-content:flex-end; gap:8px; }
.snip-form-btn { font-size:12px; padding:4px 12px; border-radius:6px; cursor:pointer; }
.snip-form-btn.confirm { background:#4db6a4; color:#0e2622; font-weight:600; }
.snip-form-btn.confirm:hover { background:#63d6c0; }
.snip-form-btn.cancel { color:rgba(255,255,255,0.4); }
.snip-form-btn.cancel:hover { color:rgba(255,255,255,0.65); }

.snip-groups { display:flex; flex-direction:column; gap:8px; }
.snip-group-name { font-size:11px; color:rgba(255,255,255,0.32); font-weight:600;
    margin-bottom:5px; padding-left:1px; }
.snip-list { display:flex; flex-wrap:wrap; gap:7px; align-content:flex-start; }
.snip { background:rgba(77,182,164,0.15); border:1px solid rgba(77,182,164,0.3);
    color:#7fe0cf; border-radius:8px; padding:6px 12px; font-size:12.5px; cursor:pointer;
    position:relative; max-width:100%; }
.snip:hover { background:rgba(77,182,164,0.28); }
.snip:active { transform:scale(0.96); }
.snip .sdel { position:absolute; top:-6px; right:-6px; width:16px; height:16px; border-radius:50%;
    background:#e06c6c; color:#fff; font-size:11px; line-height:16px; text-align:center;
    display:none; }
.snip:hover .sdel { display:block; }
.toast { position:fixed; bottom:12px; left:50%; transform:translateX(-50%);
    background:rgba(77,182,164,0.95); color:#fff; padding:5px 14px; border-radius:8px;
    font-size:12px; opacity:0; transition:opacity 0.2s; pointer-events:none; }
.toast.show { opacity:1; }
</style></head>
<body>
<div class="panel" id="panelRoot">
    <div class="sec-title"><span>待办事项</span><span class="add" id="addTodoBtn">＋</span></div>
    <input class="todo-input" id="todoInput" placeholder="输入任务，回车添加" style="display:none;">
    <div class="todo-list" id="todoList"></div>
    <div class="divider"></div>
    <div class="sec-title"><span>快速粘贴</span><span class="add" id="addSnipBtn">＋</span></div>
    <div class="snip-form" id="snipForm" style="display:none;">
        <input class="snip-input" id="snipLabelInput" placeholder="按钮显示的名称，如：测试环境地址">
        <input class="snip-input" id="snipTextInput" placeholder="点击后粘贴的内容">
        <input class="snip-input" id="snipGroupInput" placeholder="所属分组，留空为“常用”" list="groupOptions">
        <datalist id="groupOptions"></datalist>
        <div class="snip-form-actions">
            <span class="snip-form-btn cancel" id="snipCancelBtn">取消</span>
            <span class="snip-form-btn confirm" id="snipConfirmBtn">添加</span>
        </div>
    </div>
    <div class="snip-groups" id="snipGroups"></div>
</div>
<div class="toast" id="toast">已复制</div>
<script>
]]

    local script = [[
var TODOS = ]] .. todosJson .. [[;
var SNIPPETS = ]] .. snippetsJson .. [[;
function send(obj){ try{ webkit.messageHandlers.QuickPanel.postMessage(obj); }catch(e){} }
function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function bindIMEAwareInput(inp){
    inp._imeComposing = false;
    inp.addEventListener('compositionstart', function(){ inp._imeComposing = true; });
    inp.addEventListener('compositionend', function(){ inp._imeComposing = false; });
}
function isIMEComposing(e, inp){
    return !!(e.isComposing || e.keyCode === 229 || (inp && inp._imeComposing));
}

function renderTodos(){
    var el = document.getElementById('todoList');
    if(!TODOS.length){ el.innerHTML = '<div class="empty">暂无待办</div>'; return; }
    var sorted = TODOS.slice().sort(function(a,b){ return (a.done?1:0)-(b.done?1:0); });
    el.innerHTML = sorted.map(function(t){
        return '<div class="todo '+(t.done?'done':'')+'">'
            + '<div class="dot" onclick="toggleTodo('+t.id+')"></div>'
            + '<div class="txt" onclick="toggleTodo('+t.id+')">'+esc(t.text)+'</div>'
            + '<div class="del" onclick="delTodo('+t.id+')">×</div></div>';
    }).join('');
}
function renderSnips(){
    var el = document.getElementById('snipGroups');
    // 按分组归类，保持组内原始顺序；分组顺序按首次出现顺序
    var groupNames = [];
    var groupMap = {};
    SNIPPETS.forEach(function(s, i){
        var g = s.group || '常用';
        if(!groupMap[g]){ groupMap[g] = []; groupNames.push(g); }
        groupMap[g].push(i);
    });
    var html = '';
    groupNames.forEach(function(g){
        var items = groupMap[g].map(function(i){
            var s = SNIPPETS[i];
            return '<div class="snip" onclick="pasteSnip('+i+')" title="'+esc(s.text)+'">'
                + esc(s.label)
                + '<span class="sdel" onclick="event.stopPropagation();delSnip('+i+')">×</span></div>';
        }).join('');
        html += '<div class="snip-group"><div class="snip-group-name">'+esc(g)+'</div>'
            + '<div class="snip-list">'+items+'</div></div>';
    });
    if(!groupNames.length){
        html = '<div class="empty">暂无快速粘贴项</div>';
    }
    el.innerHTML = html;

    // 分组名自动补全列表
    var dl = document.getElementById('groupOptions');
    dl.innerHTML = groupNames.map(function(g){ return '<option value="'+esc(g)+'">'; }).join('');
}
function toggleTodo(id){ send({action:'toggleTodo', id:id}); }
function delTodo(id){ send({action:'delTodo', id:id}); }
function pasteSnip(i){ showToast(); send({action:'paste', index:i}); }
function delSnip(i){ send({action:'delSnip', index:i}); }

// 快速粘贴：内嵌表单新增（不用原生 prompt，悬浮不激活窗口里 prompt 不可靠）
var snipForm = document.getElementById('snipForm');
var snipLabelInput = document.getElementById('snipLabelInput');
var snipTextInput = document.getElementById('snipTextInput');
var snipGroupInput = document.getElementById('snipGroupInput');

function openSnipForm(){
    snipForm.style.display = 'block';
    snipLabelInput.value = ''; snipTextInput.value = ''; snipGroupInput.value = '';
    snipLabelInput.focus();
    reportHeight();
}
function closeSnipForm(){
    snipForm.style.display = 'none';
    reportHeight();
}
function submitSnipForm(){
    var label = snipLabelInput.value.trim();
    var text = snipTextInput.value.trim();
    var group = snipGroupInput.value.trim() || '常用';
    if(!label || !text){
        (label ? snipTextInput : snipLabelInput).focus();
        return;
    }
    send({action:'addSnip', label:label, text:text, group:group});
    closeSnipForm();
}
document.getElementById('addSnipBtn').onclick = function(){
    if(snipForm.style.display === 'none'){ openSnipForm(); } else { closeSnipForm(); }
};
document.getElementById('snipCancelBtn').onclick = closeSnipForm;
document.getElementById('snipConfirmBtn').onclick = submitSnipForm;
[snipLabelInput, snipTextInput, snipGroupInput].forEach(function(inp){
    bindIMEAwareInput(inp);
    inp.addEventListener('keydown', function(e){
        if(isIMEComposing(e, inp)) return;
        if(e.key === 'Enter'){ e.preventDefault(); submitSnipForm(); }
        if(e.key === 'Escape'){ e.preventDefault(); closeSnipForm(); }
    });
});
function showToast(){
    var t = document.getElementById('toast'); t.classList.add('show');
    setTimeout(function(){ t.classList.remove('show'); }, 900);
}
var input = document.getElementById('todoInput');
bindIMEAwareInput(input);
document.getElementById('addTodoBtn').onclick = function(){
    input.style.display = (input.style.display==='none') ? 'block' : 'none';
    if(input.style.display==='block') input.focus();
    reportHeight();
};
input.addEventListener('keydown', function(e){
    if(isIMEComposing(e, input)) return;
    if(e.key==='Enter' && input.value.trim()){
        e.preventDefault();
        send({action:'addTodo', text:input.value.trim()});
        input.value='';
    }
    if(e.key==='Escape'){
        e.preventDefault();
        input.style.display='none';
        reportHeight();
    }
});

// 内容自适应高度：测量 panel 实际高度上报给 Hammerspoon 调整窗口大小
var lastReportedH = 0;
function reportHeight(){
    var h = document.getElementById('panelRoot').scrollHeight;
    if(h !== lastReportedH){
        lastReportedH = h;
        send({action:'reportHeight', height:h});
    }
}
renderTodos(); renderSnips();
reportHeight();
// 内容后续变化（增删待办/粘贴项）时也会重新上报
new MutationObserver(function(){ reportHeight(); })
    .observe(document.getElementById('panelRoot'), { childList:true, subtree:true, attributes:true });
</script>
</body>
</html>
]]

    return head .. script
end

------------------------------------------------------------
-- 面板显示 / 隐藏
------------------------------------------------------------
local currentPanelFrame = nil  -- 面板当前实际 frame（随内容自适应高度会变化），供点击监听读取

local function computeFrame(height)
    -- 定位到菜单栏图标下方，右对齐；高度按内容自适应（由 JS 测高上报）
    local mbFrame = menubar and menubar:frame() or nil
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local sf = screen:fullFrame()

    local h = height or config.minHeight
    if h < config.minHeight then h = config.minHeight end
    -- 高度不超过屏幕可用空间，避免超出屏幕（极端情况下兜底交给 webview 内部滚动）
    local maxH = sf.h - 60
    if h > maxH then h = maxH end

    local x, y
    if mbFrame then
        x = mbFrame.x + mbFrame.w - config.width
        y = mbFrame.y + mbFrame.h + 4
    else
        x = sf.x + sf.w - config.width - 20
        y = sf.y + 30
    end
    -- 防止超出屏幕左边界
    if x < sf.x + 8 then x = sf.x + 8 end
    -- 防止超出屏幕下边界
    if y + h > sf.y + sf.h then y = sf.y + sf.h - h - 8 end
    return { x = x, y = y, w = config.width, h = h }
end

-- 根据内容实际高度调整面板窗口大小（不改变左上角锚点逻辑，保持右对齐菜单栏图标）
local function resizePanel(contentHeight)
    if not panel then return end
    -- 内容高度需加上面板 CSS padding(14*2=28)，JS 上报的是 panelRoot.scrollHeight（已含 padding）
    local frame = computeFrame(contentHeight)
    panel:frame(frame)
    currentPanelFrame = frame
end

local function hidePanel()
    if not isVisible then return end
    if panel then panel:delete(); panel = nil end
    if escKey then escKey:delete(); escKey = nil end
    if clickWatcher then clickWatcher:stop(); clickWatcher = nil end
    currentPanelFrame = nil
    isVisible = false
end

-- 执行粘贴：恢复原应用焦点 -> 写剪贴板 -> 注入 Cmd+V
local function doPaste(text)
    if not text or text == "" then return end
    hs.pasteboard.setContents(text)
    local target = prevApp
    hidePanel()
    hs.timer.doAfter(0.08, function()
        if target then target:activate() end
        hs.timer.doAfter(0.08, function()
            hs.eventtap.keyStroke({"cmd"}, "v", 0)
            logger.i("已粘贴: " .. text:sub(1, 20))
        end)
    end)
end

local function handleMessage(msg)
    local body = msg.body
    if type(body) ~= "table" then return end
    local action = body.action

    if action == "addTodo" then
        table.insert(todos, { id = nextTodoId, text = body.text, done = false })
        nextTodoId = nextTodoId + 1
        saveTodos()
        if panel then panel:html(renderHTML()) end

    elseif action == "toggleTodo" then
        for _, t in ipairs(todos) do
            if t.id == body.id then t.done = not t.done; break end
        end
        saveTodos()
        if panel then panel:html(renderHTML()) end

    elseif action == "delTodo" then
        for i, t in ipairs(todos) do
            if t.id == body.id then table.remove(todos, i); break end
        end
        saveTodos()
        if panel then panel:html(renderHTML()) end

    elseif action == "paste" then
        local s = snippets[(body.index or 0) + 1]
        if s then doPaste(s.text) end

    elseif action == "addSnip" then
        table.insert(snippets, { label = body.label, text = body.text, group = (body.group and body.group ~= "" and body.group) or DEFAULT_GROUP })
        saveSnippets()
        if panel then panel:html(renderHTML()) end

    elseif action == "delSnip" then
        table.remove(snippets, (body.index or 0) + 1)
        saveSnippets()
        if panel then panel:html(renderHTML()) end

    elseif action == "reportHeight" then
        local h = tonumber(body.height)
        if h then
            if pendingFirstShow then
                -- 首次弹出：定位好尺寸后再显示，避免出现"先小后大"跳动
                local frame = computeFrame(h)
                panel:frame(frame)
                currentPanelFrame = frame
                panel:show()
                pendingFirstShow = false
            else
                resizePanel(h)
            end
        end
    end
end

local function showPanel()
    if isVisible then return end
    -- 记录当前前台应用（用于粘贴恢复焦点）
    prevApp = hs.application.frontmostApplication()
    loadData()

    local uc = hs.webview.usercontent.new("QuickPanel")
    uc:setCallback(handleMessage)

    -- 先用最小高度创建（不立即显示），等 JS 首次测高上报后再定位显示，避免尺寸跳动
    local initFrame = computeFrame(config.minHeight)
    panel = hs.webview.new(initFrame, { javaScriptEnabled = true }, uc)
    panel:windowStyle(128 + 8192)         -- nonactivating + HUD：不抢占前台应用焦点
    panel:level(hs.canvas.windowLevels.floating)
    panel:behavior(1 + 16 + 64 + 256)     -- 可跨 Space、随全屏切换
    panel:allowTextEntry(true)            -- 允许在面板内输入（不激活窗口）
    panel:transparent(true)
    currentPanelFrame = initFrame
    pendingFirstShow = true
    panel:html(renderHTML())
    -- 注意：不在此处调用 panel:show()，交由 handleMessage 里的 reportHeight 首帧回调触发显示
    isVisible = true

    -- ESC 关闭
    if not escKey then
        escKey = hs.hotkey.bind({}, "escape", function() hidePanel() end)
    end

    -- 点击面板外部自动关闭（排除面板区域与菜单栏图标区域；面板 frame 会随内容自适应变化，实时读取 currentPanelFrame）
    clickWatcher = hs.eventtap.new(
        { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown },
        function(e)
            local p = e:location()
            local pf = currentPanelFrame
            -- 落在面板内：不关闭
            if pf and p.x >= pf.x and p.x <= pf.x + pf.w
                and p.y >= pf.y and p.y <= pf.y + pf.h then
                return false
            end
            -- 落在菜单栏图标上：交给 toggle 处理，避免关了又开
            local mb = menubar and menubar:frame() or nil
            if mb and p.x >= mb.x and p.x <= mb.x + mb.w
                and p.y >= mb.y and p.y <= mb.y + mb.h then
                return false
            end
            hidePanel()
            return false
        end
    )
    clickWatcher:start()
end

local function togglePanel()
    if isVisible then hidePanel() else showPanel() end
end

------------------------------------------------------------
-- 启动 / 停止
------------------------------------------------------------
function M.start()
    loadData()
    menubar = hs.menubar.new()
    menubar:setTitle("📋")
    menubar:setTooltip("快捷面板：待办 & 快速粘贴")
    menubar:setClickCallback(function(mods)
        if mods and (mods.ctrl or mods.rightClick) then
            hs.execute("open " .. todosFile)   -- Ctrl/右键：打开配置文件
        else
            togglePanel()
        end
    end)
    logger.i("快捷面板模块已启动")
end

function M.stop()
    hidePanel()
    if menubar then menubar:delete(); menubar = nil end
    logger.i("快捷面板模块已停止")
end

-- 可选：绑定全局快捷键唤起（Cmd+Shift+J）
hs.hotkey.bind({"cmd", "shift"}, "j", function()
    togglePanel()
end)

return M
