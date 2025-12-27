--[[
    MEPH: Movement Blocker with Key Unbinding

    When a configured boss casts a spell:
    1. Block ALL keyboard input immediately
    2. Unbind movement keys (safe - keys released during block)
    3. Unblock keyboard (keys stay unbound)
    4. Wait for debuff to expire
    5. Rebind movement keys
--]]

-- Initialize saved variables on load
MephDB = MephDB or {}

-- Set defaults if not present
local function InitializeDB()
    if not MephDB.targets then
        MephDB.targets = {
            {
                caster = "Mephistroth", 
                spell = "Shackles of the Legion", 
                debuff = "Shackles of the Legion",
                scanDuration = 5.0 -- Covers 3s cast + 2s buffer
            }
        }
    end
    -- Backward compatibility for existing DB
    if MephDB.targets then
        for _, target in ipairs(MephDB.targets) do
            if not target.scanDuration then
                target.scanDuration = 5.0
            end
        end
    end

    if not MephDB.emergency_time then
        MephDB.emergency_time = 12.0
    end
    if MephDB.debug == nil then
        MephDB.debug = false
    end
end

-- State
local blockFrame = nil
local isBlocking = false
local debuffScanFrame = nil
local activeConfig = nil
local emergencyTimer = nil
local keysUnbound = false
local savedBindings = {}
local playerPos = {lastX = 0, lastY = 0, lastTime = 0}
local unbindFrame = nil  -- Global reference to movement check frame

-- Debug window
local debugWindow = nil
local debugEditBox = nil
local debugText = ""

-- Create debug window
local function CreateDebugWindow()
    if debugWindow then return end

    -- Main frame
    debugWindow = CreateFrame("Frame", "MephDebugWindow", UIParent)
    debugWindow:SetWidth(600)
    debugWindow:SetHeight(500)
    debugWindow:SetPoint("CENTER", 0, 0)
    debugWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = {left = 11, right = 12, top = 12, bottom = 11}
    })
    debugWindow:SetMovable(true)
    debugWindow:EnableMouse(true)
    debugWindow:RegisterForDrag("LeftButton")
    debugWindow:SetScript("OnDragStart", function() this:StartMoving() end)
    debugWindow:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    debugWindow:Hide()

    -- Title
    local title = debugWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("MEPH Debug Log")

    -- Close button (also disables debug mode)
    local closeButton = CreateFrame("Button", nil, debugWindow, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    closeButton:SetScript("OnClick", function()
        debugWindow:Hide()
        MephDB.debug = false
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Debug mode OFF")
    end)

    -- Select All button
    local selectButton = CreateFrame("Button", nil, debugWindow, "UIPanelButtonTemplate")
    selectButton:SetWidth(80)
    selectButton:SetHeight(22)
    selectButton:SetPoint("BOTTOMLEFT", 20, 15)
    selectButton:SetText("Select All")
    selectButton:SetScript("OnClick", function()
        if debugEditBox then
            debugEditBox:HighlightText()
            debugEditBox:SetFocus()
        end
    end)

    -- Clear button
    local clearButton = CreateFrame("Button", nil, debugWindow, "UIPanelButtonTemplate")
    clearButton:SetWidth(60)
    clearButton:SetHeight(22)
    clearButton:SetPoint("LEFT", selectButton, "RIGHT", 5, 0)
    clearButton:SetText("Clear")
    clearButton:SetScript("OnClick", function()
        debugText = ""
        if debugEditBox then
            debugEditBox:SetText("")
        end
    end)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "MephDebugScroll", debugWindow, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 20, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 50)

    -- Edit box (properly sized for scrolling)
    debugEditBox = CreateFrame("EditBox", nil, scrollFrame)
    debugEditBox:SetMultiLine(true)
    debugEditBox:SetFontObject(ChatFontNormal)
    debugEditBox:SetWidth(scrollFrame:GetWidth())
    debugEditBox:SetHeight(5000)  -- Large fixed height for scrolling
    debugEditBox:SetMaxLetters(0)  -- No character limit
    debugEditBox:SetAutoFocus(false)
    debugEditBox:EnableMouse(true)
    debugEditBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

    scrollFrame:SetScrollChild(debugEditBox)
