-- =============================================================================
-- BLOOMBET LIGHTWEIGHT AUTOMATION SCRIPT (DELTA REFIX)
-- =============================================================================

local BRIDGE_URL = "https://humorous-unpledged-grain.ngrok-free.dev"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local isProcessingTrade = false

-- ─── SIMPLE UNIVERSAL HTTP HANDLERS ──────────────────────────────────────────

local function httpGet(endpoint)
    local success, result = pcall(function()
        return game:HttpGet(BRIDGE_URL .. endpoint)
    end)
    if success then
        return HttpService:JSONDecode(result)
    else
        return nil
    end
end

local function httpPost(endpoint, payload)
    local success, result = pcall(function()
        -- Directly look for the universal request function without wrapping it
        local req = request or http_request or (syn and syn.request)
        if req then
            return req({
                Url = BRIDGE_URL .. endpoint,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload)
            })
        else
            -- Absolute fallback using native backend pipeline if request is completely hidden
            return game:HttpPostAsync(BRIDGE_URL .. endpoint, HttpService:JSONEncode(payload), "application/json")
        end
    end)
    return success
end

-- ─── SAFE INTERACTION FOR MOBILE UI ──────────────────────────────────────────

local function ClickUI(button)
    if button and button.Visible then
        pcall(function()
            -- Bypasses complex event scanning to prevent engine execution panics
            local guiService = game:GetService("GuiService")
            guiService.SelectedObject = button
            task.wait(0.05)
            button:Activate()
            guiService.SelectedObject = nil
        end)
    end
end

-- ─── DEPOSIT/TRADE LIFECYCLE ─────────────────────────────────────────────────

local function handleTradeWindow(partnerName)
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return end
    
    local tradeGui = playerGui:FindFirstChild("TradeGUI")
    if not tradeGui or not tradeGui:FindFirstChild("Container") then return end
    
    local container = tradeGui.Container
    if container.Visible and container:FindFirstChild("Main") then
        local main = container.Main
        local partnerLabel = main:FindFirstChild("PartnerLabel")
        
        if partnerLabel and string.find(string.lower(partnerLabel.Text), string.lower(partnerName)) then
            -- 1. Click Accept if partner accepted
            local partnerStatus = main:FindFirstChild("PartnerStatus")
            local acceptBtn = main:FindFirstChild("AcceptButton")
            
            if partnerStatus and partnerStatus.Text == "Accepted" and acceptBtn then
                print("📩 Partner accepted. Triggering click...")
                ClickUI(acceptBtn)
            end
            
            -- 2. Click Final Confirm
            local finalConfirmBtn = main:FindFirstChild("ConfirmButton")
            if finalConfirmBtn and finalConfirmBtn.Visible then
                print("✅ Partner confirmed. Triggering final confirmation...")
                ClickUI(finalConfirmBtn)
            end
        end
    end
end

local function hookInventoryDataChanged()
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
                        local cleanName = string.gsub(string.gsub(rawText, "Trading With: ", ""), " ", "")
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
                print("🏁 Trade window closed. Notifying local bridge...")
                isProcessingTrade = false
                
                -- Dynamic extraction fallback logic
                local currentTradePartner = "Unknown"
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= LocalPlayer then
                        currentTradePartner = p.Name
                        break
                    end
                end
                
                local targetPlayer = Players:FindFirstChild(currentTradePartner)
                local targetId = targetPlayer and targetPlayer.UserId or 0
                local tradedItems = {{ name = "Blue Seer", assetId = 0 }}
                
                httpPost("/trade-completed", {
                    userId = targetId,
                    tradeId = "mm2-" .. tostring(os.time()),
                    items = tradedItems
                })
            end
        end
    end)
    print("📋 Systems hooked and tracking inventory states.")
end

-- ─── CORE WITHDRAWAL POLLING LOOP ───────────────────────────────────────────

local function startWithdrawalPollingLoop()
    print("🔁 Outbound active polling process instantiated.")
    while true do
        if not isProcessingTrade then
            local data = httpGet("/pending-withdrawal")
            if data and data.withdrawal then
                local job = data.withdrawal
                print("🚨 Received pending queue item for: " .. tostring(job.robloxUsername))
                
                local targetUser = Players:FindFirstChild(job.robloxUsername)
                if not targetUser then
                    warn("❌ Targeted withdrawal recipient is not in this instance.")
                end
            end
        end
        task.wait(4) -- Polling interval
    end
end

-- ─── SYSTEM INITIALIZATION ───────────────────────────────────────────────────

task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    print("⏳ Game loaded. Delaying execution startup for assets to settle...")
    task.wait(5)
    
    hookInventoryDataChanged()
    startWithdrawalPollingLoop()
end)
