--[[
    MEPH FINAL: Simple Movement Disabler
    
    Simple system to disable movement keys when specific units cast specific spells.
    Waits for player to be stationary, then disables keys until debuff is gone.
--]]

DEFAULT_CHAT_FRAME:AddMessage("MEPH: Loading movement disabler...")

-- Simple timer system
local function CreateSimpleTimer(duration, callback)
    local frame = CreateFrame("Frame")
    local elapsed = 0
    frame:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed >= duration then
            frame:SetScript("OnUpdate", nil)
            callback()
        end
    end)
    return frame
end

-- Configuration
local CAST_TIME = 3.0
local GRACE_PERIOD = 0.5
local DEBUG_MODE = true

-- Movement actions to look for
local MOVEMENT_ACTIONS = {
    "MOVEFORWARD",
    "MOVEBACKWARD", 
    "STRAFELEFT",
    "STRAFERIGHT",
    "TURNLEFT",
    "TURNRIGHT",
    "JUMP",
    "TOGGLEAUTORUN"
}

-- Target configurations
local targetConfigs = {
    {
        caster = "Mephistroth",
        spell = "Shackles of the Legion", 
        debuff = "Shackles of the Legion"
    }
}

-- State tracking
local originalBindings = {}
local playerPos = {}
local castInProgress = false
local keysDisabled = false
local debuffScanFrame = nil
local stationaryStartTime = nil
local currentConfig = nil

-- Debug function
local function DebugMsg(msg)
    if DEBUG_MODE then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: " .. msg)
    end
end

-- Movement detection
local function IsPlayerMoving()
    local x, y = GetPlayerMapPosition("player")
    local now = GetTime()
    
    if not playerPos.lastX then
        playerPos.lastX, playerPos.lastY = x, y
        playerPos.lastTime = now
        return false
    end
    
    if now - (playerPos.lastTime or 0) < 0.1 then
        return playerPos.wasMoving or false
    end
    
    local moved = (x ~= playerPos.lastX or y ~= playerPos.lastY)
    playerPos.lastX, playerPos.lastY = x, y
    playerPos.lastTime = now
    playerPos.wasMoving = moved
    
    -- Track stationary time
    if moved then
        stationaryStartTime = nil
    else
        if not stationaryStartTime then
            stationaryStartTime = now
        end
    end
    
    return moved
end

-- Store original bindings by scanning all bindings for movement actions
local function StoreOriginalBindings()
    originalBindings = {}
    
    -- Scan through all possible bindings to find movement keys
    for i = 1, GetNumBindings() do
        local command, key1, key2 = GetBinding(i)
        
        -- Check if this command is a movement action we want to disable
        for _, movementAction in ipairs(MOVEMENT_ACTIONS) do
            if command == movementAction then
                if key1 then
                    originalBindings[key1] = command
                    DebugMsg("Found movement key: " .. key1 .. " -> " .. command)
                end
                if key2 then
                    originalBindings[key2] = command
                    DebugMsg("Found movement key: " .. key2 .. " -> " .. command)
                end
                break
            end
        end
    end
    
    DebugMsg("Stored " .. table.getn(originalBindings) .. " movement key bindings")
end

-- Disable movement keys
local function DisableMovementKeys()
    if keysDisabled then return end
    
    local isMoving = IsPlayerMoving()
    local now = GetTime()
    
    if isMoving then
        DebugMsg("Player still moving, waiting...")
        return false
    end
    
    if not stationaryStartTime then
        DebugMsg("Player just stopped, starting grace period...")
        return false
    end
    
    local stationaryDuration = now - stationaryStartTime
    if stationaryDuration < GRACE_PERIOD then
        DebugMsg("Grace period active (" .. string.format("%.1f", stationaryDuration) .. "s/" .. GRACE_PERIOD .. "s)")
        return false
    end
    
    if not next(originalBindings) then
        StoreOriginalBindings()
    end
    
    -- Disable each discovered movement key
    for key, action in pairs(originalBindings) do
        SetBinding(key)  -- Unbind the key
        DebugMsg("Disabled key: " .. key .. " (was " .. action .. ")")
    end
    SaveBindings(2)
    
    keysDisabled = true
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys DISABLED! Player stationary for " .. string.format("%.1f", stationaryDuration) .. "s")
    
    return true
end

-- Restore movement keys
local function RestoreMovementKeys()
    if not keysDisabled then return end
    
    for key, action in pairs(originalBindings) do
        SetBinding(key, action)
    end
    SaveBindings(2)
    
    keysDisabled = false
    originalBindings = {}
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys RESTORED!")
end