end

-- Debug output (always captures, always outputs to debug window)
local function Debug(msg)
    local timestamp = date("%H:%M:%S")
    local logMsg = "[" .. timestamp .. "] " .. msg

    -- ALWAYS add to debugText buffer (even if window closed)
    debugText = debugText .. logMsg .. "\n"

    -- Update window if it exists
    if debugEditBox then
        debugEditBox:SetText(debugText)

        -- Scroll to bottom
        local scrollFrame = debugEditBox:GetParent()
        if scrollFrame then
            scrollFrame:UpdateScrollChildRect()
            local maxScroll = scrollFrame:GetVerticalScrollRange()
            if maxScroll and maxScroll > 0 then
                scrollFrame:SetVerticalScroll(maxScroll)
            end
        end
    end
end

-- Create the blocking frame
local function CreateBlockFrame()
    if blockFrame then return end

    blockFrame = CreateFrame("Frame", "MephBlockFrame")
    blockFrame:SetFrameStrata("TOOLTIP")
    blockFrame:EnableKeyboard(false)
end

-- Start blocking ALL keyboard input
local function BlockKeys()
    if isBlocking then return end

    if not blockFrame then CreateBlockFrame() end

    blockFrame:EnableKeyboard(true)
    blockFrame:SetScript("OnKeyDown", function() end)  -- Eat all key presses
    blockFrame:SetScript("OnKeyUp", function() end)    -- Eat all key releases

    isBlocking = true
    Debug("KEYS BLOCKED!")
end

-- Stop blocking keyboard
local function StopBlocking()
    if not isBlocking then return end

    if blockFrame then
        blockFrame:EnableKeyboard(false)
        blockFrame:SetScript("OnKeyDown", nil)
        blockFrame:SetScript("OnKeyUp", nil)
    end

    isBlocking = false
    Debug("Keyboard blocking disabled")
end

-- Check if player is moving by comparing coordinates
local function IsPlayerMoving()
    local x, y = GetPlayerMapPosition("player")

    -- If coordinates are 0,0 (player not on world map), consider as not moving
    if x == 0 and y == 0 then
        return false
    end

    local moved = (x ~= playerPos.lastX or y ~= playerPos.lastY)
    playerPos.lastX = x
    playerPos.lastY = y

    return moved
end

-- Store original bindings (EXACT COPY FROM WORKING VERSION)
local function StoreOriginalBindings()
    savedBindings = {}

    -- Don't unbind TOGGLEAUTORUN so player can stop auto-run!
    -- Don't unbind turn since turning doesn't break shackles
    local actions = {"MOVEFORWARD", "MOVEBACKWARD", "STRAFELEFT", "STRAFERIGHT", "JUMP"}

    for i = 1, GetNumBindings() do
        local command, key1, key2 = GetBinding(i)

        for _, movementAction in ipairs(actions) do
            if command == movementAction then
                if key1 then
                    savedBindings[key1] = command
                    Debug("Saved binding: " .. key1 .. " = " .. command)
                end
                if key2 then
                    savedBindings[key2] = command
                    Debug("Saved binding: " .. key2 .. " = " .. command)
                end
                break
            end
        end
    end
    -- Count hash table entries manually
    local count = 0
    for _ in pairs(savedBindings) do count = count + 1 end
    Debug("Total keys saved: " .. count)
end

-- Unbind movement keys
local function UnbindKeys()
    if keysUnbound then
        Debug("UnbindKeys called but already unbound")
        return
    end

    Debug("Unbinding keys...")
    for key, action in pairs(savedBindings) do
        SetBinding(key)  -- Unbind
        Debug("  Unbound: " .. key .. " (was " .. action .. ")")
    end
    SaveBindings(2)

    keysUnbound = true
    Debug("All keys unbound")
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys DISABLED!")
end

