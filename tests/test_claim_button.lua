#!/usr/bin/env luajit
-- ==========================================================================
-- tests/test_claim_button.lua - Tests for lua/tac/claim_button.lua
--
-- Runs under plain LuaJIT 2.1, no MacroQuest needed. Loads the real plugin
-- file, tests its pure logic (plugin.logic) and drives its TAC hooks against
-- stub mq / ImGui / core objects that also check every ImGui push and Begin
-- is balanced.
--
-- Usage:  luajit tests/test_claim_button.lua
-- Exit:   0 when every test passes, 1 otherwise.
-- ==========================================================================

local pass, fail, errors = 0, 0, {}

local function check(cond, label)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        errors[#errors + 1] = '  FAIL: ' .. label
    end
end

local function eq(got, expect, label)
    check(got == expect, string.format('%s (expected %s, got %s)', label, tostring(expect), tostring(got)))
end

local function section(name)
    print('-- ' .. name)
end

-- --------------------------------------------------------------------------
-- Load the plugin
-- --------------------------------------------------------------------------
local here = (arg and arg[0] or ''):match('^(.*)[/\\]') or '.'
local pluginPath = here .. '/../lua/tac/claim_button.lua'
local chunk = assert(loadfile(pluginPath))
local plugin = chunk()   -- must not touch mq / ImGui while loading (TAC rejects that)
local logic = plugin.logic
local L = logic.LIMITS

-- --------------------------------------------------------------------------
section('plugin table')
-- --------------------------------------------------------------------------
eq(plugin.id, 'claim_button', 'id')
eq(plugin.defaultEnabled, true, 'enabled by default (On column)')
eq(plugin.runOutOfCombatOnly, false, 'ticks in combat (Cbt column)')
eq(plugin.window and plugin.window.flag, 'show_claim_button', 'window flag (Show/Hide)')
eq(plugin.window and plugin.window.headerButton, true, 'header button (Hdr column)')
eq(plugin.uses, nil, 'no dependencies (Uses column empty)')
for _, hook in ipairs({ 'onInit', 'onDestroy', 'onTick', 'onDrawUI', 'onDrawSettings', 'onLoadSettings', 'onSaveSettings', 'onZoned', 'onCommand' }) do
    eq(type(plugin[hook]), 'function', 'hook ' .. hook)
end

-- --------------------------------------------------------------------------
section('parseStatusLine')
-- --------------------------------------------------------------------------
local function parsed(line)
    local looter, name = logic.parseStatusLine(line)
    return tostring(looter) .. '|' .. tostring(name)
end
eq(parsed('[NMS] Active looter: you.'), 'me|you', 'you')
eq(parsed('[NMS] Active looter: You'), 'me|You', 'You, no period')
eq(parsed('[NMS] Active looter: Bob.'), 'other|Bob', 'another player')
eq(parsed('[NMS] Active looter: none.'), 'none|none', 'none')
eq(parsed('[NMS] Active looter: Nobody.'), 'none|Nobody', 'nobody')
eq(parsed('[NMS] Active looter: no one.'), 'none|no one', 'no one')
eq(parsed('[16:35:39] [NMS] Active looter: you.'), 'me|you', 'chat timestamp')
eq(parsed("Bob says, '[NMS] Active looter: you.'"), 'nil|nil', 'quoted by a player')
eq(parsed('[NMS] Offers waiting: 0 (0 items).'), 'nil|nil', 'offers line')
eq(parsed('[Triune NMS] Active looter is now Bob.'), 'nil|nil', 'nmsloot announcement')
eq(parsed('[NMS] Active looter: .'), 'nil|nil', 'empty name')
eq(parsed(nil), 'nil|nil', 'nil line')

-- --------------------------------------------------------------------------
section('clamps')
-- --------------------------------------------------------------------------
eq(logic.clampPollSec(nil), 60, 'poll nil -> default')
eq(logic.clampPollSec('abc'), 60, 'poll text -> default')
eq(logic.clampPollSec(0 / 0), 60, 'poll NaN -> default')
eq(logic.clampPollSec(1), 5, 'poll below min')
eq(logic.clampPollSec(-5), 5, 'poll negative')
eq(logic.clampPollSec(5), 5, 'poll min')
eq(logic.clampPollSec('30'), 30, 'poll numeric string')
eq(logic.clampPollSec(59.6), 60, 'poll rounds')
eq(logic.clampPollSec(600), 600, 'poll max')
eq(logic.clampPollSec(601), 600, 'poll above max')
eq(logic.clampPollSec(1e12), 600, 'poll huge')
eq(L.POLL_DEFAULT_SEC, 60, 'default poll 60 s')
eq(logic.clampIdleAlpha(nil), 40, 'idle nil -> default')
eq(logic.clampIdleAlpha(0), 10, 'idle below min')
eq(logic.clampIdleAlpha(150), 100, 'idle above max')
eq(logic.clampIdleAlpha(55.4), 55, 'idle rounds')

-- --------------------------------------------------------------------------
section('isOwnKill')
-- --------------------------------------------------------------------------
local names = { varthak = true, kabobab = true, bob = true }
eq(logic.isOwnKill('Varthak', names), true, 'me, case-insensitive')
eq(logic.isOwnKill(' Kabobab ', names), true, 'pet, trimmed')
eq(logic.isOwnKill('Bob', names), true, 'group member')
eq(logic.isOwnKill('Stranger', names), false, 'outsider')
eq(logic.isOwnKill('', names), false, 'empty')
eq(logic.isOwnKill(nil, names), false, 'nil slayer')
eq(logic.isOwnKill('Bob', nil), false, 'nil names')

-- --------------------------------------------------------------------------
section('query scheduler')
-- --------------------------------------------------------------------------
local cfgOn = { pollEnabled = true, pollSec = 60 }
local cfgOff = { pollEnabled = false, pollSec = 60 }
local s = logic.newState()
logic.request(s, 'start', 2)
eq(logic.nextQuery(s, cfgOn, 1), nil, 'start not due yet')
eq(logic.nextQuery(s, cfgOn, 2), 'start', 'start due')
logic.markSent(s, 'start', 2)
eq(logic.nextQuery(s, cfgOn, 3), nil, 'in flight blocks')
logic.applyReply(s, 'other', 'Bob', 2.5)
eq(s.looter, 'other', 'reply sets looter')
eq(s.inFlightAt, nil, 'reply ends in-flight')
eq(logic.nextQuery(s, cfgOn, 62.4), nil, 'poll not due before 60 s')
eq(logic.nextQuery(s, cfgOn, 62.5), 'poll', 'poll due 60 s after the reply')
eq(logic.nextQuery(s, cfgOff, 200), nil, 'poll off never polls')
logic.applyReply(s, 'other', 'Bob', 30)
eq(logic.nextQuery(s, cfgOn, 62.5), nil, 'any reply restarts the timer')
eq(logic.nextQuery(s, cfgOn, 90), 'poll', 'poll due 60 s after the newest reply')

s = logic.newState()
eq(logic.nextQuery(s, cfgOn, 1000), nil, 'no poll before the first query or reply')
logic.markSent(s, 'manual', 10)
logic.request(s, 'manual', 11)
eq(logic.nextQuery(s, cfgOn, 14.9), nil, 'unanswered query blocks until timeout')
eq(logic.nextQuery(s, cfgOn, 15), 'manual', 'timeout frees the next query')
logic.markSent(s, 'manual', 15)
eq(logic.nextQuery(s, cfgOn, 74.9), nil, 'silent server: poll counts from the last query')
eq(logic.nextQuery(s, cfgOn, 75), 'poll', 'silent server: one poll per period')

s = logic.newState()
logic.scheduleKill(s, 100)
eq(s.due.kill, 101, 'kill asks one second later')
logic.scheduleKill(s, 100.5)
eq(s.due.kill, 101, 'a second kill shares the queued query')
eq(logic.nextQuery(s, cfgOff, 101), 'kill', 'kill due')
logic.markSent(s, 'kill', 101)
logic.applyReply(s, 'me', 'you', 101.2)
logic.scheduleKill(s, 103)
eq(s.due.kill, 111, 'kill inside the 10 s gap waits for it')
eq(logic.nextQuery(s, cfgOff, 110.9), nil, 'gap holds the kill query')
eq(logic.nextQuery(s, cfgOff, 111), 'kill', 'kill query after the gap')

s = logic.newState()
logic.request(s, 'start', 50)
logic.request(s, 'zone', 50)
logic.request(s, 'manual', 50)
logic.scheduleKill(s, 40)
logic.applyReply(s, 'none', 'none', 40.5)
eq(s.due.start, nil, 'reply answers start')
eq(s.due.zone, nil, 'reply answers zone')
eq(s.due.manual, nil, 'reply answers manual')
eq(s.due.kill, 41, 'reply before the kill delay keeps the kill query')
logic.request(s, 'manual', 60)
logic.request(s, 'manual', 55)
eq(s.due.manual, 55, 'earlier request wins')

s = logic.newState()
logic.request(s, 'start', 1)
logic.request(s, 'manual', 1)
eq(logic.nextQuery(s, cfgOn, 2, true), 'manual', 'closed: a query the player asked for goes out')
logic.markSent(s, 'manual', 2)
logic.applyReply(s, 'me', 'you', 2.1)
logic.request(s, 'kill', 3)
logic.request(s, 'zone', 3)
eq(logic.nextQuery(s, cfgOn, 100, true), nil, 'closed: no poll, kill or zone query')
logic.request(s, 'claim', 100)
eq(logic.nextQuery(s, cfgOn, 100, true), 'claim', 'closed: claim confirm goes out')

s = logic.newState()
s.visible = true
logic.setVisible(s, false, 10)
eq(s.due.show, nil, 'closing asks nothing')
logic.setVisible(s, true, 20)
eq(s.due.show, 20, 'showing again asks at once')
logic.setVisible(s, true, 21)
eq(s.due.show, 20, 'staying open asks nothing more')
s = logic.newState()
logic.setVisible(s, true, 5)
eq(s.due.show, nil, 'the first look is not "shown again"')

-- --------------------------------------------------------------------------
section('claim')
-- --------------------------------------------------------------------------
s = logic.newState()
eq(logic.clickAction(s, 0), 'ask', 'unknown: click asks')
s.looter = 'other'
eq(logic.clickAction(s, 0), 'claim', 'other: click claims')
s.looter = 'none'
eq(logic.clickAction(s, 0), 'claim', 'nobody: click claims')
s.looter = 'me'
eq(logic.clickAction(s, 0), nil, 'me: click does nothing')

s = logic.newState()
s.looter = 'other'
logic.markClaim(s, 200)
eq(s.due.claim, 201.5, 'confirm query 1.5 s after the claim')
eq(logic.claimPending(s, 200.5), true, 'pending after the claim')
eq(logic.clickAction(s, 200.5), nil, 'pending ignores clicks')
logic.applyReply(s, 'me', 'you', 200.8)
eq(logic.claimPending(s, 201), true, 'an early reply does not end the claim')
eq(s.due.claim, 201.5, 'an early reply keeps the confirm query')
eq(logic.nextQuery(s, cfgOff, 201.5), 'claim', 'confirm query due')
logic.markSent(s, 'claim', 201.5)
logic.applyReply(s, 'me', 'you', 201.7)
eq(logic.claimPending(s, 201.7), false, 'confirm reply ends the claim')

s = logic.newState()
logic.markClaim(s, 300)
eq(logic.claimPending(s, 306.4), true, 'unanswered claim still pending')
eq(logic.claimPending(s, 306.5), false, 'unanswered claim times out')

-- --------------------------------------------------------------------------
section('fade')
-- --------------------------------------------------------------------------
eq(logic.fadeAlpha(10, 10.4, 0.4), 1, 'opaque while within the delay')
eq(logic.fadeAlpha(10, 10.5, 0.4), 1, 'opaque at exactly half a second')
check(math.abs(logic.fadeAlpha(10, 10.625, 0.4) - 0.7) < 1e-9, 'half way through the fade')
eq(logic.fadeAlpha(10, 11, 0.4), 0.4, 'idle opacity reached')
eq(logic.fadeAlpha(10, 99, 1), 1, '100 never fades')

-- --------------------------------------------------------------------------
section('settings')
-- --------------------------------------------------------------------------
plugin.onLoadSettings({ pollEnabled = false, pollSec = 2, queryOnKill = false, idleAlpha = 500 })
eq(plugin.cfg.pollEnabled, false, 'load pollEnabled')
eq(plugin.cfg.pollSec, 5, 'load pollSec clamped')
eq(plugin.cfg.queryOnKill, false, 'load queryOnKill')
eq(plugin.cfg.idleAlpha, 100, 'load idleAlpha clamped')
plugin.onLoadSettings('junk')
eq(plugin.cfg.pollSec, 5, 'non-table settings ignored')
plugin.onLoadSettings({ pollSec = 'abc' })
eq(plugin.cfg.pollSec, 60, 'invalid pollSec -> default')
local saved = plugin.onSaveSettings()
plugin.onLoadSettings({ pollEnabled = true, pollSec = 120, queryOnKill = true, idleAlpha = 25 })
plugin.onLoadSettings(saved)
eq(plugin.cfg.pollSec, 60, 'round trip pollSec')
eq(plugin.cfg.pollEnabled, false, 'round trip pollEnabled')
eq(plugin.cfg.idleAlpha, 100, 'round trip idleAlpha')
plugin.onLoadSettings({ pollEnabled = true, pollSec = 60, queryOnKill = true, idleAlpha = 40 })

-- --------------------------------------------------------------------------
-- Stubs for the TAC hooks
-- --------------------------------------------------------------------------
local clock = 0
plugin.clock = function() return clock end

local enumMeta = { __index = function(t, k) local v = rawget(t, '_n') + 1; rawset(t, '_n', v); rawset(t, k, v); return v end }
local function enum() return setmetatable({ _n = 0 }, enumMeta) end
ImGuiCol, ImGuiStyleVar, ImGuiWindowFlags, ImGuiHoveredFlags, ImGuiCond = enum(), enum(), enum(), enum(), enum()
ImVec2 = function(x, y) return { x = x, y = y } end

local ui = { styleVars = 0, styleColors = 0, windows = 0, popups = 0, maxBad = nil,
             buttonClicked = false, popupOpen = false, hovered = false, triangles = 0, tooltips = {},
             active = false, dragging = false, dragDelta = { 0, 0 }, movedTo = nil, varValues = {} }
local function bad(msg) ui.maxBad = ui.maxBad or msg end
ImGui = {
    Begin = function() ui.windows = ui.windows + 1; return true, true end,
    End = function() ui.windows = ui.windows - 1; if ui.windows < 0 then bad('End without Begin') end end,
    PushStyleVar = function(idx, v) ui.styleVars = ui.styleVars + 1; ui.varValues[idx] = v end,
    PopStyleVar = function(n) ui.styleVars = ui.styleVars - (n or 1); if ui.styleVars < 0 then bad('PopStyleVar underflow') end end,
    PushStyleColor = function() ui.styleColors = ui.styleColors + 1 end,
    PopStyleColor = function(n) ui.styleColors = ui.styleColors - (n or 1); if ui.styleColors < 0 then bad('PopStyleColor underflow') end end,
    SetNextWindowSize = function() end,
    SetNextItemWidth = function() end,
    GetContentRegionAvail = function() return 60, 30 end,
    GetWindowPos = function() return 100, 100 end,
    GetWindowSize = function() return 60, 30 end,
    GetMousePos = function() return 0, 0 end,
    GetFontSize = function() return 13 end,
    GetStyle = function() return { FrameRounding = 4 } end,
    GetStyleColorVec4 = function() return { x = 0.26, y = 0.59, z = 0.98, w = 0.2 } end,
    GetWindowDrawList = function() return { AddTriangleFilled = function() ui.triangles = ui.triangles + 1 end } end,
    Button = function(label) if label == '##claimButton' then local c = ui.buttonClicked; ui.buttonClicked = false; return c end return false end,
    SmallButton = function() return false end,
    IsItemHovered = function() return ui.hovered end,
    IsItemActive = function() return ui.active end,
    IsMouseDragging = function() return ui.dragging end,
    GetMouseDragDelta = function() return ui.dragDelta[1], ui.dragDelta[2] end,
    ResetMouseDragDelta = function() ui.dragDelta = { 0, 0 } end,
    SetWindowPos = function(x, y) ui.movedTo = { x, y } end,
    IsWindowHovered = function() return ui.hovered end,
    IsMouseDown = function() return false end,
    BeginPopupContextItem = function() if ui.popupOpen then ui.popups = ui.popups + 1; return true end return false end,
    EndPopup = function() ui.popups = ui.popups - 1; if ui.popups < 0 then bad('EndPopup without Begin') end end,
    TextDisabled = function() end,
    Separator = function() end,
    Spacing = function() end,
    SameLine = function() end,
    SliderInt = function(_, v) return v end,
    Checkbox = function(_, v) return v end,
}

local tlo = { gameState = 'CHARSELECT', me = 'Varthak', pet = 'Kabobab', group = { 'Bob' } }
local function val(v) return function() return v end end
local function spawnOf(name, pet)
    return { CleanName = val(name), Pet = { CleanName = val(pet) } }
end
local mqStub = {
    cmds = {}, events = {}, unevents = {},
    TLO = {
        MacroQuest = { GameState = function() return tlo.gameState end },
        Me = spawnOf(tlo.me, tlo.pet),
        Group = {
            Members = function() return #tlo.group end,
            Member = function(i) return spawnOf(tlo.group[i], nil) end,
        },
        Spawn = function() return spawnOf('', nil) end,
    },
}
mqStub.cmd = function(c) table.insert(mqStub.cmds, c) end
mqStub.event = function(name, pattern, fn) mqStub.events[name] = { pattern = pattern, fn = fn } end
mqStub.unevent = function(name) mqStub.events[name] = nil; mqStub.unevents[#mqStub.unevents + 1] = name end

local windowOpts = {}
local menuCalls = {}
local core = {
    ctrl = {}, mq = mqStub, ImGui = ImGui, colors = {},
    saveLoadout = function() end,
    pushTheme = function() end, popTheme = function() end,
    preBeginWindow = function() end, postBeginWindow = function() end, preEndWindow = function() end,
    windowFlags = function(_, f) return f end,
    windowOpts = function(key) return windowOpts[key] end,
    setWindowOpt = function(key, name, v) windowOpts[key] = windowOpts[key] or {}; windowOpts[key][name] = v or nil end,
    drawWindowMenuItems = function(key, opts) menuCalls[#menuCalls + 1] = { key = key, opts = opts } end,
    drawWindowScaleControl = function() end,
    applyWindowScale = function() end,
    px = function(n) return n end,
    accent = function() end,
    setTooltip = function(t) ui.tooltips[#ui.tooltips + 1] = t end,
}

local function balanced(label)
    eq(ui.styleVars, 0, label .. ': style vars balanced')
    eq(ui.styleColors, 0, label .. ': style colours balanced')
    eq(ui.windows, 0, label .. ': Begin/End balanced')
    eq(ui.popups, 0, label .. ': popups balanced')
    eq(ui.maxBad, nil, label .. ': no stack underflow')
end

local function lastCmd() return mqStub.cmds[#mqStub.cmds] end

-- --------------------------------------------------------------------------
section('hooks: init, tick, events')
-- --------------------------------------------------------------------------
plugin.onInit(core)
eq(core.ctrl.show_claim_button, true, 'window visible on first enable')
check(mqStub.events.ClaimButtonStatus ~= nil, 'status event registered')
check(mqStub.events.ClaimButtonSlain ~= nil, 'own kill event registered')
check(mqStub.events.ClaimButtonSlainBy ~= nil, 'slain-by event registered')

clock = 5
plugin.onTick()
eq(#mqStub.cmds, 0, 'no query outside the game')
tlo.gameState = 'INGAME'
plugin.onTick()
eq(lastCmd(), '/say #nms status', 'start query once in game')
mqStub.events.ClaimButtonStatus.fn('[NMS] Active looter: Bob.')
eq(plugin.state.looter, 'other', 'status event sets the looter')
mqStub.events.ClaimButtonStatus.fn("Bob says, '[NMS] Active looter: you.'")
eq(plugin.state.looter, 'other', 'quoted line ignored')

clock = 10
mqStub.events.ClaimButtonSlainBy.fn('a gnoll has been slain by Stranger!', 'Stranger')
eq(plugin.state.due.kill, nil, 'outsider kill ignored')
mqStub.events.ClaimButtonSlainBy.fn('a gnoll has been slain by Bob!', 'Bob')
eq(plugin.state.due.kill, 11, 'group member kill schedules a query')
plugin.state.due.kill = nil
mqStub.events.ClaimButtonSlainBy.fn('a gnoll has been slain by Kabobab!', 'Kabobab')
eq(plugin.state.due.kill, 11, 'pet kill schedules a query')
plugin.state.due.kill = nil
mqStub.events.ClaimButtonSlain.fn('You have slain a gnoll!')
eq(plugin.state.due.kill, 11, 'own kill schedules a query')
local before = #mqStub.cmds
clock = 11
plugin.onTick()
eq(#mqStub.cmds, before + 1, 'kill query sent')
mqStub.events.ClaimButtonStatus.fn('[NMS] Active looter: Bob.')

plugin.cfg.queryOnKill = false
plugin.state.due.kill = nil
mqStub.events.ClaimButtonSlain.fn('You have slain a gnoll!')
eq(plugin.state.due.kill, nil, 'kill queries off')
plugin.cfg.queryOnKill = true

plugin.onZoned()
eq(plugin.state.due.zone, 16, 'zone query 5 s after zoning')

-- --------------------------------------------------------------------------
section('hooks: drawing')
-- --------------------------------------------------------------------------
plugin.onDrawUI()
balanced('idle frame')
eq(ui.triangles, 1, 'resize grip drawn')
eq(ui.varValues[ImGuiStyleVar.FrameBorderSize], 0, 'button drawn without the theme border')

ui.hovered = true
plugin.onDrawUI()
balanced('hovered frame')
check(#ui.tooltips > 0 and ui.tooltips[#ui.tooltips]:find('Click to claim', 1, true) ~= nil, 'tooltip offers the claim')

ui.buttonClicked = true
plugin.onDrawUI()
balanced('click frame')
eq(lastCmd(), '/say #nms claim', 'click on red claims')
eq(logic.claimPending(plugin.state, clock), true, 'claim pending after click')
before = #mqStub.cmds
ui.buttonClicked = true
plugin.onDrawUI()
balanced('pending click frame')
eq(#mqStub.cmds, before, 'click while pending does nothing')

ui.popupOpen = true
plugin.onDrawUI()
balanced('menu frame')
eq(#menuCalls, 1, 'shared TAC menu items drawn')
eq(menuCalls[1] and menuCalls[1].key, 'claim_button', 'menu items for this window')
eq(menuCalls[1] and menuCalls[1].opts.ghost, false, 'ghost left out')
eq(menuCalls[1] and menuCalls[1].opts.titleBar, false, 'title bar toggle left out')
eq(plugin.state.menuOpen, true, 'menu keeps the window opaque')
ui.popupOpen = false

-- Drag the (still red) button: the window follows and the release is no click.
clock = 30
plugin.state.claimAt = nil
before = #mqStub.cmds
ui.active, ui.dragging, ui.dragDelta = true, true, { 5, 3 }
plugin.onDrawUI()
balanced('drag frame')
eq(ui.movedTo and (ui.movedTo[1] .. ',' .. ui.movedTo[2]), '105,103', 'drag moves the window')
ui.active, ui.dragging, ui.buttonClicked = false, false, true
plugin.onDrawUI()
eq(#mqStub.cmds, before, 'release after a drag does not claim')
eq(plugin.state.dragged, false, 'drag state cleared on release')

windowOpts.claim_button = { lock = true }
ui.triangles, ui.movedTo = 0, nil
ui.active, ui.dragging, ui.dragDelta = true, true, { 5, 3 }
plugin.onDrawUI()
balanced('locked frame')
eq(ui.triangles, 0, 'no grip while locked')
eq(ui.movedTo, nil, 'locked window does not move')
ui.active, ui.dragging = false, false
plugin.onDrawUI()
windowOpts.claim_button = nil

plugin.state.looter = 'me'
plugin.state.claimAt = nil
before = #mqStub.cmds
ui.buttonClicked = true
plugin.onDrawUI()
eq(#mqStub.cmds, before, 'click on green does nothing')
ui.hovered = false

plugin.onDrawSettings()
balanced('settings panel')

-- --------------------------------------------------------------------------
section('hooks: commands, destroy')
-- --------------------------------------------------------------------------
eq(plugin.onCommand('nms', { 'nms' }), false, 'other commands pass through')
local oldPrint = print
print = function() end
eq(plugin.onCommand('claimbutton', { 'claimbutton', 'hide' }), true, 'hide handled')
eq(core.ctrl.show_claim_button, false, 'hide hides')
plugin.onCommand('claimbutton', { 'claimbutton' })
eq(core.ctrl.show_claim_button, true, 'toggle shows')
plugin.onCommand('ClaimButton', { 'ClaimButton', 'status' })
eq(plugin.state.due.manual, clock, 'status asks now')
plugin.onCommand('claimbutton', { 'claimbutton', 'nonsense' })
print = oldPrint
plugin.onDrawUI()
balanced('after commands')

-- --------------------------------------------------------------------------
section('hooks: paused while closed')
-- --------------------------------------------------------------------------
clock = 40
plugin.state.due = {}
mqStub.events.ClaimButtonStatus.fn('[NMS] Active looter: Bob.')
core.ctrl.show_claim_button = false
before = #mqStub.cmds
clock = 200
plugin.onTick()
eq(#mqStub.cmds, before, 'no poll while closed')
mqStub.events.ClaimButtonSlain.fn('You have slain a gnoll!')
eq(plugin.state.due.kill, nil, 'kills not queued while closed')
plugin.onZoned()
plugin.onTick()
eq(#mqStub.cmds, before, 'no zone query while closed')
print = function() end
plugin.onCommand('claimbutton', { 'claimbutton', 'status' })
print = oldPrint
plugin.onTick()
eq(#mqStub.cmds, before + 1, '/ac claimbutton status works while closed')
mqStub.events.ClaimButtonStatus.fn('[NMS] Active looter: Bob.')
eq(plugin.state.due.zone, nil, 'that reply also answers the zone query')
clock = 210
core.ctrl.show_claim_button = true
plugin.onTick()
eq(#mqStub.cmds, before + 2, 'showing the window sends one query')
eq(lastCmd(), '/say #nms status', 'and it is a status query')
mqStub.events.ClaimButtonStatus.fn('[NMS] Active looter: you.')
eq(plugin.state.looter, 'me', 'state refreshed on show')
clock = 269.9
plugin.onTick()
eq(#mqStub.cmds, before + 2, 'poll waits 60 s from the show reply')
clock = 270
plugin.onTick()
eq(#mqStub.cmds, before + 3, 'polling resumed')

plugin.onDestroy()
eq(#mqStub.unevents >= 3, true, 'events released')
check(next(mqStub.events) == nil, 'no event left registered')

-- --------------------------------------------------------------------------
print(string.format('\n%d passed, %d failed', pass, fail))
for _, e in ipairs(errors) do print(e) end
os.exit(fail == 0 and 0 or 1)
