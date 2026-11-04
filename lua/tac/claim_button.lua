---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- ============================================================================
-- TAC/lua/tac/claim_button.lua - Claim Button (NMS active looter at a glance)
-- ============================================================================
-- Project Triune's personal loot hands each kill's items to the group's
-- *active looter*. This plugin is one button that says whether this
-- character holds that slot: green when it does, red when someone else or
-- nobody does, grey until the server has answered. Clicking red types
-- `#nms claim`; clicking green or grey asks again (`#nms status`).
--
-- The state is read from the server's reply to `#nms status`:
--   [NMS] Active looter: you.
--   [NMS] Active looter: Bob.
--   [NMS] Active looter: none.
-- Every such line counts, whoever asked (this plugin, the player, the nmsloot
-- plugin), so a fresh reply also restarts the poll timer. The plugin asks on
-- its own:
--   * once when it starts, and a few seconds after each zone change;
--   * every pollSec seconds since the last reply (optional, 5-600 s);
--   * shortly after a kill by you, your pets, your group or their pets,
--     a burst of kills sharing one query;
--   * right after a claim, to confirm it.
-- None of that runs while the window is closed: showing it again asks at
-- once and resumes. Queries the player asks for (Ask now, /ac claimbutton
-- status or claim) go out either way.
-- The commands and replies still show in chat: MacroQuest Lua can read chat
-- lines but not hide them, and /filter would hide them from this plugin too.
--
-- The window has no title bar and the button face fills it; dragging it
-- moves the window. It resizes from the bottom-right grip like every TAC
-- window; the face would cover that grip, so the grip is drawn again on
-- top of it. Right-click opens the idle
-- opacity slider and the shared TAC window items (lock, scale, layout,
-- close); the Config panel on the Plugins page holds every option.
-- ============================================================================

local plugin = {
    id                 = 'claim_button',
    name               = 'Claim Button',
    version            = '1.0.0',
    author             = 'BernatGames',
    description        = 'NMS active looter at a glance: a green button while this character holds the slot, red otherwise (click to #nms claim).',
    defaultEnabled     = true,
    tickInterval       = 0.25,
    runOutOfCombatOnly = false,
    hasThread          = false,
    window             = { label = 'Claim', tooltip = 'Toggles the Claim Button window (claim_button plugin): green = you are the NMS active looter, red = click to claim.', flag = 'show_claim_button', desc = 'NMS active looter button', headerButton = true, order = 97 },
}

-- Populated by refresh() on every entry point; typed so the language server
-- does not treat them as permanently nil.
local core = nil  ---@type table
local ctrl, ImGui, mq = nil, nil, nil  ---@type table, table, table

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------
local KEY          = 'claim_button'                  -- window options / layout key: the plugin id
local FLAG         = 'show_claim_button'             -- ctrl flag of plugin.window
local WINDOW_TITLE = 'Claim Button###TacClaimButton'
local TAG          = '\ag[Claim Button]\ax'
local STATUS_CMD   = '/say #nms status'
local CLAIM_CMD    = '/say #nms claim'

local LIMITS = {
    POLL_MIN_SEC       = 5,
    POLL_MAX_SEC       = 600,
    POLL_DEFAULT_SEC   = 60,
    IDLE_ALPHA_MIN     = 10,     -- percent
    IDLE_ALPHA_MAX     = 100,
    IDLE_ALPHA_DEFAULT = 40,
}
local START_DELAY_SEC   = 2.0    -- first query after the plugin starts
local ZONE_SETTLE_SEC   = 5.0    -- query after a zone change, once the zone has loaded
local KILL_DELAY_SEC    = 1.0    -- lets the server hand out the kill's loot before we ask
local KILL_MIN_GAP_SEC  = 10.0   -- kill queries at most this often; later kills wait for the next slot
local CLAIM_CONFIRM_SEC = 1.5    -- #nms status this long after #nms claim
local REPLY_TIMEOUT_SEC = 5.0    -- an unanswered query stops blocking the next one after this
local CLICK_ASK_GAP_SEC = 2.0    -- a click asks at most this often after the last query
local IDLE_DELAY_SEC    = 0.5    -- mouse away this long before the window fades
local FADE_OUT_SEC      = 0.25
local PENDING_ALPHA     = 0.55   -- button opacity while a claim is being confirmed
local MIN_SIZE          = 16
local DEFAULT_W         = 60
local DEFAULT_H         = 30

