-- 小白掷骰子小应用 v5（布局修正版）
-- 单击功能键 = 掷骰子；长按 3 秒 = 退出小应用（系统级）。
-- 统计：本次进入小应用以来，点数 1~6 各自出现次数，常驻画面底部柱状图。
-- 布局：标题在上，骰子居中，柱状图底部=「点数在基线下、次数在柱顶」。
-- 小应用按钮只有「单击」回调，双击/三击是系统保留行为，不能用。
-- 纯矩形 + 文字绘制，无图片接口。
-- 硬约束：屏幕 240x240；screen.text 的 y ∈ [0,224]（240-16px字体）；
--        一帧最多 16 段文字(MINIAPP_MAX_TEXTS，已改大)、最多 128 个矩形；
--        screen.rect 的 x/y ∈ [0,239]，x+w<=240，y+h<=240。

local W, H = 240, 240

local WHITE    = 0xF7F8FA
local PIP      = 0x151A22
local BORDER   = 0x5A6478
local SHADOW   = 0x05070C
local TITLE    = 0xF4C64A
local TEXT     = 0xE8ECF3
local TEXT_DIM = 0x9AA6B8
local BAR      = 0x4A6FA5
local BAR_HI   = 0xF4C64A
local BASELINE = 0x3A4A66

local SIZE   = 96
local BASE_X = 72
local BASE_Y = 28

local PIPS = {
  { {2,2} },
  { {1,1},{3,3} },
  { {1,1},{2,2},{3,3} },
  { {1,1},{1,3},{3,1},{3,3} },
  { {1,1},{1,3},{2,2},{3,1},{3,3} },
  { {1,1},{2,1},{3,1},{1,3},{2,3},{3,3} },
}

local state = "idle"  -- "idle" | "rolling"
local value  = 1
local target = 1
local elapsed = 0
local roll_duration = 0
local total_ms = 0
local clicks = 0
local dx, dy = 0, 0

local counts = { 0, 0, 0, 0, 0, 0 }
local total  = 0

local rng = 1
local function rnd()
  rng = (rng * 16807) % 2147483647
  if rng <= 0 then rng = 1 end
  return rng / 2147483647
end
local function rnd_int(n)
  return math.floor(rnd() * n) + 1
end

local function beep(hz, ms)
  if buzzer ~= nil then buzzer.play(hz, ms) end
end

-- 音效：buzzer 只能发单音，且每发一次都要重开音频流；60ms 内连发两次会互相打断，
-- 听上去就是“没声音”。synth 能一次提交整段乐谱（4 声部 / 方波 / 三角 / 噪声），
-- 所以滚动声一次播完，落定再单独一声。
local has_synth = (synth ~= nil and synth.play ~= nil)

local function N(at, hz, ms, voice, wave, vol)
  return { at = at, hz = hz, ms = ms, voice = voice, wave = wave, volume = vol }
end

-- 830ms 的撞击声：间隔逐渐拉长 = 骰子越滚越慢
local ROLL_SCORE = {
  N(0, 2400, 20, 1, "noise", 80), N(58, 2100, 20, 1, "noise", 76),
  N(112, 2600, 20, 1, "noise", 80), N(162, 2000, 20, 1, "noise", 74),
  N(212, 2500, 20, 1, "noise", 80), N(266, 2150, 20, 1, "noise", 74),
  N(326, 2450, 20, 1, "noise", 78), N(392, 2050, 20, 1, "noise", 72),
  N(464, 2500, 20, 1, "noise", 76), N(542, 2100, 20, 1, "noise", 70),
  N(626, 2400, 20, 1, "noise", 74), N(716, 2000, 20, 1, "noise", 68),
  N(810, 2500, 20, 1, "noise", 72),
  N(0, 150, 70, 2, "square", 40), N(300, 130, 80, 2, "square", 35),
  N(620, 120, 90, 2, "square", 30),
}
local LAND_SCORE = {
  N(0, 880, 90, 1, "triangle", 80), N(96, 1175, 130, 1, "triangle", 80),
  N(0, 440, 90, 2, "triangle", 45),
}

local function play_score(notes)
  if has_synth then
    if pcall then
      if pcall(synth.play, notes) then return end
    else
      synth.play(notes)
      return
    end
  end
  beep(notes[1].hz, notes[1].ms)
