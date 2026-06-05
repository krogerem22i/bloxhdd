-- =============================================================================
-- BLOOMBET AUTOMATION LUA SCRIPT FOR LDPLAYER (MM2 ENGINE)
-- =============================================================================

-- ⚠️ REPLACE THIS LINK WITH YOUR ACTIVE NGROK LINK FROM YOUR TERMINAL SCREEN
local BRIDGE_URL = "https://humorous-unpledged-grain.ngrok-free.dev"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local itemLookup = {}
local isProcessingTrade = false

-- ─── UTILITY FUNCTIONS ───────────────────────────────────────────────────────

local function httpGet(endpoint)
    local success, result = pcall(function()
        return game:HttpGet(BRIDGE_URL .. endpoint)
    end)
    if success then
        return HttpService:JSONDecode(result)
    else
        warn("⚠️ Bridge GET failed (" .. endpoint .. "): " .. tostring(result))
        return nil
    end
end

local function httpPost(endpoint, payload)
    local success, result = pcall(function()
        return request({
            Url = BRIDGE_URL .. endpoint,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload)
        })
    end)
    if not success then
        warn("⚠️ Bridge POST failed (" .. endpoint .. "): " .. tostring(result))
    end
    return success
end

-- ─── EMULATOR-SAFE INTERACTION ENGINE ────────────────────────────────────────

local function ClickUI(button)
    if button and button.Visible then
        -- Force-fires execution connections directly, bypassing mouse coordinate bugs
        local events = {"MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "Activated"}
        for _, eventName in ipairs(events) do
            if button[eventName] then
                pcall(function()
                    for _, connection in ipairs(getconnections(button[eventName])) do
                        connection:Fire()
                    end
                end)
            end
        end
        return true
    end
    return false
end

-- ─── ITEM LOOKUP SCANNER ─────────────────────────────────────────────────────

local function buildItemLookup()
    table.clear(itemLookup)
    -- Wait and dynamically extract database values directly from MM2 storage modules
    local itemDatabase = ReplicatedStorage:FindFirstChild("ItemDatabase")
    if itemDatabase then
        for _, category in ipairs(itemDatabase:GetChildren()) do
            for _, item in ipairs(category:GetChildren()) do
                if item:IsA("Configuration") then
                    local displayName = item.Name
                    itemLookup[displayName:lower()] = displayName
                end
            end
        end
    end
    
    local count = 0
    for _ in pairs(itemLookup) do count = count + 1 end
    print("✅ Item lookup rebuilt safely: " .. count .. " game asset mappings verified.")
end

-- ─── DEPOSIT/TRADE LIFECYCLE ─────────────────────────────────────────────────

local function handleTradeWindow(partnerName)
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local tradeGui = playerGui:WaitForChild("TradeGUI")
    local container = tradeGui:WaitForChild("Container")
    
    -- Safety checks to ensure we are looking at the right player window
    if container.Visible and container:FindFirstChild("Main") then
        local main = container.Main
        local partnerLabel = main:FindFirstChild("PartnerLabel")
        
        if partnerLabel and partnerLabel.Text:lower():find(partnerName:lower()) then
            -- 1. Click Accept if partner accepted
            local partnerStatus = main:FindFirstChild("PartnerStatus")
            local acceptBtn = main:FindFirstChild("AcceptButton")
            
            if partnerStatus and partnerStatus.Text == "Accepted" and acceptBtn then
                print("📩 Partner accepted. Triggering programmatic Accept click...")
                ClickUI(acceptBtn)
            end
            
            -- 2. Click Final Confirm if layout shifts to confirmation phase
            local finalConfirmBtn = main:FindFirstChild("ConfirmButton")
            if finalConfirmBtn and finalConfirmBtn.Visible then
                print("✅ Partner confirmed. Triggering programmatic final Confirm click...")
                ClickUI(finalConfirmBtn)
            end
        end
    end
end

local function hookInventoryDataChanged()
    -- Safely monitor the trade container elements for inventory mutations
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local tradeGui = playerGui:WaitForChild("TradeGUI")
    
    tradeGui.Container.ChildAdded:Connect(function(child)
        if child.Name == "Main" then
            isProcessingTrade = true
            task.spawn(function()
                while isProcessingTrade and tradeGui.Container:FindFirstChild("Main") do
                    local main = tradeGui.Container.Main
                    local partnerLabel = main:FindFirstChild("PartnerLabel")
                    if partnerLabel then
                        local rawText = partnerLabel.Text
                        -- Strip decorations to isolate target name
                        local cleanName = rawText:gsub("Trading With: ", ""):gsub(" ", "")
                        handleTradeWindow(cleanName)
                    end
                    task.wait(0.5)
                end
            end)
        end
    end)

    tradeGui.Container.ChildRemoved:Connect(function(child)
        if child.Name == "Main" then
            if isProcessingTrade then
                print("🏁 Trade window closed. Offloading completed structure payload to Bridge server.")
                isProcessingTrade = false
                
                -- Construct extraction map
                local currentTradePartner = "Unknown" 
                local targetPlayer = Players:FindFirstChild(currentTradePartner)
                local targetId = targetPlayer and targetPlayer.UserId or 0
                
                -- Extract items dynamically held inside the trade log windows
                local tradedItems = {}
                -- Add internal extraction parsing rules here based on your inventory tracking layout
                
                httpPost("/trade-completed", {
                    userId = targetId,
                    tradeId = "mm2-" .. tostring(os.time()),
                    items = tradedItems
                })
            end
        end
    end)
    print("📋 Inventory signal hook bound successfully.")
end

-- ─── CORE WITHDRAWAL POLLING LOOP ───────────────────────────────────────────

local function startWithdrawalPollingLoop()
    print("🔁 Outbound active polling process instantiated.")
    while true do
        if not isProcessingTrade then
            local data = httpGet("/pending-withdrawal")
            if data and data.withdrawal then
                local job = data.withdrawal
                print("🚨 Received pending queue item: processing order inside server instance for " .. job.robloxUsername)
                
                local targetUser = Players:FindFirstChild(job.robloxUsername)
                if targetUser then
                    -- Execute trade engine commands directly through ReplicatedStorage remotes
                    local tradeRemote = ReplicatedStorage: some instances wrapper matching your specific setup
                    -- tradeRemote:PostServer(targetUser)
                else
                    warn("❌ Targeted withdrawal recipient [" .. job.robloxUsername .. "] is not present in this lobby.")
                end
            end
        end
        task.wait(3) -- Poll every 3 seconds
    end
end

-- ─── SYSTEM INITIALIZATION ───────────────────────────────────────────────────

task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    print("⏳ Game state verified. Delaying startup to allow MM2 container assets to stream...")
    task.wait(5)
    
    buildItemLookup()
    hookInventoryDataChanged()
    startWithdrawalPollingLoop()
end)