-- Pastel, but dark enough to stay readable over bright zones.
local COLORS = {
    me      = { 0.43, 0.75, 0.49 },
    other   = { 0.85, 0.42, 0.42 },
    unknown = { 0.50, 0.52, 0.56 },
}
COLORS.none = COLORS.other
local HOVER_LIGHTEN = 0.08
local ACTIVE_DARKEN = 0.10

-- Dear ImGui's dark style, which the TAC theme leaves in place for the grip.
local GRIP_FALLBACK = {
    ResizeGrip        = { 0.26, 0.59, 0.98, 0.20 },
    ResizeGripHovered = { 0.26, 0.59, 0.98, 0.67 },
    ResizeGripActive  = { 0.26, 0.59, 0.98, 0.95 },
}
-- Where a rounded corner's arc crosses the diagonal, as a fraction of the
-- rounding radius (1 - 1/sqrt(2)): the grip's corner vertex sits there.
local ARC_DIAGONAL = 0.29

local NOBODY = { none = true, nobody = true, noone = true, ['no one'] = true }

local EVENT_STATUS  = 'ClaimButtonStatus'
local EVENT_SLAIN   = 'ClaimButtonSlain'
local EVENT_SLAINBY = 'ClaimButtonSlainBy'

-- One-off queries any reply answers: they only mean "we do not know yet".
-- Kill and claim queries keep their due time, since the state may change then.
local ANSWERED_BY_ANY_REPLY = { start = true, zone = true, manual = true, show = true }

-- Queries the player asked for; they go out even while the window is closed.
local EXPLICIT = { manual = true, claim = true }

-- ----------------------------------------------------------------------------
-- Settings and state
-- ----------------------------------------------------------------------------
local cfg = {
    pollEnabled = true,
    pollSec     = LIMITS.POLL_DEFAULT_SEC,
    queryOnKill = true,
    idleAlpha   = LIMITS.IDLE_ALPHA_DEFAULT,   -- percent
}

local logic = {}
logic.LIMITS = LIMITS

function logic.newState()
    return {
        looter          = nil,   -- 'me' | 'other' | 'none' | nil (no reply yet)
        looterName      = nil,   -- what the server said: 'you', 'Bob', 'none'
        replyAt         = nil,   -- nowSec() of the last status reply
        sentAt          = nil,   -- nowSec() of the last status query this plugin sent
        inFlightAt      = nil,   -- set while that query waits for its reply
        claimAt         = nil,   -- nowSec() of the last #nms claim
        lastKillQueryAt = nil,
        due             = {},    -- reason -> nowSec() a one-off query is due
        visible         = nil,   -- window shown at the last tick (automatic queries pause while closed)
        heldAt          = 0,     -- last frame the mouse was over the window or its menu was open
        hovered         = false,
        menuOpen        = false,
        pressHere       = false, -- the left button went down on the face (not the grip, no menu open)
        diag            = nil,   -- last frame's input state, for /ac claimbutton debug
        alpha           = 1,
        events          = {},
    }
end

local state = logic.newState()