-- Rebind movement keys (EXACT COPY FROM WORKING VERSION)
local function RebindKeys()
    Debug("RebindKeys called")
    StopBlocking()  -- Always stop blocking first

    -- Stop movement check frame if it's still running
    if unbindFrame then
        unbindFrame:SetScript("OnUpdate", nil)
        unbindFrame = nil
        Debug("Stopped movement check frame from RebindKeys")
    end

    Debug("Rebinding keys...")
    for key, action in pairs(savedBindings) do
        SetBinding(key, action)
        Debug("  Rebound: " .. key .. " = " .. action)
    end
    SaveBindings(2)

    keysUnbound = false
    savedBindings = {}

    Debug("Movement keys RESTORED! YOU CAN MOVE!")
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: Movement keys RESTORED! YOU CAN MOVE!")
end

-- Check if player has a specific debuff
local tooltip = CreateFrame("GameTooltip", "MephScanTooltip", nil, "GameTooltipTemplate")
tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function GetDebuffName(index)
    tooltip:ClearLines()
    tooltip:SetUnitDebuff("player", index)
    return MephScanTooltipTextLeft1:GetText()
end

local function HasDebuff(name)
    for i = 1, 16 do
        if UnitDebuff("player", i) then
            local debuffName = GetDebuffName(i)
            if debuffName and string.lower(debuffName) == string.lower(name) then
                return true
            end
        end
    end
    return false
end

-- Scan for debuff and rebind when gone
local function StartDebuffScan(debuffName, maxDuration)
    if debuffScanFrame then
        debuffScanFrame:SetScript("OnUpdate", nil)
    end
    
    local limit = maxDuration or 5.0
    Debug("Starting debuff scan for: " .. debuffName .. " (limit: " .. limit .. "s)")

    local scanTimer = 0
    local debuffFound = false
    local startTime = GetTime()
    local scanCount = 0

    debuffScanFrame = CreateFrame("Frame")
    debuffScanFrame:SetScript("OnUpdate", function()
        scanTimer = scanTimer + arg1

        if scanTimer >= 0.1 then
            scanTimer = 0
            scanCount = scanCount + 1

            local hasIt = HasDebuff(debuffName)
            local elapsed = GetTime() - startTime

            if hasIt then
                if not debuffFound then
                    Debug("Debuff FOUND! (scan #" .. scanCount .. ", elapsed: " .. string.format("%.1f", elapsed) .. "s)")
                end
                debuffFound = true
            else
                if debuffFound then
                    -- Debuff was there, now it's gone - REBIND KEYS
                    Debug("Debuff EXPIRED (scan #" .. scanCount .. ", elapsed: " .. string.format("%.1f", elapsed) .. "s)")
                    RebindKeys()

                    -- Clean up
                    debuffScanFrame:SetScript("OnUpdate", nil)
                    activeConfig = nil
                    if emergencyTimer then
                        emergencyTimer:SetScript("OnUpdate", nil)
                        emergencyTimer = nil
                    end
                    Debug("Debuff scan cleanup complete")
                else
                    -- Never found debuff - timeout after specified duration (limit)
                    if elapsed >= limit then
                        Debug("Debuff NEVER FOUND - timeout after " .. string.format("%.1f", elapsed) .. "s (resisted?)")
                        RebindKeys()
                        debuffScanFrame:SetScript("OnUpdate", nil)
                        activeConfig = nil
                        if emergencyTimer then
                            emergencyTimer:SetScript("OnUpdate", nil)
                            emergencyTimer = nil
                        end
                        Debug("Timeout cleanup complete")
                    end
                end
            end
        end
    end)
end

-- Emergency restore timer
local function StartEmergencyTimer()
    if emergencyTimer then
        emergencyTimer:SetScript("OnUpdate", nil)
    end

    Debug("Emergency timer started (" .. MephDB.emergency_time .. "s)")

    local elapsed = 0
    emergencyTimer = CreateFrame("Frame")
    emergencyTimer:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed >= MephDB.emergency_time then
            Debug("EMERGENCY RESTORE TRIGGERED! (" .. string.format("%.1f", elapsed) .. "s)")
            StopBlocking()
            RebindKeys()
            if debuffScanFrame then
                debuffScanFrame:SetScript("OnUpdate", nil)
            end
            activeConfig = nil
            emergencyTimer:SetScript("OnUpdate", nil)
            Debug("Emergency restore complete")
        end
    end)
