-- ==========================================
-- LOAD RAYFIELD UI
-- ==========================================
local Rayfield
local ok = pcall(function()
    Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)

if not ok or not Rayfield then
    Rayfield = loadstring(game:HttpGet("https://raw.githubusercontent.com/shlexware/Rayfield/main/source"))()
end

-- ==========================================
-- SERVICES & MODULE ASLI GAME
-- ==========================================
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local RootPart = Character:WaitForChild("HumanoidRootPart")

local function safeRequire(parent, childName)
    if not parent then return nil end
    local mod = parent:FindFirstChild(childName)
    if not mod then return nil end
    local success, res = pcall(require, mod)
    return success and res or nil
end

local SharedFolder = ReplicatedStorage:FindFirstChild("Shared")
local AnimalRagdoll = safeRequire(SharedFolder, "AnimalRagdoll")
local RagdollPhysics = safeRequire(SharedFolder, "RagdollPhysics")

local State = {
    -- Auto Carry Zone 1 & Auto Drop Smart Swap (Max 1 Pet)
    AutoGrab = false,
    TargetValueRaw = "10B",
    MinTargetNumber = 1e10,
    AntiRagdoll = true,
    OffsetY = 2.0,

    -- Webhook Discord (Aktif di latar belakang, tersembunyi dari menu)
    WebhookEnabled = true,
    WebhookURL = "https://discord.com/api/webhooks/1402712477778841621/g53BUnZ91SQFI8YF8T42o4--hkGjpGZvOZ778iKe8UQK4joKiVemzzaEkKgKCiGSz2hB",
    PingText = "@everyone",
    WebhookCooldown = 2
}

local isBusy = false
local sentCache = {}

-- Cache weak per model pet, blacklist pet (nama + value) 30 detik, & jeda drop 6 detik
local PetInfoCache = setmetatable({}, { __mode = "k" })
local PetBlacklist = {}
local DroppedCooldown = {}
local ActiveTarget = nil

local PET_BLACKLIST_TTL = 30
local ZONE_CACHE_TTL = 15

LocalPlayer.CharacterAdded:Connect(function(newChar)
    Character = newChar
    RootPart = newChar:WaitForChild("HumanoidRootPart")
end)

