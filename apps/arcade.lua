-- arcade.lua 游戏大厅 v2
-- 入口：语音「打开游戏大厅」→ play_arcade
-- 主菜单：贪吃蛇 / 概率实验室 / 平衡挑战 / 打靶 / 2048
-- 概率实验室二级菜单：掷骰子 / 掷硬币 / 高尔顿板 / 频率收敛 / 蒙提霍尔 / 二项分布
-- 返回：任意页面单击板载侧键（功能键）= 返回上一级；主菜单上 = 退出小应用。
--       每个页面右下/右上角都印了「侧键 返回」提示。
--
-- 方向键（gpio.read 轮询）：↑=PB7 ↓=PA0 ←=PB6 →=PA1，高电平有效
--       注：早期版本把四根线接反了（按上出下、按左出右），2026-11 按实测改正
-- 屏幕上统一用 ↑↓←→ 显示（lv_font_chinese_16 含 U+2190..2199 字形）
-- 旋钮：adc.read(7) 输出 0~1023（PD4 = CH32V003 ADC ch7）
--
-- 硬约束：屏幕 240x240；screen.text y∈[0,224]；一帧 ≤32 段文字、≤256 个图形；
--         on_tick(dt) 的 dt 单位毫秒。

local W, H = 240, 240

-- 绘制兜底：C 侧所有 screen.* 参数都是 luaL_checkinteger，浮点数哪怕等于
-- 120.0 也会报 “number has no integer representation” 并中断脚本（平衡挑战
-- 卡在 180.0 的坐标上就是这么崩的）。所有入口统一先取整。
local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
local function iv(v)
    return math.floor(v + 0.5)
end

-- rect 额外要求 1<=w,h 且必须整块在屏内；柱状图在极端参数下会算出 0 宽或越界，
-- 这里静默丢弃（少画一根柱子，而不是整个游戏挂掉）。
local _rect = screen.rect
screen.rect = function(x, y, w, h, c)
    if not w or not h then return end
    x, y, w, h = iv(x), iv(y), iv(w), iv(h)
    if w < 1 or h < 1 then return end
    if x < 0 or y < 0 then return end
    if x + w > W or y + h > H then return end
    _rect(x, y, w, h, c)
end

local _circle = screen.circle
screen.circle = function(x, y, r, c, o)
    if not r or r < 1 then return end
    _circle(iv(x), iv(y), clamp(iv(r), 1, H), c, o)
end

local _line = screen.line
screen.line = function(x1, y1, x2, y2, c, o)
    _line(iv(x1), iv(y1), iv(x2), iv(y2), c, o)
end

local _text = screen.text
screen.text = function(s, x, y, c, o)
    _text(s, clamp(iv(x), 0, W - 1), clamp(iv(y), 0, H - 16), c, o)
end

-- ================= 颜色 =================
local TITLE  = 0xF4C64A
local TEXT   = 0xE8ECF3
local DIM    = 0x9AA6B8
local WHITE  = 0xF7F8FA
local GREEN  = 0x2ECC71
local DGREEN = 0x1E8449
local RED    = 0xFF6B5E
local BLUE   = 0x4A90E2
local YELLOW = 0xF4C64A
local PURPLE = 0xBB86FC
local GRAY   = 0x8B98AB
local BG     = 0x172134

local BG_GRAD = { 0x23324F, 0x1F2C46, 0x1B263D, 0x172134, 0x131C2B, 0x0F1722 }

-- ================= 通用提示 =================
-- 返回方式统一为「单击板载侧键」。每个页面都要印出来，否则用户不知道能退。
-- 文字宽 68px（侧键 2 字 + 空格 + 返回 2 字），所以 x=164 时右边界 232。
local BACK_LABEL = "侧键 返回"
local function hint_back(x, y)
    screen.text(BACK_LABEL, x or 164, y or 222, DIM)
end

-- ================= 随机数（LCG） =================
local rng = 1
local function rnd()
    rng = (rng * 16807) % 2147483647
    if rng <= 0 then rng = 1 end
    return rng / 2147483647
end
local function rnd_int(n)
    return math.floor(rnd() * n) + 1
end

-- ================= 音效 =================
-- 两层：
--   buzzer.play(hz, ms) 只能发单音方波（就是那个“嘟”），而且每次都要重新开一条
--     音频流。60ms 内连发两次，后一条会打断前一条的启动过程，结果两下都听不见
--     —— 骰子连击没声音就是这么来的。
--   synth.play(notes) 一次提交整段乐谱：4 个声部、方波/三角/噪声、毫秒时间轴，
--     固件线程连续渲染，所以枪声、连击、叮当可以一次播完，不会自己打断自己。
-- 参数是 C 侧 luaL_checkinteger 严格校验的，越界/浮点直接抛错：
--   at 0..60000, ms 20..3000, hz 50..5000, voice 1..4, volume 0..100,
--   wave = "square"|"triangle"|"noise"；同一 voice 上音符不能重叠。
local has_synth = (synth ~= nil and synth.play ~= nil)

local function beep(hz, ms)
    if buzzer == nil then return end
    if ms < 20 then ms = 20 elseif ms > 3000 then ms = 3000 end
    if hz < 100 then hz = 100 elseif hz > 5000 then hz = 5000 end
    if pcall then
        pcall(buzzer.play, hz, ms)
    else
        buzzer.play(hz, ms)
    end
end

-- 音符简写：N(起始毫秒, 频率, 时长, 声部, 波形, 音量)
local function N(at, hz, ms, voice, wave, vol)
    return { at = at, hz = hz, ms = ms, voice = voice, wave = wave, volume = vol }
end

local S = {
    -- ── 菜单 ──
    move   = { N(0, 1320, 22, 1, "triangle", 35) },
    select = { N(0, 700, 45, 1, "triangle", 65), N(52, 1050, 80, 1, "triangle", 65) },
    back   = { N(0, 950, 45, 1, "triangle", 60), N(52, 620, 80, 1, "triangle", 60) },
    deny   = { N(0, 240, 55, 1, "square", 45), N(62, 180, 90, 1, "square", 45) },

    -- ── 打靶：枪声 = 高频爆音 + 低频冲击 + 噪声尾音（约 150ms）──
    gun = {
        N(0, 4300, 28, 1, "noise", 100),
        N(24, 1500, 80, 3, "noise", 55),
        N(0, 270, 50, 2, "square", 95),
        N(52, 105, 90, 2, "triangle", 70),
    },
    -- 命中反馈接在枪声熄灭之后（shift 170ms），两个声音不会互相掐断
    hit10 = {
        N(0, 784, 45, 1, "triangle", 80), N(50, 988, 45, 1, "triangle", 80),
        N(100, 1319, 90, 1, "triangle", 80), N(100, 659, 90, 2, "triangle", 40),
        N(0, 1568, 40, 3, "triangle", 45),
    },
    hit8 = { N(0, 784, 50, 1, "triangle", 75), N(56, 1047, 90, 1, "triangle", 75) },
    hit4 = { N(0, 523, 90, 1, "triangle", 70) },
    miss = { N(0, 300, 60, 1, "square", 55), N(68, 190, 110, 1, "square", 55) },

    -- ── 骰子：整段滚动一次提交（13 下撞击、间隔逐渐拉长 = 越滚越慢）──
    dice_roll = {
        N(0, 2400, 20, 1, "noise", 80), N(58, 2100, 20, 1, "noise", 76),
        N(112, 2600, 20, 1, "noise", 80), N(162, 2000, 20, 1, "noise", 74),
        N(212, 2500, 20, 1, "noise", 80), N(266, 2150, 20, 1, "noise", 74),
        N(326, 2450, 20, 1, "noise", 78), N(392, 2050, 20, 1, "noise", 72),
        N(464, 2500, 20, 1, "noise", 76), N(542, 2100, 20, 1, "noise", 70),
        N(626, 2400, 20, 1, "noise", 74), N(716, 2000, 20, 1, "noise", 68),
        N(810, 2500, 20, 1, "noise", 72),
        N(0, 150, 70, 2, "square", 40), N(300, 130, 80, 2, "square", 35),
        N(620, 120, 90, 2, "square", 30),
    },
    dice_land = {
        N(0, 880, 90, 1, "triangle", 80), N(96, 1175, 130, 1, "triangle", 80),
        N(0, 440, 90, 2, "triangle", 45),
    },

    -- ── 硬币：三下旋转的“叮”，接落定双音 ──
    coin = {
        N(0, 2637, 25, 1, "triangle", 55), N(30, 2349, 25, 1, "triangle", 50),
        N(60, 2637, 25, 1, "triangle", 45), N(96, 1760, 70, 1, "triangle", 55),
        N(96, 880, 70, 2, "triangle", 30),
    },

    -- ── 高尔顿板 ──
    drop      = { N(0, 700, 40, 1, "triangle", 55), N(48, 980, 50, 1, "triangle", 55) },
    pin_tick  = { N(0, 1500, 20, 1, "triangle", 40) },
    bin_land  = { N(0, 660, 70, 1, "triangle", 70), N(74, 990, 90, 1, "triangle", 70) },

    -- ── 贪吃蛇 ──
    eat = { N(0, 880, 30, 1, "square", 55), N(34, 1320, 45, 1, "square", 55) },
    die = {
        N(0, 420, 90, 1, "square", 70), N(94, 320, 90, 1, "square", 70),
        N(188, 210, 160, 1, "square", 70), N(0, 1200, 70, 2, "noise", 45),
    },

    -- ── 平衡 ──
    fail = {
        N(0, 300, 120, 1, "square", 65), N(130, 210, 180, 1, "square", 65),
        N(0, 900, 60, 2, "noise", 40),
    },
    warn = { N(0, 1400, 40, 1, "triangle", 60), N(48, 1400, 40, 1, "triangle", 60) },

    -- ── 2048 ──
    slide   = { N(0, 900, 25, 1, "noise", 42) },
    merge2  = { N(0, 660, 45, 1, "triangle", 65) },
    merge3  = { N(0, 784, 45, 1, "triangle", 68) },
    merge4  = { N(0, 988, 50, 1, "triangle", 70) },
    merge5  = { N(0, 1175, 55, 1, "triangle", 72) },
    merge6  = { N(0, 1568, 60, 1, "triangle", 75) },
    win = {
        N(0, 784, 70, 1, "triangle", 75), N(76, 988, 70, 1, "triangle", 78),
        N(152, 1175, 70, 1, "triangle", 80), N(228, 1568, 200, 1, "triangle", 82),
        N(228, 784, 200, 2, "triangle", 45),
    },
}

