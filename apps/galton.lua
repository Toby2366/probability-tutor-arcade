-- 小白高尔顿板小应用 v1（正态分布 / 中心极限定理演示）
-- 单击功能键 = 放一个小球；长按 3 秒 = 退出小应用（系统级）。
-- 小球从顶部下落，经过 7 层钉子，每层随机左/右（各 50%），落到 8 个格子之一。
-- 多次放球后，底部柱状图趋近正态分布（二项分布 Binomial(7, 0.5)）。
-- 纯矩形 + 文字绘制，无图片接口。
-- 硬约束：屏幕 240x240；screen.text 的 y ∈ [0,224]；一帧最多 16 段文字、128 个矩形。

local W, H = 240, 240

local PIN       = 0x8B98AB  -- 钉子（小方块）
local BALL      = 0xFF6B5E  -- 小球（亮红）
local BORDER    = 0x5A6478
local TITLE     = 0xF4C64A
local TEXT      = 0xE8ECF3
local TEXT_DIM  = 0x9AA6B8
local BAR       = 0x4A6FA5
local BAR_HI    = 0xF4C64A
local BASELINE  = 0x3A4A66

local LAYERS   = 7        -- 钉子层数
local BINS     = 8        -- 底部格子数 = LAYERS + 1
local LAYER_GAP = 14      -- 每层垂直间距
local PIN_TOP  = 28       -- 第一层钉子 y
local PIN_DX   = 28       -- 相邻钉子水平间距

local BASE_Y   = 210      -- 柱状图基线
local MAX_H    = 40       -- 柱状图最大高度

local state = "idle"      -- "idle" | "falling"
local ball_x = 120
local ball_y = 14
local ball_layer = 0      -- 当前经过的层数 0~LAYERS
local ball_r = 0          -- 累计右偏次数 0~LAYERS
local drop_elapsed = 0    -- 下落累计时间(ms)

local counts = { 0, 0, 0, 0, 0, 0, 0, 0 }
local total  = 0

local total_ms = 0
local clicks = 0

local rng = 1
local function rnd()
  rng = (rng * 16807) % 2147483647
  if rng <= 0 then rng = 1 end
  return rng / 2147483647
end

local function beep(hz, ms)
  if buzzer ~= nil then buzzer.play(hz, ms) end
end

local function draw_bg()
  local bgs = { 0x23324F, 0x1F2C46, 0x1B263D, 0x172134, 0x131C2B, 0x0F1722 }
  for i = 1, 6 do
    screen.rect(0, (i - 1) * 40, W, 40, bgs[i])
  end
end

-- 钉子三角形：第 k 层有 k+1 个钉子（k=0..LAYERS-1），顶点朝上
local function draw_pins()
  for k = 0, LAYERS - 1 do
    local n = k + 1
    local y = PIN_TOP + k * LAYER_GAP
    for i = 0, n - 1 do
      local x = 120 + i * PIN_DX - k * (PIN_DX / 2)
      screen.rect(x - 1, y - 1, 3, 3, PIN)
    end
  end
end

-- 底部 8 格柱状图：柱高=频次，柱顶上方显示频次，最高格金色
local function draw_bins()
  local max_f = 1
  for i = 1, BINS do
    if counts[i] > max_f then max_f = counts[i] end
  end

  local bin_w = 24
  local gap   = 28
  local x0    = 10

  screen.rect(x0 - 2, BASE_Y, 220, 2, BASELINE)

  for i = 1, BINS do
    local x = x0 + (i - 1) * gap
    local f = counts[i]
    if f > 0 then
      local h = math.max(4, math.floor(f * MAX_H / max_f))
      local y = BASE_Y - h
      local color = (f == max_f) and BAR_HI or BAR
      screen.rect(x, y, bin_w, h, color)
      screen.text(tostring(f), x + bin_w / 2 - 4, y - 15, color)
    end
  end
end

local function draw()
  screen.begin(0x172134)
  draw_bg()
  screen.text("高尔顿板", 88, 4, TITLE)
  draw_pins()
  if state == "falling" then
    screen.rect(ball_x - 3, ball_y - 3, 6, 6, BALL)
  end
  draw_bins()
  screen.text("共放 " .. total .. " 个球", 84, 222, TEXT_DIM)
  screen.present()
end

local function do_ball()
  if state == "falling" then return end
  rng = (total_ms * 2654435761 + clicks * 97 + 1) % 2147483646 + 1
  state = "falling"
  ball_layer = 0
  ball_r = 0
  ball_x = 120
  ball_y = 14
  drop_elapsed = 0
  clicks = clicks + 1
  beep(700, 30)
end

function on_start()
  draw()
end

function on_tick(dt_ms)
  total_ms = total_ms + dt_ms

  if state == "falling" then
    drop_elapsed = drop_elapsed + dt_ms
    if ball_layer < LAYERS then
      -- 每 60ms 落一层，随机左/右
      if drop_elapsed >= 60 then
        drop_elapsed = 0
        if rnd() < 0.5 then ball_r = ball_r + 1 end
        ball_layer = ball_layer + 1
        ball_x = 120 + (2 * ball_r - ball_layer) * (PIN_DX / 2)
        ball_y = 14 + ball_layer * LAYER_GAP
        beep(500 + ball_layer * 80, 20)
      end
    else
      -- 已过 7 层，继续下落到对应格子柱顶
      ball_y = ball_y + 4
      if ball_y >= BASE_Y - 4 then
        state = "idle"
        local idx = ball_r + 1
        counts[idx] = counts[idx] + 1
        total = total + 1
        beep(1320, 120)
      end
    end
    draw()
  end
end

function on_button_click(button_id)
  if button_id ~= "function" then return end
  do_ball()
  draw()
end

function on_exit()
end