end

local function draw_bg()
  local bgs = { 0x23324F, 0x1F2C46, 0x1B263D, 0x172134, 0x131C2B, 0x0F1722 }
  for i = 1, 6 do
    screen.rect(0, (i - 1) * 40, W, 40, bgs[i])
  end
end

local function draw_dice()
  local sx = BASE_X + dx
  local sy = BASE_Y + dy
  screen.rect(sx + 4, sy + 4, SIZE + 4, SIZE + 4, SHADOW)
  screen.rect(sx - 3, sy - 3, SIZE + 6, SIZE + 6, BORDER)
  screen.rect(sx, sy, SIZE, SIZE, WHITE)

  local p = 18
  local layout = PIPS[value]
  for i, rc in ipairs(layout) do
    local cx = sx + math.floor((rc[2] * 2 - 1) * SIZE / 6)
    local cy = sy + math.floor((rc[1] * 2 - 1) * SIZE / 6)
    local hx = math.floor(cx - p / 2)
    local hy = math.floor(cy - p / 2)
    screen.rect(hx, hy, p, p, PIP)
    screen.rect(hx, hy, 4, 4, WHITE)
    screen.rect(hx + p - 4, hy, 4, 4, WHITE)
    screen.rect(hx, hy + p - 4, 4, 4, WHITE)
    screen.rect(hx + p - 4, hy + p - 4, 4, 4, WHITE)
  end
end

-- 底部柱状图：6 根柱子从左到右 = 点数 1~6。
-- 基线上方：柱子（柱高=频次），柱顶上方显示「次数」；
-- 基线下方：显示「点数」（1~6）。
-- 最高频柱子金色高亮。
local function draw_stats()
  local max_f = 1
  for i = 1, 6 do
    if counts[i] > max_f then max_f = counts[i] end
  end

  local bar_w   = 26
  local bar_gap = 32
  local bar_x0  = 20
  local base_y  = 218
  local max_h   = 30

  -- 基线
  screen.rect(bar_x0 - 2, base_y, 196, 2, BASELINE)

  for i = 1, 6 do
    local x = bar_x0 + (i - 1) * bar_gap
    local cx = x + math.floor(bar_w / 2)
    local f = counts[i]
    if f > 0 then
      local h = math.max(4, math.floor(f * max_h / max_f))
      local y = base_y - h
      local color = (f == max_f and f > 0) and BAR_HI or BAR
      screen.rect(x, y, bar_w, h, color)
      -- 柱顶次数
      screen.text(tostring(f), cx - 4, y - 15, color)
    end
    -- 基线下方点数
    screen.text(tostring(i), cx - 4, base_y + 2, TEXT_DIM)
  end
end

local function draw()
  screen.begin(0x172134)
  draw_bg()
  screen.text("掷骰子", 96, 4, TITLE)
  screen.text("共掷 " .. total .. " 次", 82, 136, TEXT)
  draw_dice()
  draw_stats()
  screen.present()
end

local function do_roll()
  if state == "rolling" then return end
  rng = (total_ms * 2654435761 + clicks * 97 + 1) % 2147483646 + 1
  target = rnd_int(6)
  roll_duration = 820          -- 与 ROLL_SCORE（830ms）对齐，音画同步
  elapsed = 0
  state = "rolling"
  clicks = clicks + 1
  play_score(ROLL_SCORE)
end

function on_start()
  value = 1
  draw()
end

function on_tick(dt_ms)
  total_ms = total_ms + dt_ms

  if state == "rolling" then
    elapsed = elapsed + dt_ms
    dx = rnd_int(7) - 4
    dy = rnd_int(7) - 4
    if math.floor(elapsed / 60) ~= math.floor((elapsed - dt_ms) / 60) then
      value = rnd_int(6)
    end
    if elapsed >= roll_duration then
      state = "idle"
      value = target
      dx, dy = 0, 0
      counts[target] = counts[target] + 1
      total = total + 1
      play_score(LAND_SCORE)
    end
    draw()
  end
end

function on_button_click(button_id)
  if button_id ~= "function" then return end
  do_roll()
  draw()
end

function on_exit()
end