-- Debuff detection (working method)
local tooltip = CreateFrame("GameTooltip", "MephTooltip", nil, "GameTooltipTemplate")
tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function GetDebuffName(debuffIndex)
    tooltip:ClearLines()
    tooltip:SetUnitDebuff("player", debuffIndex)
    local name = MephTooltipTextLeft1:GetText()
    return name
end

local function HasTargetDebuff(debuffName)
    for i = 1, 16 do
        local debuffTexture = UnitDebuff("player", i)
        if debuffTexture then
            local foundDebuffName = GetDebuffName(i)
            if foundDebuffName and string.lower(foundDebuffName) == string.lower(debuffName) then
                return true
            end
        end
    end
    return false
end

-- Start debuff scanning
local function StartDebuffScanning()
    if not currentConfig then return end
    
    if debuffScanFrame then
        debuffScanFrame:SetScript("OnUpdate", nil)
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Starting scan for debuff: " .. currentConfig.debuff)
    
    debuffScanFrame = CreateFrame("Frame")
    local scanElapsed = 0
    local debuffWasFound = false
    local scanStartTime = GetTime()
    local NO_DEBUFF_TIMEOUT = 1.0  -- If no debuff found after 1s, restore keys
    
    debuffScanFrame:SetScript("OnUpdate", function()
        scanElapsed = scanElapsed + arg1
        
        -- Only scan every 0.1 seconds for more responsive detection
        if scanElapsed >= 0.1 then
            scanElapsed = 0
            
            local hasDebuff = HasTargetDebuff(currentConfig.debuff)
            local totalScanTime = GetTime() - scanStartTime
            
            DebugMsg("Debuff scan: " .. (hasDebuff and "FOUND" or "NOT FOUND") .. " (" .. string.format("%.1f", totalScanTime) .. "s)")
            
            if hasDebuff then
                if not debuffWasFound then
                    DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. currentConfig.debuff .. " debuff detected!")
                    debuffWasFound = true
                end
                
                -- Continue trying to disable keys during debuff
                if not keysDisabled then
                    DisableMovementKeys()
                end
            else
                -- Debuff not found
                if debuffWasFound then
                    -- Debuff was there but now gone
                    DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. currentConfig.debuff .. " debuff GONE! Restoring keys...")
                    RestoreMovementKeys()
                    
                    -- Stop scanning
                    debuffScanFrame:SetScript("OnUpdate", nil)
                    castInProgress = false
                    currentConfig = nil
                else
                    -- Debuff was never found - check timeout
                    if totalScanTime >= NO_DEBUFF_TIMEOUT then
                        DEFAULT_CHAT_FRAME:AddMessage("MEPH: No debuff found after " .. NO_DEBUFF_TIMEOUT .. "s (resisted?). Restoring keys...")
                        RestoreMovementKeys()
                        
                        -- Stop scanning
                        debuffScanFrame:SetScript("OnUpdate", nil)
                        castInProgress = false
                        currentConfig = nil
                    end
                end
            end
        end
    end)
end

-- Handle cast detection
local function OnTargetCastDetected(config)
    if castInProgress then return end
    
    castInProgress = true
    currentConfig = config
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. config.caster .. " casting " .. config.spell .. "! Starting monitoring...")
    
    -- Monitor during cast
    local castStartTime = GetTime()
    local castFrame = CreateFrame("Frame")
    local castElapsed = 0
    
    castFrame:SetScript("OnUpdate", function()
        castElapsed = castElapsed + arg1
        
        -- Check every 0.1 seconds during cast
        if castElapsed >= 0.1 then
            castElapsed = 0
            
            local elapsed = GetTime() - castStartTime
            
            if elapsed >= CAST_TIME then
                -- Cast finished, start debuff scanning
                DebugMsg("Cast finished, starting debuff scan...")
                StartDebuffScanning()
                
                -- Try to disable keys one more time
                if not keysDisabled then
                    DisableMovementKeys()
                end
                
                castFrame:SetScript("OnUpdate", nil)
                return
            end
            
            -- During cast: try to disable keys when player stops moving
            if not keysDisabled then
                DisableMovementKeys()
            end
        end
    end)
end

-- Chat message handler
local function OnChatMessage(event, message)
    if not message then return end
    
    for _, config in ipairs(targetConfigs) do
        if string.find(message, config.caster) and string.find(message, config.spell) then
            if string.find(message, "begins to cast") or string.find(message, "casts") then
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: CAST DETECTED: " .. message)
                OnTargetCastDetected(config)
                break
            end
        end
    end
