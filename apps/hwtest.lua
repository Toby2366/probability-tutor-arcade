-- hwtest.lua - 硬件自检：1 旋钮(电位器) + 4 按钮(大按键)
-- 旋钮：旋转电位器模块 OUT -> PD4 (CH32V003 ADC ch7, 实际量程 0~1023)
-- 按钮：大按键模块 OUT -> PA01/PA00/PB07/PB06 (高电平有效: 按下=1 / 松开=0)
-- 供电：VCC 接 3.3V、GND 接 GND
-- 约束：screen.text y∈[0,224]，一帧≤16 段文字

function on_start()
end

function on_tick(dt)
    screen.begin(0x000000)

    screen.text("HW SELF TEST", 8, 2, 0x888888)

    -- ===== 旋钮（电位器）=====
    screen.text("KNOB PD4=A7", 8, 22, 0xFFFF00)
    local knob = adc.read(7)
    local kstr = (knob >= 0) and tostring(knob) or "ERR"
    local pct = 0
    if knob > 0 then
        pct = math.floor(knob * 100 / 1023)
        if pct > 100 then pct = 100 end
    end
    screen.text("raw " .. kstr .. "  " .. pct .. "%", 8, 40, 0xFFFF00)

    screen.rect(8, 60, 224, 12, 0x2A2A2A)
    if knob > 0 then
        local fill = math.floor(224 * knob / 1023)
        if fill > 224 then fill = 224 end
        screen.rect(8, 60, fill, 12, 0x0066FF)
    end

    -- ===== 4 按钮 GPIO =====
    local btns = {
        { "← PA01", "a", 1, 86 },
        { "↑ PA00", "a", 0, 116 },
        { "↓ PB07", "b", 7, 146 },
        { "→ PB06", "b", 6, 176 },
    }
    for i = 1, #btns do
        local y = btns[i][4]
        screen.text(btns[i][1], 8, y, 0xBBBBBB)
        local v = gpio.read(btns[i][2], btns[i][3])
        if v == 1 then
            screen.rect(70, y - 3, 162, 24, 0x00CC00)
            screen.text("PRESSED", 108, y, 0x000000)
        elseif v == 0 then
            screen.rect(70, y - 3, 162, 24, 0x2A2A2A)
            screen.text("RELEASED", 102, y, 0xFFFFFF)
        else
            screen.rect(70, y - 3, 162, 24, 0x550000)
            screen.text("ERR", 130, y, 0xFFFFFF)
        end
    end

    -- 返回方式：单击板载侧键（走 on_button_click 退出，见文件末尾）
    screen.text("侧键 退出", 164, 222, 0x888888)

    screen.present()
end

function on_button_click(id)
    -- 侧键单击 = 退出自检页
    if id ~= "function" then return end
    if app and app.exit then app.exit() end
end
