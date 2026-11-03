// 无头回归：fengari 跑 arcade.lua，假屏幕严格复刻 C 层的参数校验
// （luaL_checkinteger 拒收浮点、rect 要求 w/h>=1、text y<=224），
// 这样「平衡挑战闪退」这类问题在本地就能复现，不用烧板子试。
const fs = require('fs');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function run(name, code) {
  const s = lauxlib.luaL_loadbuffer(L, to_luastring(code), code.length, to_luastring(name));
  if (s !== lua.LUA_OK) { console.log('LOAD FAIL', name, lua.lua_tojsstring(L, -1)); process.exit(1); }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) { console.log('RUN FAIL', name, lua.lua_tojsstring(L, -1)); process.exit(1); }
}

run('prologue', `
SIM = { keys = {}, knob = 512, t = 0, shapes = {}, texts = {}, frames = 0, scene = nil }

local function chk_int(v, where)
  if type(v) ~= "number" then error(where .. ": expected number, got " .. type(v)) end
  if v % 1 ~= 0 then error(where .. ": number has no integer representation (" .. tostring(v) .. ")") end
  return v
end
local function chk_range(v, lo, hi, where)
  if v < lo or v > hi then error(where .. ": out of range (" .. tostring(v) .. ")") end
  return v
end

screen = {
  begin = function(c)
    SIM.shapes, SIM.texts = {}, {}
    SIM.bg = c
  end,
  rect = function(x, y, w, h, c)
    chk_int(x, "rect#1"); chk_int(y, "rect#2"); chk_int(w, "rect#3"); chk_int(h, "rect#4")
    chk_range(x, 0, 239, "rect#1"); chk_range(y, 0, 239, "rect#2")
    chk_range(w, 1, 240, "rect#3"); chk_range(h, 1, 240, "rect#4")
    if x + w > 240 or y + h > 240 then error("invalid rectangle") end
    SIM.shapes[#SIM.shapes + 1] = { k = "rect", x = x, y = y, w = w, h = h, c = c }
  end,
  circle = function(x, y, r, c)
    chk_int(x, "circle#1"); chk_int(y, "circle#2"); chk_int(r, "circle#3")
    chk_range(r, 1, 240, "circle#3")
    SIM.shapes[#SIM.shapes + 1] = { k = "circle", x = x, y = y, r = r, c = c }
  end,
  line = function(x1, y1, x2, y2, c)
    chk_int(x1, "line#1"); chk_int(y1, "line#2"); chk_int(x2, "line#3"); chk_int(y2, "line#4")
    chk_range(x1, -240, 480, "line#1"); chk_range(y1, -240, 480, "line#2")
    chk_range(x2, -240, 480, "line#3"); chk_range(y2, -240, 480, "line#4")
    SIM.shapes[#SIM.shapes + 1] = { k = "line", x1 = x1, y1 = y1, x2 = x2, y2 = y2, c = c }
  end,
  text = function(s, x, y, c)
    chk_int(x, "text#2"); chk_int(y, "text#3")
    chk_range(x, 0, 239, "text#2"); chk_range(y, 0, 224, "text#3")
    if #SIM.texts >= 32 then error("screen.text limit is 32") end
    SIM.texts[#SIM.texts + 1] = { s = s, x = x, y = y, c = c }
  end,
  present = function() SIM.frames = SIM.frames + 1 end,
}
gpio = { read = function(bank, pin) return SIM.keys[bank .. pin] or 0 end }
adc = { read = function(ch) return SIM.knob end }
buzzer = { play = function() end }
clock = { ms = function() return SIM.t end, now = function() return 0 end }
app = { width = 240, height = 240, exit = function() SIM.exited = true end }

-- synth.play 的严格复刻：C 侧对每个 note 做 luaL_checkinteger + 范围校验，
-- 同一 voice 上的音符排序后不能重叠，否则直接抛错（真机上就是整个安装失败）。
SIM.sfx_calls, SIM.sfx_notes = 0, 0
synth = {
  play = function(notes, opts)
    if type(notes) ~= "table" then error("score must be a table") end
    local n = #notes
    if n < 1 or n > 256 then error("score requires 1..256 notes (got " .. n .. ")") end
    local list = {}
    for i = 1, n do
      local t = notes[i]
      local at = chk_int(t.at, "note.at")
      local ms = chk_int(t.ms, "note.ms")
      local hz = chk_int(t.hz, "note.hz")
      local voice = chk_int(t.voice, "note.voice")
      local vol = chk_int(t.volume, "note.volume")
      chk_range(at, 0, 60000, "note.at")
      chk_range(ms, 20, 3000, "note.ms")
      chk_range(hz, 50, 5000, "note.hz")
      chk_range(voice, 1, 4, "note.voice")
      chk_range(vol, 0, 100, "note.volume")
      if t.wave ~= "square" and t.wave ~= "triangle" and t.wave ~= "noise" then
        error("note.wave must be square|triangle|noise (got " .. tostring(t.wave) .. ")")
      end
      if at + ms > 60000 then error("score exceeds 60 seconds") end
      list[#list + 1] = { at = at, ms = ms, voice = voice }
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    local ends = { 0, 0, 0, 0 }
    for _, t in ipairs(list) do
      if t.at < ends[t.voice] then
        error("notes overlap on voice " .. t.voice .. " at " .. t.at .. "ms")
      end
      ends[t.voice] = t.at + t.ms
    end
    SIM.sfx_calls = SIM.sfx_calls + 1
    SIM.sfx_notes = SIM.sfx_notes + n
  end,
}
`);

