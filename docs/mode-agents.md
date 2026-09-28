# Mode Agents

## 背景

键盘固件固定 4 个 Mode 槽位（Mode 1–4）。早期版本把槽位硬编码为 Claude Code / Cursor / Codex / custom；
现在每个槽位可以由用户在 Studio 里指派任意已知 Agent，指派结果决定槽位名称、默认按键预设与内置 OLED 动图。

## Agent 目录

| id | 名称 | 按键风格 | 内置 OLED 素材 |
|----|------|----------|----------------|
| claude | Claude Code | 终端权限 Y/N | claude.gif |
| cursor | Cursor | Composer Accept/Reject | cursor.gif |
| codex | Codex | 审批 ↵ / Esc | codex.gif |
| kimi | Kimi Code | 终端权限 Y/N | kimi.gif |
| opencode | OpenCode | 审批 ↵ / Esc | opencode.gif |
| qoder | Qoder | 终端权限 Y/N | qoder.gif |
| custom | custom | 无预设 | 无 |

按键风格含义：

- **终端权限 Y/N**：Key2 发 ↵（菜单默认选中 Yes），Key3 跑固件原生宏 ↓↓⏎（Claude CLI 菜单光标在 Yes，选 No 需下移两次回车）。
- **审批 ↵ / Esc**：Key2 发 ↵ 确认，Key3 发 Esc 取消。
- **Composer Accept/Reject**：Key2 发 ↵、Key3 发 ⌫（与裸键一致；⌘ 组合由用户自行加修饰）。

## 存储

- 指派关系：UserDefaults `ahakey.mode.agents.v1`（`{slot: agentId}`），未指派时回退出厂映射
  （Mode 1→claude、Mode 2→cursor、Mode 3→codex、Mode 4→custom）。
- 槽位改名仍走 `ahakey.mode.customNames.v1`；指派会清掉与旧生效名相同的自定义名，让新 Agent 名显示出来。
- 草稿（按键/OLED/灯条）仍走 `ahakey.studio.draft.v1`。

## OLED 动图与写入设备

- `DefaultOLEDAssets.bundledFileName(for:)` 按指派解析内置素材；素材位于
  `ahakeyconfig-mac/Resources/DefaultOLED/`，由 build 脚本拷进 bundle。
- 指派带内置动图的 Agent 时，该槽位的 OLED 草稿会重置为该 Agent 的出厂默认
  （覆盖 nil、旧 bundle 图与用户旧上传），保证动画一定随指派写入。
- 写入时机：Studio 持有蓝牙（编辑配置态）时指派会立即上传；否则状态栏提示
  「进入编辑配置并保存后写入」。首次连接的 autoSync 只填充设备上空槽位（frameCount==0），
  不覆盖已有动画。
- 按键预设不会随指派自动覆盖：需要显式点菜单里的「重置为该 Agent 预设按键」。

## 新增 Agent / 生成 OLED 素材

1. 在 `AhaKeyStudioModels.swift` 的 `AhaKeyAgentPreset.all` 加一条目录项。
2. 生成 320×160 OLED GIF：

   ```bash
   swift ahakeyconfig-mac/scripts/generate_agent_gif.swift <品牌图.png> <输出.gif> [--label "显示名"]
   ```

   画布为黑底；品牌图居中（有 label 时位于上方），label 用白色 Menlo-Bold。
   品牌色背景（如 Claude 米色）需自行合成，参考 `claude.gif` 的生成方式
   （从官方图标提取星形 mask 再上色）。
3. 如需终端 Y/N 或 ↵/Esc 之外的按键风格，扩展 `AhaKeyAgentPreset.Style` 与
   `AhaKeyModeDraft.default(for:)` 的分支。

## 与 Hook 侧的关系

Mode 指派只影响本机 Studio 的按键/品牌；IDE 实时状态识别由 `ahakeyconfig-agent` 的
per-IDE hook handler（Claude/Cursor/Codex/Kimi）负责，与 Mode 无关。
Qoder / OpenCode 的实时状态接入尚未实现（Qoder 的 hook 与 Claude 兼容，可复用其 handler）。
