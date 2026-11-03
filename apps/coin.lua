-- 小白掷硬币小应用 v1（大数定律演示）
-- 单击功能键 = 掷一次硬币；长按 3 秒 = 退出小应用（系统级）。
-- 演示：伯努利试验，正面频率随投掷次数收敛到 50%（大数定律）。
-- 布局：标题在上，硬币居中，下方统计 + 正面频率进度条（中间 50% 刻度线）。
-- 纯矩形 + 文字绘制，无图片接口。
-- 硬约束：屏幕 240x240；screen.text 的 y ∈ [0,224]（240-16px字体）；
--        一帧最多 16 段文字、最多 128 个矩形。

local W, H = 240, 240

local HEAD_COLOR = 0xF4C64A  -- 正面：金色
local TAIL_COLOR = 0xC3CBD8  -- 反面：银灰
local FACE_TEXT   = 0x151A22  -- 硬币上的「正/反」字色
local BORDER      = 0x5A6478
local SHADOW      = 0x05070C
local TITLE       = 0xF4C64A
local TEXT        = 0xE8ECF3
local TEXT_DIM    = 0x9AA6B8
local BAR_BG      = 0x3A4A66
local BAR_FILL    = 0x4A6FA5
local MID_LINE    = 0xF4C64A

local COIN_X = 75
local COIN_Y = 36
local COIN_S = 90

local state = "idle"  -- "idle" | "flipping"
local side  = 1       -- 1=正面(heads) 0=反面(tails)
local heads = 0
local tails = 0
local total = 0
local elapsed = 0
local flip_duration = 0
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

local function draw_coin()
  screen.rect(COIN_X + 4, COIN_Y + 4, COIN_S + 4, COIN_S + 4, SHADOW)
  screen.rect(COIN_X - 3, COIN_Y - 3, COIN_S + 6, COIN_S + 6, BORDER)
  local color = (side == 1) and HEAD_COLOR or TAIL_COLOR
  screen.rect(COIN_X, COIN_Y, COIN_S, COIN_S, color)
  -- 内圈（用一圈浅色方块做出硬币的边沿凹槽感）
  screen.rect(COIN_X + 8, COIN_Y + 8, COIN_S - 16, COIN_S - 16, color)
  -- 「正/反」字（16px，居中）
  local face = (side == 1) and "正" or "反"
  screen.text(face, COIN_X + (COIN_S - 16) / 2, COIN_Y + (COIN_S - 16) / 2, FACE_TEXT)
end

local function draw_rate_bar()
  -- 进度条：正面频率 0~100%，中间 50% 刻度线（大数定律收敛目标）
  local bar_x = 20
  local bar_y = 156
  local bar_w = 200
  local bar_h = 14
  screen.rect(bar_x, bar_y, bar_w, bar_h, BAR_BG)
  local rate = 0.5
  if total > 0 then rate = heads / total end
  local fill_w = math.floor(bar_w * rate + 0.5)
  if fill_w > 0 then
    screen.rect(bar_x, bar_y, fill_w, bar_h, BAR_FILL)
  end
  -- 50% 刻度线
  screen.rect(bar_x + math.floor(bar_w / 2) - 1, bar_y - 3, 2, bar_h + 6, MID_LINE)
end

local function draw()
  screen.begin(0x172134)
  draw_bg()
  screen.text("掷硬币", 96, 4, TITLE)
  draw_coin()
  screen.text("正面 " .. heads .. " · 反面 " .. tails, 60, 134, TEXT)
  draw_rate_bar()
  local pct = "50%"
  if total > 0 then pct = tostring(math.floor(heads * 100 / total + 0.5)) .. "%" end
  screen.text("正面频率 " .. pct, 78, 176, TEXT)
  screen.text("共掷 " .. total .. " 次", 84, 198, TEXT_DIM)
  screen.present()
end

local function do_flip()
  if state == "flipping" then return end
  rng = (total_ms * 2654435761 + clicks * 97 + 1) % 2147483646 + 1
  side = rnd() < 0.5 and 1 or 0
  flip_duration = 600 + math.floor(rnd() * 400)
  elapsed = 0
  state = "flipping"
  clicks = clicks + 1
  beep(880, 40)
end

function on_start()
  side = 1
  draw()
end

function on_tick(dt_ms)
  total_ms = total_ms + dt_ms

  if state == "flipping" then
    elapsed = elapsed + dt_ms
    -- 每 60ms 翻转一次颜色，模拟硬币旋转
    if math.floor(elapsed / 60) ~= math.floor((elapsed - dt_ms) / 60) then
      side = (side == 1) and 0 or 1
      beep(600 + side * 200, 20)
    end
    if elapsed >= flip_duration then
      state = "idle"
      if side == 1 then heads = heads + 1 else tails = tails + 1 end
      total = total + 1
      beep(1320, 120)
    end
    draw()
  end
end

function on_button_click(button_id)
  if button_id ~= "function" then return end
  do_flip()
  draw()
end

function on_exit()
end
