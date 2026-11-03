# Arcs Mini Arcade · 小聆掌机游戏厅

在 **聆思 Arcs Mini3**（LS2663 + CH32V003 扩展板）的 240×240 圆屏上，用 Lua 写的一套可玩的小游戏与概率教学实验，外加一层让"声音、画面、按键"真正好用的固件增强。

12 个画面、26 组程序化乐谱、一套能在 PC 上跑的无头仿真器。

> A Lua mini-game collection for the ListenAI Arcs Mini3 handheld (240×240 round LCD), with firmware patches that add a 4-voice synth binding, `app.exit()`, and on-device screen/key/glyph/audio inspection commands.

---

## 效果

<table>
  <tr>
    <td><img src="docs/images/snake.jpg" width="230" alt="贪吃蛇"></td>
    <td><img src="docs/images/dice.jpg" width="230" alt="掷骰子"></td>
    <td><img src="docs/images/coin.jpg" width="230" alt="掷硬币"></td>
  </tr>
  <tr>
    <td align="center">贪吃蛇（像素级连续移动）</td>
    <td align="center">掷骰子（抖动 + 滚动乐谱）</td>
    <td align="center">掷硬币（频率统计）</td>
  </tr>
</table>

> 图为原型机：白色外壳 + 3D 打印扩展板（方向键、功能键、旋钮），杜邦线接到主控排针。

---

## 目录

