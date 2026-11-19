# HammerFlow ⚡

> A productivity toolkit for macOS powered by [Hammerspoon](https://www.hammerspoon.org/)

开箱即用的 Hammerspoon 配置，涵盖桌面空间管理、音频设备管理、屏幕画笔、番茄钟等实用功能。

## ✨ 功能一览

| 模块 | 功能 | 快捷键 |
|------|------|--------|
| **桌面空间指示器** | 切换桌面时居中显示大号 overlay + 菜单栏实时状态 | — |
| **Option+数字切桌面** | 按 Option+1~9 快速切换到第 N 个桌面 | `Option+1~9` |
| **圆环启动器** | 环形应用快速启动面板，支持通过 Bundle ID 精确启动 | `Cmd+Shift+Space` |
| **音频设备管理** | 按优先级自动切换输入/输出设备，支持手动锁定 | `Cmd+Shift+O/I/A` |
| **快捷面板** | 常驻菜单栏的紧凑面板：TODO 管理（创建日期、新任务置顶、已完成折叠）+ 快速粘贴（分组管理、一键粘贴到当前输入框）；输入框已做中文输入法组合态保护，点击面板外部自动关闭 | `Cmd+Shift+J` / `Ctrl+Home` |
| **番茄钟** | 可配置的番茄工作法计时器 | 菜单栏点击 |
| **屏幕画笔** | 全屏绘图标注（自由画/矩形/圆形/椭圆/箭头 + 渐隐消失） | `Ctrl+Shift+D` |
| **专注度提醒** | 外部自动化调用的专注力提醒弹窗 | CLI 调用 |
| **刘海避让** | 自动检测刘海区域，避免面板/浮层被刘海遮挡 | `Ctrl+Cmd+N` 刷新<br>`Ctrl+Cmd+Shift+N` 可视化 |
| **Chrome 窗口循环** | 跨显示器循环切换 Chrome 窗口（系统 `Cmd+\`` 不支持跨屏/跨桌面） | `` Ctrl+` `` 下一个<br>`` Ctrl+Shift+` `` 上一个<br>`Ctrl+K` 呼出/隐藏 |
| **6 键宏键盘** | 按设备隔离，把外接宏键盘重映射为 macOS 快捷键、应用启动和桌面切换 | 外接设备物理键 |
| **访达就地唤出** | 把访达窗口带到当前屏幕/桌面（点 Dock 会跳到窗口所在桌面，导致无法拖放） | `Cmd+Alt+F` |
| **锁屏并关显示器** | 先锁屏再立即关闭显示器，离开工位一键搞定 | `Ctrl+Alt+L` |

## 📦 安装

### 前置条件

- macOS 12+
- [Hammerspoon](https://www.hammerspoon.org/) 已安装

### 步骤

```bash
# 1. 备份现有配置（如有）
mv ~/.hammerspoon ~/.hammerspoon.bak

# 2. 克隆项目
git clone https://github.com/yourname/HammerFlow.git ~/.hammerspoon

# 3. 复制示例配置并按需修改
cp -r ~/.hammerspoon/config.example ~/.hammerspoon/config

# 4. 编辑配置文件（详见下方）
vim ~/.hammerspoon/config/launcher_apps.json
vim ~/.hammerspoon/config/audio_devices.json
vim ~/.hammerspoon/config/space_names.json
vim ~/.hammerspoon/config/todos.json
vim ~/.hammerspoon/config/snippets.json
vim ~/.hammerspoon/config/macro_keypad.json

# 5. 启动/重载 Hammerspoon
```

## ⚙️ 配置说明

所有配置文件位于 `config/` 目录，示例见 `config.example/`。

### `launcher_apps.json` — 圆环启动器应用列表

```json
[
    { "name": "Google Chrome",  "bundleID": "com.google.Chrome" },
    { "name": "VS Code",       "bundleID": "com.microsoft.VSCode" },
    { "name": "Terminal",       "bundleID": "com.apple.Terminal" }
]
```

- `name`: 显示名称
- `bundleID`: 应用的 Bundle ID（用于获取图标；若存在会优先用 `hs.application.launchOrFocusByBundleID` 启动，比按名称匹配更可靠，避免部分应用改装/改名后启动失败）
- `cmd`（可选）: 自定义启动脚本路径，点击时执行该脚本而非打开 App

> 💡 查找 Bundle ID: `mdls -name kMDItemCFBundleIdentifier /Applications/YourApp.app`

### `audio_devices.json` — 音频设备优先级

```json
{
  "autoSwitch": true,
  "ignore": ["MiRemoteV"],
  "output": { "priority": ["AirPods Pro", "MacBook Pro扬声器"] },
  "input":  { "priority": ["AirPods Pro", "MacBook Pro麦克风"] }
}
```

`ignore` 用于隐藏不想在菜单里看到的设备（如虚拟声卡），按名称**模糊匹配、不区分大小写**：写 `"MiRemoteV"` 即可隐藏 `MiRemoteV 2ch`。被忽略的设备同时不会出现在输入、输出菜单和「按优先级/下一个设备」的切换序列中。

### `space_names.json` — 桌面名称别名

```json
{
    "你的显示器名称": {
        "1": "主桌面",
        "2": "浏览器",
        "3": "开发"
    }
}
```

> 💡 在 Hammerspoon 控制台执行 `hs.dumpSpaces()` 查看当前屏幕名称和桌面序号。

### `todos.json` — 快捷面板待办事项

```json
[
    { "id": 1, "text": "示例：点右上角 + 添加新任务", "done": false, "createdAt": "2026-01-01 09:00" },
    { "id": 2, "text": "示例：点圆点标记完成", "done": true, "createdAt": "2026-01-01 09:01" }
]
```

- `id`: 唯一标识（新增时自动分配为当前最大 id + 1）
- `text`: 待办内容
- `done`: 是否完成；未完成排在前面（新建的排最上面），已完成默认折叠收纳在底部
- `createdAt`: 创建时间 `YYYY-MM-DD HH:MM`，面板中只显示 `MM-DD`，鼠标悬停显示完整时间；缺失该字段的历史数据不受影响，仅不显示日期

> 该文件由快捷面板程序读写，一般不需要手动编辑；每次弹出面板都会重新读取，手动改完保存后下次打开即可生效（面板打开状态下修改文件不会实时刷新）。

### `snippets.json` — 快捷面板快速粘贴

```json
[
    { "label": "邮箱", "text": "your-email@example.com", "group": "常用" },
    { "label": "手机号", "text": "13800000000", "group": "常用" }
]
```

- `label`: 按钮上显示的名称
- `text`: 点击后写入剪贴板并粘贴到当前输入框的实际内容
- `group`: 所属分组，面板按分组分块展示；分组显示顺序按文件中该分组第一次出现的位置决定。也可以直接在面板"快速粘贴"标题旁的 ＋ 里新增，填入新分组名即可自动创建分组

### `macro_keypad.json` — 6 键 USB 宏键盘

当前设备实测为 VID `0x413D` / PID `0x553A`，Hammerspoon `keyboardType=40`；主键盘为 `keyboardType=91`，因此可以只拦截宏键盘，不影响主键盘上的同名组合键。

```json
{
  "enabled": true,
  "deviceType": 40,
  "strictModifiers": true,
  "doubleClickInterval": 0.4,
  "bindings": {
    "8": {
      "sourceMods": ["ctrl"],
      "label": "复制",
      "action": { "type": "keystroke", "mods": ["cmd"], "key": "c" }
    },
    "9": {
      "sourceMods": ["ctrl"],
      "immediateSingle": true,
      "doubleClickInterval": 0.4,
      "pendingHint": "0.4 秒内再按一次：打开微信",
      "singleAction": { "type": "launchApp", "bundleID": "com.tencent.WeWorkMac" },
      "doubleAction": { "type": "launchApp", "bundleID": "com.tencent.xinWeChat" }
    }
  }
}
```

支持以下动作：

- `keystroke`：发送 macOS 组合键，如 `Cmd+C`、`Cmd+V`
- `launchApp`：按 Bundle ID 启动或聚焦 App
- `toggleApp`：App 在前台时隐藏，否则启动或聚焦
- `cycleAppMenuWindow`：通过指定 App 的“窗口”菜单循环切换窗口，可覆盖其他 macOS 桌面中的窗口；按菜单项**序号**切换，多个窗口标题相同也能区分；App 不在前台时先激活再操作
- `switchDesktop`：按 `direction: "left"` 或 `"right"` 切换到相邻桌面，边界处不循环（切换后校验是否生效，未生效自动重试最多 3 次）
- 单击/双击：默认延迟单击；设置 `immediateSingle=true` 后首次立即执行，窗口内再次按下执行双击动作

模块精确匹配 `deviceType + keyCode + sourceMods`，吞掉宏键盘原始 Ctrl/Fn 事件，再注入目标事件；合成事件带防递归标记。配置保存后自动热重载。

> **桌面切换实现（macOS 27 走 AppleEvent 通道）**：`hs.spaces.gotoSpace` 依赖调度中心 AX 树中的 `mc.display` / `mc.spaces` 节点，这两个节点在 macOS 27 上已不存在，调用只会返回 `no display with specified id found`；合成的 CGEvent 也无法触发系统「切换桌面」快捷键。因此 `switchDesktop` 改为经 System Events 发送 `key code 123/124`（←/→）+ `control`，再轮询目标屏的活动桌面确认，未生效自动重试。

### `finder_here.json` — 访达就地唤出

点 Dock 上的访达图标时，macOS 会切到访达窗口所在的桌面，导致没法在当前桌面拖文件。本模块把访达带到**当前屏幕**：

1. 当前屏幕已有访达窗口 → 直接激活
2. 有窗口但都在另一块屏 → 把最前面那个搬过来
3. 完全没有窗口 → 新建窗口后搬到当前屏幕

```json
{
  "enabled": true,
  "hotkey": { "mods": ["cmd", "alt"], "key": "f" },
  "defaultPath": null,
  "frame": null,
  "hintAllDesktops": true,
  "alertOnFail": true
}
```

| 字段 | 说明 |
|------|------|
| `hotkey` | 唤出快捷键 |
| `defaultPath` | 新建窗口时的目录，留空用访达默认位置 |
| `frame` | 可选，`{x,y,w,h}` 为相对当前屏幕的比例，用于把窗口固定在右侧、与目标 App 并排拖放 |
| `hintAllDesktops` | 窗口未覆盖该屏幕全部桌面时提示开启「所有桌面」 |

实现约束（macOS 26 实测）：

- `hs.spaces.moveWindowToSpace` 已失效（返回 `true` 但窗口不动），因此改用 `hs.window:moveToScreen()` 把窗口带到目标屏幕的当前桌面
- 对访达调用 `hs.window:focus()` / `:raise()` 会把焦点弹回上一个 App，只能用 `app:activate()`，提升具体窗口走 AppleScript `set index`
- `hs.window` 没有窗口层级接口，**无法让访达置顶**，需借助第三方工具

建议同时在 Dock 右键访达 → 选项 → **所有桌面**，这样窗口在该屏幕的每个桌面都可见，点 Dock 也不会跳桌面。

## 📁 项目结构

```
HammerFlow/
├── init.lua                        # 主入口
├── modules/
│   ├── circle_launcher.lua         # 圆环应用启动器
│   ├── audio_manager.lua           # 音频设备优先级管理
│   ├── quick_panel.lua             # 快捷面板（TODO + 快速粘贴）
│   ├── pomodoro.lua                # 番茄钟
│   ├── screen_draw.lua             # 屏幕画笔
│   ├── focus_alert.lua             # 专注度提醒
│   ├── notch_avoidance.lua         # 刘海避让
│   ├── macro_keypad.lua            # 6 键 USB 宏键盘映射
│   ├── finder_here.lua             # 访达就地唤出（带到当前屏幕/桌面）
│   └── lock_screen.lua             # 锁屏并关闭显示器（Ctrl+Alt+L）
├── config/                         # 个人配置（git ignored）
│   ├── launcher_apps.json
│   ├── audio_devices.json
│   ├── space_names.json
│   ├── todos.json
│   ├── snippets.json
│   ├── macro_keypad.json
│   └── finder_here.json
├── config.example/                 # 示例配置
│   ├── launcher_apps.json
│   ├── audio_devices.json
│   ├── space_names.json
│   ├── todos.json
│   ├── snippets.json
│   ├── macro_keypad.json
│   └── finder_here.json
├── LICENSE
└── README.md
```

## 🔧 调试

在 Hammerspoon 控制台中可用的调试命令：

```lua
-- 查看所有桌面信息
hs.dumpSpaces()

-- 查看音频设备状态
hs.dumpAudioDevices()

-- 触发专注提醒
focusAlert({ title="测试", tasks={"任务1"}, urgent=false })
```

## 📄 License

[MIT](LICENSE)
