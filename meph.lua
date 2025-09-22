--[[
    MEPH IMPROVED: Simple Movement Disabler with Emergency Restore
    
    Simple system to disable movement keys when specific units cast specific spells.
    Waits for player to be stationary, then disables keys until debuff is gone.
    Added: Emergency restore timer to prevent permanent key lockouts.
--]]

-- Loading message removed to prevent reload crash

-- Saved Variables (persisted between logins)
MephDB = MephDB or {}

-- Simple timer system
local function CreateSimpleTimer(duration, callback)
    if not duration or not callback then return nil end
    local frame = CreateFrame("Frame")
    local elapsed = 0
    frame:SetScript("OnUpdate", function()
        if not arg1 then return end
        elapsed = elapsed + arg1
        if elapsed >= duration then
            frame:SetScript("OnUpdate", nil)
            if callback then callback() end
        end
    end)
    return frame
end

-- Configuration (loaded from saved variables)
local CAST_TIME = 3.0
local GRACE_PERIOD = 0.5
local DEBUG_MODE = false
local EMERGENCY_RESTORE_TIME = 12.0  -- Emergency restore keys after this time no matter what

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

-- Target configurations (loaded from saved variables)
local targetConfigs = {}

-- State tracking
local originalBindings = {}
local playerPos = {}
local castInProgress = false
local keysDisabled = false
local debuffScanFrame = nil
local stationaryStartTime = nil
local currentConfig = nil
local emergencyRestoreTimer = nil  -- New: Emergency restore timer
local addonLoaded = false  -- Track if addon is fully loaded

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

-- Restore movement keys function
local function RestoreMovementKeys()
    if not keysDisabled then return end
    
    for key, action in pairs(originalBindings) do
        SetBinding(key, action)
    end
    SaveBindings(2)
    
    keysDisabled = false
    originalBindings = {}
    
    -- Cancel emergency restore timer if it exists
    if emergencyRestoreTimer then
        emergencyRestoreTimer:SetScript("OnUpdate", nil)
        emergencyRestoreTimer = nil
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys RESTORED! YOU CAN MOVE!")
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
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys DISABLED!")
    
    -- NEW: Start emergency restore timer
    local emergencyTime = EMERGENCY_RESTORE_TIME  -- Capture current value
    emergencyRestoreTimer = CreateSimpleTimer(emergencyTime, function()
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: EMERGENCY RESTORE! Keys disabled for " .. emergencyTime .. " seconds!")
        -- Emergency restore should stop all scanning and force restore
        if debuffScanFrame then
            debuffScanFrame:SetScript("OnUpdate", nil)
        end
        castInProgress = false
        currentConfig = nil
        RestoreMovementKeys()
    end)
    
    return true
end


-- Debuff detection
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

-- Start debuff scanning with continued movement monitoring
local function StartDebuffScanning()
    if not currentConfig then return end
    
    if debuffScanFrame then
        debuffScanFrame:SetScript("OnUpdate", nil)
    end
    
    DebugMsg("Starting scan for debuff: " .. currentConfig.debuff)
    
    debuffScanFrame = CreateFrame("Frame")
    local scanElapsed = 0
    local debuffWasFound = false
    local scanStartTime = GetTime()
    local NO_DEBUFF_TIMEOUT = 1.5  -- Time to wait for debuff if none found
    
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
                    DebugMsg(currentConfig.debuff .. " debuff detected!")
                    debuffWasFound = true
                end
                
                -- CONTINUE trying to disable keys during debuff (extended grace period)
                if not keysDisabled then
                    DebugMsg("Debuff active - trying to disable keys...")
                    DisableMovementKeys()
                end
            else
                -- Debuff not found
                if debuffWasFound then
                    -- Debuff was there but now gone
                    DebugMsg(currentConfig.debuff .. " debuff GONE! Restoring keys...")
                    RestoreMovementKeys()
                    
                    -- Stop scanning
                    debuffScanFrame:SetScript("OnUpdate", nil)
                    castInProgress = false
                    currentConfig = nil
                else
                    -- Debuff was never found - CONTINUE trying to disable keys during timeout window
                    if not keysDisabled and totalScanTime < NO_DEBUFF_TIMEOUT then
                        DebugMsg("No debuff yet - still trying to disable keys...")
                        DisableMovementKeys()
                    end
                    
                    -- Check timeout
                    if totalScanTime >= NO_DEBUFF_TIMEOUT then
                        DebugMsg("No debuff found after " .. NO_DEBUFF_TIMEOUT .. "s (resisted?). Restoring keys...")
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
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. config.caster .. " casting " .. config.spell .. "! STOP MOVING NOW!!!")
    
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
                DebugMsg("CAST DETECTED: " .. message)
                OnTargetCastDetected(config)
                break
            end
        end
    end