-- ----------------------------------------------------------------------------
-- Pure logic (plugin.logic, covered by tests/test_claim_button.lua)
-- ----------------------------------------------------------------------------
local function clampInt(v, lo, hi, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return math.max(lo, math.min(hi, math.floor(v + 0.5)))
end

function logic.clampPollSec(v)
    return clampInt(v, LIMITS.POLL_MIN_SEC, LIMITS.POLL_MAX_SEC, LIMITS.POLL_DEFAULT_SEC)
end

function logic.clampIdleAlpha(v)
    return clampInt(v, LIMITS.IDLE_ALPHA_MIN, LIMITS.IDLE_ALPHA_MAX, LIMITS.IDLE_ALPHA_DEFAULT)
end

-- "[NMS] Active looter: you." -> 'me', 'you'; nil for any other line. The
-- line must start with the server's prefix (a chat timestamp aside), so
-- "Bob says, '[NMS] Active looter: you.'" does not count.
function logic.parseStatusLine(line)
    if type(line) ~= 'string' then return nil end
    local text = line:gsub('^%[%d+:%d+:%d+%]%s*', '')
    local who = text:match('^%[NMS%] Active looter:%s*(.-)%s*$')
    if not who then return nil end
    who = who:gsub('[%.!]+$', '')
    if who == '' then return nil end
    local low = who:lower()
    if low == 'you' then return 'me', who end
    if NOBODY[low] then return 'none', who end
    return 'other', who
end

-- True when the slayer of "X has been slain by <slayer>!" is in `names`, a
-- set of lower-case names (you, your pets, your group, their pets).
function logic.isOwnKill(slayer, names)
    if type(slayer) ~= 'string' or type(names) ~= 'table' then return false end
    local s = slayer:gsub('^%s+', ''):gsub('%s+$', ''):lower()
    return s ~= '' and names[s] == true
end

-- Asks for a one-off query at `at`; an earlier request for the same reason wins.
function logic.request(s, reason, at)
    local cur = s.due[reason]
    if cur == nil or at < cur then s.due[reason] = at end
end

-- A kill asks KILL_DELAY_SEC later. A kill while one is queued shares it, and
-- one inside KILL_MIN_GAP_SEC of the last kill query waits for the gap.
function logic.scheduleKill(s, now)
    if s.due.kill then return end
    local at = now + KILL_DELAY_SEC
    if s.lastKillQueryAt then at = math.max(at, s.lastKillQueryAt + KILL_MIN_GAP_SEC) end
    s.due.kill = at
end

-- The reason of the status query to send now, or nil. While the window is
-- `hidden` only the queries the player asked for go out; the others wait.
function logic.nextQuery(s, c, now, hidden)
    if s.inFlightAt and (now - s.inFlightAt) < REPLY_TIMEOUT_SEC then return nil end
    local best, bestAt = nil, nil
    for reason, at in pairs(s.due) do
        if at <= now and (not hidden or EXPLICIT[reason]) and (bestAt == nil or at < bestAt) then best, bestAt = reason, at end
    end
    if best then return best end
    if c.pollEnabled and not hidden then
        -- From the last reply or the last query, so a server that never
        -- answers is asked once per period, not every tick.
        local last = math.max(s.replyAt or -math.huge, s.sentAt or -math.huge)
        if last > -math.huge and (now - last) >= c.pollSec then return 'poll' end
    end
    return nil
end

-- Showing the window again asks at once; the reply also restarts the poll timer.
function logic.setVisible(s, visible, now)
    if visible and s.visible == false then logic.request(s, 'show', now) end
    s.visible = visible
end

function logic.markSent(s, reason, now)
    s.due[reason] = nil
    s.sentAt = now
    s.inFlightAt = now
    if reason == 'kill' then s.lastKillQueryAt = now end
end

function logic.applyReply(s, looter, name, now)
    s.looter, s.looterName, s.replyAt = looter, name, now
    s.inFlightAt = nil
    for reason, at in pairs(s.due) do
        if ANSWERED_BY_ANY_REPLY[reason] or at <= now then s.due[reason] = nil end
    end
end

function logic.markClaim(s, now)
    s.claimAt = now
    logic.request(s, 'claim', now + CLAIM_CONFIRM_SEC)
end

-- A claim is pending until a reply arrives after its confirm time, or until
-- that confirm query has had time to time out.
function logic.claimPending(s, now)
    if not s.claimAt then return false end
    local confirmAt = s.claimAt + CLAIM_CONFIRM_SEC
    if s.replyAt and s.replyAt >= confirmAt then return false end
    return now < confirmAt + REPLY_TIMEOUT_SEC
end

-- What a left click does: 'claim' (red), 'ask' (green or grey: refresh),
-- or nil while a claim is being confirmed.
function logic.clickAction(s, now)
    if logic.claimPending(s, now) then return nil end
    if s.looter == nil or s.looter == 'me' then return 'ask' end
    return 'claim'
end

-- A refresh asked by a click. Ignored while a query waits for its reply or
-- within CLICK_ASK_GAP_SEC of the last one, so fast clicking sends one query
-- instead of filling the chat. Returns whether a query was queued.
function logic.askFromClick(s, now)
    if s.inFlightAt and (now - s.inFlightAt) < REPLY_TIMEOUT_SEC then return false end
    if s.sentAt and (now - s.sentAt) < CLICK_ASK_GAP_SEC then return false end
    logic.request(s, 'manual', now)
    return true
end

-- Window opacity: 1 while held, then after IDLE_DELAY_SEC down to `idle`
-- (0-1) over FADE_OUT_SEC.
function logic.fadeAlpha(heldAt, now, idle)
    if idle >= 1 then return 1 end
    local away = now - (heldAt or now)
    if away <= IDLE_DELAY_SEC then return 1 end
    local t = math.min(1, (away - IDLE_DELAY_SEC) / FADE_OUT_SEC)
    return 1 - (1 - idle) * t
end

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------
local function refresh()
    ctrl = core.ctrl
    ImGui = core.ImGui
    mq = core.mq
end

local function isVisible()
    return ctrl ~= nil and ctrl[FLAG] == true
end

-- Seconds; tests override plugin.clock.
local function nowSec()
    if plugin.clock then return plugin.clock() end
    if mq and mq.gettime then
        local ok, ms = pcall(mq.gettime)
        if ok and type(ms) == 'number' then return ms / 1000 end
    end
    return os.clock()
end

local function say(fmt, ...)
    print(TAG .. ' ' .. string.format(fmt, ...))
end

local function inGame()
    local ok, gs = pcall(function() return mq.TLO.MacroQuest.GameState() end)
    return ok and gs == 'INGAME'
end

local function fmtAge(sec)
    if sec < 1 then return '<1s' end
    if sec < 60 then return string.format('%ds', math.floor(sec)) end
    if sec < 3600 then return string.format('%dm', math.floor(sec / 60)) end
    return string.format('%dh', math.floor(sec / 3600))
end

-- ImGui getters return an ImVec2 or two numbers depending on the binding.
local function xy(a, b)
    if type(a) == 'userdata' or (type(a) == 'table' and a.x) then return a.x, a.y end
    return tonumber(a) or 0, tonumber(b) or 0
end

local function call2(fn)
    if not fn then return 0, 0 end
    local ok, a, b = pcall(fn)
    if not ok then return 0, 0 end
    return xy(a, b)
end

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

local function col32(r, g, b, a)
    r, g, b, a = clamp01(r), clamp01(g), clamp01(b), clamp01(a)
    if IM_COL32 then
        return IM_COL32(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), math.floor(a * 255))
    end
    -- Packed ABGR, the ImU32 layout IM_COL32 produces.
    return math.floor(a * 255) * 16777216 + math.floor(b * 255) * 65536 + math.floor(g * 255) * 256 + math.floor(r * 255)
