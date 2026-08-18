-- =============================================
-- 日历面板模块 (Calendar Panel)
-- 菜单栏日期图标 / Ctrl+R 唤起：
--   1. 月历网格（公历 + 农历 + 节气 + 传统/公历节日）
--   2. 有待办的日期显示圆点，点击日期展开当天待办（按 createdAt 归属）
--   3. 深色毛玻璃拟态，底部滑杆实时调节背景透明度（持久化）
-- =============================================

local M = {}

local configDir = hs.configdir
local todosFile = configDir .. "/config/todos.json"
local calendarFile = configDir .. "/config/calendar.json"
local logger = hs.logger.new("CalendarPanel", "info")

-- 面板尺寸（高度按内容自适应，这里只是兜底默认值/最小高度）
local config = {
    width = 400,
    minHeight = 320,
}

-- 状态
local menubar = nil
local panel = nil          -- hs.webview
local isVisible = false
local escKey = nil
local clickWatcher = nil    -- 监听面板外点击，自动关闭
local pendingFirstShow = false -- 首次弹出：等待内容测高完成后再 show，避免尺寸跳动
local menuTimer = nil       -- 菜单栏日期标题定时刷新
local alpha = 0.62          -- 背景透明度（CSS 变量 --alpha，持久化到 config/calendar.json）

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

local function loadPrefs()
    local prefs = readJSON(calendarFile, {})
    if type(prefs.alpha) == "number" and prefs.alpha >= 0.2 and prefs.alpha <= 1 then
        alpha = prefs.alpha
    end
end

local function savePrefs()
    writeJSON(calendarFile, { alpha = alpha })
end

local function loadTodos()
    return readJSON(todosFile, {})
end