end


-- Load settings from saved variables and initialize defaults
local function LoadSettings()
    -- DEBUG: Show what the hardcoded default is
    DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: Hardcoded EMERGENCY_RESTORE_TIME = " .. EMERGENCY_RESTORE_TIME)
    
    -- Ensure MephDB exists (SavedVariables might override our initial value)
    if not MephDB then
        MephDB = {}
    end
    
    -- Safely initialize targetConfigs with defaults if not present
    if not MephDB.targetConfigs or type(MephDB.targetConfigs) ~= "table" then
        MephDB.targetConfigs = {
            {
                caster = "Mephistroth",
                spell = "Shackles of the Legion", 
                debuff = "Shackles of the Legion"
            }
        }
    end
    
    -- Create a safe copy of targetConfigs to avoid reference issues during reload
    targetConfigs = {}
    for i, config in ipairs(MephDB.targetConfigs) do
        if config and config.caster and config.spell and config.debuff then
            targetConfigs[i] = {
                caster = config.caster,
                spell = config.spell,
                debuff = config.debuff
            }
        end
    end
    
    -- Safely initialize settings with defaults if not present
    if not MephDB.settings or type(MephDB.settings) ~= "table" then
        MephDB.settings = {
            CAST_TIME = 3.0,
            GRACE_PERIOD = 0.5,
            DEBUG_MODE = false
            -- EMERGENCY_RESTORE_TIME only added when user changes it
        }
    end
    
    -- Safely load settings from MephDB
    CAST_TIME = tonumber(MephDB.settings.CAST_TIME) or 3.0
    GRACE_PERIOD = tonumber(MephDB.settings.GRACE_PERIOD) or 0.5
    if MephDB.settings.DEBUG_MODE ~= nil then
        DEBUG_MODE = MephDB.settings.DEBUG_MODE
    else
        DEBUG_MODE = false
    end
    -- Use saved override or keep the hardcoded default
    if MephDB.settings.EMERGENCY_RESTORE_TIME then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: Found DB override = " .. MephDB.settings.EMERGENCY_RESTORE_TIME)
        EMERGENCY_RESTORE_TIME = tonumber(MephDB.settings.EMERGENCY_RESTORE_TIME)
    else
        DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: No DB override, using hardcoded default")
    end
    DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: Final EMERGENCY_RESTORE_TIME = " .. EMERGENCY_RESTORE_TIME)
    -- If no override in DB, EMERGENCY_RESTORE_TIME keeps its hardcoded default value
end


-- Add target configuration
local function AddTargetConfig(caster, spell, debuff)
    if not addonLoaded then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Addon not fully loaded yet. Please wait.")
        return
    end
    
    for i, config in ipairs(targetConfigs) do
        if config.caster == caster and config.spell == spell then
            config.debuff = debuff
            -- Also update MephDB since we're using copies now
            if MephDB.targetConfigs[i] then
                MephDB.targetConfigs[i].debuff = debuff
            end
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Updated target: " .. caster .. " -> " .. spell .. " -> " .. debuff)
            return
        end
    end
    
    local newConfig = {
        caster = caster,
        spell = spell,
        debuff = debuff
    }
    table.insert(targetConfigs, newConfig)
    -- Also add to MephDB since we're using copies now
    table.insert(MephDB.targetConfigs, {
        caster = caster,
        spell = spell,
        debuff = debuff
    })
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Added target: " .. caster .. " -> " .. spell .. " -> " .. debuff)
end

