--[[
    BLOOMBET BOT (Deposit + Withdrawal)
    Runs via Delta executor on MuMu Player instance running MM2.

    Deposit flow:
      1. Auto-accepts every incoming trade request.
      2. Hooks InventoryDataChanged to capture items that arrive in bot inventory.
      3. Clicks Accept → Confirm, then POSTs to bridge → backend.

    Withdrawal flow:
      1. Polls /pending-withdrawal every 3 seconds.
      2. When a withdrawal is queued, waits for the target player to enter this server.
      3. Waits for the target player to send the bot a trade request (bot auto-accepts).
      4. Adds the requested items to the bot's offer side via Trade.OfferItem.
      5. Accepts + confirms, then POSTs /withdrawal-completed to bridge.

    Requires:
      - bloombet/bot/bridge.js running on the same machine (node bridge.js)
      - Delta executor (uses request() for HTTP)
--]]

-- FIXED: Bridge URL redirected to your actual PC Local IPv4 address for Emulator-to-Host communication
local BRIDGE_URL = "http://192.168.100.119:4000"

-- ─── Services ────────────────────────────────────────────────────────────────
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Players             = game:GetService("Players")
local HttpService         = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser         = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
local TradeFolder = ReplicatedStorage:WaitForChild("Trade")

-- ─── State ───────────────────────────────────────────────────────────────────
local INACTIVITY_LIMIT  = 25
local lastUpdate        = tick()
local inTrade           = false
local tradingPlayerId   = nil
local tradingPlayerName = nil
local tradeId           = tostring(tick())
local tradeCompleted    = false   -- set true when we fire reportTradeCompleted

-- Items that actually arrived in the bot's inventory this trade
local receivedItems   = {}
-- True when the bot has put items in its own offer (= withdrawal, not deposit)
local botIsOffering   = false

-- Withdrawal state
local pendingWithdrawal = nil   -- { withdrawalId, robloxUsername, items=[{name}] }
local withdrawalMode    = false -- true when current trade is a withdrawal

-- Reverse lookup: displayName → templateId
-- Primary: built from RS item template scan on startup.
-- Secondary: updated live via InventoryDataChanged as items flow through the bot.
local displayNameToTemplateId = {}

-- ─── HTTP helpers ─────────────────────────────────────────────────────────────
local function httpPost(path, data)
    local ok, err = pcall(function()
        request({
            Url     = BRIDGE_URL .. path,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode(data),
        })
    end)
    if not ok then
        warn("Bridge POST failed (" .. path .. "): " .. tostring(err))
    end
end

local function httpGet(path)
    local ok, res = pcall(function()
        return request({ Url = BRIDGE_URL .. path, Method = "GET" })
    end)
    if ok and res and res.StatusCode == 200 then
        local ok2, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if ok2 then return data end
    end
    return nil
end

-- ─── UI click helper ─────────────────────────────────────────────────────────
local function ClickUI(button)
    if button and button.Visible and button.AbsoluteSize.X > 0 then
        local x = button.AbsolutePosition.X + (button.AbsoluteSize.X / 2)
        local y = button.AbsolutePosition.Y + (button.AbsoluteSize.Y / 2) + 58
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true,  game, 1)
        task.wait(0.1)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
        return true
    end
    return false
end

