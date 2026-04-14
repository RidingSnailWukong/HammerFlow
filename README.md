# HammerFlow ⚡

> A productivity toolkit for macOS powered by [Hammerspoon](https://www.hammerspoon.org/)

开箱即用的 Hammerspoon 配置，涵盖桌面空间管理、音频设备管理、屏幕画笔、番茄钟等实用功能。

## ✨ 功能一览

| 模块 | 功能 | 快捷键 |
|------|------|--------|
| **桌面空间指示器** | 切换桌面时居中显示大号 overlay + 菜单栏实时状态 | — |
| **Option+数字切桌面** | 按 Option+1~9 快速切换到第 N 个桌面 | `Option+1~9` |
| **圆环启动器** | 环形应用快速启动面板 | `Cmd+Shift+Space` |
| **音频设备管理** | 按优先级自动切换输入/输出设备，支持手动锁定 | `Cmd+Shift+O/I/A` |
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

- `name`: 显示名称，也用于 `hs.application.launchOrFocus`
- `bundleID`: 应用的 Bundle ID（用于获取图标）
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

## 📁 项目结构

```
HammerFlow/
├── init.lua                        # 主入口
├── modules/
│   ├── circle_launcher.lua         # 圆环应用启动器
│   ├── audio_manager.lua           # 音频设备优先级管理
│   ├── pomodoro.lua                # 番茄钟
│   ├── screen_draw.lua             # 屏幕画笔
│   └── focus_alert.lua             # 专注度提醒
├── config/                         # 个人配置（git ignored）
│   ├── launcher_apps.json
│   ├── audio_devices.json
│   └── space_names.json
├── config.example/                 # 示例配置
│   ├── launcher_apps.json
│   ├── audio_devices.json
│   └── space_names.json
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
