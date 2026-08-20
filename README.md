# OpenCode Widget

一个常驻桌面的圆形悬浮小挂件（macOS），实时显示 [OpenCode](https://opencode.ai) 当前正在做什么。

## 演示

https://github.com/user-attachments/assets/bae20744-84c2-4d5b-968e-06867cb97aba

## 特性

- **圆形头像挂件**：头像 + 状态环 + 实时动作提示
- **实时状态**：
  - 🟢 绿环呼吸 = 正在运行工具（如 `⚡ bash · git status`）
  - 🟠 橙环 = 正在思考 / 生成文本
  - ⚪ 灰环 = 空闲（`摸鱼中 🐟`）
- **只展示活跃会话**：最近 20 秒内有活动的会话才显示
- **自定义头像**：把照片存为 `avatar.png` 放同一目录，重启即可

## 环境要求

- macOS（需 Xcode CommandLineTools，即 `swiftc`）
- OpenCode 桌面端已安装并运行过（读取 `~/.local/share/opencode/opencode.db`）

## 构建 / 运行

```bash
./build.sh            # 编译 -> opencode-widget
./opencode-widget &   # 后台运行
```

停止：`pkill -f opencode-widget`

## 使用自定义头像

把图片命名为 `avatar.png`（或 `.jpg` / `.jpeg`）放到挂件二进制同目录，重启挂件即可自动加载。没放就用默认 🤖。

## 工作原理

OpenCode 把会话、消息、工具调用等全部存在本地 SQLite：
`~/.local/share/opencode/opencode.db`。

挂件以**只读**方式打开该库，读取最新的 `session` → 取该 session 最新的 `part` → 解析 `part.data.type` / `state.status`，判断会话状态：

| part 类型 | 状态 |
|---|---|
| `tool` + `status=running` | 🟢 运行中 |
| `reasoning` / `step-start` | 🟠 思考中 |
| `text` | 🟠 生成文本中 |
| `step-finish` / 其他 | ⚪ 空闲 |

**事件驱动刷新**：用 `DispatchSource` 监听 `opencode.db-wal` 的写入事件，数据库一变就刷新 UI，并保留 5 秒兜底定时器。（FSEvents 抓不到 SQLite WAL 的 mmap 写，所以用 VFS 文件事件源。）

## 可配置

- 数据库路径：环境变量 `OPENCODE_WIDGET_DB`（默认 `~/.local/share/opencode/opencode.db`）
- 活跃判定窗口：`main.swift` 里 `activeWindowMs`（默认 20 秒）

## License

[MIT](LICENSE)