end

-- An event handler error must not break the core's doevents pass.
local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then say('event error: %s', tostring(err)) end
    end
end

-- ----------------------------------------------------------------------------
-- Talking to the server
-- ----------------------------------------------------------------------------
local function sendStatus(reason, now)
    if not (mq and mq.cmd) then return end
    mq.cmd(STATUS_CMD)
    logic.markSent(state, reason, now)
end

local function sendClaim(now)
    if not (mq and mq.cmd) then return end
    mq.cmd(CLAIM_CMD)
    logic.markClaim(state, now)
end

-- Lower-case names whose kills count as ours: this character, its pets
-- (every multiclass pet TAC tracks), the group members and their pets.
local function ownNames()
    local names = {}
    local function add(n)
        n = n ~= nil and tostring(n) or ''
        if n ~= '' and n:lower() ~= 'null' then names[n:lower()] = true end
    end
    pcall(function() add(mq.TLO.Me.CleanName()) end)
    pcall(function() add(mq.TLO.Me.Pet.CleanName()) end)
    if core.getMultiPetList then
        pcall(function()
            local slots, extra = core.getMultiPetList()
            for _, slot in ipairs(slots or {}) do
                if slot.petId and slot.petId > 0 then add(mq.TLO.Spawn(slot.petId).CleanName()) end
            end
            for _, id in ipairs(extra or {}) do add(mq.TLO.Spawn(id).CleanName()) end
        end)
    end
    pcall(function()
        for i = 1, (mq.TLO.Group.Members() or 0) do
            local m = mq.TLO.Group.Member(i)
            add(m.CleanName())
            -- No pet (or not in zone): the member still counts.
            pcall(function() add(m.Pet.CleanName()) end)
        end
    end)
    return names
end

local function onStatusLine(line)
    local looter, name = logic.parseStatusLine(line)
    if looter then logic.applyReply(state, looter, name, nowSec()) end
end

-- Kills while the window is closed are not queued: showing it asks anyway.
local function onOwnKill()
    if cfg.queryOnKill and isVisible() then logic.scheduleKill(state, nowSec()) end
end

local function onSlainBy(_, slayer)
    if cfg.queryOnKill and isVisible() and logic.isOwnKill(slayer, ownNames()) then logic.scheduleKill(state, nowSec()) end
end

local function registerEvents()
    if not (mq and mq.event) then return end
    local defs = {
        { EVENT_STATUS,  '#*#[NMS] Active looter: #*#', onStatusLine },
        { EVENT_SLAIN,   'You have slain #*#!',         onOwnKill },
        { EVENT_SLAINBY, '#*# has been slain by #1#!',  onSlainBy },
    }
    for _, d in ipairs(defs) do
        if mq.unevent then pcall(mq.unevent, d[1]) end
        if pcall(mq.event, d[1], d[2], safe(d[3])) then table.insert(state.events, d[1]) end
    end