end

-- Handle cast detection
local function OnCastDetected(config)
    if activeConfig then return end  -- Already active

    activeConfig = config
    Debug(config.caster .. " casting " .. config.spell .. "!")
    DEFAULT_CHAT_FRAME:AddMessage("MEPH: " .. config.caster .. " casting " .. config.spell .. "! STOP MOVING NOW!!!")

    -- STEP 1: BLOCK keyboard immediately
    BlockKeys()

    -- STEP 2: Save current bindings
    StoreOriginalBindings()

    -- STEP 3: Initialize position tracking
    local x, y = GetPlayerMapPosition("player")
    playerPos.lastX = x
    playerPos.lastY = y
    Debug("Initial position: " .. x .. ", " .. y)

    -- STEP 4: Monitor for safe moment to unbind (no time limit, wait as long as needed)
    -- Stop previous movement check frame if it exists
    if unbindFrame then
        unbindFrame:SetScript("OnUpdate", nil)
        Debug("Stopped previous movement check frame")
    end

    local checkTimer = 0
    local stationaryTime = 0
    local totalElapsed = 0
    local checkCount = 0
    unbindFrame = CreateFrame("Frame")
    unbindFrame:SetScript("OnUpdate", function()
        checkTimer = checkTimer + arg1
        totalElapsed = totalElapsed + arg1

        -- Check movement every 0.1 seconds
        if checkTimer >= 0.1 then
            checkTimer = 0
            checkCount = checkCount + 1

            local isMoving = IsPlayerMoving()

            if isMoving then
                -- Player is moving, reset stationary timer
                if stationaryTime > 0 then
                    Debug("Player moved after being stationary for " .. string.format("%.1f", stationaryTime) .. "s")
                end
                stationaryTime = 0
            else
                -- Player is stationary, accumulate time
                stationaryTime = stationaryTime + 0.1
                Debug("Stationary: " .. string.format("%.1f", stationaryTime) .. "s (check #" .. checkCount .. ", elapsed: " .. string.format("%.1f", totalElapsed) .. "s)")

                -- If player has been stationary for 0.7 seconds AND we're still in active sequence, safe to unbind
                if stationaryTime >= 0.7 and not keysUnbound and activeConfig then
                    Debug("Stationary threshold reached! Unbinding now...")
                    UnbindKeys()

                    -- Wait another 0.5 seconds, THEN stop blocking
                    Debug("Waiting 0.5s before unblocking...")
                    local postTimer = 0
                    local postFrame = CreateFrame("Frame")
                    postFrame:SetScript("OnUpdate", function()
                        postTimer = postTimer + arg1
                        if postTimer >= 0.5 then
                            StopBlocking()
                            postFrame:SetScript("OnUpdate", nil)
                            Debug("Unblocking complete")
                        end
                    end)

                    unbindFrame:SetScript("OnUpdate", nil)
                    unbindFrame = nil
                    Debug("Movement check frame stopped")
                end
            end
        end
    end)

    -- Start scanning for debuff (will rebind when debuff expires)
    StartDebuffScan(config.debuff, config.scanDuration)

    -- Start emergency timer
    StartEmergencyTimer()
end