-- 把两段乐谱拼成一段（第二段整体后移 shift 毫秒）。
-- 用于“枪声 + 命中音”：分成两次 synth.play 会互相打断，合成一条才连得上。
local function join_score(a, b, shift)
    local out = {}
    for i = 1, #a do
        local n = a[i]
        out[#out + 1] = N(n.at, n.hz, n.ms, n.voice, n.wave, n.volume)
    end
    for i = 1, #b do
        local n = b[i]
        out[#out + 1] = N(n.at + shift, n.hz, n.ms, n.voice, n.wave, n.volume)
    end
    return out
end

S.gun_hit10 = join_score(S.gun, S.hit10, 170)
S.gun_hit8  = join_score(S.gun, S.hit8, 170)
S.gun_hit4  = join_score(S.gun, S.hit4, 170)
S.gun_miss  = join_score(S.gun, S.miss, 170)

-- 播放节流：固件音频队列只有 4 格，满了直接丢；同一声效太密也没意义。
local now_ms = 0
local sfx_last = {}
local intro_until = 0            -- 小白在讲话时先不发音效（会盖住人声）
local function play_sfx(name, gap)
    if intro_until > now_ms then return end
    local notes = S[name]
    if not notes then return end
    gap = gap or 60
    local last = sfx_last[name]
    if last and (now_ms - last) < gap then return end
    sfx_last[name] = now_ms
    if has_synth then
        if pcall then
            if pcall(synth.play, notes) then return end
        else
            synth.play(notes)
            return
        end
    end
    beep(notes[1].hz, notes[1].ms)   -- 没有合成器时退回单音
end

-- ================= 小白讲玩法（TTS）=================
-- 运行时暴露 tts.speak(text)（见 docs/miniapp.md「文本播报」）：异步、不阻塞，
-- 结果走全局回调 on_tts_result(id, {status=...})，失败带 error.code。
-- 所以进游戏的瞬间念一段说明，手照样能按；播报期间把合成器音效静音，
-- 免得“嘟嘟”声盖住人声，讲完自动恢复（intro_until 是兜底计时）。
-- 文本上限 512 字节（中文 3 字节/字），下面每段都远低于这个数。
local INTRO = {
    snake    = "贪吃蛇。方向键转向，吃红点会变长，撞墙或撞到自己就结束。",
    balance  = "平衡挑战。小球会自己往两边跑，转旋钮把它掰回来，越快越难。",
    target   = "打靶。旋钮微调准星，按右键开枪，越靠靶心环数越高。",
    g2048    = "二零四八。方向键滑动方块，相同数字合并，凑出二零四八。",
    dice     = "掷骰子。按右键掷一颗，看每个点数出现的次数。",
    coin     = "掷硬币。按右键抛一次，统计正面和反面的次数。",
    galton   = "高尔顿板。小球每层随机往左或往右，落下来堆成钟形曲线。",
    converge = "频率收敛。一直投硬币，正面出现的频率会稳定在百分之五十。",
    monty    = "蒙提霍尔。三扇门后一车两羊。你先选一扇，主持人开一扇羊门，再决定换不换。",
    binom    = "二项分布。旋钮调成功率，左右键改试验次数，看柱子怎么变。",
    buffon   = "蒲丰投针。针随机落在平行线上，相交的比例能算出圆周率。上键投一根，下键投十根，右键看圆周率怎么逼近真值。屏幕上只画最近一批针，总数照常累加。",
}

local intro_id = 0
local intro_pending = nil      -- 待念的场景名（连翻几页时只念最后一段）
local intro_busy = false       -- 上一条请求还没交付结果
local intro_deadline = 0
local intro_timeouts = 0       -- 连续几次没回包（>=2 就本次运行不再念）

local intro_flush

local function intro_speak(name)
    local text = INTRO[name]
    if not text then return nil end
    if pcall then
        local ok, id = pcall(tts.speak, text)
        if ok then return id end
        return nil
    end
    return tts.speak(text)
end

-- 运行时同时只允许一条播报（再多会直接抛 "too many pending TTS results"，
-- 设备上的精简 Lua 没有 pcall 兜不住），所以这里自己排队：
-- 新的一段进来先 cancel 旧的，等旧的结果回调交付后再念新的。
local function intro_say(name)
    if not tts or not tts.speak then return end
    if not INTRO[name] then
        -- 回到菜单：这一段不用再念了
        intro_pending = nil
        if intro_busy and intro_id ~= 0 and tts.cancel then
            if pcall then pcall(tts.cancel, intro_id) else tts.cancel(intro_id) end
        end
        return
    end
    intro_pending = name
    if intro_busy then
        if intro_id ~= 0 and tts.cancel then
            if pcall then pcall(tts.cancel, intro_id) else tts.cancel(intro_id) end
        end
    else
        intro_flush()
    end
end

intro_flush = function()
    if intro_busy or intro_pending == nil then return end
    -- 这台机器的语音服务连续两次没回包：本次运行不再念，
    -- 免得每进一个游戏都要白等 20 秒静音
    if intro_timeouts >= 2 then
        intro_pending = nil
        return
    end
    local name = intro_pending
    intro_pending = nil
    local id = intro_speak(name)
    if not id then return end
    intro_id = id
    intro_busy = true
    intro_deadline = now_ms + 20000      -- 回调万一丢了，20s 后自己放开
    -- 240ms/字 是这台机器上的语速，加 700ms 收尾；正常会被回调提前清掉
    intro_until = now_ms + math.floor(#INTRO[name] / 3) * 240 + 700
end

function on_tts_result(id, res)
    if id ~= intro_id then return end
    intro_id = 0
    intro_busy = false
    intro_until = 0
    -- 只要有一条正常交付，就说明语音服务是好的，把超时计数清掉
    if res and res.status == "completed" then intro_timeouts = 0 end
end

-- ================= 输入：方向键轮询 + 旋钮 =================
local keys = { up = false, down = false, left = false, right = false }
local keys_prev = { up = false, down = false, left = false, right = false }
local input_based = false

local function read_input()
    keys_prev.up = keys.up
    keys_prev.down = keys.down
    keys_prev.left = keys.left
    keys_prev.right = keys.right
    -- 引脚与丝印方向是交叉的：实测按「上」键读到的是 PB7，按「下」键读到 PA0。
    keys.up    = (gpio.read("b", 7) == 1)  -- PB7 = 上
    keys.down  = (gpio.read("a", 0) == 1)  -- PA0 = 下
    keys.left  = (gpio.read("b", 6) == 1)  -- PB6 = 左
    keys.right = (gpio.read("a", 1) == 1)  -- PA1 = 右
    -- 第一帧引脚刚从复用功能切到 GPIO，可能读到瞬时高电平。
    -- 只把它当基线，不产生“按下”边沿，否则开局会自己跳一格。
    if not input_based then
        input_based = true
        keys_prev.up = keys.up
        keys_prev.down = keys.down
        keys_prev.left = keys.left
        keys_prev.right = keys.right
    end
end
local function pressed(name)
    return keys[name] and not keys_prev[name]
end

-- 旋钮增量（菜单导航用，过滤微抖，累计有效旋转）
local knob_prev = nil
local knob_acc = 0
local knob_warm = 0
local function knob_step()
    local v = adc.read(7)
    -- exadc 走 I2C 桥，偶发读失败会返回负数；不当真，否则一次 -1 就能算出 -614 的跳变
    if not v or v < 0 or v > 1023 then return 0 end
    -- 刚切场景时头几个采样可能是上一次的残留值，先取几次当基线
    if knob_prev == nil or knob_warm < 3 then
        knob_warm = knob_warm + 1
        knob_prev = v
        knob_acc = 0
        return 0
    end
    local d = v - knob_prev
    knob_prev = v
    if math.abs(d) > 300 then knob_acc = 0; return 0 end   -- 跳变：当作重新落位，不算旋转
    -- 电位器静止时实测抖动 ±3（连读三次 613/608/611）。门槛放到 8，
    -- 否则随机游走几秒就能凑出一次"假旋转" —— 在蒲丰投针里会直接把统计清零。
    if math.abs(d) < 8 then return 0 end
    knob_acc = knob_acc + d
    local TH = 200
    if knob_acc >= TH then knob_acc = 0; return 1 end
    if knob_acc <= -TH then knob_acc = 0; return -1 end
    return 0
end
local function knob_raw()
    local v = adc.read(7)
    if not v or v < 0 or v > 1023 then return knob_prev or 512 end
    return v
end

-- ================= 场景状态机 =================
local scene = "menu"
local SCENES = {}

local function set_scene(name)
    scene = name
    knob_prev = nil
    knob_acc = 0
    knob_warm = 0
    local s = SCENES[name]
    if s and s.init then s.init() end
    intro_say(name)      -- 进游戏就念一段玩法，念的同时手能继续操作
end

-- ================= 菜单 icon（矩形/圆简单绘制） =================
local function draw_icon(name, x, y)
    if name == "snake" then
        screen.rect(x + 12, y, 9, 9, GREEN)
        screen.rect(x + 3, y + 9, 9, 9, GREEN)
        screen.rect(x + 12, y + 18, 9, 9, GREEN)
        screen.rect(x + 21, y + 9, 7, 7, RED)
    elseif name == "prob_menu" then
        screen.rect(x, y + 15, 6, 9, BLUE)
        screen.rect(x + 8, y + 8, 6, 16, BLUE)
        screen.rect(x + 16, y + 3, 6, 21, YELLOW)
    elseif name == "balance" then
        screen.rect(x, y + 12, 28, 4, YELLOW)
        screen.rect(x + 11, y + 15, 6, 9, GRAY)
        screen.circle(x + 5, y + 10, 4, GREEN)
        screen.circle(x + 23, y + 16, 4, RED)
    elseif name == "target" then
        screen.circle(x + 14, y + 14, 14, RED)
        screen.circle(x + 14, y + 14, 9, WHITE)
        screen.circle(x + 14, y + 14, 5, RED)
    elseif name == "g2048" then
        screen.rect(x + 1, y + 1, 13, 13, 0x4A6FA5)
        screen.rect(x + 16, y + 1, 13, 13, 0xBB86FC)
        screen.rect(x + 1, y + 16, 13, 13, 0xF4C64A)
        screen.rect(x + 16, y + 16, 13, 13, 0xFF6B5E)
    elseif name == "dice" then
        screen.rect(x + 3, y + 3, 22, 22, WHITE)
        screen.rect(x + 9, y + 9, 5, 5, BG)
        screen.rect(x + 16, y + 16, 5, 5, BG)
    elseif name == "coin" then
        screen.circle(x + 14, y + 14, 12, YELLOW)
        screen.circle(x + 14, y + 14, 7, 0xC9A227)
    elseif name == "galton" then
        screen.rect(x + 4, y + 3, 3, 3, GRAY)
        screen.rect(x + 9, y + 3, 3, 3, GRAY)
        screen.rect(x + 14, y + 3, 3, 3, GRAY)
        screen.rect(x + 6, y + 8, 3, 3, GRAY)
        screen.rect(x + 11, y + 8, 3, 3, GRAY)
        screen.rect(x + 8, y + 13, 3, 3, GRAY)
    elseif name == "converge" then
        screen.line(x, y + 22, x + 14, y + 11, BLUE)
        screen.line(x + 14, y + 11, x + 28, y + 12, BLUE)
        screen.line(x, y + 14, x + 28, y + 14, DIM)
    elseif name == "monty" then
        screen.rect(x + 1, y + 3, 7, 22, GREEN)
        screen.rect(x + 11, y + 3, 7, 22, GREEN)
        screen.rect(x + 21, y + 3, 7, 22, GREEN)
    elseif name == "binom" then
        screen.rect(x, y + 14, 5, 10, PURPLE)
        screen.rect(x + 7, y + 7, 5, 17, PURPLE)
        screen.rect(x + 14, y + 3, 5, 21, PURPLE)
        screen.rect(x + 21, y + 7, 5, 17, PURPLE)
    end
end

-- ================= 通用菜单 =================
local function make_menu(items, title, back)
    local m = { items = items, title = title, back = back, sel = 1 }
    m.init = function() m.sel = 1 end
    m.draw = function()
        screen.begin(BG)
        for i = 1, 6 do
            screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
        end
        screen.text(m.title, 8, 5, TITLE)
        -- 7 项时（概率实验室）单列 30px 会顶到返回提示，改用 25px 紧凑行 + 色块代替图标
        local n = #m.items
        local compact = (n > 6)
        local item_h = (n <= 5) and 36 or (compact and 25 or 30)
        local y0 = compact and 30 or 32
        for i, it in ipairs(m.items) do
            local y = y0 + (i - 1) * item_h
            if i == m.sel then
                screen.rect(4, y, 232, item_h - 1, 0x2A3A5A)
            end
            if compact then
                screen.rect(16, y + 6, 6, 13, (i == m.sel) and YELLOW or 0x3A4A66)
                screen.text(it.name, 32, y + 4, (i == m.sel) and TITLE or TEXT)
            else
                draw_icon(it.scene, 14, y + 4)
                screen.text(it.name, 56, y + 6, (i == m.sel) and TITLE or TEXT)
            end
        end
        -- 底部：左侧选择/确认键位，右侧侧键（主菜单上=退出，子菜单上=返回）
        screen.text("↑↓选择 →确认", 8, 222, DIM)
        screen.text(m.back and BACK_LABEL or "侧键 退出", 164, 222, DIM)
        screen.present()
    end
    m.update = function(dt)
        if pressed("up") then
            m.sel = m.sel - 1
            if m.sel < 1 then m.sel = #m.items end
            play_sfx("move", 40)
        end
        if pressed("down") then
            m.sel = m.sel + 1
            if m.sel > #m.items then m.sel = 1 end
            play_sfx("move", 40)
        end
        if pressed("right") then
            play_sfx("select", 0)
            set_scene(m.items[m.sel].scene)
            return
        end
        if pressed("left") then
            if m.back then set_scene(m.back) end
            return
        end
        m.draw()
    end
    return m
end

local MENU_MAIN = {
    { name = "贪吃蛇",    scene = "snake" },
    { name = "概率实验室", scene = "prob_menu" },
    { name = "平衡挑战",   scene = "balance" },
    { name = "打靶",      scene = "target" },
    { name = "2048",      scene = "g2048" },
}
local MENU_PROB = {
    { name = "掷骰子",    scene = "dice" },
    { name = "掷硬币",    scene = "coin" },
    { name = "高尔顿板",  scene = "galton" },
    { name = "频率收敛",  scene = "converge" },
    { name = "蒲丰投针",  scene = "buffon" },
    { name = "蒙提霍尔",  scene = "monty" },
    { name = "二项分布",  scene = "binom" },
}
SCENES.menu = make_menu(MENU_MAIN, "游戏大厅", nil)
SCENES.prob_menu = make_menu(MENU_PROB, "概率实验室", "menu")

-- ================= 贪吃蛇（像素级平滑移动） =================
-- 手感关键：不做“整格跳”，头按像素连续前进；方向键当帧生效（tick 实测 20ms），
-- 头部眼睛立刻翻到新方向，按下就有反馈。
-- 速度：基础 24px/s（原版整格跳等效 53px/s），每吃一颗 +2.2px/s，上限 42px/s。
local CELL = 10
local GRID = 22
local SNAKE_Y0 = 18
local PLAY_X0 = 10
local PLAY_W = GRID * CELL      -- 220
local PLAY_H = GRID * CELL      -- 220
local SEG_SP = 8                -- 相邻体节间距（px）
local BASE_SPEED = 24
local SPEED_GAIN = 2.2
local SPEED_MAX = 42

local snake = {
    x = 0, y = 0, dir = { 1, 0 }, path = {}, pts = {},
    segs = 4, score = 0, state = "ready", speed = BASE_SPEED,
    food = { 11, 11 },
}

local function cell_cx(c) return PLAY_X0 + (c - 0.5) * CELL end
local function cell_cy(c) return SNAKE_Y0 + (c - 0.5) * CELL end

-- 追加轨迹点（位移不足 0.6px 不记，避免点过密）
local function path_push(x, y)
    local n = #snake.path
    if n > 0 then
        local p = snake.path[n]
        local dx, dy = x - p[1], y - p[2]
        if dx * dx + dy * dy < 0.36 then return end
    end
    snake.path[n + 1] = { x, y }
end

-- 只保留“够画完整条蛇 + 一节余量”的轨迹，控制内存与遍历开销
local function path_trim(need)
    local n = #snake.path
    if n < 3 then return end
    local acc = 0
    for i = n, 2, -1 do
        local a, b = snake.path[i], snake.path[i - 1]
        local dx, dy = a[1] - b[1], a[2] - b[2]
        acc = acc + math.sqrt(dx * dx + dy * dy)
        if acc >= need then
            local keep = n - i + 1
            while #snake.path > keep do table.remove(snake.path, 1) end
            return
        end
    end
end

-- 沿轨迹等距取点，得到每节身体的位置（pts[1] = 头）
local function recompute_pts()
    local count = snake.segs
    local pts = {}
    local n = #snake.path
    local acc, want = 0, 0
    local idx = 1
    for k = n, 2, -1 do
        local a, b = snake.path[k], snake.path[k - 1]
        local dx, dy = b[1] - a[1], b[2] - a[2]   -- a → b 方向（从新到旧）
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 1e-6 then
            while idx <= count and want <= acc + d do
                local t = (want - acc) / d
                pts[idx] = { a[1] + dx * t, a[2] + dy * t }
                idx = idx + 1
                want = want + SEG_SP
            end
            acc = acc + d
        end
        if idx > count then break end
    end
    local tail = snake.path[1]
    while idx <= count do
        pts[idx] = { tail[1], tail[2] }
        idx = idx + 1
    end
    snake.pts = pts
end

local function snake_hits_body(x, y)
    for i = 3, #snake.pts do
        local p = snake.pts[i]
        local dx, dy = x - p[1], y - p[2]
        if dx * dx + dy * dy < SEG_SP * SEG_SP * 0.55 then return true end
    end
    return false
end

local function snake_place_food()
    local fx, fy, guard = 11, 11, 0
    repeat
        fx = rnd_int(GRID)
        fy = rnd_int(GRID)
        guard = guard + 1
    until (not snake_hits_body(cell_cx(fx), cell_cy(fy))) or guard > 300
    snake.food = { fx, fy }
end

local function init_snake()
    local c = math.floor(GRID / 2)
    snake.x = cell_cx(c)
    snake.y = cell_cy(c)
    snake.dir = { 1, 0 }
    snake.segs = 4
    snake.score = 0
    snake.speed = BASE_SPEED
    snake.state = "ready"
    snake.path = {}
    for k = 4, 0, -1 do
        snake.path[#snake.path + 1] = { snake.x - k * SEG_SP, snake.y }
    end
    recompute_pts()
    snake_place_food()
end

local function draw_snake()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("贪吃蛇", 96, 1, TITLE)
    screen.text("得分 " .. snake.score, 8, 2, TEXT)
    hint_back(164, 2)   -- 标题栏右侧：网格铺满全屏，底部没有空位
    screen.rect(0, SNAKE_Y0 - 2, W, 2, 0x3A4A66)

    -- 场边（左右两条淡线，明确撞墙边界）
    screen.rect(PLAY_X0 - 1, SNAKE_Y0, 1, PLAY_H, 0x2A3850)
    screen.rect(PLAY_X0 + PLAY_W, SNAKE_Y0, 1, PLAY_H, 0x2A3850)

    -- 食物
    local fx = math.floor(cell_cx(snake.food[1])) - 4
    local fy = math.floor(cell_cy(snake.food[2])) - 4
    screen.rect(fx, fy, 8, 8, RED)

    -- 身体：从尾到头画，头最后画在最上层
    local pts = snake.pts
    for i = #pts, 2, -1 do
        local p = pts[i]
        screen.rect(math.floor(p[1]) - 3, math.floor(p[2]) - 3, 7, 7, DGREEN)
    end
    if pts[1] then
        local hx = math.floor(pts[1][1])
        local hy = math.floor(pts[1][2])
        screen.rect(hx - 4, hy - 4, 8, 8, GREEN)
        -- 眼睛朝当前方向：方向键一按下当帧就翻面，这就是“跟手”的视觉反馈
        local dx, dy = snake.dir[1], snake.dir[2]
        if dx == 1 then
            screen.rect(hx + 2, hy - 3, 2, 2, 0x0B1220)
            screen.rect(hx + 2, hy + 2, 2, 2, 0x0B1220)
        elseif dx == -1 then
            screen.rect(hx - 4, hy - 3, 2, 2, 0x0B1220)
            screen.rect(hx - 4, hy + 2, 2, 2, 0x0B1220)
        elseif dy == -1 then
            screen.rect(hx - 3, hy - 4, 2, 2, 0x0B1220)
            screen.rect(hx + 2, hy - 4, 2, 2, 0x0B1220)
        else
            screen.rect(hx - 3, hy + 2, 2, 2, 0x0B1220)
            screen.rect(hx + 2, hy + 2, 2, 2, 0x0B1220)
        end
    end

    if snake.state == "ready" then
        screen.rect(30, 96, 180, 44, 0x1F2C46)
        screen.text("按方向键开始", 66, 106, TEXT)
        screen.text("←左 ↓下 →右", 68, 122, DIM)
    elseif snake.state == "dead" then
        screen.rect(30, 84, 180, 70, 0x3A1F1F)
        screen.text("游戏结束", 84, 92, RED)
        screen.text("得分 " .. snake.score, 96, 114, TEXT)
        screen.text("→重开", 96, 134, DIM)
    end
    screen.present()
end

local function snake_update_play(dt)
    -- 输入：每帧采样，当帧改向（不做“等下一格”）
    if pressed("up") and snake.dir[2] ~= 1 then
        snake.dir = { 0, -1 }
    elseif pressed("down") and snake.dir[2] ~= -1 then
        snake.dir = { 0, 1 }
    elseif pressed("left") and snake.dir[1] ~= 1 then
        snake.dir = { -1, 0 }
    elseif pressed("right") and snake.dir[1] ~= -1 then
        snake.dir = { 1, 0 }
    end

    local step = snake.speed * dt / 1000
    snake.x = snake.x + snake.dir[1] * step
    snake.y = snake.y + snake.dir[2] * step
    path_push(snake.x, snake.y)
    path_trim(snake.segs * SEG_SP + 8)
    recompute_pts()

    -- 撞墙
    if snake.x < PLAY_X0 + 4 or snake.x > PLAY_X0 + PLAY_W - 4 or
       snake.y < SNAKE_Y0 + 4 or snake.y > SNAKE_Y0 + PLAY_H - 4 then
        snake.state = "dead"
        play_sfx("die", 300)
        return
    end

    -- 吃食物
    local fdx = snake.x - cell_cx(snake.food[1])
    local fdy = snake.y - cell_cy(snake.food[2])
    if fdx * fdx + fdy * fdy < 36 then
        snake.score = snake.score + 1
        snake.segs = snake.segs + 1
        snake.speed = math.min(BASE_SPEED + snake.score * SPEED_GAIN, SPEED_MAX)
        play_sfx("eat", 0)
        snake_place_food()
    end

    -- 自撞
    if snake_hits_body(snake.x, snake.y) then
        snake.state = "dead"
        play_sfx("die", 300)
    end
end

local function update_snake(dt)
    if not dt or dt < 0 then dt = 20 end
    if dt > 100 then dt = 100 end

    if snake.state == "ready" then
        local d = nil
        if pressed("up") then d = { 0, -1 }
        elseif pressed("left") then d = { -1, 0 }
        elseif pressed("down") then d = { 0, 1 }
        elseif pressed("right") then d = { 1, 0 } end
        -- 初始身体在头左侧，开局禁止直接往左（会立刻自撞）
        if d and d[1] == -1 then d = nil end
        if d then
            snake.dir = d
            snake.state = "play"
            play_sfx("select", 0)
        end
        draw_snake()
        return
    end

    if snake.state == "dead" then
        if pressed("right") then init_snake() end
        if pressed("down") then set_scene("menu"); return end   -- 兜底：侧键失灵时也能退
        draw_snake()
        return
    end

    snake_update_play(dt)
    draw_snake()
end

SCENES.snake = { init = init_snake, update = update_snake, draw = draw_snake }

-- ================= 平衡挑战 =================
local bal = { x = 120, v = 0, alive = true, t = 0, score = 0 }

local function init_balance()
    bal.x = 120
    bal.v = 0
    bal.t = 0
    bal.score = 0
    bal.alive = true
end

local function draw_balance()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("平衡挑战", 88, 3, TITLE)
    screen.text("得分 " .. bal.score, 8, 4, TEXT)
    screen.rect(116, 150, 8, 10, GRAY)
    local k = knob_raw()
    local off = (k - 512) / 512.0
    if off > 1 then off = 1 end
    if off < -1 then off = -1 end
    local tilt = math.floor(off * 46)
    screen.line(16, 120 - tilt, 224, 120 + tilt, YELLOW)
    screen.line(16, 123 - tilt, 224, 123 + tilt, YELLOW)
    -- 球在杆上的纵向位置：必须取整，C 侧 rect/circle 拒收浮点
    local ybar = math.floor(120 + (bal.x - 120) / 208.0 * (tilt * 2))
    local bc = bal.alive and GREEN or RED
    screen.circle(clamp(bal.x, 6, 234), clamp(ybar, 100, 140), 6, bc)
    if bal.alive then
        screen.text("旋钮调平", 8, 222, DIM)
    else
        screen.text("→重开", 8, 222, DIM)
    end
    hint_back()
    screen.present()
end

local function update_balance(dt)
    if not bal.alive then
        if pressed("right") then init_balance() end
        draw_balance()
        return
    end
    if not dt or dt <= 0 then dt = 20 end
    local s = dt / 1000
    bal.t = bal.t + dt
    bal.score = math.floor(bal.t / 100)
    local k = knob_raw()
    local off = clamp((k - 512) / 512.0, -1, 1)
    -- 按秒积分：加速度 300px/s²、阻尼 2.2/s，终端速度约 136px/s，半秒内能救回来。
    -- 手抖噪声 240px/s²，什么都不做大约撑 20 秒落杆。
    local acc = off * 300 + (rnd() - 0.5) * 1100
    bal.v = bal.v + acc * s
    bal.v = bal.v * (1 - 2.2 * s)
    bal.v = clamp(bal.v, -170, 170)
    bal.x = bal.x + bal.v * s
    if bal.x < 8 or bal.x > 232 then
        bal.alive = false
        play_sfx("fail", 300)
    end
    draw_balance()
end

SCENES.balance = { init = init_balance, update = update_balance, draw = draw_balance }

-- ================= 打靶 =================
-- 玩法：每发开始准星随机落在靶面某处，旋钮做相对微调，→ 发射。
-- （旧版准星由旋钮绝对值直接决定，每次都停在正中，没有“重新找靶”的过程。）
local MAX_SHOTS = 5
local tg = { aim = 120, shots = 0, score = 0, state = "aim", holes = {}, kprev = nil, flash = 0 }
local AIM_MIN, AIM_MAX = 44, 196   -- 靶面 50..190，留一点余量，避免每次都在白圈外

local function target_place_aim()
    tg.aim = AIM_MIN + rnd_int(AIM_MAX - AIM_MIN + 1) - 1
    tg.kprev = nil          -- 重建旋钮基线，上一发的转动不会被算进这一发
end

local function init_target()
    tg.shots = 0
    tg.score = 0
    tg.state = "aim"
    tg.holes = {}
    tg.flash = 0
    target_place_aim()
end

local function target_fire()
    local jitter = math.floor((rnd() - 0.5) * 22)   -- 射击抖动 ±11px，考验瞄准但不会瞎打
    local hx = clamp(tg.aim + jitter, 6, 234)
    local dist = math.abs(hx - 120)
    local ring = 2
    if dist < 10 then ring = 10
    elseif dist < 25 then ring = 8
    elseif dist < 42 then ring = 6
    elseif dist < 60 then ring = 4 end
    tg.score = tg.score + ring
    tg.shots = tg.shots + 1
    tg.holes[#tg.holes + 1] = { x = hx, ring = ring }
    tg.state = "result"
    tg.flash = 60            -- 枪口闪光：白圈亮一下
    -- 枪声和命中反馈是同一段乐谱（枪响 170ms 后接提示音），分成两次提交会互相打断
    local sfx = "gun_miss"
    if ring == 10 then sfx = "gun_hit10"
    elseif ring >= 8 then sfx = "gun_hit8"
    elseif ring >= 4 then sfx = "gun_hit4" end
    play_sfx(sfx, 0)
end

local function draw_target()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("打靶", 104, 2, TITLE)
    screen.text("得分 " .. tg.score, 8, 2, TEXT)
    screen.text(tg.shots .. "/" .. MAX_SHOTS, 200, 2, TEXT)
    local cy = 100
    if (tg.flash or 0) > 0 then screen.circle(120, cy, 78, WHITE) end
    screen.circle(120, cy, 70, RED)
    screen.circle(120, cy, 55, WHITE)
    screen.circle(120, cy, 40, RED)
    screen.circle(120, cy, 25, WHITE)
    screen.circle(120, cy, 10, RED)
    screen.circle(120, cy, 3, YELLOW)
    for i, h in ipairs(tg.holes) do
        screen.rect(h.x - 2, cy - 2, 4, 4, 0x000000)
    end
    if tg.state == "aim" then
        screen.rect(tg.aim - 1, cy + 74, 2, 12, YELLOW)
        screen.rect(tg.aim - 6, cy + 86, 12, 2, YELLOW)
        screen.text("旋钮瞄准 →发射", 8, 222, DIM)
    else
        local last = tg.holes[#tg.holes]
        screen.text(last.ring .. " 环", 8, 176, YELLOW)
        if tg.shots >= MAX_SHOTS then
            screen.text("总 " .. tg.score .. " 分  →重开", 66, 176, TEXT)
            screen.text("→重开", 8, 222, DIM)
        else
            screen.text("→ 下一发", 86, 176, DIM)
        end
    end
    hint_back()
    screen.present()
end

local function update_target(dt)
    if tg.flash and tg.flash > 0 then tg.flash = tg.flash - (dt or 20) end
    -- 旋钮相对调节：转多少走多少，可以慢慢从随机落点挪到靶心
    local k = knob_raw()
    if tg.kprev == nil then tg.kprev = k end
    local d = k - tg.kprev
    if d >= 4 or d <= -4 then
        tg.kprev = k
        tg.aim = clamp(tg.aim + d * 0.22, AIM_MIN, AIM_MAX)
    end
    if tg.state == "aim" then
        if pressed("right") then target_fire() end
    else
        if pressed("right") then
            if tg.shots >= MAX_SHOTS then
                init_target()
            else
                tg.state = "aim"
                target_place_aim()   -- 每一发都重新随机落点
            end
        end
    end
    draw_target()
end

SCENES.target = { init = init_target, update = update_target, draw = draw_target }

-- ================= 概率实验室：掷骰子 =================
local PIPS = {
    { { 2, 2 } },
    { { 1, 1 }, { 3, 3 } },
    { { 1, 1 }, { 2, 2 }, { 3, 3 } },
    { { 1, 1 }, { 1, 3 }, { 3, 1 }, { 3, 3 } },
    { { 1, 1 }, { 1, 3 }, { 2, 2 }, { 3, 1 }, { 3, 3 } },
    { { 1, 1 }, { 2, 1 }, { 3, 1 }, { 1, 3 }, { 2, 3 }, { 3, 3 } },
}
local dice = {
    value = 1, counts = { 0, 0, 0, 0, 0, 0 }, total = 0, rolling = false,
    target = 1, elapsed = 0, tick = 0, dx = 0, dy = 0,
}
local DICE_ROLL_MS = 830   -- 与 S.dice_roll 的长度对齐（约 13 下撞击）

local function init_dice()
    dice.value = 1
    dice.counts = { 0, 0, 0, 0, 0, 0 }
    dice.total = 0
    dice.rolling = false
    dice.target = 1
    dice.elapsed, dice.tick = 0, 0
    dice.dx, dice.dy = 0, 0
end

-- 先摇 830ms（点数乱跳 + 抖动），再定到目标点数并记入统计
local function dice_start()
    if dice.rolling then return end
    dice.target = rnd_int(6)
    dice.elapsed, dice.tick = 0, 0
    dice.rolling = true
    play_sfx("dice_roll", 0)
end

local function draw_dice()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("掷骰子", 96, 2, TITLE)
    screen.text(dice.rolling and "摇…" or "→掷", 8, 2, DIM)
    hint_back(164, 2)
    local jx = dice.dx or 0
    local jy = dice.dy or 0
    local sx, sy, sz = 80 + jx, 26 + jy, 80
    screen.rect(sx - 3, sy - 3, sz + 6, sz + 6, 0x5A6478)
    screen.rect(sx, sy, sz, sz, WHITE)
    local layout = PIPS[dice.value]
    for i, rc in ipairs(layout) do
        local cx = sx + math.floor((rc[2] * 2 - 1) * sz / 6)
        local cy = sy + math.floor((rc[1] * 2 - 1) * sz / 6)
        screen.rect(cx - 6, cy - 6, 12, 12, 0x151A22)
    end
    screen.text("共掷 " .. dice.total .. " 次", 76, 120, TEXT)
    local maxf = 1
    for i = 1, 6 do if dice.counts[i] > maxf then maxf = dice.counts[i] end end
    local bar_x0, base_y, max_h = 20, 210, 26
    screen.rect(bar_x0 - 2, base_y, 204, 2, 0x3A4A66)
    for i = 1, 6 do
        local x = bar_x0 + (i - 1) * 34
        local f = dice.counts[i]
        if f > 0 then
            local h = math.max(4, math.floor(f * max_h / maxf))
            screen.rect(x, base_y - h, 22, h, 0x4A6FA5)
            screen.text(tostring(f), x + 7, base_y - h - 15, 0x9AA6B8)
        end
        screen.text(tostring(i), x + 7, base_y + 2, DIM)
    end
    screen.present()
end

local function update_dice(dt)
    if dice.rolling then
        -- 抖动 + 快速改点数；音效本身已经在一次提交里播完整段滚动
        dice.elapsed = dice.elapsed + dt
        dice.tick = dice.tick + dt
        if dice.tick >= 55 then
            dice.tick = dice.tick - 55
            dice.value = rnd_int(6)
        end
        dice.dx = rnd_int(7) - 4      -- -3..3
        dice.dy = rnd_int(7) - 4
        if dice.elapsed >= DICE_ROLL_MS then
            dice.rolling = false
            dice.value = dice.target
            dice.dx, dice.dy = 0, 0
            dice.counts[dice.value] = dice.counts[dice.value] + 1
            dice.total = dice.total + 1
            play_sfx("dice_land", 0)
        end
    elseif pressed("right") then
        dice_start()
    end
    if pressed("down") and not dice.rolling then set_scene("prob_menu"); return end
    draw_dice()
end

SCENES.dice = { init = init_dice, update = update_dice, draw = draw_dice }

-- ================= 概率实验室：掷硬币 =================
local coin = { side = 1, heads = 0, total = 0 }

local function init_coin()
    coin.side = 1
    coin.heads = 0
    coin.total = 0
end

local function coin_flip()
    coin.side = (rnd() < 0.5) and 1 or 0
    if coin.side == 1 then coin.heads = coin.heads + 1 end
    coin.total = coin.total + 1
    play_sfx("coin", 0)
end

local function draw_coin()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("掷硬币", 96, 2, TITLE)
    screen.text("→掷", 8, 2, DIM)
    local cx, cy, r = 120, 60, 42
    local c = (coin.side == 1) and YELLOW or 0xC3CBD8
    screen.circle(cx, cy, r, c)
    screen.circle(cx, cy, r - 10, 0x1B263D)
    local face = (coin.side == 1) and "正" or "反"
    screen.text(face, cx - 8, cy - 8, 0x151A22)
    screen.text("正面 " .. coin.heads .. " 次", 60, 116, TEXT)
    screen.text("共掷 " .. coin.total .. " 次", 72, 140, TEXT)
    local rate = 0.5
    if coin.total > 0 then rate = coin.heads / coin.total end
    local bx, by, bw, bh = 20, 168, 200, 16
    screen.rect(bx, by, bw, bh, 0x3A4A66)
    screen.rect(bx, by, math.floor(bw * rate + 0.5), bh, BLUE)
    screen.rect(bx + math.floor(bw / 2) - 1, by - 3, 2, bh + 6, YELLOW)
    local pct = "50%"
    if coin.total > 0 then pct = tostring(math.floor(coin.heads * 100 / coin.total + 0.5)) .. "%" end
    screen.text("正面频率 " .. pct, 78, 192, TEXT)
    hint_back()
    screen.present()
end

local function update_coin(dt)
    if pressed("right") then coin_flip() end
    if pressed("down") then set_scene("prob_menu"); return end
    draw_coin()
end

SCENES.coin = { init = init_coin, update = update_coin, draw = draw_coin }

-- ================= 概率实验室：高尔顿板 =================
local gal = {
    counts = { 0, 0, 0, 0, 0, 0, 0, 0 }, total = 0,
    falling = false, ball_layer = 0, ball_r = 0,
    ball_x = 120, ball_y = 14, drop_elapsed = 0,
}
local G_LAYERS = 7
local G_BINS = 8

local function init_galton()
    gal.counts = { 0, 0, 0, 0, 0, 0, 0, 0 }
    gal.total = 0
    gal.falling = false
end

local function galton_drop()
    gal.falling = true
    gal.ball_layer = 0
    gal.ball_r = 0
    gal.ball_x = 120
    gal.ball_y = 14
    gal.drop_elapsed = 0
    play_sfx("drop", 0)
end

local function draw_galton()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("高尔顿板", 88, 2, TITLE)
    screen.text("→放球", 8, 2, DIM)
    local LAYER_GAP, PIN_TOP, PIN_DX = 14, 30, 28
    for k = 0, G_LAYERS - 1 do
        local n = k + 1
        local y = PIN_TOP + k * LAYER_GAP
        for i = 0, n - 1 do
            local x = 120 + i * PIN_DX - k * (PIN_DX / 2)
            screen.rect(x - 1, y - 1, 3, 3, GRAY)
        end
    end
    if gal.falling then
        screen.rect(gal.ball_x - 3, gal.ball_y - 3, 6, 6, RED)
    end
    local base_y, max_h = 210, 40
    local maxf = 1
    for i = 1, G_BINS do if gal.counts[i] > maxf then maxf = gal.counts[i] end end
    screen.rect(8, base_y, 224, 2, 0x3A4A66)
    for i = 1, G_BINS do
        local x = 12 + (i - 1) * 27
        local f = gal.counts[i]
        if f > 0 then
            local h = math.max(4, math.floor(f * max_h / maxf))
            screen.rect(x, base_y - h, 22, h, 0x4A6FA5)
        end
    end
    screen.text("共 " .. gal.total .. " 球", 8, 222, DIM)
    hint_back()
    screen.present()
end

local function update_galton(dt)
    if pressed("right") then galton_drop() end
    if pressed("down") then set_scene("prob_menu"); return end
    if gal.falling then
        gal.drop_elapsed = gal.drop_elapsed + dt
        if gal.ball_layer < G_LAYERS then
            if gal.drop_elapsed >= 60 then
                gal.drop_elapsed = 0
                if rnd() < 0.5 then gal.ball_r = gal.ball_r + 1 end
                gal.ball_layer = gal.ball_layer + 1
                gal.ball_x = 120 + (2 * gal.ball_r - gal.ball_layer) * 14
                gal.ball_y = 14 + gal.ball_layer * 14
                play_sfx("pin_tick", 55)
            end
        else
            gal.ball_y = gal.ball_y + 4
            if gal.ball_y >= 206 then
                gal.falling = false
                local idx = gal.ball_r + 1
                gal.counts[idx] = gal.counts[idx] + 1
                gal.total = gal.total + 1
                play_sfx("bin_land", 0)
            end
        end
    end
    draw_galton()
end

SCENES.galton = { init = init_galton, update = update_galton, draw = draw_galton }

-- ================= 概率实验室：频率收敛（大数定律） =================
local cv = { heads = 0, total = 0, points = {} }

local function init_converge()
    cv.heads = 0
    cv.total = 0
    cv.points = {}
end

local function converge_toss(n)
    for i = 1, n do
        if rnd() < 0.5 then cv.heads = cv.heads + 1 end
        cv.total = cv.total + 1
        local freq = cv.heads / cv.total
        local px = 20 + cv.total - 1
        if px <= 220 then
            local py = 180 - math.floor(freq * 160)
            cv.points[#cv.points + 1] = { px, py }
        end
    end
    play_sfx("drop", 0)
end

local function draw_converge()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("频率收敛", 88, 2, TITLE)
    screen.text("→投1  ←投10  ↑清", 8, 2, DIM)
    screen.rect(20, 20, 200, 160, 0x1B263D)
    -- 50% 基准线
    screen.rect(20, 100, 200, 1, YELLOW)
    -- 0% / 100% 参考线
    screen.rect(20, 180, 200, 1, 0x3A4A66)
    screen.rect(20, 20, 200, 1, 0x3A4A66)
    for i, p in ipairs(cv.points) do
        screen.rect(p[1], p[2], 2, 2, BLUE)
    end
    local pct = "50%"
    if cv.total > 0 then
        pct = tostring(math.floor(cv.heads * 100 / cv.total + 0.5)) .. "%"
    end
    screen.text("正面频率 " .. pct, 68, 190, TEXT)
    screen.text("已投 " .. cv.total .. " 次", 78, 210, DIM)
    hint_back()
    screen.present()
end

local function update_converge(dt)
    if pressed("right") then converge_toss(1) end
    if pressed("left") then converge_toss(10) end
    if pressed("up") then init_converge() end
    if pressed("down") then set_scene("prob_menu"); return end
    draw_converge()
end

SCENES.converge = { init = init_converge, update = update_converge, draw = draw_converge }

-- ================= 概率实验室：蒲丰投针 =================
-- 长 L 的针随机落进间距 D 的平行线，理论上相交概率 P = 2L/(πD)。
-- 反过来用实测相交率反推圆周率：π ≈ 2·L·N / (D·C)   （N=总针数，C=相交数）
-- 两个视图（→ 切换）：
--   1) 平行线与针：相交画红、不交画蓝 —— “交不交”本身要能一眼看出来
--   2) 收敛曲线：横轴是投针次数，纵轴就是每投一根之后算出来的圆周率，
--      黄线是 3.1416 —— 投得越多，曲线越贴着它，这才是大数定律该有的画面
-- 按键：↑投 1 根、↓投 10 根、←切换旋钮调哪个参数、→切换视图、侧键返回。
local BF_X0, BF_X1 = 10, 230
local BF_Y0, BF_Y1 = 58, 184          -- 板面 120x126
local BF_PI = 3.14159265
local BF_L = { 14, 20, 26, 32, 38, 44, 50, 56 }   -- 针长候选（px）
local BF_D = { 30, 35, 40, 45, 50, 60 }           -- 线距候选（px）

-- 收敛曲线图的绘图区与纵轴范围（纵轴放宽一点，好让前几根针那些离谱的估计也看得见）
local BF_CX0, BF_CX1 = 34, 230
local BF_CY0, BF_CY1 = 56, 176
local BF_VMIN, BF_VMAX = 2.20, 4.20
local BF_HIST_MAX = 500                -- 曲线点上限，超了就隔一个丢一个（横向只画 66 列，再多也看不出来）
-- 一帧最多 256 个图元：板面 1 + 平行线最多 5 + 文字 6，留给针的约 240 条。
-- 取 160 是留余量（针太长或线太密时也不会顶到上限），
-- 超了就把最旧的针挪走 —— 屏上永远是“最近的一把”，统计仍按全部针数算。
local BF_SHOW_MAX = 160

local buffon = { view = 1, knob = 1, li = 4, di = 4, n = 0, c = 0, needles = {}, hist = {} }

local function buffon_reset()
    buffon.n = 0
    buffon.c = 0
    buffon.needles = {}
    buffon.hist = {}
end

-- 估计值 → 曲线图上的 y 像素。投针时就把每点的 r（sqrt(次数)）和 py 一起算好存下：
-- 这两样只跟这一根针有关，每帧重算 900 次会把一帧拖到 100ms 以上（曲线视图实测值）。
local function chart_py(v)
    if v < BF_VMIN then v = BF_VMIN elseif v > BF_VMAX then v = BF_VMAX end
    return math.floor(BF_CY1 - (v - BF_VMIN) / (BF_VMAX - BF_VMIN) * (BF_CY1 - BF_CY0) + 0.5)
end

-- 针尖会越出板面，按 y 裁掉；平行线是横线，裁 y 不改变是否相交
local function bf_clip(x1, y1, x2, y2)
    if y1 < BF_Y0 and y2 ~= y1 then
        local t = (BF_Y0 - y1) / (y2 - y1)
        x1, y1 = x1 + t * (x2 - x1), BF_Y0
    elseif y1 > BF_Y1 and y2 ~= y1 then
        local t = (BF_Y1 - y1) / (y2 - y1)
        x1, y1 = x1 + t * (x2 - x1), BF_Y1
    end
    if y2 < BF_Y0 and y1 ~= y2 then
        local t = (BF_Y0 - y2) / (y1 - y2)
        x2, y2 = x2 + t * (x1 - x2), BF_Y0
    elseif y2 > BF_Y1 and y1 ~= y2 then
        local t = (BF_Y1 - y2) / (y1 - y2)
        x2, y2 = x2 + t * (x1 - x2), BF_Y1
    end
    return x1, y1, x2, y2
end

local function buffon_throw(count)
    local L = BF_L[buffon.li]
    local D = BF_D[buffon.di]
    local h = L / 2
    local m = math.floor((BF_Y1 - BF_Y0) / D)
    if m < 1 then m = 1 end
    local span = m * D          -- 板内正好是 m 个完整线距，落点在这个区间里才是均匀的
    for i = 1, count do
        local a = rnd() * BF_PI
        local cx = 10 + h + rnd() * (220 - 2 * h)
        local cy = BF_Y0 + rnd() * span
        local dx = math.cos(a) * h
        local dy = math.sin(a) * h
        -- 针覆盖的 y 区间里有没有 k 使 y = Y0 + k*D
        local lo = math.ceil((cy - math.abs(dy) - BF_Y0) / D)
        local hi = math.floor((cy + math.abs(dy) - BF_Y0) / D)
        local cross = (hi >= lo)
        buffon.n = buffon.n + 1
        if cross then buffon.c = buffon.c + 1 end
        -- 端点（含越界裁剪）在这里算一次就固定了：板面和 L/D 不变时针不会动，
        -- 每帧再裁 160 次纯属白烧 CPU（实测帧耗时 5ms -> 35ms 就是这么来的）
        local ax, ay, bx, by = bf_clip(cx - dx, cy - dy, cx + dx, cy + dy)
        buffon.needles[#buffon.needles + 1] = {
            ax = ax, ay = ay, bx = bx, by = by,
            cross = cross, col = cross and RED or BLUE,
        }
        -- 收敛曲线的采样点：前 4 根针的估计值毫无意义（可能几十），不入图。
        -- r / py 一起存：曲线每帧要画的点不变，没必要每帧重算 900 次开方和映射
        if buffon.c > 0 and buffon.n >= 4 then
            local hist = buffon.hist
            local v = 2 * L * buffon.n / (D * buffon.c)
            hist[#hist + 1] = { n = buffon.n, r = math.sqrt(buffon.n), py = chart_py(v) }
        end
    end
    -- 一帧画不下所有针：屏上只留最近 BF_SHOW_MAX 根，统计仍按全部算。
    -- 一次投十根时逐个 table.remove 是 O(n²) 的搬运，直接重建末尾这一截更省。
    local nd = buffon.needles
    local over = #nd - BF_SHOW_MAX
    if over > 0 then
        local keep = {}
        for i = over + 1, #nd do keep[#keep + 1] = nd[i] end
        buffon.needles = keep
    end
    -- 曲线点太多就隔一个丢一个：形状不变，内存和每帧遍历量都可控
    if #buffon.hist > BF_HIST_MAX then
        local hist = buffon.hist
        local thin = {}
        for i = 1, #hist - 1, 2 do thin[#thin + 1] = hist[i] end
        thin[#thin + 1] = hist[#hist]
        buffon.hist = thin
    end
    play_sfx("drop", 0)
end

local function init_buffon()
    buffon.view = 1
    buffon.knob = 1
    buffon.li = 4
    buffon.di = 4
    buffon_reset()
    buffon_throw(12)          -- 先撒一把，进来就有东西看
end

-- 视图 1：平行线与针。相交红、不交蓝
local function draw_buffon_board(L, D)
    local m = math.floor((BF_Y1 - BF_Y0) / D)
    if m < 1 then m = 1 end
    -- 板面 + 平行线
    screen.rect(BF_X0, BF_Y0, BF_X1 - BF_X0, BF_Y1 - BF_Y0, 0x1B263D)
    for k = 0, m do
        local y = BF_Y0 + k * D
        screen.line(BF_X0, y, BF_X1, y, 0x3A4A66)
    end
    -- 针：红 = 与某条线相交，蓝 = 没相交（端点和颜色都是投针时算好的）
    for i = 1, #buffon.needles do
        local nd = buffon.needles[i]
        screen.line(nd.ax, nd.ay, nd.bx, nd.by, nd.col)
    end
end

-- 视图 2：圆周率的收敛过程
-- 横向用平方根压缩代替对数刻度：前几十根针铺得开、后面积累的挤在右边，
-- 恰好是“先乱跳、后贴线”的样子；纵轴固定 2.2~4.2，黄线就是 3.1416。

local function draw_buffon_chart()
    local hist = buffon.hist
    screen.rect(BF_CX0, BF_CY0, BF_CX1 - BF_CX0, BF_CY1 - BF_CY0, 0x141D2E)
    -- 上下边界 + 3.1416 真值参考线
    screen.rect(BF_CX0, BF_CY0, BF_CX1 - BF_CX0, 1, 0x2A3A5A)
    screen.rect(BF_CX0, BF_CY1, BF_CX1 - BF_CX0, 1, 0x2A3A5A)
    local yref = chart_py(BF_PI)
    screen.rect(BF_CX0, yref, BF_CX1 - BF_CX0, 1, YELLOW)
    -- 纵轴刻度只标两端，中间那条黄线就是真值（标题行已写 3.1416）
    screen.text("4.2", 2, BF_CY0 - 2, DIM)
    screen.text("2.2", 2, BF_CY1 - 12, DIM)

    local total = buffon.n
    if total < 4 or #hist == 0 then
        screen.text("再多投几根", 92, 110, DIM)
        return
    end
    local root = math.sqrt(total)
    if root < 1 then root = 1 end
    local scale = (BF_CX1 - BF_CX0) / root
    -- 每一列只留最新的一根针，避免同一列反复覆盖把曲线画脏
    local cols = {}
    for i = 1, #hist do
        local p = hist[i]
        local px = math.floor(BF_CX0 + p.r * scale + 0.5)
        if px < BF_CX0 then px = BF_CX0 elseif px > BF_CX1 then px = BF_CX1 end
        cols[px] = p.py
    end
    -- 隔 3px 取一列连成折线：约 66 段，稳稳低于一帧的图形预算
    local prevx, prevy, lastx, lasty
    for px = BF_CX0, BF_CX1, 3 do
        local py
        for q = px + 2, px, -1 do
            if py == nil then py = cols[q] end
        end
        if py ~= nil then
            if prevx ~= nil then
                screen.line(prevx, prevy, px, py, 0x4A90E2)
            end
            prevx, prevy, lastx, lasty = px, py, px, py
        end
    end
    -- 最新的一点用红色点亮，对应标题行那个圆周率估计
    if lastx ~= nil then
        screen.rect(lastx - 1, lasty - 1, 3, 3, RED)
    end
end

local function draw_buffon()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("蒲丰投针", 8, 2, TITLE)
    hint_back(164, 2)

    local L = BF_L[buffon.li]
    local D = BF_D[buffon.di]

    if buffon.view == 1 then
        draw_buffon_board(L, D)
    else
        draw_buffon_chart()
    end

    local est = "----"
    if buffon.c > 0 then
        est = string.format("%.3f", 2 * L * buffon.n / (D * buffon.c))
    end
    screen.text("圆周率 " .. est, 8, 20, YELLOW)
    screen.text("共" .. buffon.n, 152, 20, DIM)
    screen.text("真值 3.1416", 8, 38, DIM)
    screen.text("交" .. buffon.c, 152, 38, DIM)

    local mode_txt = (buffon.knob == 1) and ("旋钮 针长 " .. L) or ("旋钮 线距 " .. D)
    screen.text(mode_txt, 8, 190, YELLOW)
    -- 屏上针数封顶后，这里写出“屏上留了几根”，和上面的“共 N 根”对照着看，
    -- 就知道旧针是被顶掉的，不是统计丢了
    if buffon.n > #buffon.needles then
        screen.text("屏" .. #buffon.needles, 144, 190, DIM)
    end
    screen.text("↑投1 ↓投10", 8, 206, TEXT)
    screen.text("←切参数 →换视图", 8, 222, DIM)
    screen.present()
end

local function update_buffon(dt)
    local step = knob_step()
    if step ~= 0 then
        if buffon.knob == 1 then
            local i = buffon.li + step
            if i < 1 then i = 1 elseif i > #BF_L then i = #BF_L end
            -- 针不能比线距长（否则一根针可能同时扎两条线，这个公式就不成立了）
            while i > 1 and BF_L[i] > BF_D[buffon.di] do i = i - 1 end
            if i ~= buffon.li then
                buffon.li = i
                buffon_reset()          -- 换 L/D 就是换实验，统计清零才诚实
                play_sfx("move", 40)
            end
        else
            local i = buffon.di + step
            if i < 1 then i = 1 elseif i > #BF_D then i = #BF_D end
            if i ~= buffon.di then
                buffon.di = i
                while buffon.li > 1 and BF_L[buffon.li] > BF_D[i] do buffon.li = buffon.li - 1 end
                buffon_reset()
                play_sfx("move", 40)
            end
        end
    end
    if pressed("up") then buffon_throw(1) end
    if pressed("down") then buffon_throw(10) end
    if pressed("left") then
        buffon.knob = 3 - buffon.knob
        play_sfx("select", 0)
    end
    if pressed("right") then
        -- 平行线与针 <-> 圆周率收敛曲线；统计不清零，两个视图看的是同一批针
        buffon.view = 3 - buffon.view
        play_sfx("move", 40)
    end
    draw_buffon()
end

SCENES.buffon = { init = init_buffon, update = update_buffon, draw = draw_buffon }

-- ================= 概率实验室：蒙提霍尔（三门问题） =================
-- 规则要一眼看懂，所以整局都把三扇门摊在屏幕上：
--   1) 你选一扇（旋钮选，右键确认）
--   2) 主持人知道车在哪，会打开一扇你没选的羊门
--   3) 你决定换门还是坚持，然后全部门打开
-- 关键在于第 2 步不是随机的：他一定开羊门，所以剩下那扇门的胜率是 2/3。
local monty = {
    state = "choose", sel = 1, car = 1, revealed = 0, final = 1,
    swapped = false, win = false,
    sw_wins = 0, sw_total = 0, st_wins = 0, st_total = 0,
}

local function init_monty()
    monty.state = "choose"
    monty.sel = 1
    monty.car = rnd_int(3)
    monty.revealed = 0
    monty.final = 1
    monty.swapped = false
    monty.win = false
end

local function monty_reveal()
    local opts = {}
    for d = 1, 3 do
        if d ~= monty.sel and d ~= monty.car then opts[#opts + 1] = d end
    end
    monty.revealed = opts[rnd_int(#opts)]
    monty.final = monty.sel
    monty.state = "decide"
    play_sfx("select", 0)
end

local function monty_stat(w, t)
    if t <= 0 then return w .. "/" .. t end
    return w .. "/" .. t .. " " .. math.floor(w * 100 / t + 0.5) .. "%"
end

local function draw_monty()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("蒙提霍尔", 8, 2, TITLE)
    hint_back(164, 2)

    for d = 1, 3 do
        local x = 12 + (d - 1) * 74
        -- 关着 = 灰；你选中的 = 蓝；主持人打开的羊门 = 暗；结果页全开
        local color = 0x5A6478
        if monty.state == "choose" and d == monty.sel then color = BLUE end
        if monty.state == "result" or (monty.state == "decide" and d == monty.revealed) then
            color = 0x3A4A66
        end
        screen.rect(x, 36, 64, 88, color)
        screen.rect(x + 5, 41, 54, 78, 0x1B263D)
        screen.rect(x + 46, 96, 6, 6, 0xE8ECF3)          -- 门把手
        local shown = (monty.state == "result") or (monty.state == "decide" and d == monty.revealed)
        if shown then
            local is_car = (d == monty.car)
            screen.text(is_car and "车" or "羊", x + 24, 70, is_car and YELLOW or DIM)
        end
        screen.text(tostring(d), x + 24, 128, TEXT)
    end

    if monty.state == "choose" then
        screen.text("一扇门后有车，先选一扇", 8, 152, TEXT)
        screen.text("旋钮选门   →确认", 8, 174, TEXT)
    elseif monty.state == "decide" then
        screen.text("主持人开了 " .. monty.revealed .. " 号：是羊", 8, 152, TEXT)
        screen.text("换门↑   坚持↓", 8, 174, TEXT)
        screen.text("换门赢的概率是 2/3", 8, 194, YELLOW)
    else
        local pick = "你" .. (monty.swapped and "换到 " or "守住 ") .. monty.final .. " 号"
        screen.text(pick, 8, 152, TEXT)
        if monty.win then
            screen.text("门后是车，赢了！", 8, 172, YELLOW)
        else
            screen.text("门后是羊，输了", 8, 172, RED)
        end
        screen.text("→ 再来一局", 8, 194, DIM)
    end

    screen.text("换 " .. monty_stat(monty.sw_wins, monty.sw_total), 8, 216, BLUE)
    screen.text("守 " .. monty_stat(monty.st_wins, monty.st_total), 124, 216, GREEN)
    screen.present()
end

local function update_monty(dt)
    if pressed("down") and monty.state == "choose" then
        set_scene("prob_menu")
        return
    end
    if monty.state == "choose" then
        local step = knob_step()
        if step ~= 0 then
            monty.sel = monty.sel + step
            if monty.sel < 1 then monty.sel = 3 end
            if monty.sel > 3 then monty.sel = 1 end
            play_sfx("move", 40)
        end
        if pressed("right") then monty_reveal() end
    elseif monty.state == "decide" then
        if pressed("up") or pressed("down") then
            local final_door = monty.sel
            if pressed("up") then
                for d = 1, 3 do
                    if d ~= monty.sel and d ~= monty.revealed then final_door = d end
                end
                monty.swapped = true
                monty.sw_total = monty.sw_total + 1
                if final_door == monty.car then monty.sw_wins = monty.sw_wins + 1 end
            else
                monty.swapped = false
                monty.st_total = monty.st_total + 1
                if final_door == monty.car then monty.st_wins = monty.st_wins + 1 end
            end
            monty.final = final_door
            monty.win = (final_door == monty.car)
            monty.state = "result"
            play_sfx(monty.win and "win" or "fail", 0)
        end
    elseif monty.state == "result" then
        if pressed("right") then init_monty() end
    end
    draw_monty()
end

SCENES.monty = { init = init_monty, update = update_monty, draw = draw_monty }

-- ================= 概率实验室：二项分布调参 =================
local bin = { p = 0.5, n = 10 }

local function init_binom()
    bin.p = 0.5
    bin.n = 10
end

local function comb(n, k)
    if k < 0 or k > n then return 0 end
    local r = 1.0
    for i = 1, k do
        r = r * (n - k + i) / i
    end
    return r
end

local function draw_binom()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("二项分布", 88, 2, TITLE)
    hint_back(164, 2)
    local n = bin.n
    local maxp = 0
    for k = 0, n do
        local pr = comb(n, k) * bin.p ^ k * (1 - bin.p) ^ (n - k)
        if pr > maxp then maxp = pr end
    end
    local base_y, max_h = 190, 130
    local bar_w = math.floor(230 / (n + 1))
    screen.rect(4, base_y, 232, 2, 0x3A4A66)
    for k = 0, n do
        local pr = comb(n, k) * bin.p ^ k * (1 - bin.p) ^ (n - k)
        local h = math.floor(pr * max_h / maxp)
        if h < 1 then h = 1 end   -- 概率极小的柱子也要看得见（rect 不接受 0 高）
        local x = 8 + k * bar_w
        screen.rect(x, base_y - h, bar_w - 2, h, PURPLE)
    end
    screen.text("p = " .. string.format("%.2f", bin.p), 8, 196, YELLOW)
    screen.text("n " .. n .. "  →/←切换", 124, 196, TEXT)
    screen.text("旋钮调 p", 84, 218, DIM)
    screen.present()
end

local function update_binom(dt)
    local k = knob_raw()
    bin.p = k / 1023.0
    if pressed("right") then
        bin.n = (bin.n == 5) and 10 or (bin.n == 10 and 20 or 5)
        play_sfx("move", 40)
    end
    if pressed("left") then
        bin.n = (bin.n == 20) and 10 or (bin.n == 10 and 5 or 20)
        play_sfx("move", 40)
    end
    if pressed("down") then set_scene("prob_menu"); return end
    draw_binom()
end

SCENES.binom = { init = init_binom, update = update_binom, draw = draw_binom }

-- ================= 2048 =================
-- 4x4 棋盘，方向键整行滑动 + 同值合并，每步随机补 1 个新块（90% 2 / 10% 4）。
-- 布局：格子 44px、间距 4px、棋盘 188x188，正好塞进 240x240，标题栏留 28px。
local G8_N = 4
local G8_CELL, G8_GAP = 44, 4
local G8_X0, G8_Y0 = 26, 32
local G8C = {
    [2]    = 0x2E4265,
    [4]    = 0x38557F,
    [8]    = 0x3F6EA5,
    [16]   = 0x4A90E2,
    [32]   = 0x5B6FD8,
    [64]   = 0x7A5BD2,
    [128]  = 0x9A6BE0,
    [256]  = 0xBB86FC,
    [512]  = 0xF4C64A,
    [1024] = 0xF0A030,
    [2048] = 0xFF6B5E,
}
local g8 = { cells = {}, score = 0, state = "play", won = false }

local function g8_index(x, y)
    return (y - 1) * G8_N + x
end

local function g8_clear()
    g8.cells = {}
    for i = 1, G8_N * G8_N do g8.cells[i] = 0 end
end

local function g8_spawn()
    local empty = {}
    for i = 1, G8_N * G8_N do
        if g8.cells[i] == 0 then empty[#empty + 1] = i end
    end
    if #empty == 0 then return false end
    g8.cells[empty[rnd_int(#empty)]] = (rnd() < 0.9) and 2 or 4
    return true
end

local function init_g2048()
    g8_clear()
    g8.score = 0
    g8.state = "play"
    g8.won = false
    g8_spawn()
    g8_spawn()
end

local function g8_has_moves()
    for i = 1, #g8.cells do
        if g8.cells[i] == 0 then return true end
    end
    for y = 1, G8_N do
        for x = 1, G8_N do
            local v = g8.cells[g8_index(x, y)]
            if x < G8_N and g8.cells[g8_index(x + 1, y)] == v then return true end
            if y < G8_N and g8.cells[g8_index(x, y + 1)] == v then return true end
        end
    end
    return false
end

-- 把第 n 行/列按移动方向排成“从落点端到远端”的下标序列
local function g8_line(dir, n)
    local idx = {}
    for k = 1, G8_N do
        local x, y
        if dir == "left" then
            x, y = k, n
        elseif dir == "right" then
            x, y = G8_N + 1 - k, n
        elseif dir == "up" then
            x, y = n, k
        else
            x, y = n, G8_N + 1 - k
        end
        idx[k] = g8_index(x, y)
    end
    return idx
end

local function g8_move(dir)
    local changed, gain, max_merge = false, 0, 0
    for n = 1, G8_N do
        local idx = g8_line(dir, n)
        local vals = {}
        for k = 1, G8_N do
            local v = g8.cells[idx[k]]
            if v ~= 0 then vals[#vals + 1] = v end
        end
        local out = {}
        local i = 1
        while i <= #vals do
            if vals[i + 1] and vals[i + 1] == vals[i] then
                local v = vals[i] * 2
                out[#out + 1] = v
                gain = gain + v
                if v > max_merge then max_merge = v end
                i = i + 2          -- 一次移动里合并过的块不再参与合并
            else
                out[#out + 1] = vals[i]
                i = i + 1
            end
        end
        for k = 1, G8_N do
            local v = out[k] or 0
            if g8.cells[idx[k]] ~= v then changed = true end
            g8.cells[idx[k]] = v
        end
    end
    if not changed then return false end

    g8.score = g8.score + gain
    -- 合并音随块的大小升调，滑而不合并只给一声轻轻的“沙”
    local anim = "slide"
    if max_merge >= 1024 then anim = "merge6"
    elseif max_merge >= 256 then anim = "merge5"
    elseif max_merge >= 64 then anim = "merge4"
    elseif max_merge >= 16 then anim = "merge3"
    elseif max_merge >= 4 then anim = "merge2" end
    play_sfx(anim, 0)
    for i = 1, #g8.cells do
        if g8.cells[i] >= 2048 and not g8.won then
            g8.won = true
            g8.state = "win"
            play_sfx("win", 0)
        end
    end
    g8_spawn()
    if g8.state ~= "win" and not g8_has_moves() then
        g8.state = "over"
        play_sfx("fail", 300)
    end
    return true
end

local function draw_g2048()
    screen.begin(BG)
    for i = 1, 6 do
        screen.rect(0, (i - 1) * 40, W, 40, BG_GRAD[i])
    end
    screen.text("2048", 8, 2, TITLE)
    screen.text("分 " .. g8.score, 88, 2, TEXT)
    hint_back(164, 2)   -- 棋盘铺满下半屏，提示放标题栏右侧
    screen.rect(G8_X0 - 4, G8_Y0 - 4, 196, 196, 0x1B263D)
    for y = 1, G8_N do
        for x = 1, G8_N do
            local cx = G8_X0 + (x - 1) * (G8_CELL + G8_GAP)
            local cy = G8_Y0 + (y - 1) * (G8_CELL + G8_GAP)
            local v = g8.cells[g8_index(x, y)]
            screen.rect(cx, cy, G8_CELL, G8_CELL, G8C[v] or 0xFF6B5E)
            if v > 0 then
                local s = tostring(v)
                local tw = #s * 9          -- 数字字宽 9px
                local tc = (v <= 4) and TEXT or 0x101820
                screen.text(s, cx + math.floor((G8_CELL - tw) / 2), cy + 14, tc)
            end
        end
    end
    if g8.state == "over" then
        screen.rect(28, 96, 184, 56, 0x3A1F1F)
        screen.text("无法移动", 82, 102, RED)
        screen.text("→ 重开", 88, 124, DIM)
    elseif g8.state == "win" then
        screen.rect(28, 96, 184, 56, 0x2A3A5A)
        screen.text("达成 2048！", 66, 102, YELLOW)
        screen.text("→ 继续", 88, 124, DIM)
    end
    screen.present()
end

local function update_g2048(dt)
    if g8.state == "over" then
        if pressed("right") then init_g2048() end
        draw_g2048()
        return
    end
    if g8.state == "win" then
        if pressed("right") then g8.state = "play" end
        draw_g2048()
        return
    end
    if pressed("up") then
        g8_move("up")
    elseif pressed("down") then
        g8_move("down")
    elseif pressed("left") then
        g8_move("left")
    elseif pressed("right") then
        g8_move("right")
    end
    -- 按键无效（方向被堵）时也要判负，否则满盘后再怎么按都没反应
    if g8.state == "play" and not g8_has_moves() then
        g8.state = "over"
        play_sfx("fail", 300)
    end
    draw_g2048()
end

SCENES.g2048 = { init = init_g2048, update = update_g2048, draw = draw_g2048 }

-- ================= 入口回调 =================
local last_ms = nil

function on_start()
    scene = "menu"
    last_ms = nil
    now_ms = 0
    sfx_last = {}
    intro_id = 0
    intro_pending = nil
    intro_busy = false
    intro_until = 0
    intro_timeouts = 0
    set_scene("menu")
end

function on_tick(dt)
    read_input()

    -- 用真实毫秒差作为 dt：帧率波动时游戏速度仍与墙钟一致
    local step_dt = dt
    if clock and clock.ms then
        local now = clock.ms()
        if last_ms then
            step_dt = now - last_ms
            if step_dt < 0 then step_dt = step_dt + 4294967296 end
            if step_dt > 120 then step_dt = 120 end
            if step_dt < 1 then step_dt = 1 end
        else
            step_dt = 0
        end
        last_ms = now
    end

    local s = SCENES[scene]
    if s and s.update then s.update(step_dt) end

    now_ms = now_ms + step_dt       -- 音效节流用（clock.ms 只在调试固件里有）

    -- 讲解队列：一次只跑一条，等上一条交付结果再念下一条
    if intro_busy and now_ms > intro_deadline then
        -- 回调丢了（设备的语音服务偶尔会卡住不回包）。必须主动取消这一条：
        -- 否则音频通道一直被它占着，synth.play 全部失败 —— 整个游戏就哑了。
        if intro_id ~= 0 and tts and tts.cancel then
            if pcall then pcall(tts.cancel, intro_id) else tts.cancel(intro_id) end
        end
        intro_id = 0
        intro_busy = false
        intro_until = 0
        intro_timeouts = intro_timeouts + 1
    end
    -- 连续两次都没回包，就当这台机器的语音服务不可用：
    -- 本次运行不再念，免得每进一个游戏都要卡 20 秒静音
    if intro_pending ~= nil and not intro_busy and intro_timeouts < 2 then intro_flush() end
end

-- 侧键返回的层级关系：概率实验室里的游戏退到二级菜单，其余退到主菜单
local PARENT = {
    prob_menu = "menu",
    dice = "prob_menu", coin = "prob_menu", galton = "prob_menu",
    converge = "prob_menu", buffon = "prob_menu", monty = "prob_menu", binom = "prob_menu",
    snake = "menu", balance = "menu", target = "menu", g2048 = "menu",
}

function on_button_click(button_id)
    -- 板载侧键（功能键）单击：返回上一级；在主菜单上则退出小应用
    if button_id ~= "function" then return end
    play_sfx("back", 0)
    if scene == "menu" then
        if app and app.exit then app.exit() end
        return
    end
    set_scene(PARENT[scene] or "menu")
end

function on_exit()
end