end

local function unregisterEvents()
    if mq and mq.unevent then
        for _, name in ipairs(state.events) do pcall(mq.unevent, name) end
    end
    state.events = {}
end

-- ----------------------------------------------------------------------------
-- Window
-- ----------------------------------------------------------------------------
local function looterLabel()
    if state.looter == nil then return 'unknown' end
    if state.looter == 'me' then return 'you' end
    if state.looter == 'none' then return 'nobody' end
    return tostring(state.looterName)
end

local function replyAge(now)
    if not state.replyAt then return 'no reply yet' end
    return 'reply ' .. fmtAge(now - state.replyAt) .. ' ago'
end

local function tooltipText(now)
    local line
    if logic.claimPending(state, now) then
        line = 'Claiming the active looter slot...'
    elseif state.looter == 'me' then
        line = 'You are the active looter. Click to refresh.'
    elseif state.looter == 'other' then
        line = 'Active looter: ' .. tostring(state.looterName) .. '. Click to claim.'
    elseif state.looter == 'none' then
        line = 'Nobody is the active looter. Click to claim.'
    else
        line = 'Active looter unknown. Click to ask the server.'
    end
    return line .. '\n(' .. replyAge(now) .. ')'
end

local function onClick(now)
    local action = logic.clickAction(state, now)
    if action == 'claim' then
        sendClaim(now)
    elseif action == 'ask' then
        logic.askFromClick(state, now)
    end
end

local function windowHovered()
    local HF = ImGuiHoveredFlags
    local flags = HF and bit.bor(HF.RootAndChildWindows or 0, HF.AllowWhenBlockedByActiveItem or 0, HF.AllowWhenBlockedByPopup or 0) or 0
    local ok, hov = pcall(ImGui.IsWindowHovered, flags)
    return ok and hov == true
end

local function styleColor(name)
    local idx = ImGuiCol and ImGuiCol[name]
    if idx ~= nil and ImGui.GetStyleColorVec4 then
        local ok, c = pcall(ImGui.GetStyleColorVec4, idx)
        if ok and c ~= nil and c.x ~= nil then return c.x, c.y, c.z, c.w end
    end
    local f = GRIP_FALLBACK[name]
    return f[1], f[2], f[3], f[4]
end

local function frameRounding()
    local ok, r = pcall(function() return ImGui.GetStyle().FrameRounding end)
    return (ok and tonumber(r)) or 0
end

local function isLocked()
    local o = core.windowOpts and core.windowOpts(KEY)
    return o ~= nil and o.lock == true
end

local function mouseFlag(fn)
    if not fn then return false end
    local ok, v = pcall(fn, 0)
    return ok and v == true
end

-- True once the left button has moved past ImGui's drag threshold since it
-- went down: that press moved or resized the window, it is not a click.
local function mouseDragged()
    local ok, a, b = pcall(ImGui.GetMouseDragDelta, 0)
    if not ok then return false end
    local dx, dy = xy(a, b)
    return dx ~= 0 or dy ~= 0
end

-- The window rectangle and the size of ImGui's bottom-right resize grip.
local function windowRect()
    local x, y = call2(ImGui.GetWindowPosVec or ImGui.GetWindowPos)
    local w, h = call2(ImGui.GetWindowSizeVec or ImGui.GetWindowSize)
    local okF, font = pcall(ImGui.GetFontSize)
    if not okF or type(font) ~= 'number' then font = 13 end
    return x, y, w, h, math.min(math.floor(font * 1.35), w, h)
end

local function overGrip(mx, my, x2, y2, size)
    return mx <= x2 and my <= y2 and (x2 - mx) + (y2 - my) <= size
end

-- The button face: one rounded rectangle over the whole window, lighter
-- under the mouse, darker while pressed, dimmed while a claim is pending.
local function drawFace(dl, x, y, w, h, hovered, pressed, now)
    local c = COLORS[state.looter or 'unknown']
    local d = 0
    if pressed then d = -ACTIVE_DARKEN elseif hovered then d = HOVER_LIGHTEN end
    local a = state.alpha * (logic.claimPending(state, now) and PENDING_ALPHA or 1)
    pcall(function()
        dl:AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), col32(c[1] + d, c[2] + d, c[3] + d, a), frameRounding())
    end)
end