------------------------------------------------------------
-- HTML 渲染
------------------------------------------------------------
local function renderHTML()
    local todosJson = hs.json.encode(loadTodos())

    local head = [[
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><style>
* { margin:0; padding:0; box-sizing:border-box; -webkit-user-select:none; }
html,body { width:100%; background:transparent; overflow:hidden;
    font-family:-apple-system,"SF Pro Text","PingFang SC",sans-serif;
    -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility; }

/* ---- 液态毛玻璃 · 灰色通透材质 ---- */
.panel { position:relative; width:100%;
    background:linear-gradient(180deg,
        rgba(74,74,80,var(--alpha)) 0%,
        rgba(56,56,62,var(--alpha)) 100%);
    border-radius:24px; padding:18px; color:#ececf0;
    border:1px solid rgba(255,255,255,0.18);
    -webkit-backdrop-filter:blur(32px) saturate(150%);
    backdrop-filter:blur(32px) saturate(150%);
    box-shadow:
        0 14px 36px rgba(0,0,0,0.22),
        0 2px 8px rgba(0,0,0,0.10),
        inset 0 1px 0 rgba(255,255,255,0.28),
        inset 0 -1px 0 rgba(255,255,255,0.06); }
/* 顶部高光 + 菲涅尔边缘光晕（模拟环境光掠射，轻盈） */
.panel::before { content:""; position:absolute; inset:0; border-radius:inherit;
    pointer-events:none; z-index:0; opacity:0.35;
    background:
        radial-gradient(120% 60% at 18% 0%, rgba(255,255,255,0.35) 0%, rgba(255,255,255,0) 55%),
        radial-gradient(90% 50% at 85% 100%, rgba(255,255,255,0.12) 0%, rgba(255,255,255,0) 60%); }
.panel > * { position:relative; z-index:1; }

.cal-head { display:flex; align-items:center; justify-content:space-between; margin-bottom:3px; }
.cal-title { font-size:18px; font-weight:700; letter-spacing:-0.2px; color:#f2f2f5;
    display:flex; align-items:center; gap:7px; }
.nav { color:rgba(255,255,255,0.42); cursor:pointer; font-size:15px; width:24px; height:24px;
    display:inline-flex; align-items:center; justify-content:center; border-radius:50%; line-height:1; }
.nav:hover { background:rgba(255,255,255,0.10); color:rgba(255,255,255,0.8); }
.today-btn { font-size:11px; font-weight:600; color:#5da8ff; cursor:pointer; padding:4px 11px;
    border:1px solid rgba(93,168,255,0.4); border-radius:999px; background:rgba(93,168,255,0.10); }
.today-btn:hover { background:rgba(93,168,255,0.20); }
.lunar-sub { font-size:11px; color:rgba(255,255,255,0.5); text-align:center; margin:4px 0 12px;
    letter-spacing:0.3px; }

.weekrow { display:grid; grid-template-columns:repeat(7,1fr); font-size:10.5px; font-weight:600;
    color:rgba(255,255,255,0.32); text-align:center; margin-bottom:5px; }
.cal-grid { display:grid; grid-template-columns:repeat(7,1fr); gap:3px; }
.cell { position:relative; aspect-ratio:1/1; border-radius:10px; cursor:pointer;
    display:flex; flex-direction:column; align-items:center; justify-content:center; padding-top:1px;
    transition:background 0.12s ease; }
.cell:hover { background:rgba(255,255,255,0.08); }
.cell .g { font-size:13.5px; font-weight:600; color:rgba(245,245,248,0.92); line-height:1.15; }
.cell .l { font-size:8.5px; color:rgba(255,255,255,0.48); line-height:1.2; transform:scale(0.92);
    white-space:nowrap; }
.cell.other .g { color:rgba(255,255,255,0.22); }
.cell.other .l { color:rgba(255,255,255,0.18); }
.cell .l.term { color:#6fb3e0; font-weight:600; }
.cell .l.fest { color:#e8a45c; font-weight:600; }
.cell.today { background:rgba(93,168,255,0.28); }
.cell.today .g { color:#8ec2ff; font-weight:700; }
.cell.sel { outline:1.5px solid rgba(93,168,255,0.6); outline-offset:-1.5px; }
.cell .tdot { position:absolute; bottom:4px; left:50%; transform:translateX(-50%);
    width:4px; height:4px; border-radius:50%; background:#4da3ff; }

.detail { border-top:1px solid rgba(255,255,255,0.10); margin-top:12px; padding-top:10px; display:none; }
.detail .dtitle { font-size:12px; font-weight:600; color:rgba(255,255,255,0.55); margin-bottom:7px; }
.dtodo { display:flex; align-items:center; padding:6px 5px; border-radius:8px; font-size:12.5px;
    color:#ececf0; }
.dtodo:hover { background:rgba(255,255,255,0.06); }
.dtodo .dot { width:13px; height:13px; border-radius:50%; border:1.5px solid rgba(255,255,255,0.35);
    margin-right:9px; flex:0 0 auto; }
.dtodo.done .dot { background:#4da3ff; border-color:#4da3ff; }
.dtodo .txt { flex:1; word-break:break-all; }
.dtodo.done .txt { color:rgba(255,255,255,0.35); text-decoration:line-through; }
.dempty { color:rgba(255,255,255,0.3); font-size:12px; text-align:center; padding:9px 0; }

.alpha-row { display:flex; align-items:center; gap:10px; margin-top:12px; padding-top:11px;
    border-top:1px solid rgba(255,255,255,0.10); }
.alpha-row .lbl { font-size:10.5px; color:rgba(255,255,255,0.4); white-space:nowrap; }
.alpha-row input[type=range] { flex:1; height:3px; accent-color:#4da3ff; cursor:pointer; }
</style></head>
<body>
<div class="panel" id="panelRoot">
    <div class="cal-head">
        <div class="cal-title">
            <span class="nav" id="prevM">‹</span>
            <span id="monthTitle"></span>
            <span class="nav" id="nextM">›</span>
        </div>
        <span class="today-btn" id="todayBtn">今天</span>
    </div>
    <div class="lunar-sub" id="lunarSub"></div>
    <div class="weekrow"><span>一</span><span>二</span><span>三</span><span>四</span><span>五</span><span>六</span><span>日</span></div>
    <div class="cal-grid" id="calGrid"></div>
    <div class="detail" id="detail"></div>
    <div class="alpha-row">
        <span class="lbl">透明度</span>
        <input type="range" id="alphaSlider" min="20" max="100" step="5">
        <span class="lbl" id="alphaVal"></span>
    </div>
</div>
<script>
]]

    local script = [[
var TODOS = ]] .. todosJson .. [[;
var ALPHA = ]] .. string.format("%.2f", alpha) .. [[;
function send(obj){ try{ webkit.messageHandlers.CalendarPanel.postMessage(obj); }catch(e){} }
function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

// ---------------- 农历换算（1900-2100 查表法） ----------------
var LUNAR_INFO=[
0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
0x06ca0,0x0b550,0x15355,0x04da0,0x0a5d0,0x14573,0x052d0,0x0a9a8,0x0e950,0x06aa0,
0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b5a0,0x195a6,
0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0,
0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
0x05aa0,0x076a3,0x096d0,0x04bd7,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
0x14b63];

var S_TERM_INFO=[0,21208,42467,63836,85337,107014,128867,150921,173149,195551,218072,240693,
263343,285989,308563,331033,353350,375494,397447,419210,440795,462224,483532,504758];
var S_TERM_NAMES=["小寒","大寒","立春","雨水","惊蛰","春分","清明","谷雨","立夏","小满","芒种","夏至",
"小暑","大暑","立秋","处暑","白露","秋分","寒露","霜降","立冬","小雪","大雪","冬至"];
var GAN=["甲","乙","丙","丁","戊","己","庚","辛","壬","癸"];
var ZHI=["子","丑","寅","卯","辰","巳","午","未","申","酉","戌","亥"];
var ANIMALS=["鼠","牛","虎","兔","龙","蛇","马","羊","猴","鸡","狗","猪"];
var NUM_CN=["日","一","二","三","四","五","六","七","八","九","十"];
var DAY_PRE=["初","十","廿","卅"];
var LUNAR_FEST={"1-1":"春节","1-15":"元宵","2-2":"龙抬头","5-5":"端午","7-7":"七夕","7-15":"中元",
"8-15":"中秋","9-9":"重阳","12-8":"腊八","12-23":"小年"};
var SOLAR_FEST={"1-1":"元旦","2-14":"情人节","3-8":"妇女节","3-12":"植树节","5-1":"劳动节","5-4":"青年节",
"6-1":"儿童节","7-1":"建党节","8-1":"建军节","9-10":"教师节","10-1":"国庆","12-24":"平安夜","12-25":"圣诞节"};

function leapMonth(y){ return LUNAR_INFO[y-1900]&0xf; }
function leapDays(y){ return leapMonth(y) ? ((LUNAR_INFO[y-1900]&0x10000)?30:29) : 0; }
function monthDays(y,m){ return (LUNAR_INFO[y-1900]&(0x10000>>m))?30:29; }
function lYearDays(y){ var i,sum=348; for(i=0x8000;i>0x8;i>>=1){ sum+=(LUNAR_INFO[y-1900]&i)?1:0; } return sum+leapDays(y); }
function sTermDay(y,n){ var t=new Date((31556925974.7*(y-1900)+S_TERM_INFO[n]*60000)+Date.UTC(1900,0,6,2,5)); return t.getUTCDate(); }
function lunarDayName(d){
    if(d===10) return "初十";
    if(d===20) return "二十";
    if(d===30) return "三十";
    return DAY_PRE[Math.floor((d-1)/10)] + NUM_CN[d%10];
}
function lunarMonthName(m){ return "正二三四五六七八九十冬腊".charAt(m-1)+"月"; }
function gzYear(ly){ return GAN[(ly-4)%10]+ZHI[(ly-4)%12]; }
function animalOf(ly){ return ANIMALS[(ly-4)%12]; }

// 公历 -> 农历（y 范围 1900-2100）
function lunarFromSolar(y,m,d){
    var offset=Math.floor((Date.UTC(y,m-1,d)-Date.UTC(1900,0,31))/86400000);
    var i,temp=0;
    for(i=1900;i<2101&&offset>0;i++){ temp=lYearDays(i); offset-=temp; }
    if(offset<0){ offset+=temp; i--; }
    var ly=i, leap=leapMonth(i), isLeap=false;
    for(i=1;i<13&&offset>0;i++){
        if(leap>0&&i===(leap+1)&&!isLeap){ --i; isLeap=true; temp=leapDays(ly); }
        else { temp=monthDays(ly,i); }
        if(isLeap&&i===(leap+1)) isLeap=false;
        offset-=temp;
    }
    if(offset===0&&leap>0&&i===leap+1){ if(isLeap){ isLeap=false; } else { isLeap=true; --i; } }
    if(offset<0){ offset+=temp; --i; }
    return { ly:ly, lm:i, ld:offset+1, isLeap:isLeap };
}

// 单元格副标：节气 > 除夕 > 农历节日 > 公历节日 > 初一(显示月份) > 农历日
function cellLabel(y,m,d,lun){
    var sIdx=(m-1)*2;
    if(d===sTermDay(y,sIdx))   return { t:S_TERM_NAMES[sIdx],   cls:"term" };
    if(d===sTermDay(y,sIdx+1)) return { t:S_TERM_NAMES[sIdx+1], cls:"term" };
    if(lun.lm===12 && lun.ld===monthDays(lun.ly,12)) return { t:"除夕", cls:"fest" };
    var lf=LUNAR_FEST[lun.lm+"-"+lun.ld]; if(lf) return { t:lf, cls:"fest" };
    var sf=SOLAR_FEST[m+"-"+d];           if(sf) return { t:sf, cls:"fest" };
    if(lun.ld===1) return { t:(lun.isLeap?"闰":"")+lunarMonthName(lun.lm), cls:"" };
    return { t:lunarDayName(lun.ld), cls:"" };
}

// ---------------- 渲染 ----------------
var now=new Date();
var view={ y:now.getFullYear(), m:now.getMonth()+1 };
var selDate=null;   // 当前展开详情的日期 "YYYY-MM-DD"

function pad2(n){ return (n<10?"0":"")+n; }
function dateStr(y,m,d){ return y+"-"+pad2(m)+"-"+pad2(d); }

function todosOf(ds){
    var list=TODOS.filter(function(t){
        return t.createdAt && String(t.createdAt).indexOf(ds)===0;
    });
    list.sort(function(a,b){ return ((a.done?1:0)-(b.done?1:0)) || ((b.id||0)-(a.id||0)); });
    return list;
}

function render(){
    var y=view.y, m=view.m;
    document.getElementById("monthTitle").textContent=y+"年"+m+"月";

    // 头部农历信息（取当月 15 日对应的农历，保证落在本月主农历月内）
    var mid=lunarFromSolar(y,m,15);
    document.getElementById("lunarSub").textContent =
        gzYear(mid.ly)+"年("+animalOf(mid.ly)+") · "+(mid.isLeap?"闰":"")+lunarMonthName(mid.lm);

    // 网格：周一开头，6×7
    var first=new Date(y,m-1,1);
    var lead=(first.getDay()+6)%7;          // 周一为 0
    var dim=new Date(y,m,0).getDate();      // 本月天数
    var prevDim=new Date(y,m-1,0).getDate();// 上月天数
    var todayStr=dateStr(now.getFullYear(),now.getMonth()+1,now.getDate());

    var html="";
    for(var i=0;i<42;i++){
        var cy,cy2,cm,cd,cur;
        if(i<lead){ cm=m-1; cd=prevDim-lead+1+i; cur=false; }
        else if(i<lead+dim){ cm=m; cd=i-lead+1; cur=true; }
        else { cm=m+1; cd=i-lead-dim+1; cur=false; }
        cy2=y;
        if(cm===0){ cm=12; cy2=y-1; }
        if(cm===13){ cm=1; cy2=y+1; }
        cy=cy2;

        var inRange=(cy>=1900&&cy<=2100);
        var lbl=inRange?cellLabel(cy,cm,cd,lunarFromSolar(cy,cm,cd)):{t:"",cls:""};
        var ds=dateStr(cy,cm,cd);
        var hasTodo=todosOf(ds).length>0;

        var cls="cell"+(cur?"":" other");
        if(ds===todayStr) cls+=" today";
        if(ds===selDate) cls+=" sel";

        html+='<div class="'+cls+'" data-ds="'+ds+'">'
            +'<div class="g">'+cd+'</div>'
            +'<div class="l '+lbl.cls+'">'+lbl.t+'</div>'
            +(hasTodo?'<div class="tdot"></div>':'')
            +'</div>';
    }
    document.getElementById("calGrid").innerHTML=html;

    var cells=document.getElementById("calGrid").children;
    for(var j=0;j<cells.length;j++){
        cells[j].addEventListener("click",function(){
            var ds=this.getAttribute("data-ds");
            selDate=(selDate===ds)?null:ds;
            render();
        });
    }
    renderDetail();
}

function renderDetail(){
    var el=document.getElementById("detail");
    if(!selDate){ el.style.display="none"; el.innerHTML=""; return; }
    var list=todosOf(selDate);
    var html='<div class="dtitle">'+selDate+' 待办 ('+list.length+')</div>';
    if(!list.length){
        html+='<div class="dempty">当天没有待办</div>';
    } else {
        for(var i=0;i<list.length;i++){
            var t=list[i];
            html+='<div class="dtodo'+(t.done?' done':'')+'">'
                +'<div class="dot"></div>'
                +'<div class="txt">'+esc(t.text)+'</div></div>';
        }
    }
    el.innerHTML=html;
    el.style.display="block";
}

// ---------------- 事件 ----------------
document.getElementById("prevM").onclick=function(){
    view.m--; if(view.m===0){ view.m=12; view.y--; } render();
};
document.getElementById("nextM").onclick=function(){
    view.m++; if(view.m===13){ view.m=1; view.y++; } render();
};
document.getElementById("todayBtn").onclick=function(){
    view={ y:now.getFullYear(), m:now.getMonth()+1 };
    render();
};

// 透明度滑杆：拖动即时改 CSS（本地生效，无 Lua 往返），松手后持久化
var slider=document.getElementById("alphaSlider");
var panelRoot=document.getElementById("panelRoot");
function applyAlpha(v){
    panelRoot.style.setProperty("--alpha", v);
    document.getElementById("alphaVal").textContent=Math.round(v*100)+"%";
}
slider.value=Math.round(ALPHA*100);
applyAlpha(ALPHA);
slider.addEventListener("input",function(){ applyAlpha(this.value/100); });
slider.addEventListener("change",function(){ send({action:"setAlpha", value:this.value/100}); });

// 内容自适应高度：测量 panel 实际高度上报给 Hammerspoon 调整窗口大小
var lastReportedH=0;
function reportHeight(){
    var h=panelRoot.scrollHeight;
    if(h!==lastReportedH){ lastReportedH=h; send({action:"reportHeight", height:h}); }
}
render();
reportHeight();
new MutationObserver(function(){ reportHeight(); })
    .observe(panelRoot,{ childList:true, subtree:true, attributes:true });
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
    local screen = hs.screen.mainScreen()  -- 固定主屏，避免鼠标在副屏时面板跑到副屏
    local sf = screen:fullFrame()

    local h = height or config.minHeight
    if h < config.minHeight then h = config.minHeight end
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
    if x < sf.x + 8 then x = sf.x + 8 end
    if y + h > sf.y + sf.h then y = sf.y + sf.h - h - 8 end
    return { x = x, y = y, w = config.width, h = h }
end

local function resizePanel(contentHeight)
    if not panel then return end
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

local function handleMessage(msg)
    local body = msg.body
    if type(body) ~= "table" then return end
    local action = body.action

    if action == "setAlpha" then
        local v = tonumber(body.value)
        if v and v >= 0.2 and v <= 1 then
            alpha = v
            savePrefs()
        end

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
    loadPrefs()

    local uc = hs.webview.usercontent.new("CalendarPanel")
    uc:setCallback(handleMessage)

    -- 先用最小高度创建（不立即显示），等 JS 首次测高上报后再定位显示，避免尺寸跳动
    local initFrame = computeFrame(config.minHeight)
    panel = hs.webview.new(initFrame, { javaScriptEnabled = true }, uc)
    panel:windowStyle(128)                -- nonactivating：不抢占前台应用焦点（去掉 HUD，避免激活其他 app 后面板被系统降级）
    panel:level(hs.canvas.windowLevels.popUpMenu)  -- 高于普通应用窗口，始终浮于最上层，不被遮挡
    panel:behavior(1 + 16 + 64 + 256)     -- 可跨 Space、随全屏切换
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
            if pf and p.x >= pf.x and p.x <= pf.x + pf.w
                and p.y >= pf.y and p.y <= pf.y + pf.h then
                return false
            end
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

-- 暴露给外部调用（调试/脚本化触发）
M.toggle = togglePanel

------------------------------------------------------------
-- 菜单栏标题（"8月18日 周二"），定时刷新保证跨天正确
------------------------------------------------------------
local WEEK_CN = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

local function updateMenuTitle()
    if not menubar then return end
    local t = os.date("*t")
    menubar:setTitle(string.format("%d月%d日 %s", t.month, t.day, WEEK_CN[t.wday]))
end

------------------------------------------------------------
-- 启动 / 停止
------------------------------------------------------------
function M.start()
    loadPrefs()
    menubar = hs.menubar.new()
    -- SF Symbols 单色日历图标（比彩色 emoji 更贴合系统菜单栏风格），template 模式自动适配深/浅色
    local icon = hs.image.imageFromName("calendar")
    if icon then menubar:setIcon(icon:size({ w = 15, h = 15 }), true) end
    updateMenuTitle()
    menubar:setTooltip("日历：农历 / 节气 / 待办 (Ctrl+R)")
    menubar:setClickCallback(function()
        togglePanel()
    end)
    -- 每 5 分钟刷新一次标题（跨天自动更新），不重抢锁
    menuTimer = hs.timer.doEvery(300, updateMenuTitle)
    logger.i("日历面板模块已启动")
end

function M.stop()
    hidePanel()
    if menuTimer then menuTimer:stop(); menuTimer = nil end
    if menubar then menubar:delete(); menubar = nil end
    logger.i("日历面板模块已停止")
end

-- 全局快捷键唤起（Ctrl+R）
hs.hotkey.bind({"ctrl"}, "r", function()
    togglePanel()
end)

return M