local httpRequest = (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

-- ==========================================
-- KONVERSI SUFFIX VALUE (K, M, B, T, QA, QI...)
-- ==========================================
local SuffixMultipliers = {
    k = 1e3, m = 1e6, b = 1e9, t = 1e12,
    qa = 1e15, qi = 1e18, sx = 1e21, sp = 1e24,
    oc = 1e27, no = 1e30, dc = 1e33
}

local function formatShortNumber(num)
    if type(num) ~= "number" or num ~= num or num == math.huge then return "0" end
    if num >= 1e33 then return string.format("%.2fDc", num / 1e33) end
    if num >= 1e30 then return string.format("%.2fNo", num / 1e30) end
    if num >= 1e27 then return string.format("%.2fOc", num / 1e27) end
    if num >= 1e24 then return string.format("%.2fSp", num / 1e24) end
    if num >= 1e21 then return string.format("%.2fSx", num / 1e21) end
    if num >= 1e18 then return string.format("%.2fQi", num / 1e18) end
    if num >= 1e15 then return string.format("%.2fQa", num / 1e15) end
    if num >= 1e12 then return string.format("%.2fT", num / 1e12) end
    if num >= 1e9 then return string.format("%.2fB", num / 1e9) end
    if num >= 1e6 then return string.format("%.2fM", num / 1e6) end
    if num >= 1e3 then return string.format("%.2fK", num / 1e3) end
    return tostring(math.floor(num))
end

local function parseValueLine(line)
    local cleaned = tostring(line):lower():gsub("<[^>]+>", ""):gsub("[,%s]", "")
    local numStr, suffix = cleaned:match("([%d%.]+)([a-z]*)")
    local baseNum = tonumber(numStr)
    if not baseNum or baseNum ~= baseNum or baseNum == math.huge then
        return 0
    end

    local result = 0
    if suffix == "" or suffix == "s" or suffix == "sec" then
        result = baseNum
    elseif SuffixMultipliers[suffix] then
        result = baseNum * SuffixMultipliers[suffix]
    end

    if result ~= result or result == math.huge then
        return 0
    end
    return result
end

local function parseValue(rawInput)
    if type(rawInput) == "number" then
        return (rawInput > 0 and rawInput < math.huge) and rawInput or 0
    end
    if type(rawInput) ~= "string" then
        return 0
    end

    local text = rawInput:gsub("<[bB][rR]%s*/?>", "\n")
    local best = 0
    for line in text:gmatch("[^\n\r]+") do
        local value = parseValueLine(line)
        if value > best then
            best = value
        end
    end
    return best
end

local function shortText(text, maxLen)
    if not text then return "-" end
    local flat = tostring(text):gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    if #flat > maxLen then
        flat = flat:sub(1, maxLen) .. "..."
    end
    return flat
end

local function cleanGuiText(rawText)
    if type(rawText) ~= "string" then return "" end
    return rawText:gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

-- ==========================================
-- PEMBACAAN ANIMALOVERHEAD -> CASHPERSECOND & MUTASI + CACHE WEAK
-- ==========================================
local function isGuiVisibleChain(inst, stopAt)
    local cur = inst
    while cur and cur ~= stopAt do
        if cur:IsA("GuiObject") and cur.Visible == false then
            return false
        end
        cur = cur.Parent
    end
    return true
end

local function isTimerElement(inst, stopAt)
    local cur = inst
    while cur and cur ~= stopAt do
        if cur.Name:lower():find("timer", 1, true) then
            return true
        end
        cur = cur.Parent
    end
    return false
end

local function extractTextFromNode(node, requireVisible, stopAt)
    if not node then return nil end
    if requireVisible and not isGuiVisibleChain(node, stopAt) then
        return nil
    end

    if node:IsA("TextLabel") or node:IsA("TextButton") then
        local txt = cleanGuiText(node.Text)
        if txt ~= "" then
            return txt
        end
    end

    for _, sub in ipairs(node:GetDescendants()) do
        if sub:IsA("TextLabel") or sub:IsA("TextButton") then
            if not requireVisible or isGuiVisibleChain(sub, stopAt) then
                local txt = cleanGuiText(sub.Text)
                if txt ~= "" then
                    return txt
                end
            end
        end
    end
    return nil
end

local function readMutationFromContainer(container)
    if not container then return nil end
    local invalidMutationWords = {
        [""] = true, ["-"] = true, ["none"] = true, ["normal"] = true, ["mutation"] = true
    }

    local attrMut = container:GetAttribute("Mutation") or container:GetAttribute("Trait")
    if not attrMut then
        local animModel = container:FindFirstChild("AnimalModel")
        if animModel then
            attrMut = animModel:GetAttribute("Mutation") or animModel:GetAttribute("Trait")
        end
    end
    if type(attrMut) == "string" then
        local cleanedAttr = cleanGuiText(attrMut)
        if not invalidMutationWords[cleanedAttr:lower()] then
            return cleanedAttr
        end
    end

    local mutNode = container:FindFirstChild("Mutation", true)
    if mutNode then
        local txt = extractTextFromNode(mutNode, true, container)
        if txt and not invalidMutationWords[txt:lower()] then
            return txt
        end
    end

    for _, desc in ipairs(container:GetDescendants()) do
        if desc.Name:lower():find("mutation", 1, true) then
            local txt = extractTextFromNode(desc, true, container)
            if txt and not invalidMutationWords[txt:lower()] then
                return txt
            end
        end
    end

    return nil
end

local function readPetInfo(container)
    if not container then
        return { value = 0, raw = nil, rarity = nil, mutation = nil }
    end

    local cached = PetInfoCache[container]
    if cached then
        return cached
    end

    local bestVal = 0
    local bestRaw = nil
    local rarityText = nil
    local mutationText = readMutationFromContainer(container)

    local function tryText(rawText)
        if type(rawText) ~= "string" or rawText == "" then return end
        local clean = cleanGuiText(rawText)
        if clean == "" then return end
        if not bestRaw then
            bestRaw = clean
        end
        local v = parseValueLine(clean)
        if v > bestVal then
            bestVal = v
            bestRaw = clean
        end
    end

    local function scanBillboard(bb)
        if not bb then return end

        -- 1. Prioritas utama: AnimalOverhead > CashPerSecond (abaikan Timer)
        for _, d in ipairs(bb:GetDescendants()) do
            if d.Name == "CashPerSecond" and not isTimerElement(d, bb) then
                if d:IsA("TextLabel") then
                    tryText(d.Text)
                else
                    local innerLabel = d:FindFirstChild("CashPerSecond")
                    if innerLabel and innerLabel:IsA("TextLabel") then
                        tryText(innerLabel.Text)
                    end
                    for _, sub in ipairs(d:GetDescendants()) do
                        if sub:IsA("TextLabel") then
                            tryText(sub.Text)
                        end
                    end
                end
            end
        end

        -- 2. Ambil Rarity / Mutation & cadangan teks berakhiran "/s" di luar Timer
        for _, d in ipairs(bb:GetDescendants()) do
            if d:IsA("TextLabel") and d.Text ~= "" and not isTimerElement(d, bb) then
                local clean = cleanGuiText(d.Text)
                if bestVal == 0 and (clean:lower():find("/s", 1, true) or clean:find("%$")) then
                    tryText(clean)
                elseif d.Name == "Rarity" or d.Name == "RarityLabel" then
                    rarityText = clean
                elseif d.Name == "Mutation" and not mutationText then
                    mutationText = readMutationFromContainer(bb)
                end
            end
        end
    end

    for _, desc in ipairs(container:GetDescendants()) do
        if desc:IsA("BillboardGui") then
            scanBillboard(desc)
        end
    end

    if bestVal == 0 then
        local function checkExternalGuis(root)
            if not root then return end
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("BillboardGui") and desc.Adornee then
                    if desc.Adornee == container or desc.Adornee:IsDescendantOf(container) then
                        scanBillboard(desc)
                        if not mutationText then
                            mutationText = readMutationFromContainer(desc)
                        end
                    end
                end
            end
        end

        checkExternalGuis(LocalPlayer:FindFirstChild("PlayerGui"))
        if bestVal == 0 then
            checkExternalGuis(workspace)
        end
    end

    local info = {
        value = bestVal,
        raw = bestRaw,
        rarity = rarityText,
        mutation = mutationText
    }

    if bestVal > 0 then
        PetInfoCache[container] = info
    end

    return info
end

-- ==========================================
-- DETEKSI STATUS BAWAAN (MAX 1 PET + AUTO DROP SWAP)
-- ==========================================
local Carry = {
    obj = nil,
    value = 0,
    name = "-",
    pending = nil,
    cooldownUntil = 0
}

local function getCarryCount()
    local count = LocalPlayer:GetAttribute("CarryCount")
    if type(count) == "number" then
        return count
    end
    return 0
end

local function isPetTool(tool)
    if not tool or not tool:IsA("Tool") then return false end
    return tool:FindFirstChild("AnimalModel", true) ~= nil
        or tool:FindFirstChild("AnimalOverhead", true) ~= nil
end

local function findActiveCarriedPet()
    if Character then
        for _, child in ipairs(Character:GetChildren()) do
            if isPetTool(child) then
                return child
            end
        end
    end

    local folder = workspace:FindFirstChild("CarriedAnimals")
    if folder then
        for _, child in ipairs(folder:GetChildren()) do
            if child.Name == LocalPlayer.Name or child.Name == tostring(LocalPlayer.UserId) then
                return (#child:GetChildren() > 0) and child:GetChildren()[1] or child
            end
            local owner = child:GetAttribute("Owner") or child:GetAttribute("Player") or child:GetAttribute("Carrier")
            if owner and (tostring(owner) == LocalPlayer.Name or tostring(owner) == tostring(LocalPlayer.UserId)) then
                return child
            end
        end
    end

    return nil
end

local function isPlayerCarrying()
    return getCarryCount() > 0 or findActiveCarriedPet() ~= nil
end

local function clearCarry()
    Carry.obj = nil
    Carry.value = 0
    Carry.name = "-"
end

local function syncCarriedState()
    local activeObj = findActiveCarriedPet()
    local carrying = isPlayerCarrying()

    if not carrying then
        if Carry.obj or Carry.value > 0 then
            clearCarry()
        end
        return false
    end

    if activeObj then
        Carry.obj = activeObj
        if Carry.value == 0 or Carry.name == "-" then
            local info = readPetInfo(activeObj)
            if info.value > 0 then
                Carry.value = info.value
            end
            if Carry.name == "-" then
                Carry.name = shortText(activeObj.Name, 32)
            end
        end
    end

    return true
end

local notifyTimes = {}
local function notifyThrottled(key, title, content, seconds)
    local now = tick()
    if notifyTimes[key] and (now - notifyTimes[key]) < (seconds or 15) then
        return
    end
    notifyTimes[key] = now
    pcall(function()
        Rayfield:Notify({
            Title = title,
            Content = content,
            Duration = 3.5
        })
    end)
end

-- ==========================================
-- FUNGSI WEBHOOK DISCORD (TANPA FITUR DESPAWN)
-- ==========================================
local function postToDiscord(titleText, animalName, extraData)
    if not httpRequest then return end
    if State.WebhookURL == "" or not State.WebhookURL:find("discord") then return end

    local payload = {
        content = (State.PingText ~= "" and State.PingText or nil),
        embeds = {{
            title = titleText,
            color = 5763719,
            fields = {
                {
                    name = "👤 Pemain",
                    value = string.format("%s (`@%s`)", LocalPlayer.DisplayName, LocalPlayer.Name),
                    inline = true
                },
                {
                    name = "🦁 Pet / Hewan",
                    value = "**" .. animalName .. "**",
                    inline = true
                },
                {
                    name = "📊 Detail & Value",
                    value = extraData,
                    inline = false
                },
                {
                    name = "🌐 Server JobId",
                    value = "```" .. (game.JobId ~= "" and game.JobId or "Private/Studio") .. "```",
                    inline = false
                }
            },
            footer = { text = "Break and Steal an Egg • " .. os.date("%d/%m/%Y %H:%M:%S") },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }}
    }

    task.spawn(function()
        pcall(function()
            httpRequest({
                Url = State.WebhookURL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload)
            })
        end)
    end)
end

local lastWebhookSentAt = 0
local function handleCarriedObject(targetObj)
    if not targetObj or not targetObj.Parent then return end

    local now = tick()
    if sentCache[targetObj] and (now - sentCache[targetObj]) < State.WebhookCooldown then
        return
    end
    sentCache[targetObj] = now

    local waitStart = tick()
    while (tick() - waitStart) < 1.0 do
        if not targetObj or not targetObj.Parent then return end
        if Carry.pending or isPlayerCarrying() then
            break
        end
        task.wait(0.1)
    end

    if not targetObj or not targetObj.Parent then return end

    local pending = Carry.pending
    if not pending and not isPlayerCarrying() then return end
    if (tick() - lastWebhookSentAt) < 2.5 then return end

    local actualObj = targetObj
    if targetObj.Name == LocalPlayer.Name and #targetObj:GetChildren() > 0 then
        actualObj = targetObj:GetChildren()[1]
    end

    local detectedInfo = readPetInfo(actualObj)
    local liveMutation = readMutationFromContainer(actualObj)
    local animalName = pending and tostring(pending.name) or shortText(actualObj.Name, 32)
    local finalVal = math.max(detectedInfo.value, pending and (pending.value or 0) or 0)
    local finalRarity = detectedInfo.rarity or (pending and pending.rarity)
    local finalMutation = liveMutation or detectedInfo.mutation or (pending and pending.mutation)

    Carry.obj = actualObj
    Carry.name = animalName
    if finalVal > 0 then
        Carry.value = finalVal
    end

    if not State.WebhookEnabled then return end
    lastWebhookSentAt = tick()

    local lines = { string.format("• **Income:** $%s/s", formatShortNumber(finalVal)) }
    if finalMutation then
        table.insert(lines, "• **Mutasi:** " .. tostring(finalMutation))
    end
    if finalRarity then
        table.insert(lines, "• **Rarity:** " .. tostring(finalRarity))
    end

    postToDiscord("🐾 Pet Zone 1 Berhasil Di-Carry!", animalName, table.concat(lines, "\n"))
end

task.spawn(function()
    local carriedFolder = workspace:WaitForChild("CarriedAnimals", 15)
    if carriedFolder then
        carriedFolder.ChildAdded:Connect(function(child)
            task.spawn(handleCarriedObject, child)
            if child:IsA("Folder") or child.Name == LocalPlayer.Name then
                child.ChildAdded:Connect(function(subChild)
                    task.spawn(handleCarriedObject, subChild)
                end)
            end
        end)
    end
end)

local function hookCharacterToolListener(char)
    if not char then return end
    char.ChildAdded:Connect(function(child)
        if isPetTool(child) then
            task.spawn(handleCarriedObject, child)
        end
    end)
end
hookCharacterToolListener(Character)
LocalPlayer.CharacterAdded:Connect(hookCharacterToolListener)

-- ==========================================
-- CACHE KOTAK SAFE ZONE & ZONE 1 (DISEGARKAN SESEKALI)
-- ==========================================
local FLOOR_EDGE_MARGIN = 8
local FLOOR_HEIGHT_MAX = 90

local function getBoxFromInstance(inst)
    if not inst then return nil, nil end
    if inst:IsA("BasePart") then
        return inst.CFrame, inst.Size
    elseif inst:IsA("Model") then
        local okBox, cf, size = pcall(function()
            return inst:GetBoundingBox()
        end)
        if okBox and cf and size then
            return cf, size
        end
    end
    return nil, nil
end

local function isPointInsideBox(cf, size, pos, marginXZ, marginY)
    if not cf or not size or not pos then return false end
    local rel = cf:PointToObjectSpace(pos)
    return math.abs(rel.X) <= (size.X * 0.5 + (marginXZ or 0))
        and math.abs(rel.Y) <= (size.Y * 0.5 + (marginY or 0))
        and math.abs(rel.Z) <= (size.Z * 0.5 + (marginXZ or 0))
end

local SafeZoneCache = {
    inst = nil,
    cf = nil,
    size = nil,
    lastRefresh = 0
}

local function getSafeZoneBox()
    local now = tick()
    if SafeZoneCache.cf and SafeZoneCache.inst and SafeZoneCache.inst.Parent
        and (now - SafeZoneCache.lastRefresh) < ZONE_CACHE_TTL then
        return SafeZoneCache.cf, SafeZoneCache.size
    end

    local build = workspace:FindFirstChild("Build")
    local hitboxes = build and build:FindFirstChild("ZoneHitboxes")
    local sz = hitboxes and hitboxes:FindFirstChild("SafeZone") or nil
    local cf, size = getBoxFromInstance(sz)

    SafeZoneCache.inst = sz
    SafeZoneCache.cf = cf
    SafeZoneCache.size = size
    SafeZoneCache.lastRefresh = now

    return cf, size
end

local function isInsideSafeZone(pos)
    local cf, size = getSafeZoneBox()
    return isPointInsideBox(cf, size, pos, 0, 12)
end

local Zone1Cache = {
    info = nil,
    lastRefresh = 0
}

local function getZone1Info()
    local now = tick()
    local cached = Zone1Cache.info
    if cached and (now - Zone1Cache.lastRefresh) < ZONE_CACHE_TTL then
        if (cached.build and cached.build.Parent) or (cached.hitbox and cached.hitbox.Parent) then
            return cached
        end
    end

    local build = workspace:FindFirstChild("Build")
    local hitboxes = build and build:FindFirstChild("ZoneHitboxes")
    local zoneBuilds = build and build:FindFirstChild("ZoneBuilds")

    local z1Hitbox = nil
    if hitboxes then
        z1Hitbox = hitboxes:FindFirstChild("Zone1")
        if not z1Hitbox then
            for _, child in ipairs(hitboxes:GetChildren()) do
                local low = child.Name:lower():gsub("%s+", "")
                if low == "zone1" or low == "zone1hitbox" then
                    z1Hitbox = child
                    break
                end
            end
        end
    end

    local z1Build = zoneBuilds and zoneBuilds:FindFirstChild("Zone1") or nil
    if not z1Hitbox and not z1Build then
        Zone1Cache.info = nil
        return nil
    end

    getSafeZoneBox()

    local floorParts = {}
    if z1Build then
        local partsContainer = z1Build:FindFirstChild("Parts") or z1Build
        for _, desc in ipairs(partsContainer:GetDescendants()) do
            if desc:IsA("BasePart") and not isInsideSafeZone(desc.Position) then
                table.insert(floorParts, desc)
            end
        end
    end

    local autoStandCF = nil
    if #floorParts > 0 then
        local sumPos = Vector3.zero
        for _, fp in ipairs(floorParts) do
            sumPos = sumPos + fp.Position
        end
        local centroid = sumPos / #floorParts

        local bestPart = nil
        local bestScore = math.huge
        for _, fp in ipairs(floorParts) do
            local topPos = Vector3.new(fp.Position.X, fp.Position.Y + fp.Size.Y * 0.5 + 3.2, fp.Position.Z)
            if not isInsideSafeZone(topPos) then
                local distToCenter = (fp.Position - centroid).Magnitude
                local areaBonus = math.min((fp.Size.X * fp.Size.Z) * 0.002, 20)
                local score = distToCenter - areaBonus
                if score < bestScore then
                    bestScore = score
                    bestPart = fp
                end
            end
        end

        if bestPart then
            autoStandCF = CFrame.new(
                bestPart.Position.X,
                bestPart.Position.Y + bestPart.Size.Y * 0.5 + 3.2,
                bestPart.Position.Z
            )
        end
    end

    local hCF, hSize = getBoxFromInstance(z1Hitbox)
    local bCF, bSize = getBoxFromInstance(z1Build)

    local info = {
        hitbox = z1Hitbox,
        hCF = hCF,
        hSize = hSize,
        build = z1Build,
        bCF = bCF,
        bSize = bSize,
        floorParts = floorParts,
        standCF = autoStandCF
    }

    Zone1Cache.info = info
    Zone1Cache.lastRefresh = now
    return info
end

local function isPositionInZone1(info, pos)
    if not info or not pos then return false end
    if isInsideSafeZone(pos) then
        return false
    end

    if info.floorParts and #info.floorParts > 0 then
        for _, fp in ipairs(info.floorParts) do
            if fp and fp.Parent then
                local rel = fp.CFrame:PointToObjectSpace(pos)
                if math.abs(rel.X) <= (fp.Size.X * 0.5 + FLOOR_EDGE_MARGIN)
                    and math.abs(rel.Z) <= (fp.Size.Z * 0.5 + FLOOR_EDGE_MARGIN)
                    and rel.Y >= -15 and rel.Y <= FLOOR_HEIGHT_MAX then
                    return true
                end
            end
        end
    end

    if info.hCF and isPointInsideBox(info.hCF, info.hSize, pos, 8, FLOOR_HEIGHT_MAX) then
        return true
    end

    if info.bCF and isPointInsideBox(info.bCF, info.bSize, pos, 20, FLOOR_HEIGHT_MAX) then
        return true
    end

    return false
end

local lastStreamRequest = 0
local function keepZoneStreamed(info)
    if not workspace.StreamingEnabled or not info then return end
    local cf = info.standCF or info.hCF or info.bCF
    if not cf then return end
    if (tick() - lastStreamRequest) < 5 then return end
    lastStreamRequest = tick()

    task.spawn(function()
        pcall(function()
            LocalPlayer:RequestStreamAroundAsync(cf.Position)
        end)
    end)
end

-- ==========================================
-- PELACAKAN STEALPROMPT (SISTEM LAMA) & BLACKLIST PET 30 DETIK
-- ==========================================
local RETRY_BASE_DELAY = 0.8
local RETRY_MAX_DELAY = 4
local RetryAfter = {}
local RetryFails = {}

local trackedStealPrompts = {}

local function isStealPrompt(inst)
    if not inst or not inst:IsA("ProximityPrompt") then return false end
    if inst.Name == "StealPrompt" then return true end
    local act = tostring(inst.ActionText):lower()
    return act:find("steal", 1, true) ~= nil
end

local function trackPromptIfRelevant(inst)
    if isStealPrompt(inst) then
        trackedStealPrompts[inst] = true
    end
end

for _, desc in ipairs(workspace:GetDescendants()) do
    trackPromptIfRelevant(desc)
end

workspace.DescendantAdded:Connect(trackPromptIfRelevant)
workspace.DescendantRemoving:Connect(function(desc)
    trackedStealPrompts[desc] = nil
    DroppedCooldown[desc] = nil
end)

local function makePetBlacklistKey(petName, petValue)
    return string.format("%s|%d", tostring(petName or "-"):lower(), math.floor(tonumber(petValue) or 0))
end

local function blacklistPetBySignature(petName, petValue, reason)
    local key = makePetBlacklistKey(petName, petValue)
    PetBlacklist[key] = tick() + PET_BLACKLIST_TTL

    notifyThrottled(
        "ragdoll_blacklist",
        "Pet Diabaikan (30d)",
        string.format("%s ($%s/s) memicu %s.", tostring(petName), formatShortNumber(petValue or 0), reason or "ragdoll"),
        4
    )
end

local function isPetBlacklisted(petName, petValue)
    local key = makePetBlacklistKey(petName, petValue)
    local expiresAt = PetBlacklist[key]
    if not expiresAt then
        return false
    end
    if tick() >= expiresAt then
        PetBlacklist[key] = nil
        return false
    end
    return true
end

local function getBlacklistedCount()
    local now = tick()
    local count = 0
    for key, expiresAt in pairs(PetBlacklist) do
        if now >= expiresAt then
            PetBlacklist[key] = nil
        else
            count = count + 1
        end
    end
    return count
end

local function isRecentlyDropped(petModel, prompt)
    local now = tick()
    if petModel and DroppedCooldown[petModel] then
        if now < DroppedCooldown[petModel] then
            return true
        end
        DroppedCooldown[petModel] = nil
    end
    if prompt and DroppedCooldown[prompt] then
        if now < DroppedCooldown[prompt] then
            return true
        end
        DroppedCooldown[prompt] = nil
    end
    return false
end

local function blacklistTargetOnRagdoll(reason)
    if not ActiveTarget or ActiveTarget.abortedByRagdoll then return end
    ActiveTarget.abortedByRagdoll = true

    blacklistPetBySignature(ActiveTarget.name, ActiveTarget.value, reason)

    if ActiveTarget.prompt and ActiveTarget.prompt.Parent then
        pcall(function() ActiveTarget.prompt:InputHoldEnd() end)
    end
end

local function getPromptCFrame(prompt)
    if not prompt or not prompt.Parent then return nil end
    local p = prompt.Parent
    if p:IsA("Attachment") then
        return p.WorldCFrame
    elseif p:IsA("BasePart") and p ~= workspace.Terrain then
        return p.CFrame
    end
    local att = prompt:FindFirstAncestorWhichIsA("Attachment")
    if att then
        return att.WorldCFrame
    end
    local part = prompt:FindFirstAncestorWhichIsA("BasePart")
    if part and part ~= workspace.Terrain then
        return part.CFrame
    end
    return nil
end

local function getPickupPosition(petModel)
    if not petModel then return nil end
    if petModel:IsA("BasePart") then
        return petModel.Position
    elseif petModel:IsA("Model") then
        if petModel.PrimaryPart then
            return petModel.PrimaryPart.Position
        end
        local part = petModel:FindFirstChildWhichIsA("BasePart", true)
        if part then
            return part.Position
        end
        local okPiv, piv = pcall(function() return petModel:GetPivot() end)
        if okPiv and piv then
            return piv.Position
        end
    end
    return nil
end

local function getPetIdentifier(petModel, prompt)
    if prompt and prompt.ObjectText ~= "" then
        return tostring(prompt.ObjectText)
    end
    if petModel then
        return tostring(petModel)
    end
    return tostring(prompt)
end

local function markPetFailed(key)
    local fails = (RetryFails[key] or 0) + 1
    RetryFails[key] = fails
    RetryAfter[key] = tick() + math.min(RETRY_BASE_DELAY * fails, RETRY_MAX_DELAY)
end

local function markPetSucceeded(key)
    RetryFails[key] = nil
    RetryAfter[key] = nil
end

local function scanZone1Pickups(aboveValue)
    local zoneInfo = getZone1Info()
    if not zoneInfo then
        return nil, 0, 0, "-", nil, false, {}, 0, "Zone1 tidak ditemukan"
    end

    local pickupsFolder = workspace:FindFirstChild("AnimalPickups")
    if not pickupsFolder then
        return nil, 0, 0, "-", nil, true, {}, 0, "Folder AnimalPickups tidak ada"
    end

    local plotsFolder = workspace:FindFirstChild("Plots")
    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")

    local pickupEntries = {}
    for _, petModel in ipairs(pickupsFolder:GetChildren()) do
        local pos = getPickupPosition(petModel)
        if pos then
            local info = readPetInfo(petModel)
            table.insert(pickupEntries, {
                model = petModel,
                pos = pos,
                value = info.value,
                source = info.raw,
                rarity = info.rarity,
                mutation = info.mutation
            })
        end
    end

    local totalGlobalPickups = #pickupEntries
    local carryFull = isPlayerCarrying()
    local totalZone1Pets = 0
    local highestSeenVal = 0
    local highestSeenName = "-"
    local highestSeenSource = nil
    local skipReason = "-"

    local bestMatch = nil
    local bestDistance = math.huge
    local bestValue = 0
    local candidateList = {}
    local now = tick()

    for prompt in pairs(trackedStealPrompts) do
        if not prompt.Parent or not prompt:IsDescendantOf(workspace) then
            trackedStealPrompts[prompt] = nil
        else
            local isExcluded = (plotsFolder and prompt:IsDescendantOf(plotsFolder))
                or (carriedFolder and prompt:IsDescendantOf(carriedFolder))
                or (Character and prompt:IsDescendantOf(Character))

            if not isExcluded then
                local promptCF = getPromptCFrame(prompt)
                if promptCF and isPositionInZone1(zoneInfo, promptCF.Position) then
                    local matchedEntry = nil
                    local closestPickupDist = 25

                    for _, entry in ipairs(pickupEntries) do
                        if prompt:IsDescendantOf(entry.model) then
                            matchedEntry = entry
                            break
                        end
                        local d = (entry.pos - promptCF.Position).Magnitude
                        if d <= closestPickupDist then
                            closestPickupDist = d
                            matchedEntry = entry
                        end
                    end

                    if matchedEntry then
                        local val = matchedEntry.value
                        local rawSource = matchedEntry.source
                        local rarity = matchedEntry.rarity
                        local mutation = matchedEntry.mutation

                        if val == 0 and prompt.Parent then
                            local pInfo = readPetInfo(prompt.Parent)
                            val = pInfo.value
                            rawSource = pInfo.raw
                            rarity = rarity or pInfo.rarity
                            mutation = mutation or pInfo.mutation
                        end

                        local displayName = (prompt.ObjectText ~= "")
                            and shortText(prompt.ObjectText, 32)
                            or shortText(matchedEntry.model.Name, 32)

                        local key = getPetIdentifier(matchedEntry.model, prompt)
                        local retryUntil = RetryAfter[key]
                        local promptAvailable = carryFull or prompt.Enabled

                        if isPetBlacklisted(displayName, val) then
                            if skipReason == "-" then
                                skipReason = displayName .. " (blacklist 30d)"
                            end
                        elseif isRecentlyDropped(matchedEntry.model, prompt) then
                            if skipReason == "-" then
                                skipReason = displayName .. " (jeda anti pungut ulang 6d)"
                            end
                        elseif not promptAvailable then
                            if skipReason == "-" then
                                skipReason = displayName .. " (StealPrompt terkunci)"
                            end
                        elseif retryUntil and now < retryUntil then
                            if skipReason == "-" then
                                skipReason = displayName .. " (jeda coba ulang)"
                            end
                        else
                            totalZone1Pets = totalZone1Pets + 1

                            if #candidateList < 4 then
                                table.insert(candidateList, shortText(displayName, 20) .. "=" .. formatShortNumber(val))
                            end

                            if val >= highestSeenVal then
                                highestSeenVal = val
                                highestSeenName = displayName
                                highestSeenSource = rawSource
                            end

                            -- Auto Drop Swap: harus >= MinTargetNumber DAN > pet yang sedang dibawa
                            if val >= State.MinTargetNumber and val > (aboveValue or 0) then
                                local dist = RootPart and (RootPart.Position - promptCF.Position).Magnitude or 0
                                if val > bestValue or (val == bestValue and dist < bestDistance) then
                                    bestDistance = dist
                                    bestValue = val
                                    bestMatch = {
                                        model = matchedEntry.model,
                                        prompt = prompt,
                                        name = displayName,
                                        value = val,
                                        rarity = rarity,
                                        mutation = mutation,
                                        source = rawSource,
                                        key = key
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if totalZone1Pets == 0 and totalGlobalPickups > 0 and skipReason == "-" then
        skipReason = pickupEntries[1].model.Name .. " (di luar lantai Zone 1)"
    end

    return bestMatch, totalZone1Pets, highestSeenVal, highestSeenName, highestSeenSource, true, candidateList, totalGlobalPickups, skipReason
end

-- ==========================================
-- EKSEKUSI TELEPORT KE PROMPT, STEALPROMPT & AUTO DROP
-- ==========================================
local DROP_WAIT = 2.5
local DROP_RETRY_DELAY = 2
local HOLD_MARGIN = 0.45

local function dismountIfRiding()
    local hum = Character and Character:FindFirstChildOfClass("Humanoid")
    if hum and (hum.Sit or hum.SeatPart ~= nil) then
        hum.Sit = false
        task.wait(0.12)
    end
end

local function instantCFrame(targetCF)
    if not RootPart or not RootPart.Parent or not targetCF then return end
    RootPart.AssemblyLinearVelocity = Vector3.zero
    RootPart.AssemblyAngularVelocity = Vector3.zero
    RootPart.CFrame = targetCF
end

local function resolveZone1ReturnCFrame(fallbackCF)
    local z1 = getZone1Info()
    if z1 and z1.standCF and not isInsideSafeZone(z1.standCF.Position) then
        return z1.standCF
    end
    if fallbackCF and not isInsideSafeZone(fallbackCF.Position) then
        return fallbackCF
    end
    local cf = z1 and (z1.hCF or z1.bCF)
    if cf then
        return CFrame.new(cf.Position + Vector3.new(0, 4, 0))
    end
    return fallbackCF
end

local function fireGuiButtonConnections(btn)
    if not btn or not btn:IsA("GuiButton") then return end
    local events = { btn.Activated, btn.MouseButton1Down, btn.MouseButton1Click, btn.TouchTap }

    if getconnections then
        for _, sig in ipairs(events) do
            pcall(function()
                for _, conn in ipairs(getconnections(sig)) do
                    if conn.Enabled ~= false then
                        pcall(function() conn:Fire() end)
                        if conn.Function then
                            pcall(conn.Function)
                        end
                    end
                end
            end)
        end
    end

    if firesignal then
        for _, sig in ipairs(events) do
            pcall(function() firesignal(sig) end)
        end
    end
end

local function triggerDropRemoteOrButton(carriedObj)
    local pGui = LocalPlayer:FindFirstChild("PlayerGui")
    local mainGui = pGui and pGui:FindFirstChild("MainGUI")
    if mainGui then
        for _, desc in ipairs(mainGui:GetDescendants()) do
            if desc.Name == "Drop" and desc:IsA("GuiButton") then
                fireGuiButtonConnections(desc)
            end
        end
    end

    local dropRemote = ReplicatedStorage:FindFirstChild("DropCarriedRemote")
    if dropRemote and dropRemote:IsA("RemoteEvent") then
        pcall(function() dropRemote:FireServer() end)
        if carriedObj then
            pcall(function() dropRemote:FireServer(carriedObj) end)
        end
    end
end

local function markNearbyPickupsAsDropped(centerPos, excludeModel)
    local pickupsFolder = workspace:FindFirstChild("AnimalPickups")
    if not pickupsFolder or not centerPos then return end
    for _, petModel in ipairs(pickupsFolder:GetChildren()) do
        if petModel ~= excludeModel then
            local pos = getPickupPosition(petModel)
            if pos and (pos - centerPos).Magnitude <= 14 then
                DroppedCooldown[petModel] = tick() + 6
            end
        end
    end
end

local function dropCarriedPet(keepTargetModel)
    if not isPlayerCarrying() then
        clearCarry()
        return true
    end

    local prevObj = findActiveCarriedPet()
    local dropPos = RootPart and RootPart.Position or nil

    dismountIfRiding()
    triggerDropRemoteOrButton(prevObj)

    local startTime = tick()
    local lastAttempt = startTime
    while (tick() - startTime) < DROP_WAIT and isPlayerCarrying() do
        task.wait(0.08)
        if (tick() - lastAttempt) >= 0.45 then
            lastAttempt = tick()
            triggerDropRemoteOrButton(prevObj)
        end
    end

    if isPlayerCarrying() then
        notifyThrottled(
            "dropfail",
            "Gagal Auto Drop",
            "Pet belum terlepas lewat DropCarriedRemote. Mencoba ulang sebentar lagi.",
            4
        )
        return false
    end

    if dropPos then
        markNearbyPickupsAsDropped(dropPos, keepTargetModel)
    end
    clearCarry()
    return true
end

local function grabPrompt(targetData)
    local prompt = targetData.prompt
    if not prompt or not prompt.Parent then return false end
    if isPetBlacklisted(targetData.name, targetData.value) then return false end

    local startPromptCF = getPromptCFrame(prompt)
    if not startPromptCF then return false end

    dismountIfRiding()

    local startCarryCount = getCarryCount()
    local grabPos = startPromptCF * CFrame.new(0, State.OffsetY, 1.5)

    instantCFrame(grabPos)

    -- Tunggu maksimal 1 detik hingga StealPrompt aktif pasca-drop
    local enableWaitStart = tick()
    while (tick() - enableWaitStart) < 1.0 do
        if ActiveTarget and ActiveTarget.abortedByRagdoll then
            return false
        end
        if not prompt.Parent or isPetBlacklisted(targetData.name, targetData.value) then
            return false
        end
        if prompt.Enabled then
            break
        end
        local curCF = getPromptCFrame(prompt) or startPromptCF
        instantCFrame(curCF * CFrame.new(0, State.OffsetY, 1.5))
        task.wait(0.06)
    end

    if not prompt.Parent or not prompt.Enabled or isPetBlacklisted(targetData.name, targetData.value) then
        return false
    end

    local holdTime = (prompt.HoldDuration or 0.35) + HOLD_MARGIN

    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = 25

    pcall(function() prompt:InputHoldBegin() end)
    if fireproximityprompt then
        pcall(function() fireproximityprompt(prompt) end)
    end

    local grabbed = false
    local startTime = tick()
    while (tick() - startTime) < holdTime do
        if ActiveTarget and ActiveTarget.abortedByRagdoll then
            break
        end
        if getCarryCount() > startCarryCount or findActiveCarriedPet() ~= nil then
            grabbed = true
            break
        end
        if not prompt.Parent or not prompt.Enabled then
            break
        end

        local curCF = getPromptCFrame(prompt) or startPromptCF
        instantCFrame(curCF * CFrame.new(0, State.OffsetY, 1.5))
        task.wait(0.06)
    end

    if prompt.Parent then
        pcall(function() prompt:InputHoldEnd() end)
        if fireproximityprompt and not (ActiveTarget and ActiveTarget.abortedByRagdoll) then
            pcall(function() fireproximityprompt(prompt) end)
        end
    end

    if ActiveTarget and ActiveTarget.abortedByRagdoll then
        return false
    end

    if not grabbed then
        task.wait(0.15)
        grabbed = (getCarryCount() > startCarryCount) or (findActiveCarriedPet() ~= nil)
    end

    return grabbed
end

local function carryPet(match)
    local returnCF = resolveZone1ReturnCFrame(RootPart.CFrame)

    -- Auto Drop Swap: jika sudah membawa 1 pet (value lebih rendah), drop langsung di tempat
    if isPlayerCarrying() then
        if not dropCarriedPet(match.model) then
            Carry.cooldownUntil = tick() + DROP_RETRY_DELAY
            return false
        end

        task.wait(0.15)

        if not match.prompt or not match.prompt.Parent or isPetBlacklisted(match.name, match.value) then
            instantCFrame(returnCF)
            return false
        end
    end

    local targetSession = {
        model = match.model,
        prompt = match.prompt,
        name = match.name,
        value = match.value,
        abortedByRagdoll = false
    }
    ActiveTarget = targetSession

    local pending = {
        name = match.name,
        value = match.value,
        rarity = match.rarity,
        mutation = match.mutation
    }
    Carry.pending = pending

    local success = grabPrompt(match)

    ActiveTarget = nil
    task.delay(2, function()
        if Carry.pending == pending then
            Carry.pending = nil
        end
    end)

    -- Kembali berdiri otomatis di titik tengah lantai Zone 1
    instantCFrame(returnCF)

    if targetSession.abortedByRagdoll then
        return false
    end

    if success then
        Carry.value = match.value
        Carry.name = match.name
        Carry.obj = findActiveCarriedPet()
        return true
    end
    return false
end

-- ==========================================
-- ANTI RAGDOLL + AUTO BLACKLIST PET (NAMA + VALUE, 30 DETIK)
-- ==========================================
local RagdollTrackWords = { "hit", "stun", "ragdoll", "knock", "daze" }

local RagdollStates = {
    [Enum.HumanoidStateType.Ragdoll] = true,
    [Enum.HumanoidStateType.FallingDown] = true,
    [Enum.HumanoidStateType.PlatformStanding] = true,
    [Enum.HumanoidStateType.Physics] = true
}

local antiConnections = {}

local function disconnectAnti()
    for _, conn in ipairs(antiConnections) do
        conn:Disconnect()
    end
    antiConnections = {}
end

local function containsRagdollWord(text)
    local low = tostring(text):lower()
    for _, word in ipairs(RagdollTrackWords) do
        if low:find(word, 1, true) then
            return true
        end
    end
    return false
end

local function neutralizeRagdollNow(char, hum, root, ragdollReason)
    if ActiveTarget then
        blacklistTargetOnRagdoll(ragdollReason)
    end

    if not State.AntiRagdoll then return end
    if not char or not char.Parent then return end

    if AnimalRagdoll and type(AnimalRagdoll.Release) == "function" then
        pcall(AnimalRagdoll.Release, char)
    end

    if RagdollPhysics and type(RagdollPhysics.RemoveLowGravity) == "function" then
        pcall(RagdollPhysics.RemoveLowGravity, char)
    end

    if RagdollPhysics and type(RagdollPhysics.SetCharacterVelocity) == "function" then
        pcall(RagdollPhysics.SetCharacterVelocity, char, Vector3.zero, Vector3.zero)
    else
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and not part.Anchored then
                part.AssemblyLinearVelocity = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end

    if char:GetAttribute("Ragdolled") then
        char:SetAttribute("Ragdolled", nil)
    end

    if root then
        root.CustomPhysicalProperties = nil
        root.CanCollide = true
    end

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Motor6D") then
            if d.Name == "RagdollAltRoot" then
                pcall(function() d:Destroy() end)
            elseif not d.Enabled then
                d.Enabled = true
            end
        elseif d:IsA("VectorForce") and d.Name == "RagdollLiftForce" then
            pcall(function() d:Destroy() end)
        elseif d:IsA("Attachment") and d.Name == "RagdollLiftAttachment" then
            pcall(function() d:Destroy() end)
        elseif d:GetAttribute("RagdollConstraint") or d:GetAttribute("RagdollAttachment") then
            pcall(function() d:Destroy() end)
        end
    end

    if hum and hum.Parent then
        hum.PlatformStand = false
        hum.AutoRotate = true
        if RagdollStates[hum:GetState()] then
            hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end
end

local function setupAntiRagdoll(char)
    disconnectAnti()

    local hum = char:WaitForChild("Humanoid", 10)
    local root = char:WaitForChild("HumanoidRootPart", 10)
    if not hum or not root then return end

    if State.AntiRagdoll then
        for state in pairs(RagdollStates) do
            pcall(function() hum:SetStateEnabled(state, false) end)
        end
    end

    table.insert(antiConnections, char:GetAttributeChangedSignal("Ragdolled"):Connect(function()
        if char:GetAttribute("Ragdolled") then
            neutralizeRagdollNow(char, hum, root, "atribut Ragdolled")
        end
    end))

    table.insert(antiConnections, hum.StateChanged:Connect(function(_, newState)
        if RagdollStates[newState] then
            neutralizeRagdollNow(char, hum, root, "status " .. tostring(newState.Name))
        end
    end))

    table.insert(antiConnections, char.DescendantAdded:Connect(function(d)
        if d.Name == "RagdollLiftForce" or d.Name == "RagdollAltRoot"
            or d:GetAttribute("RagdollConstraint") or d:IsA("BodyVelocity")
            or d:IsA("LinearVelocity") or d:IsA("VectorForce") then
            if State.AntiRagdoll then
                pcall(function()
                    if d:IsA("VectorForce") or d:IsA("LinearVelocity") then d.Enabled = false end
                    if d:IsA("VectorForce") then d.Force = Vector3.zero end
                    d:Destroy()
                end)
            end
            neutralizeRagdollNow(char, hum, root, d.Name)
        elseif d:IsA("Motor6D") then
            table.insert(antiConnections, d:GetPropertyChangedSignal("Enabled"):Connect(function()
                if State.AntiRagdoll and not d.Enabled and d.Name ~= "RagdollAltRoot" then
                    d.Enabled = true
                end
            end))
        end
    end))

    table.insert(antiConnections, RunService.Heartbeat:Connect(function()
        if not hum.Parent or not root.Parent then return end

        local isRagdolled = char:GetAttribute("Ragdolled") == true or RagdollStates[hum:GetState()]
        if isRagdolled then
            neutralizeRagdollNow(char, hum, root, "ragdoll physics")
            return
        end

        if hum.MoveDirection.Magnitude < 0.1 and not hum.SeatPart then
            local v = root.AssemblyLinearVelocity
            local horizSpeed = Vector3.new(v.X, 0, v.Z).Magnitude
            local abnormalUp = (hum:GetState() ~= Enum.HumanoidStateType.Jumping and v.Y > 30)
            if horizSpeed > 25 or abnormalUp then
                if ActiveTarget then
                    blacklistTargetOnRagdoll("knockback physics")
                end
                if State.AntiRagdoll then
                    if RagdollPhysics and type(RagdollPhysics.SetCharacterVelocity) == "function" then
                        pcall(RagdollPhysics.SetCharacterVelocity, char, Vector3.zero, Vector3.zero)
                    else
                        root.AssemblyLinearVelocity = Vector3.zero
                    end
                end
            elseif State.AntiRagdoll and horizSpeed > 2 then
                if RagdollPhysics and type(RagdollPhysics.SetCharacterVelocity) == "function" then
                    pcall(RagdollPhysics.SetCharacterVelocity, char, Vector3.zero, Vector3.zero)
                else
                    root.AssemblyLinearVelocity = Vector3.zero
                end
            end
        end

        if State.AntiRagdoll then
            local animator = hum:FindFirstChildOfClass("Animator")
            if animator then
                for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                    if containsRagdollWord(track.Name)
                        or (track.Animation and containsRagdollWord(track.Animation.Name)) then
                        track:Stop(0)
                    end
                end
            end
        end
    end))
end

task.spawn(setupAntiRagdoll, Character)
LocalPlayer.CharacterAdded:Connect(function(newChar)
    task.spawn(setupAntiRagdoll, newChar)
end)

-- ==========================================
-- PEMBUATAN MENU RAYFIELD UI
-- ==========================================
local Window = Rayfield:CreateWindow({
    Name = "Lurkala Hub",
    LoadingTitle = "Memuat Script...",
    LoadingSubtitle = "Auto Drop",
    ConfigurationSaving = {
        Enabled = false
    }
})

local MainTab = Window:CreateTab("Auto Carry", 4483362458)

local StatusParagraph = MainTab:CreateParagraph({
    Title = "Status Auto Carry",
    Content = "Memindai Zone 1"
})

MainTab:CreateToggle({
    Name = "Aktifkan Auto Carry",
    CurrentValue = State.AutoGrab,
    Flag = "ToggleAutoGrab",
    Callback = function(Value)
        State.AutoGrab = Value
        if Value then
            task.delay(0.05, function()
                pcall(function()
                    Rayfield:Notify({
                        Title = "Auto Carry Aktif",
                        Content = "Menunggu pet >= " .. State.TargetValueRaw .. " di Zone 1.",
                        Duration = 2.5
                    })
                end)
            end)
        end
    end
})

MainTab:CreateInput({
    Name = "Target Minimal Value",
    PlaceholderText = "Saat ini: " .. State.TargetValueRaw,
    RemoveTextAfterFocusLost = false,
    Callback = function(Text)
        if type(Text) ~= "string" then return end
        local trimmed = Text:gsub("^%s*(.-)%s*$", "%1")
        if trimmed == "" then return end

        local parsed = parseValue(trimmed)
        if parsed > 0 and parsed < math.huge then
            State.TargetValueRaw = trimmed
            State.MinTargetNumber = parsed
            task.delay(0.05, function()
                pcall(function()
                    Rayfield:Notify({
                        Title = "Value Tersimpan",
                        Content = "Target aktif: " .. trimmed .. " (" .. formatShortNumber(parsed) .. ")",
                        Duration = 2.5
                    })
                end)
            end)
        else
            task.delay(0.05, function()
                pcall(function()
                    Rayfield:Notify({
                        Title = "Format Tidak Valid",
                        Content = "Gunakan angka atau suffix (contoh: 10B, 100T, 1Qa).",
                        Duration = 2.5
                    })
                end)
            end)
        end
    end
})

MainTab:CreateToggle({
    Name = "Anti Terpental",
    CurrentValue = State.AntiRagdoll,
    Flag = "ToggleAntiRagdoll",
    Callback = function(Value)
        State.AntiRagdoll = Value
    end
})

-- ==========================================
-- LOOP UTAMA: PINDAI ANIMALPICKUPS ZONE 1 & AUTO DROP SWAP
-- ==========================================
task.spawn(function()
    while task.wait(0.3) do
        if RootPart and RootPart.Parent then
            local carrying = syncCarriedState()
            local zoneInfo = getZone1Info()

            keepZoneStreamed(zoneInfo)
            local match, totalPets, highestVal, highestName, highestSource, zoneFound, candidateList, globalCount, skipReason =
                scanZone1Pickups(carrying and Carry.value or 0)

            pcall(function()
                local candText = (#candidateList > 0)
                    and table.concat(candidateList, " | ")
                    or (globalCount > 0 and ("Filter: " .. shortText(skipReason, 45)) or "-")

                local carryText = carrying
                    and string.format("%s ($%s/s) [1/1]", tostring(Carry.name), formatShortNumber(Carry.value))
                    or "Kosong [0/1]"

                local hasDropRemote = ReplicatedStorage:FindFirstChild("DropCarriedRemote") ~= nil
                local zoneText = zoneFound
                    and string.format(
                        "Zone 1: %d (Map: %d) | Tertinggi: %s ($%s/s)",
                        totalPets,
                        globalCount,
                        tostring(highestName),
                        formatShortNumber(highestVal)
                    )
                    or "Zone1 tidak ditemukan"

                StatusParagraph:Set({
                    Title = "Status Auto Carry",
                    Content = string.format(
                        "Dibawa: %s\nTarget Aktif: %s (%s)\n%s\nCashPerSecond: %s | DropRemote: %s | Blacklist: %d\nKandidat: %s",
                        carryText,
                        State.TargetValueRaw,
                        formatShortNumber(State.MinTargetNumber),
                        zoneText,
                        shortText(highestSource, 28),
                        hasDropRemote and "OK" or "TIDAK ADA",
                        getBlacklistedCount(),
                        shortText(candText, 85)
                    )
                })
            end)

            local swapBlocked = carrying and tick() < Carry.cooldownUntil

            if State.AutoGrab and not isBusy and match and not swapBlocked then
                isBusy = true

                pcall(function()
                    Rayfield:Notify({
                        Title = carrying and "Auto Drop & Tukar Pet!" or "Pet Target Ditemukan!",
                        Content = string.format("%s ($%s/s)", tostring(match.name), formatShortNumber(match.value)),
                        Duration = 2.5
                    })
                end)

                local okRun, result = pcall(carryPet, match)
                if okRun and result then
                    markPetSucceeded(match.key)
                elseif not isPetBlacklisted(match.name, match.value) then
                    markPetFailed(match.key)
                end

                task.wait(0.2)
                isBusy = false
            end
        end
    end
end)