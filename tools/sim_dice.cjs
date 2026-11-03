// 无头回归：独立「掷骰子」应用（dice.lua）的动画与音效
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
SIM = { shapes = {}, frames = 0, sfx = 0 }
local function chk_int(v, where)
  if type(v) ~= "number" then error(where .. ": expected number, got " .. type(v)) end
  if v % 1 ~= 0 then error(where .. ": number has no integer representation (" .. tostring(v) .. ")") end
  return v
end
screen = {
  begin = function() SIM.shapes = {} end,
  rect = function(x, y, w, h, c)
    chk_int(x, "rect#1"); chk_int(y, "rect#2"); chk_int(w, "rect#3"); chk_int(h, "rect#4")
    if w < 1 or h < 1 or x < 0 or y < 0 or x + w > 240 or y + h > 240 then error("invalid rectangle") end
    SIM.shapes[#SIM.shapes + 1] = { k = "rect", x = x, y = y, w = w, h = h, c = c }
  end,
  text = function(s, x, y, c)
    chk_int(x, "text#2"); chk_int(y, "text#3")
    if y < 0 or y > 224 then error("text y out of range") end
    SIM.shapes[#SIM.shapes + 1] = { k = "text", s = s, x = x, y = y, c = c }
  end,
  present = function() SIM.frames = SIM.frames + 1 end,
}
gpio = { read = function() return 0 end }
adc = { read = function() return 512 end }
buzzer = { play = function() end }
synth = { play = function(notes)
  local n = #notes
  if n < 1 or n > 256 then error("bad note count") end
  local list = {}
  for i = 1, n do
    local t = notes[i]
    for _, k in ipairs({ "at", "ms", "hz", "voice", "volume" }) do
      if type(t[k]) ~= "number" or t[k] % 1 ~= 0 then error("note." .. k .. " not integer") end
    end
    if t.ms < 20 or t.ms > 3000 then error("note.ms range") end
    if t.hz < 50 or t.hz > 5000 then error("note.hz range") end
    if t.voice < 1 or t.voice > 4 then error("note.voice range") end
    if t.volume < 0 or t.volume > 100 then error("note.volume range") end
    if t.wave ~= "square" and t.wave ~= "triangle" and t.wave ~= "noise" then error("bad wave") end
    list[#list + 1] = t
  end
  table.sort(list, function(a, b) return a.at < b.at end)
  local ends = { 0, 0, 0, 0 }
  for _, t in ipairs(list) do
    if t.at < ends[t.voice] then error("notes overlap on voice " .. t.voice) end
    ends[t.voice] = t.at + t.ms
  end
  SIM.sfx = SIM.sfx + 1
end }
`);

run('dice', fs.readFileSync(process.argv[2], 'utf8'));

run('driver', `
on_start()
local function box()
  for _, s in ipairs(SIM.shapes) do
    if s.k == "rect" and s.w == 96 and s.h == 96 then return s end
  end
end
local before = SIM.sfx
on_button_click("function")
local xs, frames = {}, 0
for i = 1, 80 do
  on_tick(20); frames = frames + 1
  local b = box()
  if b then xs[#xs + 1] = b.x end
  local landed = false
  for _, sh in ipairs(SIM.shapes) do
    if sh.k == "text" and sh.s == "共掷 1 次" then landed = true end
  end
  if landed then break end
end
local distinct = {}
for _, x in ipairs(xs) do distinct[x] = true end
local nd = 0
for _ in pairs(distinct) do nd = nd + 1 end
print(string.format("[掷骰子] 滚动 %d 帧(%dms)、方块 %d 种 x 位置(抖动)、音效调用 +%d、帧数=%d",
      frames, frames * 20, nd, SIM.sfx - before, SIM.frames))
`)
