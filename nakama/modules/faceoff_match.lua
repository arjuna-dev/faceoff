local nk = require("nakama")

local M = {}

local VERSION = 1
local OP_STATE = 1
local OP_HIT = 2
local OP_ASSIGN = 3
local OP_FIGHTER = 7
local TICK_RATE = 20
local MAX_PLAYERS = 2
local MAX_DAMAGE = 32
local CHIP_DAMAGE = 1
local GUARD_STRAIN_DISPLACE = 32
local GUARD_SPEED_DISPLACE = 850
local GUARD_STAGGER_TICKS = 9
local GUARD_RECOVERY_PER_TICK = 9 / TICK_RATE
local VALID_REGIONS = {
    head = true,
    torso = true,
    left_forearm = true,
    right_forearm = true,
    left_shin = true,
    right_shin = true,
}
local VALID_ATTACK_LIMBS = {
    left_forearm = true,
    right_forearm = true,
    left_thigh = true,
    right_thigh = true,
    left_shin = true,
    right_shin = true,
}
local VALID_FIGHTERS = {
    batyr = true,
    kiro = true,
    jade = true,
    oculon = true,
    armk = true,
    magician = true,
}

local function number(value, fallback)
    if type(value) == "number" then
        return value
    end
    return fallback
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function valid_vector(value, max_length)
    if type(value) ~= "table" or type(value.x) ~= "number" or type(value.y) ~= "number" then
        return false
    end
    return value.x == value.x and value.y == value.y and (not max_length or value.x * value.x + value.y * value.y <= max_length * max_length)
end

local function valid_state(packet)
    if type(packet) ~= "table" or number(packet.v, VERSION) ~= VERSION then
        return false
    end
    if type(packet.sequence) ~= "number" or packet.sequence < 0 then
        return false
    end
    if not valid_vector(packet.position, nil) or not valid_vector(packet.movement, 1.01) then
        return false
    end
    if math.abs(packet.position.x) > 1600 or math.abs(packet.position.y) > 1000 then
        return false
    end
    if packet.held_targets ~= nil and type(packet.held_targets) ~= "table" then
        return false
    end
    if packet.held_targets then
        local count = 0
        for _, target in pairs(packet.held_targets) do
            count = count + 1
            if count > 8 or not valid_vector(target, 180) then
                return false
            end
        end
    end
    return true
end

local function valid_hit(event)
    if type(event) ~= "table" or event.kind ~= "hit" then
        return false
    end
    if type(event.target_slot) ~= "number" or event.target_slot < 1 or event.target_slot > MAX_PLAYERS then
        return false
    end
    if type(event.region) ~= "string" or not VALID_REGIONS[event.region] then
        return false
    end
    if type(event.speed) ~= "number" or number(event.speed, -1) < 0 or number(event.speed, -1) > 3000 then
        return false
    end
    if event.attack_limb ~= nil and event.attack_limb ~= "" and not VALID_ATTACK_LIMBS[event.attack_limb] then
        return false
    end
    if event.damage ~= nil and type(event.damage) ~= "number" then
        return false
    end
    if event.impact_damage ~= nil and type(event.impact_damage) ~= "number" then
        return false
    end
    if event.point ~= nil and not valid_vector(event.point, 2000) then
        return false
    end
    return true
end

local function player_count(state)
    local count = 0
    for _ in pairs(state.players) do count = count + 1 end
    return count
end

local function allocate_slot(state)
    for slot = 1, MAX_PLAYERS do
        local used = false
        for _, player in pairs(state.players) do
            if player.slot == slot then used = true break end
        end
        if not used then return slot end
    end
    return 0
end

local function player_for_slot(state, slot)
    for _, player in pairs(state.players) do
        if player.slot == slot then return player end
    end
    return nil
end

local function guard_is_active(player, region, tick)
    if not player or not player.fighter or type(player.fighter.held_targets) ~= "table" then
        return false
    end
    if player.guard_stagger and player.guard_stagger[region] and player.guard_stagger[region] > tick then
        return false
    end
    return player.fighter.held_targets[region] ~= nil and (string.find(region, "forearm", 1, true) ~= nil or string.find(region, "shin", 1, true) ~= nil)
end

local function update_guard_state(state, tick)
    for _, player in pairs(state.players) do
        player.guard_strain = player.guard_strain or {}
        player.guard_stagger = player.guard_stagger or {}
        for limb, strain in pairs(player.guard_strain) do
            local next_strain = strain - GUARD_RECOVERY_PER_TICK
            if next_strain <= 0 then
                player.guard_strain[limb] = nil
            else
                player.guard_strain[limb] = next_strain
            end
        end
        for limb, until_tick in pairs(player.guard_stagger) do
            if until_tick <= tick then
                player.guard_stagger[limb] = nil
            end
        end
    end
