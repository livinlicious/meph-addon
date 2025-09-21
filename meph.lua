--[[
    MEPH FINAL: Universal Cast-Based Movement Disabler
    
    Configurable system to disable movement keys when specific units cast specific spells.
    Monitors for cast detection, waits for player to be stationary (with grace period),
    then disables movement keys until the specified debuff is gone.
    
    Features:
    - Multiple target/spell/debuff configurations
    - Adjustable grace period for safe key disabling
    - Debug mode for testing and monitoring
    - Built-in Mephistroth configuration
--]]

DEFAULT_CHAT_FRAME:AddMessage("MEPH FINAL: Loading universal movement disabler...")

-- Include timer functionality
local DT_Timer = DT_Timer or {}

-- Generate timer function
local function GenerateTimer()
    local Timer = CreateFrame("Frame")
    local TimerObject = {}

    Timer.Infinite = 0
    Timer.ElapsedTime = 0

    function Timer:Start(duration, callback)
        if type(duration) ~= "number" then
            duration = 0
        end

        self:SetScript("OnUpdate", function()
            self.ElapsedTime = self.ElapsedTime + arg1

            if self.ElapsedTime >= duration and type(callback) == "function" then
                callback()
                self.ElapsedTime = 0

                if self.Infinite == 0 then
                    self:SetScript("OnUpdate", nil)
                elseif self.Infinite > 0 then
                    self.Infinite = self.Infinite - 1
                end
            end
        end)
    end

    function TimerObject:IsCancelled()
        return not Timer:GetScript("OnUpdate")
    end

    function TimerObject:Cancel()
        if Timer:GetScript("OnUpdate") then
            Timer:SetScript("OnUpdate", nil)
            Timer.Infinite = 0
            Timer.ElapsedTime = 0
        end
    end

    return Timer, TimerObject
end

-- Initialize DT_Timer if not available
if not DT_Timer.After then
    DT_Timer = {
        After = function(duration, callback)
            GenerateTimer():Start(duration, callback)
        end,
        NewTimer = function(duration, callback)
            local timer, timerObj = GenerateTimer()
            timer:Start(duration, callback)
            return timerObj
        end,
        NewTicker = function(duration, callback, ...)
            local timer, timerObj = GenerateTimer()
            local iterations = unpack(arg)

            if type(iterations) ~= "number" or iterations < 0 then
                iterations = -1  -- Infinite loop
            end

            timer.Infinite = iterations == -1 and -1 or iterations - 1
            timer:Start(duration, callback)
            return timerObj
        end
    }
end

-- Configuration
local CAST_TIME = 3.0  -- Default cast monitoring time
local MOVEMENT_KEYS = { "W", "A", "S", "D", "Q", "E", "UP", "DOWN", "LEFT", "RIGHT", "SPACE" }
local STATIONARY_GRACE_PERIOD = 0.5  -- Default 0.5 seconds grace period
local DEBUG_MODE = true  -- Show debug messages