- [效果](#效果)
- [它能做什么](#它能做什么)
- [为什么需要这些固件补丁](#为什么需要这些固件补丁)
- [硬件与运行环境](#硬件与运行环境)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [开发与调试](#开发与调试)
- [音效是怎么做的](#音效是怎么做的)
- [已知限制](#已知限制)
- [许可证与致谢](#许可证与致谢)

---

## 它能做什么

小应用 `arcade` 启动后是一个游戏大厅，用方向键选择、`→` 进入，板载侧键单击返回上级，在主菜单按侧键退出。

```
游戏大厅
├── 贪吃蛇
├── 概率实验室
│   ├── 掷骰子        单颗 d6，滚动动画 + 落点统计
│   ├── 掷硬币        正反累计、大数定律可视化
│   ├── 高尔顿板      小球下落、撞钉、入槽形成直方图
│   ├── 频率收敛      理论概率 vs 实测频率曲线
│   ├── 蒙提霍尔      三扇门，可换门；跑一批实验看换门胜率
│   └── 二项分布      n/p 可调，柱状图与理论值对照
├── 平衡挑战          旋钮反向补偿，杆越斜倒得越快
├── 打靶              5 发，每发准星随机落点，旋钮微调
└── 2048              4×4 合并，达成 2048 有专属旋律
```

| 场景 | 操作 | 关键实现 |
|---|---|---|
| 贪吃蛇 | ↑↓←→ 转向 | 像素级连续移动（不是整格跳），转向当帧生效；体节按轨迹等距铺开 |
| 概率实验室 | ↑↓ 选项，→ 进入 | 6 个统计/概率小实验共用一套菜单与返回栈 |
| 平衡挑战 | 旋钮 | 按**秒**积分（`acc = off*300 + 噪声1100`），不操作约 20 秒落杆；分数 = 存活 0.1 秒 |
| 打靶 | 旋钮微调 + → 发射 | 每发准星在 44..196 随机重置，旋钮做**相对**微调，落点带 ±11px 抖动；10/8/6/4/2 环 |
| 2048 | ↑↓←→ 滑动 | 44px 格 + 4px 间距，按合并值升调的音效，无路可走才判负 |

另有四个独立小应用，可作为最小示例阅读：

- `apps/dice.lua` — 独立掷骰子，抖动动画 + 830ms 滚动乐谱
- `apps/coin.lua` — 掷硬币，正反累计
- `apps/galton.lua` — 高尔顿板
- `apps/hwtest.lua` — 硬件自检：按键电平、旋钮 ADC、屏幕色块

## 为什么需要这些固件补丁

原厂固件能跑 Lua，但做游戏时会撞到四面墙。补丁 `patches/0001-miniapp-arcade-runtime.patch` 逐个拆掉：

| 问题 | 现象 | 补丁做法 |
|---|---|---|
| 只有单音 `buzzer.play(hz, ms)` | 每次调用都**重开一条音频流**；60ms 内连发两次会互相打断，两条都听不见 | 暴露 `synth.play(notes)`：4 声部、方波/三角/噪声、按毫秒排时间轴，一次提交整段 |
| 小应用无法主动退出 | 只能靠外部命令停掉 | 绑定 `app.exit()`，投递 `MINIAPP_EVENT_EXIT`（不在回调里拆 VM） |
| 屏幕内容看不见 | 只能靠肉眼判断渲染对不对 | `miniapp screen` 把最近一帧结构化打印出来 |
| 按键/字形没法验证 | 只能猜引脚或字体有没有 | `miniapp key <dir> <0\|1>` 注入按键、`miniapp glyph <hex>` 查 cmap |
| 音频是否真的播完 | Lua 没报错 ≠ 出声 | `miniapp audio` 输出播完段数、音符数、最近一段时长、是否正在播 |
| 一帧文字上限 16 | 2048 需要 16 格数字，加上分数就超 | `MINIAPP_MAX_TEXTS` 16 → 32 |
| Lua 堆偏小 | 大源码 + 双 VM 回滚时紧张 | `MINIAPP_HEAP_MAX_BYTES` 默认 384KB → 512KB |

补丁共 10 个文件、约 1200 行，全部围绕 `apps/arcs-mini/miniapp/`、`apps/arcs-mini/mcp-tools/` 和 `src/shell/cmd/`。

## 硬件与运行环境

| 项 | 值 |
|---|---|
| 主控 | 聆思 LS2663（arcs_mini3 板型） |
| 协处理器 | CH32V003，经 I2C 桥提供 `exadc` / `exgpiod` |
| 屏幕 | 240×240 圆屏，Lua 侧 `app.width/height = 240` |
| 方向键 | PA0=↑ PA1=← PB7=↓ PB6=→（高电平有效） |
| 侧键 | `on_button_click("function")` |
| 旋钮 | PD4 → `exadc` ch7，0..1023 |
| 字体 | `lv_font_chinese_16.bin`，1bpp，cmap 含 U+2190..U+2199 箭头 |
| 基础固件 | 聆思 arc SDK `mini-v3.1.0` 分支 |
| Lua 方言 | 精简 Lua：无 `pcall`、无 `string.format` 全量、`screen.*` 只收整数 |

## 仓库结构

```
apps/        可直接装进设备的 Lua 小应用
tools/       gen_builtin.py（Lua → C 字节数组）、sim_*.cjs（PC 端无头仿真）
patches/     相对官方 mini-v3.1.0 的固件补丁
docs/        开发记录、固件改造说明、踩坑记录
```

## 快速开始

### 路线 A：只装 Lua 应用（不改固件）

需要设备上已有带 `synth.play` 和 `app.exit` 的固件（即先走路线 B）。把 `apps/arcade.lua` 推到设备或通过 `ling` 部署，然后：

```sh
adb shell miniapp run arcade
```

### 路线 B：打补丁 + 重编固件

```sh
# 1. 从聆思开发者平台获取 arc SDK（arcs_mini 仓库），检出 mini-v3.1.0
git clone <SDK 仓库地址> arcs_mini && cd arcs_mini
git checkout mini-v3.1.0

# 2. 打补丁（在本仓库根目录之外的任意位置执行均可）
git apply <本仓库>/patches/0001-miniapp-arcade-runtime.patch

# 3. 把 Lua 源码生成 C 字节数组，直接写进 SDK 的 mcp-tools/
#    在本仓库根目录执行：
python tools/gen_builtin.py --src apps --out ../arcs_mini/apps/arcs-mini/mcp-tools

# 4. 编译
ninja -C build

# 5. 烧录（进恢复模式后推 bin 到 NAND 起始偏移）
adb shell recovery
adb -s BOOT-<serial> push build/arcs-mini.bin /RAW/NAND/600000
adb -s BOOT-<serial> shell reboot hard
```

> `gen_builtin.py` 默认输出到 `../apps/arcs-mini/mcp-tools`，可用 `--out` 指定。补丁里的 `mcp_tool_miniapp_builtin.c` 会 `#include` 这些生成的头文件，**必须先跑第 3 步再编译**。

## 开发与调试

### PC 端无头仿真

改 Lua 最痛的是"烧进去才发现崩了"。`tools/sim_arcade.cjs` 用 fengari 跑真实源码，假屏幕**严格复刻 C 层校验**——整数、`w/h>=1`、矩形不越界、`text` 的 y≤224、一帧 32 条文字上限：

```sh
cd tools && npm install fengari
node sim_arcade.cjs ../apps/arcade.lua
node sim_dice.cjs  ../apps/dice.lua
```

它对 12 个页面做「旋钮全量程 + 随机按键 80 帧」压力测试。这一层直接抓到过两个真机崩溃：平衡挑战的浮点参数、打靶弹孔的 `h.x-2`。

### 设备端自检命令

```
miniapp list                列出已注册小应用
miniapp run <id>            启动
miniapp status              帧数、掉帧、最大帧耗时、last_error
miniapp key <dir> <0|1>     注入按键（up/down/left/right）
miniapp btn                 模拟侧键单击
miniapp screen              打印最近一帧的全部图形与文字
miniapp glyph <hex...>      查字形位图与步进（如 2190 2191 2192 2193）
miniapp audio               合成器遥测：播完段数/音符数/最近时长/是否在播
```

`miniapp screen` + `miniapp audio` 的组合，让"画面对不对、声音出没出"都能在 headless 的 ADB 会话里验证，不用盯着屏幕。

## 音效是怎么做的

`apps/arcade.lua` 顶部有一个小音效引擎：把每个音效写成音符表 `N(delay_ms, hz, dur_ms, voice, wave, volume)`，`synth.play` 一次提交整段，避免多次开流互相打断。

```lua
gun = {                       -- 枪声：噪声爆音 + 低频冲击 + 余震
  N(0,   4300,  30, 1, "noise",   70),
  N(0,    270,  60, 2, "square",  60),
  N(30,  1500,  50, 1, "noise",   45),
  N(70,   105, 110, 3, "square",  50),
}
```

- **骰子滚动**是一段 830ms 的乐谱：13 下撞击、间隔逐渐拉长（越滚越慢），配 3 下低频闷响；落定再单独一声。
- **枪声 + 命中提示**用 `join_score` 拼成一条（枪响后 170ms 接琶音），分两次提交会互相掐断。
- 2048 的合并音按块值升调：2/4/8/16/32 各一个音，滑动的噪声很轻，连滑不吵。

共 26 组乐谱（外加 4 个拼接变体，实际可播 30 种）：菜单移动/确认/返回/拒绝、吃与死亡、落杆、十环/八环/四环/脱靶、硬币、放球/撞钉/入槽、滑动/合并/达成、蒙提霍尔输赢。

## 已知限制

- **源码上限 64KB**：`arcade.lua` 已 53.8KB，再加内容要留意；文字一帧 32 条也接近上限。
- **旋钮是绝对值不是编码器**：没有"转了多少格"的概念，所有旋钮交互都要自己做基线与相对量。
- **无 `pcall`**：设备端 Lua 不给 `pcall`，任何可能越界的参数都得在调用前夹取，否则直接抛错中断安装。
- **仿真器不是真机**：屏幕校验逻辑照抄 C，但时序、字体渲染、音频输出仍需真机确认。
- `miniapp` 系列调试命令会常驻固件，发布版建议用 Kconfig 裁掉。

## 许可证与致谢

- 本仓库自有代码（`apps/`、`tools/`、`docs/`）以 MIT 发布，见 [LICENSE](LICENSE)。
- `patches/` 是对**聆思官方 arc SDK** 的修改。官方 SDK 未附带开源许可证文件，因此本仓库只分发 diff，不 redistribute 任何官方源码；使用补丁前请自行获取 SDK 并遵守其条款。
- 感谢聆思（ListenAI）提供硬件、SDK 与 `ling` 工具链。