-- ImGui's bottom-right resize grip, drawn again over the face that covers
-- it. ImGui still does the resizing; this only keeps the grip visible, in
-- ImGui's own size and colours.
local function drawGrip(dl, x2, y2, size, over, down, alpha)
    if isLocked() then return end
    local name = 'ResizeGrip'
    if over then name = down and 'ResizeGripActive' or 'ResizeGripHovered' end
    local r, g, b, a = styleColor(name)
    local k = frameRounding() * ARC_DIAGONAL
    -- Clockwise, as ImGui's anti-aliased fill expects.
    pcall(function()
        dl:AddTriangleFilled(ImVec2(x2, y2 - size), ImVec2(x2 - k, y2 - k), ImVec2(x2 - size, y2), col32(r, g, b, a * alpha))
    end)
end

local function drawIdleAlphaSlider(id)
    ImGui.SetNextItemWidth(core.px(140))
    local v = logic.clampIdleAlpha(ImGui.SliderInt('Idle opacity' .. id, cfg.idleAlpha, LIMITS.IDLE_ALPHA_MIN, LIMITS.IDLE_ALPHA_MAX, '%d%%'))
    if v ~= cfg.idleAlpha then
        cfg.idleAlpha = v
        core.saveLoadout(true)
    end
    if ImGui.IsItemHovered() then core.setTooltip('How visible the button stays half a second after the mouse leaves it (100 = never fades).') end
end

-- Right-click menu: idle opacity plus the shared TAC window items. Ghost is
-- left out (it fades the frame only, and this window is all content) and so
-- is the title bar toggle (the window never has one).
local function drawMenu()
    if not ImGui.BeginPopupContextWindow('##claimButtonMenu') then
        state.menuOpen = false
        return
    end
    state.menuOpen = true
    if core.applyWindowScale then core.applyWindowScale(KEY) end
    ImGui.TextDisabled('Claim Button')
    ImGui.Separator()
    drawIdleAlphaSlider('##cbMenuIdle')
    if core.drawWindowMenuItems then
        core.drawWindowMenuItems(KEY, { header = false, titleBar = false, ghost = false })
    end
    ImGui.EndPopup()
end