// 按 UTF-8 读：latin1 读进来再 to_luastring 会二次编码，导致中文字符串比较永远不相等
run('arcade', fs.readFileSync(process.argv[2], 'utf8'));

run('driver', `
on_start()
local t = 0
local function tick(dt)
  SIM.t = t
  on_tick(dt or 20)
end
local function tap(key)
  SIM.keys[key] = 1; t = t + 20; tick()
  SIM.keys[key] = 0; t = t + 20; tick()
end
local function title()
  return SIM.texts[1] and SIM.texts[1].s or "?"
end
local function has(s)
  for _, x in ipairs(SIM.texts) do
    if x.s == s or x.s:find(s, 1, true) then return true end
  end
  return false
end
local function back_hint()
  for _, x in ipairs(SIM.texts) do
    if x.s == "侧键 返回" or x.s == "侧键 退出" then return x end
  end
  return nil
end

tick()
print("[菜单] 首屏标题=" .. title() .. " 返回提示=" .. tostring(back_hint() and back_hint().s))

-- 逐项进入主菜单，检查每页都有返回提示且不报错
local names = { "贪吃蛇", "概率实验室", "平衡挑战", "打靶", "2048" }
for i, want in ipairs(names) do
  on_start(); t = 0; tick()
  for _ = 2, i do tap("b7") end          -- 下移到第 i 项
  tap("b6")                              -- 进入
  if i <= 4 then tick() end
  local h = back_hint()
  print(string.format("[%s] 标题=%s 返回提示=%s", want, title(), h and h.s or "缺失!"))
end

-- 概率实验室六个子项
for i = 1, 6 do
  on_start(); t = 0; tick()
  tap("b7"); tap("b6")
  for _ = 2, i do tap("b7") end
  tap("b6")
  tick()
  local h = back_hint()
  print(string.format("[概率-%d] 标题=%s 返回提示=%s", i, title(), h and h.s or "缺失!"))
end

-- 平衡挑战：1) 旋钮打两端不能崩（原来 180.0 这种浮点直接抛错）
--           2) 什么都不做能撑多久 3) 反向修正能否救回来
on_start(); t = 0; tick()
tap("b7"); tap("b7"); tap("b6")
for _, kk in ipairs({ 0, 512, 1023, 300, 800 }) do
  SIM.knob = kk
  for _ = 1, 5 do t = t + 20; tick() end
end
print("[平衡] 旋钮 0/512/1023 各跑 5 帧 => 无异常, 标题=" .. title())

local function run_balance(knob_fn, max_s)
  on_start(); t = 0; tick()
  tap("b7"); tap("b7"); tap("b6")
  local ms, ball_x = 0, nil
  for i = 1, max_s * 50 do
    SIM.knob = knob_fn(ball_x)
    t = t + 20; tick(); ms = ms + 20
    ball_x = nil
    for _, s in ipairs(SIM.shapes) do
      if s.k == "circle" and s.r == 6 then ball_x = s.x end
    end
    if has("→重开") then break end
  end
  return ms / 1000, ball_x
end

local idle, _ = run_balance(function() return 512 end, 60)
print(string.format("[平衡] 不操作存活 %.1fs（目标 10~30s）", idle))

local alive, bx = run_balance(function(x)
  if not x then return 512 end
  if x > 126 then return 120 elseif x < 114 then return 900 end
  return 512
end, 60)
print(string.format("[平衡] 比例修正存活 %.1fs 末位置=%s", alive, tostring(bx)))

-- 打靶：每发准星要重新随机
on_start(); t = 0; tick()
tap("b7"); tap("b7"); tap("b7"); tap("b6")   -- 第 4 项 = 打靶
local function crosshair()
  for _, s in ipairs(SIM.shapes) do
    if s.c == 0xF4C64A and s.k == "rect" and s.w == 2 and s.h == 12 then return s.x + 1 end
  end
  return nil
end
local function hole()
  local last = nil
  for _, s in ipairs(SIM.shapes) do
    if s.k == "rect" and s.w == 4 and s.h == 4 and s.c == 0x000000 then last = s.x + 2 end
  end
  return last
end
local aims, holes = {}, {}
for shot = 1, 5 do
  tick()
  aims[#aims + 1] = crosshair()
  tap("b6")            -- 发射
  tick()
  holes[#holes + 1] = hole()
  tap("b6")            -- 下一发
end
local same, maxdev = 0, 0
for i = 2, #aims do if aims[i] == aims[i - 1] then same = same + 1 end end
for i = 1, #aims do
  local d = math.abs((holes[i] or 0) - aims[i])
  if d > maxdev then maxdev = d end
end
print("[打靶] 五发准星 x = " .. table.concat(aims, ",") .. "  相邻相同=" .. same ..
      "  落点偏离准星最大=" .. maxdev .. "px (抖动上限 11)")

-- 瞄准靶心再打：环数应该很高
on_start(); t = 0; tick()
tap("b7"); tap("b7"); tap("b7"); tap("b6")
tick()
local kk = 512
for i = 1, 200 do
  local cx = crosshair()
  if not cx then break end
  if math.abs(cx - 120) <= 2 then break end
  kk = kk + ((cx < 120) and 24 or -24)
  if kk < 0 then kk = 0 elseif kk > 1023 then kk = 1023 end
  SIM.knob = kk
  t = t + 20; tick()
end
local cx = crosshair()
tap("b6"); tick()
local ring_txt = ""
for _, x in ipairs(SIM.texts) do
  if x.s:find("环", 1, true) and #x.s <= 6 then ring_txt = x.s end
end
print("[打靶] 瞄到 x=" .. tostring(cx) .. " 后命中 " .. ring_txt .. "（靶心应 8~10 环）")

-- 2048：连续按方向键，看分数与文字数是否健康
on_start(); t = 0; tick()
for _ = 2, 5 do tap("b7") end
tap("b6")
tick()
local dirs = { "a1", "a0", "b6", "b7" }
local maxtext = 0
for i = 1, 60 do
  tap(dirs[(i % 4) + 1])
  if #SIM.texts > maxtext then maxtext = #SIM.texts end
end
local score_txt = ""
for _, x in ipairs(SIM.texts) do
  if x.s:find("分 ", 1, true) then score_txt = x.s end
end
print("[2048] 60 步后 " .. score_txt .. " 单帧最多文字=" .. maxtext .. " (上限 32)")

-- 压力测试：每个页面旋钮扫全量程 + 随机按键 80 帧，任何参数越界都会立刻抛错
local dirs2 = { "a0", "b7", "a1", "b6" }
local function stress(label, nav)
  local ok, err = pcall(function()
    on_start(); t = 0; tick()
    nav()
    for i = 1, 80 do
      SIM.knob = (i * 137) % 1024
      SIM.keys = {}
      local kk = dirs2[(i % 4) + 1]
      if (i % 7) == 0 then SIM.keys[kk] = 1 end
      t = t + 20; tick()
      SIM.keys = {}
      t = t + 20; tick()
    end
  end)
  print(string.format("[压力] %-8s %s", label, ok and "OK" or ("抛错: " .. tostring(err))))
end
stress("贪吃蛇", function() tap("b6"); tap("b6") end)
stress("掷骰子", function() tap("b7"); tap("b6"); tap("b6") end)
stress("掷硬币", function() tap("b7"); tap("b6"); tap("b7"); tap("b6") end)
stress("高尔顿", function() tap("b7"); tap("b6"); tap("b7"); tap("b7"); tap("b6") end)
stress("频率收敛", function() tap("b7"); tap("b6"); tap("b7"); tap("b7"); tap("b7"); tap("b6") end)
stress("蒙提霍尔", function() tap("b7"); tap("b6"); tap("b7"); tap("b7"); tap("b7"); tap("b7"); tap("b6") end)
stress("二项分布", function() tap("b7"); tap("b6"); tap("b7"); tap("b7"); tap("b7"); tap("b7"); tap("b7"); tap("b6") end)
stress("平衡挑战", function() tap("b7"); tap("b7"); tap("b6") end)
stress("打靶", function() tap("b7"); tap("b7"); tap("b7"); tap("b6") end)
stress("2048", function() tap("b7"); tap("b7"); tap("b7"); tap("b7"); tap("b6") end)

-- 骰子：按 → 后要有 830ms 的抖动滚动（点数乱跳 + 方块位移），然后落定计入统计
on_start(); t = 0; tick()
tap("b7"); tap("b6"); tap("b6")          -- 主菜单 -> 概率实验室 -> 掷骰子
local function dice_box()
  for _, s in ipairs(SIM.shapes) do
    if s.k == "rect" and s.w == 80 and s.h == 80 then return s end
  end
end
local sfx0 = SIM.sfx_calls
t = t + 20; tick()
tap("b6")                                 -- 掷
local frames, xs = 0, {}
for i = 1, 80 do
  t = t + 20; tick()
  frames = frames + 1
  local b = dice_box()
  if b then xs[#xs + 1] = b.x end
  if has("→掷") and frames > 5 then break end
end
local distinct = {}
for _, x in ipairs(xs) do distinct[x] = true end
local nd = 0
for _ in pairs(distinct) do nd = nd + 1 end
print(string.format("[骰子] 滚动 %d 帧(%dms)、白块 %d 种 x 位置、掷后音效 +%d、落定提示=%s",
      frames, frames * 20, nd, SIM.sfx_calls - sfx0, tostring(has("共掷 1 次"))))


-- 逐条校验全部音效乐谱（需要 _SFX_DUMP 钩子：把 arcade.lua 副本末尾加一行 _SFX_DUMP = S）
if _SFX_DUMP then
  local names = {}
  for k in pairs(_SFX_DUMP) do names[#names + 1] = k end
  table.sort(names)
  local bad = 0
  for _, k in ipairs(names) do
    local ok, err = pcall(synth.play, _SFX_DUMP[k])
    if not ok then bad = bad + 1; print("  [非法] " .. k .. " => " .. tostring(err)) end
  end
  print(string.format("[音效] %d 组乐谱全部过校验，非法 %d 组", #names, bad))
end

-- 侧键返回：主菜单 -> 退出；游戏内 -> 回到上一级
on_start(); t = 0; tick()
tap("b7"); tap("b6"); tick()        -- 进概率实验室
on_button_click("function"); tick()
print("[侧键] 概率实验室 -> 标题=" .. title())
on_button_click("function"); tick()
print("[侧键] 主菜单 -> 退出=" .. tostring(SIM.exited))
`);