-- Target configurations - table of {caster, spell, debuff}
local targetConfigs = {
    -- Built-in Mephistroth configuration
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
local debuffActive = false
local keysDisabled = false
local debuffScanTimer = nil
local stationaryStartTime = nil
local currentConfig = nil  -- Which config triggered the current cast

-- Debug function
local function DebugMsg(msg)
    if DEBUG_MODE then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH DEBUG: " .. msg)
    end
end

-- Function to detect if player is currently moving
local function IsPlayerMoving()
    local x, y = GetPlayerMapPosition("player")
    local now = GetTime()
    
    if not playerPos.lastX then
        playerPos.lastX, playerPos.lastY = x, y
        playerPos.lastTime = now
        return false
    end
    
    -- Check every 0.1 seconds for position changes
    if now - (playerPos.lastTime or 0) < 0.1 then
        return playerPos.wasMoving or false
    end
    
    local moved = (x ~= playerPos.lastX or y ~= playerPos.lastY)
    playerPos.lastX, playerPos.lastY = x, y
    playerPos.lastTime = now
    playerPos.wasMoving = moved
    
    -- Track when player stops/starts moving for grace period
    if moved then
        -- Player is moving, reset stationary timer
        stationaryStartTime = nil
    else
        -- Player is not moving, start/continue stationary timer
        if not stationaryStartTime then
            stationaryStartTime = now
        end
    end
    
    return moved
end

-- Function to store original movement key bindings
local function StoreOriginalBindings()
    originalBindings = {}
    for _, key in ipairs(MOVEMENT_KEYS) do
        originalBindings[key] = GetBindingAction(key)
    end
    DebugMsg("Stored original bindings")
end

-- Function to disable movement keys (only when stationary for grace period)
local function DisableMovementKeys()
    if keysDisabled then return end
    
    local isMoving = IsPlayerMoving()
    local now = GetTime()
    
    if isMoving then
        DebugMsg("Player still moving, waiting...")
        return false
    end
    
    -- Check if player has been stationary long enough
    if not stationaryStartTime then
        DebugMsg("Player just stopped, starting grace period...")
        return false
    end
    
    local stationaryDuration = now - stationaryStartTime
    if stationaryDuration < STATIONARY_GRACE_PERIOD then
        DebugMsg("Grace period active (" .. string.format("%.1f", stationaryDuration) .. "s/" .. STATIONARY_GRACE_PERIOD .. "s)")
        return false
    end
    
    -- Store bindings if not already stored
    if not next(originalBindings) then
        StoreOriginalBindings()
    end
    
    -- Disable each movement key
    for _, key in ipairs(MOVEMENT_KEYS) do
        SetBinding(key)  -- Unbind the key
    end
    SaveBindings(2)
    
    keysDisabled = true
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys DISABLED! Player stationary for " .. string.format("%.1f", stationaryDuration) .. "s")
    
    return true
end

-- Function to restore original movement key bindings
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

-- Function to check if player has specified debuff
local function HasTargetDebuff(debuffName)
    -- Create tooltip for scanning debuff names
    if not MephFinalTooltip then
        MephFinalTooltip = CreateFrame("GameTooltip", "MephFinalTooltip", nil, "GameTooltipTemplate")
        MephFinalTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    
    -- Check debuffs
    for i = 1, 16 do
        local debuffTexture = UnitDebuff("player", i)
        if debuffTexture then
            MephFinalTooltip:ClearLines()
            MephFinalTooltip:SetUnitDebuff("player", i)
            local foundDebuffName = MephFinalTooltipTextLeft1:GetText()
            
            if foundDebuffName and string.find(string.lower(foundDebuffName), string.lower(debuffName)) then
                return true
            end
        end
    end
    
    return false
end

-- Function to start debuff scanning
local function StartDebuffScanning()
    if not currentConfig then return end
    
    if debuffScanTimer then
        debuffScanTimer:Cancel()
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Starting scan for debuff: " .. currentConfig.debuff)
    debuffActive = true
    
    -- Scan every 0.5 seconds for the debuff
    debuffScanTimer = DT_Timer.NewTicker(0.5, function()
        local hasDebuff = HasTargetDebuff(currentConfig.debuff)
        
        if hasDebuff then
            -- Debuff is still active, keep scanning
            if not debuffActive then
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. currentConfig.debuff .. " debuff detected!")
                debuffActive = true
            end
        else
            -- Debuff is gone!
            if debuffActive then
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. currentConfig.debuff .. " debuff GONE! Restoring keys...")
                debuffActive = false
                RestoreMovementKeys()
                
                -- Stop scanning
                if debuffScanTimer then
                    debuffScanTimer:Cancel()
                    debuffScanTimer = nil
                end
                
                -- Reset cast state
                castInProgress = false
                currentConfig = nil
            end
        end
    end)
end

-- Function to handle cast detection and start monitoring
local function OnTargetCastDetected(config)
    if castInProgress then return end  -- Prevent duplicate triggers
    
    castInProgress = true
    currentConfig = config
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. config.caster .. " casting " .. config.spell .. "! Starting monitoring...")
    
    -- Start monitoring for movement stops during the cast
    local castStartTime = GetTime()
    local monitorTimer = nil
    
    monitorTimer = DT_Timer.NewTicker(0.1, function()  -- Check every 0.1 seconds
        local elapsed = GetTime() - castStartTime
        
        if elapsed >= CAST_TIME then
            -- Cast finished, start debuff scanning regardless
            DebugMsg("Cast finished, starting debuff scan...")
            StartDebuffScanning()
            
            -- If keys weren't disabled during cast, try one more time
            if not keysDisabled then
                DebugMsg("Keys not disabled during cast, trying final disable...")
                DisableMovementKeys()
            end
            
            if monitorTimer then
                monitorTimer:Cancel()
            end
            return
        end
        
        -- During cast: try to disable keys when player stops moving
        if not keysDisabled then
            if DisableMovementKeys() then
                DebugMsg("Keys disabled during cast! Waiting for debuff...")
            end
        end
    end)
end

-- Chat message event handler - looking for configured casts
local function OnChatMessage(event, message)
    if not message then return end
    
    -- Check each configured target
    for _, config in ipairs(targetConfigs) do
        if string.find(message, config.caster) and string.find(message, config.spell) then
            if string.find(message, "begins to cast") or string.find(message, "casts") then
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: CAST DETECTED: " .. message)
                OnTargetCastDetected(config)
                break  -- Only trigger once per message
            end
        end
    end
end

-- Function to add a new target configuration
local function AddTargetConfig(caster, spell, debuff)
    -- Check if this configuration already exists
    for i, config in ipairs(targetConfigs) do
        if config.caster == caster and config.spell == spell then
            -- Update existing configuration
            config.debuff = debuff
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Updated target: " .. caster .. " -> " .. spell .. " -> " .. debuff)
            return
        end
    end
    
    -- Add new configuration
    table.insert(targetConfigs, {
        caster = caster,
        spell = spell,
        debuff = debuff
    })
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Added target: " .. caster .. " -> " .. spell .. " -> " .. debuff)
end