-- The window holds no ImGui button on purpose: an item covering the whole
-- window holds the mouse, so ImGui could not move the window and the click
-- had to be told apart from a drag by hand. With no item, ImGui moves and
-- resizes the window itself (and Lock stops both), and a click is a press
-- and release inside the window, off the grip, without a drag.
local function drawContents(now)
    local avW, avH = call2(ImGui.GetContentRegionAvail)
    -- Keeps the content as big as the window, so a double-click on the grip
    -- (ImGui's auto-fit) does not shrink it to the minimum size.
    ImGui.Dummy(math.max(1, avW), math.max(1, avH))
    local x, y, w, h, gripSize = windowRect()
    local mx, my = call2(ImGui.GetMousePosVec or ImGui.GetMousePos)
    local inWindow = windowHovered()
    local onGrip = inWindow and not isLocked() and overGrip(mx, my, x + w, y + h, gripSize)
    local hovered = inWindow and not onGrip
    local down = mouseFlag(ImGui.IsMouseDown)
    if mouseFlag(ImGui.IsMouseClicked) then state.pressHere = hovered and not state.menuOpen end
    if mouseFlag(ImGui.IsMouseReleased) then
        if state.pressHere and hovered and not mouseDragged() then onClick(now) end
        state.pressHere = false
    elseif not down then
        state.pressHere = false
    end
    local okDl, dl = pcall(ImGui.GetWindowDrawList)
    if okDl and dl and w > 0 and h > 0 then
        drawFace(dl, x, y, w, h, hovered, state.pressHere and down, now)
        drawGrip(dl, x + w, y + h, gripSize, onGrip, down, state.alpha)
    end
    drawMenu()
    if hovered and not state.menuOpen then core.setTooltip(tooltipText(now)) end
    state.hovered = inWindow
    local okA, anyActive = pcall(ImGui.IsAnyItemActive)
    state.diag = { at = now, hovered = hovered, onGrip = onGrip, down = down, anyActive = okA and anyActive == true }
end

local function drawWindow()
    if not ctrl or ctrl[FLAG] ~= true then return end
    local now = nowSec()
    if state.hovered or state.menuOpen then state.heldAt = now end
    state.alpha = logic.fadeAlpha(state.heldAt, now, cfg.idleAlpha / 100)
    local WF, SV = ImGuiWindowFlags, ImGuiStyleVar

    core.pushTheme()
    -- Before preBeginWindow, so a pending Window Layout restore overrides it.
    ImGui.SetNextWindowSize(core.px(DEFAULT_W), core.px(DEFAULT_H), ImGuiCond.FirstUseEver)
    core.preBeginWindow(KEY)
    -- After preBeginWindow, which pushes the window's scaled padding.
    ImGui.PushStyleVar(SV.Alpha, state.alpha)
    ImGui.PushStyleVar(SV.WindowPadding, 0, 0)
    ImGui.PushStyleVar(SV.WindowBorderSize, 0)
    ImGui.PushStyleVar(SV.WindowMinSize, MIN_SIZE, MIN_SIZE)
    local flags = bit.bor(WF.NoTitleBar, WF.NoScrollbar, WF.NoScrollWithMouse, WF.NoBackground, WF.NoFocusOnAppearing)
    flags = core.windowFlags(KEY, flags)
    local _, draw = ImGui.Begin(WINDOW_TITLE, true, flags)
    -- Padding, border and minimum size are read by Begin only; popping them
    -- here keeps the menu and tooltip on the theme's values.
    ImGui.PopStyleVar(3)
    if draw then
        core.postBeginWindow(KEY)
        drawContents(now)
    else
        state.hovered, state.menuOpen = false, false
    end
    core.preEndWindow(KEY, true)
    ImGui.End()
    ImGui.PopStyleVar(1)
    core.popTheme()
end

-- ----------------------------------------------------------------------------
-- Settings panel
-- ----------------------------------------------------------------------------
function plugin.openWindow(val)
    refresh()
    if not ctrl then return end
    if val == nil then val = ctrl[FLAG] ~= true end
    ctrl[FLAG] = (val == true)
    core.saveLoadout(true)
end

function plugin.onDrawSettings()
    if not core then return end
    refresh()
    local now = nowSec()
    local GOLD = (core.colors and core.colors.GOLD) or { 1.0, 0.70, 0.54, 1 }
    core.accent(GOLD, 'Claim Button')
    local isOpen = (ctrl[FLAG] == true)
    if ImGui.Button((isOpen and 'Window: Visible (Click to Hide)' or 'Window: Hidden (Click to Show)') .. '##cbToggleWin', core.px(250), core.px(24)) then
        plugin.openWindow(not isOpen)
    end
    ImGui.Spacing()
    ImGui.TextDisabled('Active looter: ' .. looterLabel() .. ' (' .. replyAge(now) .. ')')
    ImGui.SameLine()
    if ImGui.SmallButton('Ask now##cbAskNow') then logic.request(state, 'manual', now) end
    if ImGui.IsItemHovered() then core.setTooltip('Send #nms status now.') end
    ImGui.Separator()

    local v = ImGui.Checkbox('Poll #nms status##cbPoll', cfg.pollEnabled)
    if v ~= cfg.pollEnabled then cfg.pollEnabled = (v == true); core.saveLoadout(true) end
    if ImGui.IsItemHovered() then core.setTooltip('Ask the server who holds the slot on a timer. The timer restarts on every reply, whoever asked.\nPaused while the window is closed; showing it again asks at once.') end
    if cfg.pollEnabled then
        ImGui.SetNextItemWidth(core.px(200))
        local sec = logic.clampPollSec(ImGui.SliderInt('Every (seconds)##cbPollSec', cfg.pollSec, LIMITS.POLL_MIN_SEC, LIMITS.POLL_MAX_SEC))
        if sec ~= cfg.pollSec then cfg.pollSec = sec; core.saveLoadout(true) end
        if ImGui.IsItemHovered() then core.setTooltip('Between 5 and 600 seconds. Ctrl+click to type a value.') end
    end

    v = ImGui.Checkbox('Ask after a kill##cbKill', cfg.queryOnKill)
    if v ~= cfg.queryOnKill then cfg.queryOnKill = (v == true); core.saveLoadout(true) end
    if ImGui.IsItemHovered() then core.setTooltip('Ask about a second after a kill by you, your pets, your group or their pets. A burst of kills shares one query (at most one every 10 s).') end

    ImGui.Separator()
    drawIdleAlphaSlider('##cbCfgIdle')
    local o = (core.windowOpts and core.windowOpts(KEY)) or {}
    local lock = ImGui.Checkbox('Lock position & size##cbLock', o.lock == true)
    if lock ~= (o.lock == true) and core.setWindowOpt then core.setWindowOpt(KEY, 'lock', lock == true) end
    if core.drawWindowScaleControl then core.drawWindowScaleControl(KEY, 'UI scale', core.px(120)) end
end

function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    if s.pollEnabled ~= nil then cfg.pollEnabled = (s.pollEnabled == true) end
    if s.pollSec ~= nil then cfg.pollSec = logic.clampPollSec(s.pollSec) end
    if s.queryOnKill ~= nil then cfg.queryOnKill = (s.queryOnKill == true) end
    if s.idleAlpha ~= nil then cfg.idleAlpha = logic.clampIdleAlpha(s.idleAlpha) end
end

function plugin.onSaveSettings()
    return { pollEnabled = cfg.pollEnabled == true, pollSec = cfg.pollSec, queryOnKill = cfg.queryOnKill == true, idleAlpha = cfg.idleAlpha }
end

-- ----------------------------------------------------------------------------
-- Lifecycle
-- ----------------------------------------------------------------------------
function plugin.onInit(coreApi)
    core = coreApi
    refresh()
    if ctrl and ctrl[FLAG] == nil then ctrl[FLAG] = true end
    state = logic.newState()
    plugin.state = state
    local now = nowSec()
    state.heldAt = now
    -- Seeded so a window already open does not also count as "shown again".
    state.visible = isVisible()
    logic.request(state, 'start', now + START_DELAY_SEC)
    registerEvents()
end

function plugin.onDestroy()
    unregisterEvents()
end

function plugin.onTick()
    if not core then return end
    refresh()
    local now = nowSec()
    -- Watched here rather than where the window is closed: Close, the header
    -- button, Window Layout and /ac claimbutton all just flip the ctrl flag.
    local visible = isVisible()
    logic.setVisible(state, visible, now)
    if not inGame() then return end
    local reason = logic.nextQuery(state, cfg, now, not visible)
    if reason then sendStatus(reason, now) end
end

function plugin.onDrawUI()
    if not core then return end
    refresh()
    drawWindow()
end

function plugin.onZoned()
    -- A reply may have been lost while zoning.
    state.inFlightAt = nil
    logic.request(state, 'zone', nowSec() + ZONE_SETTLE_SEC)
end

-- ----------------------------------------------------------------------------
-- Commands: /ac claimbutton [show|hide|status|claim]
-- ----------------------------------------------------------------------------
plugin.help = {
    '  \ag/ac claimbutton\ax - Show or hide the Claim Button window',
    '  \ag/ac claimbutton show | hide\ax - Show / hide it',
    '  \ag/ac claimbutton status\ax - Ask the server who holds the active looter slot (#nms status)',
    '  \ag/ac claimbutton claim\ax - Claim the slot (#nms claim), same as clicking the red button',
    '  \ag/ac claimbutton debug\ax - Print the button\'s state and last mouse state (for bug reports)',
}

local function printDebug(now)
    local d = state.diag
    say('looter=%s pending=%s visible=%s locked=%s menuOpen=%s pressHere=%s inFlight=%s',
        tostring(state.looter), tostring(logic.claimPending(state, now)), tostring(isVisible()), tostring(isLocked()),
        tostring(state.menuOpen), tostring(state.pressHere), tostring(state.inFlightAt ~= nil))
    if not d then
        say('No frame drawn yet.')
        return
    end
    say('last frame %s ago: hovered=%s onGrip=%s mouseDown=%s anyItemActive=%s',
        fmtAge(now - d.at), tostring(d.hovered), tostring(d.onGrip), tostring(d.down), tostring(d.anyActive))
end

function plugin.onCommand(cmd, args)
    cmd = tostring(cmd or ''):lower()
    if cmd ~= 'claimbutton' and cmd ~= 'claimbtn' then return false end
    refresh()
    local now = nowSec()
    local sub = (type(args) == 'table' and args[2]) and tostring(args[2]):lower() or ''
    if sub == '' or sub == 'toggle' then
        plugin.openWindow()
        say('Window %s.', ctrl[FLAG] and 'shown' or 'hidden')
    elseif sub == 'show' or sub == 'hide' then
        plugin.openWindow(sub == 'show')
        say('Window %s.', ctrl[FLAG] and 'shown' or 'hidden')
    elseif sub == 'status' then
        say('Active looter: %s (%s). Asking the server.', looterLabel(), replyAge(now))
        logic.request(state, 'manual', now)
    elseif sub == 'claim' then
        if logic.claimPending(state, now) then
            say('A claim is already being confirmed.')
        elseif state.looter == 'me' then
            say('You already are the active looter.')
        else
            sendClaim(now)
        end
    elseif sub == 'debug' then
        printDebug(now)
    else
        for _, line in ipairs(plugin.help) do print(line) end
    end
    return true
end

-- Exposed for tests
plugin.state = state
plugin.cfg = cfg
plugin.logic = logic

return plugin