end

local function displace_guard(player, region, impact_damage, speed, attacker, tick)
    if not player or not player.fighter or type(player.fighter.held_targets) ~= "table" then
        return false
    end
    player.guard_strain = player.guard_strain or {}
    player.guard_stagger = player.guard_stagger or {}
    local strain = number(player.guard_strain[region], 0) + impact_damage
    player.guard_strain[region] = strain
    if speed < GUARD_SPEED_DISPLACE and strain < GUARD_STRAIN_DISPLACE then
        return false
    end
    local target = player.fighter.held_targets[region]
    if not valid_vector(target, 180) then
        return false
    end
    local direction = 1
    if attacker and attacker.fighter and valid_vector(attacker.fighter.position, nil) and valid_vector(player.fighter.position, nil) then
        if player.fighter.position.x < attacker.fighter.position.x then
            direction = -1
        end
    end
    local max_length = string.find(region, "forearm", 1, true) and 87 or 127
    local displaced = {
        x = target.x + direction * 35,
        y = target.y + 18,
    }
    local length = math.sqrt(displaced.x * displaced.x + displaced.y * displaced.y)
    if length > max_length then
        displaced.x = displaced.x / length * max_length
        displaced.y = displaced.y / length * max_length
    end
    player.fighter.held_targets[region] = displaced
    if string.find(region, "shin", 1, true) then
        local side = string.sub(region, 1, string.find(region, "_") - 1)
        player.fighter.held_targets[side .. "_thigh"] = nil
    end
    player.guard_stagger[region] = tick + GUARD_STAGGER_TICKS
    return true
end

local function sanitized_state(player, tick)
    if not player.fighter then return nil end
    local packet = player.fighter
    packet.slot = player.slot
    packet.health = player.health
    packet.is_ko = player.health <= 0
    packet.guard_disabled = {}
    for limb, until_tick in pairs(player.guard_stagger or {}) do
        if until_tick > tick then
            packet.guard_disabled[limb] = true
        end
    end
    return packet
end

local function end_invitation(state)
    if not state.call_id then return end
    local obj=nk.storage_read({{collection='calls',key=state.call_id}})[1]
    if not obj or obj.value.status~='accepted' then return end
    local call=obj.value
    call.status='ended'
    pcall(nk.storage_write,{{collection='calls',key=state.call_id,value=call,version=obj.version,permission_read=0,permission_write=0}})
    for _,id in ipairs({call.caller,call.callee}) do
        nk.notification_send(id,'Faceoff',{type='call',call=call},101,nil,true)
    end
end

function M.match_init(context, setupstate)
	return {
        players = {},
        allowed_users = setupstate.allowed_users,
        call_id = setupstate.call_id,
        empty_ticks = 0,
    }, TICK_RATE, "game:faceoff protocol:1"
end

function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
    if state.allowed_users then
        local allowed=false
        for _,id in ipairs(state.allowed_users) do if id==presence.user_id then allowed=true end end
        if not allowed then return state, false, "invitation required" end
        for _,p in pairs(state.players) do
            if p.presence.user_id==presence.user_id then return state,false,"already joined" end
        end
    end
    if player_count(state) >= MAX_PLAYERS then
        return state, false, "match is full"
    end
    return state, true
end

function M.match_join(context, dispatcher, tick, state, presences)
	for _, presence in ipairs(presences) do
        local slot = allocate_slot(state)
		if slot > 0 then
            state.players[presence.session_id] = {
                presence = presence,
                slot = slot,
                health = 100,
                fighter = nil,
                fighter_id = nil,
                last_sequence = -1,
                guard_strain = {},
                guard_stagger = {},
            }
            dispatcher.broadcast_message(OP_ASSIGN, nk.json_encode({ v = VERSION, slot = slot }), { presence })
            for _, existing in pairs(state.players) do
                if existing.fighter_id then
                    dispatcher.broadcast_message(OP_FIGHTER, nk.json_encode({
                        v = VERSION,
                        slot = existing.slot,
                        fighter_id = existing.fighter_id,
                    }), { presence })
                end
            end
        end
    end
    dispatcher.broadcast_message(5, nk.json_encode({count=player_count(state)}))
    return state
end

function M.match_leave(context, dispatcher, tick, state, presences)
    if state.call_id and #presences>0 then
        end_invitation(state)
        return nil
    end
    for _, presence in ipairs(presences) do
        state.players[presence.session_id] = nil
    end
    dispatcher.broadcast_message(5, nk.json_encode({count=player_count(state)}))
    return state
end

