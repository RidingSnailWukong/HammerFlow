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
  "output": { "priority": ["AirPods Pro", "MacBook Pro扬声器"] },
  "input":  { "priority": ["AirPods Pro", "MacBook Pro麦克风"] }
}
```

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
│   └── focus_alert.lua             # 专注度提醒
├── config/                         # 个人配置（git ignored）
│   ├── launcher_apps.json
│   ├── audio_devices.json
│   ├── space_names.json
│   ├── todos.json
│   └── snippets.json
├── config.example/                 # 示例配置
│   ├── launcher_apps.json
│   ├── audio_devices.json
│   ├── space_names.json
│   ├── todos.json
│   └── snippets.json
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