-- Chat event handler
local function OnChatEvent(event, message)
    if not message then return end

    for _, config in ipairs(MephDB.targets) do
        if string.find(message, config.caster) and string.find(message, config.spell) then
            if string.find(message, "begins to cast") or string.find(message, "casts") then
                Debug("Cast detected: " .. message)
                OnCastDetected(config)
                break
            end
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
    local args = ParseQuotedArgs(msg)

    if args[1] == "debug" then
        -- Toggle debug mode
        if MephDB.debug then
            -- Turn OFF
            MephDB.debug = false
            if debugWindow then
                debugWindow:Hide()
            end
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Debug mode OFF")
        else
            -- Turn ON
            MephDB.debug = true
            CreateDebugWindow()
            if debugWindow then
                -- Update with any messages that were logged while window was closed
                if debugEditBox and debugText ~= "" then
                    debugEditBox:SetText(debugText)
                    local scrollFrame = debugEditBox:GetParent()
                    if scrollFrame then
                        scrollFrame:UpdateScrollChildRect()
                        local maxScroll = scrollFrame:GetVerticalScrollRange()
                        if maxScroll and maxScroll > 0 then
                            scrollFrame:SetVerticalScroll(maxScroll)
                        end
                    end
                end
                debugWindow:Show()
            end
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Debug mode ON (window opened)")
        end

    elseif args[1] == "add" and args[2] and args[3] and args[4] then
        -- /meph add "Livinport" "Frostbolt" "Frostbolt" [duration]
        local newTarget = {
            caster = args[2],
            spell = args[3],
            debuff = args[4],
            scanDuration = tonumber(args[5]) or 5.0
        }
        table.insert(MephDB.targets, newTarget)
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Added target: " .. args[2] .. " -> " .. args[3] .. " -> " .. args[4] .. " (timeout: " .. newTarget.scanDuration .. "s)")

    elseif args[1] == "remove" and args[2] then
        local idx = tonumber(args[2])
        if idx and idx > 0 and idx <= table.getn(MephDB.targets) then
            local removed = MephDB.targets[idx]
            table.remove(MephDB.targets, idx)
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Removed: " .. removed.caster .. " -> " .. removed.spell)
        else
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: Invalid index. Use /meph list to see targets")
        end

    elseif args[1] == "list" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Targets:")
        if table.getn(MephDB.targets) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("  (none)")
        else
            for i, config in ipairs(MephDB.targets) do
                DEFAULT_CHAT_FRAME:AddMessage("  " .. i .. ". " .. config.caster .. " -> " .. config.spell .. " -> " .. config.debuff)
            end
        end

    elseif args[1] == "test" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Testing with first config...")
        if MephDB.targets[1] then
            OnCastDetected(MephDB.targets[1])
        else
            DEFAULT_CHAT_FRAME:AddMessage("MEPH: No targets configured!")
        end

    elseif args[1] == "testblock" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Testing block for 3 seconds...")
        BlockKeys()
        local timer = 0
        local frame = CreateFrame("Frame")
        frame:SetScript("OnUpdate", function()
            timer = timer + arg1
            if timer >= 3.0 then
                StopBlocking()
                DEFAULT_CHAT_FRAME:AddMessage("MEPH: Block test complete!")
                frame:SetScript("OnUpdate", nil)
            end
        end)

    elseif args[1] == "reset" then
        DEFAULT_CHAT_FRAME:AddMessage("MEPH: Resetting...")
        StopBlocking()
        RebindKeys()
        activeConfig = nil
        if debuffScanFrame then
            debuffScanFrame:SetScript("OnUpdate", nil)
        end
        if emergencyTimer then
            emergencyTimer:SetScript("OnUpdate", nil)
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("MEPH Commands:")
        DEFAULT_CHAT_FRAME:AddMessage('  /meph add "caster" "spell" "debuff" - Add target')
        DEFAULT_CHAT_FRAME:AddMessage("  /meph remove <index> - Remove target")
        DEFAULT_CHAT_FRAME:AddMessage("  /meph list - List targets")
        DEFAULT_CHAT_FRAME:AddMessage("  /meph test - Test with first target")
        DEFAULT_CHAT_FRAME:AddMessage("  /meph testblock - Test blocking for 3 seconds")
        DEFAULT_CHAT_FRAME:AddMessage("  /meph debug - Toggle debug window")
        DEFAULT_CHAT_FRAME:AddMessage("  /meph reset - Emergency reset")
    end
end

-- Event registration
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PARTY_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
eventFrame:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "meph" then
        InitializeDB()
        Debug("MEPH addon loaded! Type /meph for help")
    else
        OnChatEvent(event, arg1)
    end
end)