-- Function to list all target configurations
local function ListTargetConfigs()
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Current target configurations:")
    for i, config in ipairs(targetConfigs) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. i .. ". " .. config.caster .. " -> " .. config.spell .. " -> " .. config.debuff)
    end
end

-- Function to parse quoted arguments
local function ParseQuotedArgs(msg)
    local args = {}
    local current = ""
    local inQuotes = false
    local i = 1
    
    while i <= string.len(msg) do
        local char = string.sub(msg, i, i)
        
        if char == '"' then
            if inQuotes then
                -- End of quoted string
                if current ~= "" then
                    table.insert(args, current)
                    current = ""
                end
                inQuotes = false
            else
                -- Start of quoted string
                inQuotes = true
            end
        elseif char == " " then
            if inQuotes then
                -- Space inside quotes, add to current
                current = current .. char
            else
                -- Space outside quotes, end current arg
                if current ~= "" then
                    table.insert(args, current)
                    current = ""
                end
            end
        else
            -- Regular character
            current = current .. char
        end
        
        i = i + 1
    end
    
    -- Add final argument if exists
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
            STATIONARY_GRACE_PERIOD = newWait
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
    elseif args[1] == "moving" then
        local moving = IsPlayerMoving()
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Player moving: " .. (moving and "YES" or "NO"))
    elseif args[1] == "debuff" then
        if currentConfig then
            local hasDebuff = HasTargetDebuff(currentConfig.debuff)
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Has " .. currentConfig.debuff .. " debuff: " .. (hasDebuff and "YES" or "NO"))
        else
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: No active configuration")
        end
    elseif args[1] == "disable" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Manual disable test...")
        DisableMovementKeys()
    elseif args[1] == "restore" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Manual restore test...")
        RestoreMovementKeys()
    elseif args[1] == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Status Report:")
        DEFAULT_CHAT_FRAME:AddMessage("  Cast in progress: " .. (castInProgress and "YES" or "NO"))
        DEFAULT_CHAT_FRAME:AddMessage("  Keys disabled: " .. (keysDisabled and "YES" or "NO"))
        DEFAULT_CHAT_FRAME:AddMessage("  Debuff active: " .. (debuffActive and "YES" or "NO"))
        DEFAULT_CHAT_FRAME:AddMessage("  Player moving: " .. (IsPlayerMoving() and "YES" or "NO"))
        DEFAULT_CHAT_FRAME:AddMessage("  Grace period: " .. STATIONARY_GRACE_PERIOD .. "s")
        DEFAULT_CHAT_FRAME:AddMessage("  Debug mode: " .. (DEBUG_MODE and "ON" or "OFF"))
    elseif args[1] == "reset" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Resetting all states...")
        castInProgress = false
        debuffActive = false
        currentConfig = nil
        if debuffScanTimer then
            debuffScanTimer:Cancel()
            debuffScanTimer = nil
        end
        RestoreMovementKeys()
    else
        DEFAULT_CHAT_FRAME:AddMessage("MEPH Commands:")
        DEFAULT_CHAT_FRAME:AddMessage('/meph target "caster" "spell" "debuff" - Add/update target')
        DEFAULT_CHAT_FRAME:AddMessage('Example: /meph target "Mephistroth" "Shackles of the Legion" "Shackles of the Legion"')
        DEFAULT_CHAT_FRAME:AddMessage("/meph list - List all targets")
        DEFAULT_CHAT_FRAME:AddMessage("/meph wait <seconds> - Set grace period (current: " .. STATIONARY_GRACE_PERIOD .. "s)")
        DEFAULT_CHAT_FRAME:AddMessage("/meph debug - Toggle debug mode")
        DEFAULT_CHAT_FRAME:AddMessage("/meph test - Test cast detection")
        DEFAULT_CHAT_FRAME:AddMessage("/meph moving - Check if player is moving")
        DEFAULT_CHAT_FRAME:AddMessage("/meph debuff - Check for active debuff")
        DEFAULT_CHAT_FRAME:AddMessage("/meph status - Show current status")
        DEFAULT_CHAT_FRAME:AddMessage("/meph reset - Reset all states")
        DEFAULT_CHAT_FRAME:AddMessage("/meph disable/restore - Manual key control")
    end
end

-- Create event frame
local frame = CreateFrame("Frame")

-- Register events for spell casting messages
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

-- Event handler
frame:SetScript("OnEvent", function()
    local event = event
    local arg1 = arg1
    
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH FINAL: Loaded successfully!")
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Monitoring " .. table.getn(targetConfigs) .. " target(s)")
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Type /meph for commands")
        
        -- Store initial bindings
        StoreOriginalBindings()
        
        -- Show initial configuration
        ListTargetConfigs()
    else
        -- Handle chat messages
        OnChatMessage(event, arg1)
    end
end)

DEFAULT_CHAT_FRAME:AddMessage("MEPH FINAL: Universal movement disabler ready!")