-- Remove target configuration
local function RemoveTargetConfig(index)
    if not addonLoaded then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Addon not fully loaded yet. Please wait.")
        return
    end
    
    local idx = tonumber(index)
    if idx and idx > 0 and idx <= table.getn(targetConfigs) then
        local config = targetConfigs[idx]
        table.remove(targetConfigs, idx)
        -- Also remove from MephDB since we're using copies now
        table.remove(MephDB.targetConfigs, idx)
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Removed target: " .. config.caster .. " -> " .. config.spell .. " -> " .. config.debuff)
    else
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Invalid target index. Use /meph list to see available targets")
    end
end

-- List configurations
local function ListTargetConfigs()
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Current target configurations:")
    if table.getn(targetConfigs) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("  No targets configured")
    else
        for i, config in ipairs(targetConfigs) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. i .. ". " .. config.caster .. " -> " .. config.spell .. " -> " .. config.debuff)
        end
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
    DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: Slash command called with: '" .. msg .. "'")
    local args = ParseQuotedArgs(msg)
    
    DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: Parsed args: [1]='" .. (args[1] or "nil") .. "' [2]='" .. (args[2] or "nil") .. "' [3]='" .. (args[3] or "nil") .. "' [4]='" .. (args[4] or "nil") .. "'")
    
    if args[1] == "target" and args[2] and args[3] and args[4] then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: Calling AddTargetConfig")
        AddTargetConfig(args[2], args[3], args[4])
    elseif args[1] == "remove" and args[2] then
        RemoveTargetConfig(args[2])
    elseif args[1] == "list" then
        ListTargetConfigs()
    elseif args[1] == "wait" and args[2] then
        if not addonLoaded then
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Addon not fully loaded yet. Please wait.")
            return
        end
        local newWait = tonumber(args[2])
        if newWait and newWait > 0 and newWait <= 3 then
            GRACE_PERIOD = newWait
            MephDB.settings.GRACE_PERIOD = newWait
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Grace period set to " .. newWait .. " seconds")
        else
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Invalid wait time. Use 0.1-3.0 seconds")
        end
    elseif args[1] == "emergency" and args[2] then
        if not addonLoaded then
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Addon not fully loaded yet. Please wait.")
            return
        end
        if args[2] == "reset" then
            -- Remove the database override to use hardcoded default
            MephDB.settings.EMERGENCY_RESTORE_TIME = nil
            -- Reset to hardcoded default (reload the settings)
            LoadSettings()
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Emergency restore time reset to default (" .. EMERGENCY_RESTORE_TIME .. " seconds)")
        else
            local newTime = tonumber(args[2])
            if newTime and newTime >= 5 and newTime <= 30 then
                EMERGENCY_RESTORE_TIME = newTime
                MephDB.settings.EMERGENCY_RESTORE_TIME = newTime
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: Emergency restore time set to " .. newTime .. " seconds")
            else
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: Invalid emergency time. Use 5-30 seconds or 'reset'")
            end
        end
    elseif args[1] == "debug" then
        if not addonLoaded then
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Addon not fully loaded yet. Please wait.")
            return
        end
        DEBUG_MODE = not DEBUG_MODE
        MephDB.settings.DEBUG_MODE = DEBUG_MODE
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
    elseif args[1] == "cleandups" then
        if not addonLoaded then
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Addon not fully loaded yet. Please wait.")
            return
        end
        -- Remove duplicate entries
        local seen = {}
        local cleaned = {}
        for _, config in ipairs(targetConfigs) do
            local key = config.caster .. "|" .. config.spell .. "|" .. config.debuff
            if not seen[key] then
                seen[key] = true
                table.insert(cleaned, {
                    caster = config.caster,
                    spell = config.spell,
                    debuff = config.debuff
                })
            end
        end
        targetConfigs = cleaned
        -- Create a safe copy for MephDB
        MephDB.targetConfigs = {}
        for i, config in ipairs(cleaned) do
            MephDB.targetConfigs[i] = {
                caster = config.caster,
                spell = config.spell,
                debuff = config.debuff
            }
        end
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Cleaned duplicate entries")
        ListTargetConfigs()
    elseif args[1] == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH STATUS:")
        DEFAULT_CHAT_FRAME:AddMessage("  addonLoaded: " .. tostring(addonLoaded))
        DEFAULT_CHAT_FRAME:AddMessage("  MephDB exists: " .. tostring(MephDB ~= nil))
        if MephDB then
            DEFAULT_CHAT_FRAME:AddMessage("  MephDB.settings exists: " .. tostring(MephDB.settings ~= nil))
            DEFAULT_CHAT_FRAME:AddMessage("  MephDB.targetConfigs exists: " .. tostring(MephDB.targetConfigs ~= nil))
        end
        DEFAULT_CHAT_FRAME:AddMessage("  targetConfigs count: " .. tostring(table.getn(targetConfigs)))
    else
        DEFAULT_CHAT_FRAME:AddMessage("MEPH Commands:")
        DEFAULT_CHAT_FRAME:AddMessage('/meph target "caster" "spell" "debuff" - Add target')
        DEFAULT_CHAT_FRAME:AddMessage("/meph remove <index> - Remove target by index")
        DEFAULT_CHAT_FRAME:AddMessage("/meph list - List targets")
        DEFAULT_CHAT_FRAME:AddMessage("/meph wait <seconds> - Set grace period")
        DEFAULT_CHAT_FRAME:AddMessage("/meph emergency <seconds> - Set emergency restore time (5-30s)")
        DEFAULT_CHAT_FRAME:AddMessage("/meph emergency reset - Reset emergency time to default")
        DEFAULT_CHAT_FRAME:AddMessage("/meph debug - Toggle debug")
        DEFAULT_CHAT_FRAME:AddMessage("/meph test - Test detection")
        DEFAULT_CHAT_FRAME:AddMessage("/meph debuff - Check debuff")
        DEFAULT_CHAT_FRAME:AddMessage("/meph reset - Reset all")
        DEFAULT_CHAT_FRAME:AddMessage("/meph cleandups - Remove duplicate entries")
        DEFAULT_CHAT_FRAME:AddMessage("/meph status - Show addon status")
        DEFAULT_CHAT_FRAME:AddMessage("NOTE: All settings are automatically saved!")
    end
end

-- Event frame with safe handling
local frame = CreateFrame("Frame", "MephEventFrame")

-- Event handler function
local function MephEventHandler()
    if not event or not arg1 then return end
    
    if event == "ADDON_LOADED" and arg1 == "meph" then
        -- Protect against multiple loads
        if addonLoaded then return end
        
        LoadSettings()  -- Load saved settings
        addonLoaded = true  -- Mark addon as fully loaded
        
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Loaded successfully!")
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Type /meph for commands")
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Emergency restore after " .. EMERGENCY_RESTORE_TIME .. " seconds")
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Debug mode " .. (DEBUG_MODE and "ON" or "OFF"))
        StoreOriginalBindings()
        ListTargetConfigs()
    else
        -- Only handle chat messages if addon is loaded
        if addonLoaded then
            OnChatMessage(event, arg1)
        end
    end
end

-- Register events
frame:RegisterEvent("ADDON_LOADED")
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

frame:SetScript("OnEvent", MephEventHandler)