-- ─── Resolve a display name from a MM2 template ID ───────────────────────────
local function resolveDisplayName(templateId)
    for _, v in pairs(ReplicatedStorage:GetDescendants()) do
        if v.Name == templateId then
            local dn = v:FindFirstChild("DisplayName") or v:FindFirstChild("ItemName")
            if dn and dn:IsA("StringValue") and #dn.Value > 0 then
                return dn.Value
            end
            local attr = v:GetAttribute("DisplayName") or v:GetAttribute("Name")
            if attr and #tostring(attr) > 0 then return tostring(attr) end
            break
        end
    end
    local name = templateId
        :gsub("_[A-Za-z]_%d+$", "")
        :gsub("_%d+$", "")
        :gsub("_[A-Za-z]$", "")
        :gsub("_", " ")
    name = name:gsub("(%l)(%u)", "%1 %2")
    name = name:match("^%s*(.-)%s*$")
    return (name and #name > 0) and name or templateId
end

-- ─── Build displayName → templateId from RS item templates (primary lookup) ───
local function buildItemLookup()
    local count = 0
    for _, v in pairs(ReplicatedStorage:GetDescendants()) do
        local dn = v:FindFirstChild("DisplayName") or v:FindFirstChild("ItemName")
        if dn and dn:IsA("StringValue") and #dn.Value > 0 then
            if not displayNameToTemplateId[dn.Value] then
                displayNameToTemplateId[dn.Value] = v.Name
                count = count + 1
            end
        end
        local attr = v:GetAttribute("DisplayName")
        if type(attr) == "string" and #attr > 0 then
            if not displayNameToTemplateId[attr] then
                displayNameToTemplateId[attr] = v.Name
                count = count + 1
            end
        end
    end
    print("✅ Item lookup built: " .. count .. " display name → template ID entries")
end

-- ─── Find template ID for a display name ─────────────────────────────────────
local function findInventoryItem(displayName)
    local templateId = displayNameToTemplateId[displayName]
    if templateId then
        print("🔍 '" .. displayName .. "' → template: " .. templateId)
        return templateId
    end
    -- Fallback: items like "Harvester" have templateId == displayName
    print("🔍 No RS entry for '" .. displayName .. "' — using name directly as template ID")
    return displayName
end

-- ─── Add an item to the bot's trade offer by template ID ─────────────────────
-- MM2 uses Trade.OfferItem:FireServer(templateId)
local function addItemToOffer(templateId)
    if not templateId then return false end
    local OfferItem = TradeFolder:FindFirstChild("OfferItem")
    if OfferItem and OfferItem:IsA("RemoteEvent") then
        pcall(function() OfferItem:FireServer(templateId) end)
        print("📤 Fired OfferItem — template: " .. tostring(templateId))
        return true
    end
    warn("⚠️ Trade.OfferItem not found in TradeFolder")
    return false
end

-- ─── Hook InventoryDataChanged ────────────────────────────────────────────────
local function hookInventoryDataChanged()
    for _, v in pairs(ReplicatedStorage:GetDescendants()) do
        if v.Name == "InventoryDataChanged" then
            local event = (v.ClassName == "BindableEvent" and v.Event)
                       or (v.ClassName == "RemoteEvent"   and v.OnClientEvent)
            if event then
                event:Connect(function(category, templateId, quantity)
                    if type(templateId) ~= "string" or #templateId == 0 then return end
                    -- Keep reverse lookup fresh (secondary source after RS scan)
                    local displayName = resolveDisplayName(templateId)
                    if not displayNameToTemplateId[displayName] then
                        displayNameToTemplateId[displayName] = templateId
                    end

                    if not inTrade then return end
                    if botIsOffering then
                        print("📤 Skipping InventoryDataChanged — bot is offering (withdrawal)")
                        return
                    end
                    print(string.format(
                        "📦 Item received: %s → '%s' (template: %s)   qty:%s",
                        tostring(category), displayName, templateId, tostring(quantity)
                    ))
                    local qty = tonumber(quantity)
                    if not qty or qty <= 0 then return end  -- skip leaving items (negative/nil qty)
                    for _ = 1, qty do
                        table.insert(receivedItems, { name = displayName, templateId = templateId, assetId = 0 })
                    end
                    lastUpdate = tick()
                end)
                print("✅ InventoryDataChanged hooked (" .. v.ClassName .. ")")
                return
            end
        end
    end
    warn("⚠️ InventoryDataChanged not found in ReplicatedStorage")
end

buildItemLookup()
hookInventoryDataChanged()

-- ─── UpdateOffers — detect if the bot is offering items (withdrawal trade) ───
TradeFolder.UpdateOffers.OnClientEvent:Connect(function(data)
    lastUpdate = tick()
    if type(data) ~= "table" then return end

    local tradeState = (data[1] and type(data[1]) == "table") and data[1] or data

    for _, key in ipairs({"Player1", "Player2"}) do
        local side = tradeState[key]
        if type(side) == "table" and side.Player == LocalPlayer then
            local offer = side.Offer
            botIsOffering = type(offer) == "table" and #offer > 0
            if botIsOffering then
                print("📤 Bot has items in offer — treating as withdrawal, deposits paused")
            end
            break
        end
    end
end)

-- ─── Resolve userId of the player trading with us ────────────────────────────
local function resolveTraderUserId(tradeGui)
    if tradingPlayerId then return tradingPlayerId end
    if tradeGui then
        for _, v in pairs(tradeGui:GetDescendants()) do
            if (v:IsA("TextLabel") or v:IsA("TextButton"))
               and (v.Name:lower():find("name") or v.Name:lower():find("player") or v.Name:lower():find("user"))
            then
                local player = Players:FindFirstChild(v.Text)
                if player and player ~= LocalPlayer then return player.UserId end
            end
        end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then return p.UserId end
    end
    return nil
end

-- ─── Check if partner has accepted ───────────────────────────────────────────
local function isPartnerReady(gui)
    for _, v in pairs(gui:GetDescendants()) do
        if v:IsA("TextLabel") or v:IsA("TextButton") then
            local txt = string.lower(v.Text)
            if string.find(txt, "accepted") or string.find(txt, "ready") then
                if string.find(txt, "other") or string.find(txt, "partner") or string.find(txt, "their") then
                    return true
                end
            end
        end
    end
    return false
end

-- ─── After trade fully resolves, notify backend ──────────────────────────────
local function reportTradeCompleted(tradeGui)
    tradeCompleted = true

    if withdrawalMode and pendingWithdrawal then
        print("✅ Withdrawal completed for " .. pendingWithdrawal.robloxUsername)
        httpPost("/withdrawal-completed", {
            withdrawalId  = pendingWithdrawal.withdrawalId,
            robloxTradeId = tradeId,
        })
        pendingWithdrawal = nil
        withdrawalMode    = false
        return
    end

    -- Deposit path
    local userId = resolveTraderUserId(tradeGui)
    local items  = receivedItems

    if not userId then
        warn("⚠️ Could not determine trader's userId — trade not reported")
        return
    end
    if #items == 0 then
        warn("⚠️ No items received (InventoryDataChanged may not have fired) — trade not reported")
        return
    end

    print(string.format("📦 Reporting trade: userId=%d, items=%d", userId, #items))
    for _, item in ipairs(items) do
        print(string.format("   • %s (template: %s)", item.name, item.templateId or "?"))
    end

    httpPost("/trade-completed", {
        robloxUserId = userId,
        tradeId      = tradeId,
        items        = items,
    })

    receivedItems = {}
end

-- ─── Hook trade lifecycle events ─────────────────────────────────────────────
TradeFolder.StartTrade.OnClientEvent:Connect(function(player)
    inTrade        = true
    lastUpdate     = tick()
    receivedItems  = {}
    botIsOffering  = false
    tradeCompleted = false
    tradeId        = tostring(math.floor(tick() * 1000))

    if typeof(player) == "Instance" and player:IsA("Player") then
        tradingPlayerId   = player.UserId
        tradingPlayerName = player.Name
    elseif type(player) == "number" then
        tradingPlayerId   = player
        local p           = Players:GetPlayerByUserId(player)
        tradingPlayerName = p and p.Name or "Unknown"
    elseif type(player) == "table" then
        for _, key in ipairs({"Player1", "Player2"}) do
            local side = player[key]
            if type(side) == "table" then
                local p = side.Player
                if typeof(p) == "Instance" and p:IsA("Player") and p ~= LocalPlayer then
                    tradingPlayerId   = p.UserId
                    tradingPlayerName = p.Name
                    break
                end
            end
        end
    else
        tradingPlayerId   = nil
        tradingPlayerName = nil
    end

    print("🤝 Trade started with:", tostring(tradingPlayerName), "(", tostring(tradingPlayerId), ")")

    -- Detect if this is a withdrawal trade
    if pendingWithdrawal and tradingPlayerName == pendingWithdrawal.robloxUsername then
        withdrawalMode = true
        print("📤 Withdrawal trade confirmed with " .. tradingPlayerName)
        -- Add items to the bot's offer side
        task.delay(1.5, function()
            if not inTrade then return end
            for _, wi in ipairs(pendingWithdrawal.items) do
                -- Use stored templateId from DB when available (exact MM2 template ID from deposit)
                -- Fall back to RS lookup or name-as-templateId for older items
                local templateId = (type(wi.templateId) == "string" and #wi.templateId > 0 and wi.templateId)
                    or findInventoryItem(wi.name)
                if templateId then
                    local added = addItemToOffer(templateId)
                    print(added and ("📤 Added to offer: " .. wi.name .. " (template: " .. templateId .. ")")
                               or ("⚠️ Failed to add: " .. wi.name))
                end
                task.wait(0.5)
            end
        end)
    end
end)

TradeFolder.EndTrade.OnClientEvent:Connect(function()
    -- If withdrawal trade ended without completing, report failure
    if withdrawalMode and pendingWithdrawal and not tradeCompleted then
        print("❌ Withdrawal trade ended without completion — reporting failure")
        httpPost("/withdrawal-failed", { withdrawalId = pendingWithdrawal.withdrawalId })
        pendingWithdrawal = nil
        withdrawalMode    = false
    end

    inTrade           = false
    tradingPlayerId   = nil
    tradingPlayerName = nil
    receivedItems     = {}
    botIsOffering     = false
    tradeCompleted    = false
end)

TradeFolder.UpdateTrade.OnClientEvent:Connect(function()
    lastUpdate = tick()
end)

-- ─── Poll bridge for pending withdrawal ───────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(3)
        if pendingWithdrawal or inTrade then continue end
        local data = httpGet("/pending-withdrawal")
        if data and data.withdrawal then
            pendingWithdrawal = data.withdrawal
            print(string.format("📤 Withdrawal queued: %s → %d item(s)",
                data.withdrawal.robloxUsername, #data.withdrawal.items))
            for _, wi in ipairs(data.withdrawal.items) do
                print("   •", wi.name)
            end
        end
    end
end)

-- ─── Watch for withdrawal target player to enter server ───────────────────────
-- The bot cannot send trade requests in MM2 — the player must send one to the bot.
task.spawn(function()
    local announced = false
    while true do
        task.wait(2)
        if not pendingWithdrawal or inTrade then
            announced = false
            continue
        end
        local targetPlayer = Players:FindFirstChild(pendingWithdrawal.robloxUsername)
        if targetPlayer and targetPlayer ~= LocalPlayer then
            if not announced then
                print("📤 Withdrawal target in server: " .. targetPlayer.Name
                    .. " — waiting for them to send a trade request")
                announced = true
            end
        else
            announced = false
        end
    end
end)

-- ─── Main loop ───────────────────────────────────────────────────────────────
print("🤖 BloomBet Bot started (deposit + withdrawal)")

task.spawn(function()
    while true do
        -- Auto-accept all incoming trade requests
        if not inTrade then
            pcall(function() TradeFolder.AcceptRequest:FireServer() end)
        end

        local tradeGui = PlayerGui:FindFirstChild("TradeGUI")
        if tradeGui and tradeGui.Enabled then
            inTrade = true

            if isPartnerReady(tradeGui) then
                local container = tradeGui:FindFirstChild("Container", true)
                local actions   = container and container:FindFirstChild("Actions", true)

                if actions then
                    local acceptBtn  = actions:FindFirstChild("Accept")
                    local confirmBtn = acceptBtn and acceptBtn:FindFirstChild("Confirm")

                    if confirmBtn and confirmBtn.Visible and confirmBtn.AbsoluteSize.X > 0 then
                        print("✅ Partner confirmed. Clicking final Confirm...")
                        local capturedGui = tradeGui
                        ClickUI(confirmBtn)
                        task.wait(2)
                        reportTradeCompleted(capturedGui)
                        task.wait(2)
                    elseif acceptBtn and acceptBtn.Visible then
                        print("📩 Partner accepted. Clicking Accept...")
                        ClickUI(acceptBtn)
                        task.wait(3)
                    end
                end
            end
        else
            if inTrade then
                inTrade         = false
                tradingPlayerId = nil
            end
        end

        task.wait(0.75)
    end
end)

-- ─── 25s inactivity auto-decline ─────────────────────────────────────────────
task.spawn(function()
    while task.wait(1) do
        if inTrade and (tick() - lastUpdate >= INACTIVITY_LIMIT) then
            print("⏰ 25s inactive. Declining trade.")
            pcall(function() TradeFolder.DeclineTrade:FireServer() end)
            inTrade         = false
            tradingPlayerId = nil
            receivedItems   = {}
            botIsOffering   = false
        end
    end
end)

-- ─── Anti-AFK ────────────────────────────────────────────────────────────────
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new(0, 0))
end)

print("✅ Bot running — bridge at " .. BRIDGE_URL)