end

-- Add target configuration
local function AddTargetConfig(caster, spell, debuff)
    for i, config in ipairs(targetConfigs) do
        if config.caster == caster and config.spell == spell then
            config.debuff = debuff
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Updated target: " .. caster .. " -> " .. spell .. " -> " .. debuff)
            return
        end
    end
    
    table.insert(targetConfigs, {
        caster = caster,
        spell = spell,
        debuff = debuff
    })
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Added target: " .. caster .. " -> " .. spell .. " -> " .. debuff)
end

-- List configurations
local function ListTargetConfigs()
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Current target configurations:")
    for i, config in ipairs(targetConfigs) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. i .. ". " .. config.caster .. " -> " .. config.spell .. " -> " .. config.debuff)
    end
end

-- Parse quoted arguments
local function ParseQuotedArgs(msg)
    local args = {}
    local current = ""
    local inQuotes = false
    local i = 1
    
    while i <= string.len(msg) do
        local char = string.sub(msg, i, i)
        
        if char == '"' then
            if inQuotes then
                if current ~= "" then
                    table.insert(args, current)
                    current = ""
                end
                inQuotes = false
            else
                inQuotes = true
            end
        elseif char == " " then
            if inQuotes then
                current = current .. char
            else
                if current ~= "" then
                    table.insert(args, current)
                    current = ""
                end
            end
        else
            current = current .. char
        end
        
        i = i + 1
    end
    
    if current ~= "" then
        table.insert(args, current)
    end
    
    return args
end

-- Slash commands
SLASH_MEPH1 = "/meph"
SlashCmdList["MEPH"] = function(msg)
    local args = ParseQuotedArgs(msg)
    
    if args[1] == "target" and args[2] and args[3] and args[4] then
        AddTargetConfig(args[2], args[3], args[4])
    elseif args[1] == "list" then
        ListTargetConfigs()
    elseif args[1] == "wait" and args[2] then
        local newWait = tonumber(args[2])
        if newWait and newWait > 0 and newWait <= 3 then
            GRACE_PERIOD = newWait
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Grace period set to " .. newWait .. " seconds")
        else
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Invalid wait time. Use 0.1-3.0 seconds")
        end
    elseif args[1] == "debug" then
        DEBUG_MODE = not DEBUG_MODE
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Debug mode " .. (DEBUG_MODE and "ON" or "OFF"))
    elseif args[1] == "test" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Testing cast detection...")
        if targetConfigs[1] then
            OnTargetCastDetected(targetConfigs[1])
        end
    elseif args[1] == "debuff" then
        if currentConfig then
            local hasDebuff = HasTargetDebuff(currentConfig.debuff)
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Has " .. currentConfig.debuff .. " debuff: " .. (hasDebuff and "YES" or "NO"))
        else
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: No active configuration")
        end
    elseif args[1] == "reset" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Resetting all states...")
        castInProgress = false
        currentConfig = nil
        if debuffScanFrame then
            debuffScanFrame:SetScript("OnUpdate", nil)
        end
        RestoreMovementKeys()
    else
        DEFAULT_CHAT_FRAME:AddMessage("MEPH Commands:")
        DEFAULT_CHAT_FRAME:AddMessage('/meph target "caster" "spell" "debuff" - Add target')
        DEFAULT_CHAT_FRAME:AddMessage("/meph list - List targets")
        DEFAULT_CHAT_FRAME:AddMessage("/meph wait <seconds> - Set grace period")
        DEFAULT_CHAT_FRAME:AddMessage("/meph debug - Toggle debug")
        DEFAULT_CHAT_FRAME:AddMessage("/meph test - Test detection")
        DEFAULT_CHAT_FRAME:AddMessage("/meph debuff - Check debuff")
        DEFAULT_CHAT_FRAME:AddMessage("/meph reset - Reset all")
    end
end

-- Event frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE") 
frame:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_PARTY_DAMAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
frame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_CREATURE")
frame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_VS_PLAYER")
frame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLYPLAYER_VS_PLAYER")
frame:RegisterEvent("CHAT_MSG_COMBAT_PARTY_VS_CREATURE")
frame:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
frame:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    local event = event
    local arg1 = arg1
    
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Loaded successfully!")
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Type /meph for commands")
        StoreOriginalBindings()
        ListTargetConfigs()
    else
        OnChatMessage(event, arg1)
    end
end)

DEFAULT_CHAT_FRAME:AddMessage("MEPH: Ready!")