function M.match_loop(context, dispatcher, tick, state, messages)
    if state.ready_count ~= player_count(state) then
        state.ready_count = player_count(state)
        dispatcher.broadcast_message(5, nk.json_encode({count=state.ready_count}))
    end
    update_guard_state(state, tick)
    if player_count(state) == 0 then
        state.empty_ticks = state.empty_ticks + 1
        if state.empty_ticks > TICK_RATE * 90 then end_invitation(state); return nil end
    else
        state.empty_ticks = 0
    end

    if state.allowed_users and player_count(state)<2 then
        if tick > TICK_RATE * 90 then end_invitation(state); return nil end
        return state
    end
    for _, message in ipairs(messages) do
        local sender = state.players[message.sender.session_id]
        if sender and message.op_code == 6 then
            if #message.data==2136 and player_count(state)==2 then
                if sender.voice_tick ~= tick then sender.voice_tick=tick; sender.voice_count=0 end
                sender.voice_count=sender.voice_count+1
                if sender.voice_count <= 2 then dispatcher.broadcast_message(6,message.data,nil,message.sender) end
            end
        elseif sender and message.op_code == OP_FIGHTER then
            local ok, payload = pcall(nk.json_decode, message.data)
            if not ok then payload = {} end
            local fighter_id = type(payload) == "table" and payload.fighter_id or nil
            if type(fighter_id) == "string" and VALID_FIGHTERS[fighter_id] then
                sender.fighter_id = fighter_id
                dispatcher.broadcast_message(OP_FIGHTER, nk.json_encode({
                    v = VERSION,
                    slot = sender.slot,
                    fighter_id = fighter_id,
                }), nil, message.sender)
            end
        elseif sender and message.op_code == OP_STATE then
            local ok,packet = pcall(nk.json_decode,message.data)
            if not ok then packet={} end
            if valid_state(packet) and packet.sequence > sender.last_sequence then
                sender.last_sequence = packet.sequence
                packet.held_targets = packet.held_targets or {}
                if sender.guard_stagger and sender.fighter and type(sender.fighter.held_targets) == "table" then
                    for limb, until_tick in pairs(sender.guard_stagger) do
                        if until_tick > tick then
                            packet.held_targets[limb] = sender.fighter.held_targets[limb]
                        end
                    end
                end
                sender.fighter = packet
                local snapshot = sanitized_state(sender, tick)
                if snapshot then
                    dispatcher.broadcast_message(OP_STATE, nk.json_encode(snapshot), nil, message.sender)
                end
            end
        elseif sender and message.op_code == OP_HIT then
            local ok,event = pcall(nk.json_decode,message.data)
            if not ok then event={} end
            local target = valid_hit(event) and player_for_slot(state, math.floor(event.target_slot)) or nil
            if target and target ~= sender and target.health > 0 then
                local blocked = guard_is_active(target, event.region, tick)
                local impact_damage = clamp(number(event.impact_damage, number(event.damage, 0)), 0, MAX_DAMAGE)
                if event.attack_limb and VALID_ATTACK_LIMBS[event.attack_limb] then
                    local base_damage = string.find(event.attack_limb, "forearm", 1, true) and 10 or 14
                    local speed_factor = 0.55 + 1.25 * clamp((number(event.speed, 0) - 60) / 1100, 0, 1)
                    impact_damage = base_damage * speed_factor
                    if event.region == "head" then
                        impact_damage = impact_damage * 1.15
                    end
                    impact_damage = clamp(impact_damage, 0, MAX_DAMAGE)
                end
                local damage = blocked and CHIP_DAMAGE or impact_damage
                if blocked then
                    displace_guard(target, event.region, impact_damage, number(event.speed, 0), sender, tick)
                end
                target.health = clamp(target.health - damage, 0, 100)
                local hit = {
                    v = VERSION,
                    kind = "hit",
                    attacker_slot = sender.slot,
                    target_slot = target.slot,
                    damage = damage,
                    impact_damage = impact_damage,
                    blocked = blocked,
                    speed = clamp(number(event.speed, 0), 0, 3000),
                    region = event.region,
                    point = event.point or { x = 0, y = 0 },
                }
                dispatcher.broadcast_message(OP_HIT, nk.json_encode(hit), { target.presence }, message.sender)
                local snapshot = sanitized_state(target, tick)
                if snapshot then
                    dispatcher.broadcast_message(OP_STATE, nk.json_encode(snapshot))
                end
            end
        end
    end
    return state
end

function M.match_signal(context, dispatcher, tick, state, data)
    if data=="end" then return nil,"ended" end
    return state, data
end

function M.match_terminate(context, dispatcher, tick, state, grace_seconds)
    return state
end

return M
