# VoiceLayer（MVP）

macOS 菜单栏语音输入工具：在任何应用里按住快捷键说话，松手后，整理成书面表达的文字会插入当前光标处。

## 构建

只需要 Command Line Tools（`xcode-select --install`），不需要完整 Xcode。

```bash
cd VoiceLayer
./build.sh
open build/VoiceLayer.app
```

如果你有固定的本地自签名证书，用它签名可以避免每次重新构建后系统权限失效：

```bash
SIGN_IDENTITY="你的证书名称" ./build.sh
```

## 首次使用

1. 启动后菜单栏出现麦克风图标，同时自动打开设置窗口。先在「服务商」下拉里选硅基流动或 OpenRouter，地址和模型名会自动填好，再填该服务商的 API Key。也可以选「自定义」接入其他 OpenAI 兼容服务。
2. 系统会依次请求两个权限：
   - **麦克风**：录音。
   - **辅助功能**：监听全局快捷键、把文字粘贴到输入框。
   授权后无需重启，应用每 2 秒自动重试，菜单栏图标会从警示变为正常。
3. 在任意输入框里，**按住 Control + 空格** 说话，松手，文字出现。

菜单栏的第一行始终显示当前状态；缺权限时点击它可直接跳转到对应的系统设置页。

## 快捷键

| 预设 | 说明 |
| --- | --- |
| Control + 空格（默认） | 会拦截该按键，避免同时触发系统的输入法切换 |
| Option + 空格 | 备选 |
| 右 Option | 单键，不拦截；按住期间如果又按了别的键，视为在打字，自动取消 |

录音中按 **Esc** 取消。按住不到 0.4 秒视为误触，不处理。

### 如果 Control + 空格 仍然切换了输入法

这说明系统快捷键先于我们处理了按键。两种办法：

- 在「系统设置 → 键盘 → 键盘快捷键 → 输入法」中，取消勾选「选择上一个输入法」。
- 或者在菜单栏「快捷键」里换成 Option + 空格 或右 Option。

## 调试开关

这些参数不启动界面，只运行对应的自测：

```bash
APP=build/VoiceLayer.app/Contents/MacOS/VoiceLayer

# 只测文本整理
VOICELAYER_API_KEY=sk-xxx $APP --polish "呃那个明天下午三点开会，不对，是四点"

# 用系统合成语音测完整的“识别 + 整理”链路
say -o /tmp/test.wav --data-format=LEI16@16000 "明天下午三点开会，不对，是四点"
VOICELAYER_API_KEY=sk-xxx $APP --selftest /tmp/test.wav

# 看悬浮条各状态
$APP --hud-demo

# 压测完整流程（识别加整理），看耗时分布和内存是否增长；最后一个参数是轮数
VOICELAYER_API_KEY=sk-xxx $APP --bench /tmp/test.wav 10

# 逐次计时对比某个识别模型的稳定性（不重试，单次超时 20 秒）
VOICELAYER_API_KEY=sk-xxx $APP --bench-asr /tmp/test.wav qwen/qwen3-asr-0.6b 6

# 临时换识别模型做测试，不会写入设置
VOICELAYER_ASR_MODEL=openai/whisper-large-v3-turbo $APP --selftest /tmp/test.wav
```

建议专门测试一句问句，例如 `--polish "今天天气怎么样"`，确认输出是整理后的问句，而不是答案。

## 排错

| 现象 | 处理 |
| --- | --- |
| 按快捷键没反应 | 菜单栏第一行看缺哪项权限；重新构建后权限可能失效，到「系统设置 → 隐私与安全性」删除旧条目再重新授权 |
| 提示 API Key 无效（401） | 检查 Key 和接口地址是否匹配同一家服务 |
| 识别或整理报 400/404 | 几乎都是模型名与服务商不匹配（例如把硅基流动的模型名用在 OpenRouter 上）。在设置里重新选一次「服务商」，会自动填入正确的模型名 |
| 文字没有插入，但在剪贴板里 | 目标应用不响应模拟粘贴，手动 Command + V |
| 能录音能识别，但从不自动粘贴 | 最常见原因：重新构建后系统里旧的辅助功能授权失效。菜单栏第一行会提示“辅助功能权限未生效”。打开「系统设置 → 隐私与安全性 → 辅助功能」，选中 VoiceLayer，点减号删除，再重新启动应用并授权 |
| 识别经常要等十几秒 | 看诊断日志里的识别耗时。OpenRouter 上的 `qwen3-asr-1.7b` 会随机卡死，请使用 `qwen3-asr-0.6b`（新版本首次启动会自动切换） |
| 开头几个字被吃掉 | 已知限制：每次按下才启动音频引擎，按下后稍等半秒再说 |
| 密码框里没反应 | 设计如此，密码输入框不插入 |

## 诊断日志

菜单栏「打开诊断日志」，或直接查看 `~/Library/Logs/VoiceLayer/voicelayer.log`。每次听写一行，包含各阶段耗时、插入结果、前台应用、权限状态和进程内存，不记录识别出的文字。反馈问题时附上最近几行即可。

## 目录

```
VoiceLayer/
├── Sources/
│   ├── main.swift            入口与调试开关
│   ├── AppDelegate.swift     菜单栏
│   ├── AppController.swift   主流程状态机
│   ├── HotkeyManager.swift   全局快捷键（CGEventTap）
│   ├── AudioRecorder.swift   录音，输出 16kHz WAV
│   ├── CloudClient.swift     云端识别与文本整理
│   ├── TextInserter.swift    插入文字（剪贴板 + 模拟粘贴）
│   ├── HUDPanel.swift        悬浮提示条
│   ├── Permissions.swift     权限检测与跳转
│   ├── SettingsWindow.swift  设置窗口
│   └── Config.swift          配置
├── Resources/Info.plist
├── build.sh
└── TASKS.md                  任务清单与验收状态
```

## 已知限制

仅 macOS 14 及以上，只测试 Apple Silicon；必须联网；单次录音最长 3 分钟；API Key 暂存在本机用户设置中，未加密。
