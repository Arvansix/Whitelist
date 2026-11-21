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
-- SERVICES & STATE DEFAULT
-- ==========================================
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local RootPart = Character:WaitForChild("HumanoidRootPart")

local CONFIG_FILE = "BreakStealEgg_Config.json"
local unpackFn = table.unpack or unpack

local State = {
    -- Auto Carry Zone 1 & Auto SafeZone Swap
    AutoGrab = false,
    AutoSafeZoneSwap = true, -- Otomatis ke SafeZone jika ada pet lebih mahal dari yang dibawa
    TargetValueRaw = "10B",
    MinTargetNumber = 1e10,
    HoldDuration = 5.0,
    ZoneRadius = 75,

    -- Koordinat Tersimpan
    Zone1CFrame = RootPart.CFrame,
    SafeZoneCFrame = nil, -- Wajib dikunci lewat tombol di menu (di dalam garis SafeZone)

    -- Pelacak Pet yang Sedang Di-Carry
    CurrentCarriedValue = 0,
    CurrentCarriedName = "-",

    -- Webhook Discord
    WebhookEnabled = true,
    WebhookURL = "",
    PingText = "",
    WebhookCooldown = 2
}

local isBusy = false
local lastAttemptedValue = 0
local lastAttemptedName = "-"
local depositCooldownUntil = 0
local sentCache = {}
local isLoaded = false

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
-- KONVERSI SUFFIX VALUE & CFRAME SERIALIZER
-- ==========================================
local SuffixMultipliers = {
    k = 1e3, m = 1e6, b = 1e9, t = 1e12,
    qa = 1e15, qi = 1e18, sx = 1e21, sp = 1e24,
    oc = 1e27, no = 1e30, dc = 1e33
}

local function formatShortNumber(num)
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
    local cleaned = line:lower():gsub("<[^>]+>", ""):gsub("[$,%s]", ""):gsub("/s[ec]*$", "")
    local numStr, suffix = cleaned:match("^([%d%.]+)(%a*)$")
    local baseNum = tonumber(numStr)
    if not baseNum then
        return 0
    end

    if suffix == "" then
        return baseNum
    end
    return SuffixMultipliers[suffix] and (baseNum * SuffixMultipliers[suffix]) or 0
end

local function parseValue(rawInput)
    if type(rawInput) == "number" then
        return rawInput
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

local function serializeCFrame(cf)
    if not cf then return nil end
    return { cf:GetComponents() }
end

local function deserializeCFrame(tbl)
    if type(tbl) == "table" and #tbl == 12 then
        return CFrame.new(unpackFn(tbl))
    end
    return nil
end

-- ==========================================
-- SISTEM AUTO SAVE & LOAD CONFIG (JSON)
-- ==========================================
local function saveConfig()
    if not isLoaded or not writefile then return end

    local dataToSave = {
        AutoGrab = State.AutoGrab,
        AutoSafeZoneSwap = State.AutoSafeZoneSwap,
        TargetValueRaw = State.TargetValueRaw,
        HoldDuration = State.HoldDuration,
        ZoneRadius = State.ZoneRadius,
        Zone1CFrame = serializeCFrame(State.Zone1CFrame),
        SafeZoneCFrame = serializeCFrame(State.SafeZoneCFrame),
        WebhookEnabled = State.WebhookEnabled,
        WebhookURL = State.WebhookURL,
        PingText = State.PingText
    }

    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(dataToSave))
    end)
end

local function loadConfig()
    if not (isfile and readfile) then
        isLoaded = true
        return false
    end

    local success, result = pcall(function()
        if isfile(CONFIG_FILE) then
            return HttpService:JSONDecode(readfile(CONFIG_FILE))
        end
        return nil
    end)

    if success and type(result) == "table" then
        if type(result.AutoGrab) == "boolean" then State.AutoGrab = result.AutoGrab end
        if type(result.AutoSafeZoneSwap) == "boolean" then State.AutoSafeZoneSwap = result.AutoSafeZoneSwap end
        if type(result.TargetValueRaw) == "string" and result.TargetValueRaw ~= "" then
            local parsed = parseValue(result.TargetValueRaw)
            if parsed > 0 then
                State.TargetValueRaw = result.TargetValueRaw
                State.MinTargetNumber = parsed
            end
        end
        if type(result.HoldDuration) == "number" then State.HoldDuration = result.HoldDuration end
        if type(result.ZoneRadius) == "number" then State.ZoneRadius = result.ZoneRadius end

        local loadedZ1 = deserializeCFrame(result.Zone1CFrame)
        if loadedZ1 then State.Zone1CFrame = loadedZ1 end

        local loadedSZ = deserializeCFrame(result.SafeZoneCFrame)
        if loadedSZ then State.SafeZoneCFrame = loadedSZ end

        if type(result.WebhookEnabled) == "boolean" then State.WebhookEnabled = result.WebhookEnabled end
        if type(result.WebhookURL) == "string" then State.WebhookURL = result.WebhookURL end
        if type(result.PingText) == "string" then State.PingText = result.PingText end

        isLoaded = true
        return true
    end

    isLoaded = true
    return false
end

local configFound = loadConfig()

-- ==========================================
-- REFERENSI FOLDER ZONE 1 & POSISI DUNIA
-- ==========================================
local function getZone1Folder()
    local build = workspace:FindFirstChild("Build")
    if not build then return nil end
    local zoneBuilds = build:FindFirstChild("ZoneBuilds")
    if not zoneBuilds then return nil end
    return zoneBuilds:FindFirstChild("Zone1")
end

local function getWorldPosition(instance)
    if not instance then return nil end
    if instance:IsA("BasePart") then
        return instance.Position
    elseif instance:IsA("Model") then
        return instance:GetPivot().Position
    elseif instance:IsA("Attachment") then
        return instance.WorldPosition
    end
    return nil
end

local function isTargetInZone1(prompt, attachPart, zone1Folder)
    if zone1Folder then
        if prompt:IsDescendantOf(zone1Folder) or attachPart:IsDescendantOf(zone1Folder) then
            return true
        end

        local okBox, boxCF, boxSize = pcall(function()
            return zone1Folder:GetBoundingBox()
        end)
        if okBox and boxCF and boxSize then
            local localPos = boxCF:PointToObjectSpace(attachPart.Position)
            local pad = 15
            if math.abs(localPos.X) <= (boxSize.X * 0.5 + pad)
                and math.abs(localPos.Y) <= (boxSize.Y * 0.5 + pad)
                and math.abs(localPos.Z) <= (boxSize.Z * 0.5 + pad) then
                return true
            end
        end
    end

    local refPos = State.Zone1CFrame and State.Zone1CFrame.Position or (RootPart and RootPart.Position)
    if refPos and (attachPart.Position - refPos).Magnitude <= State.ZoneRadius then
        return true
    end

    return false
end

-- ==========================================
-- PEMETAAN BILLBOARDGUI & EKSTRAKSI DATA
-- ==========================================
local function buildBillboardCache()
    local cache = {}

    local function processBillboard(bb)
        if not bb:IsA("BillboardGui") then return end
        local host = bb.Adornee or bb.Parent
        local pos = getWorldPosition(host)
        if not pos then return end

        local texts = {}

        for _, d in ipairs(bb:GetDescendants()) do
            if d:IsA("TextLabel") and d.Text ~= "" then
                local clean = d.Text:gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1")
                if clean ~= "" then
                    table.insert(texts, clean)
                end
            end
        end

        if #texts > 0 then
            table.insert(cache, {
                pos = pos,
                texts = texts
            })
        end
    end

    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("BillboardGui") then
            processBillboard(desc)
        end
    end

    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        for _, desc in ipairs(playerGui:GetDescendants()) do
            if desc:IsA("BillboardGui") then
                processBillboard(desc)
            end
        end
    end

    return cache
end

local BILLBOARD_MAX_DIST = 7.5
local BILLBOARD_TOLERANCE = 2.5
local IncomeKeyHints = { "income", "persec", "per_sec", "pps", "earn", "production", "yield" }

local function classifyValue(key, rawVal)
    if type(rawVal) == "number" then
        local k = tostring(key):lower()
        for _, hint in ipairs(IncomeKeyHints) do
            if k:find(hint, 1, true) then
                return 2, rawVal
            end
        end
        return 0, 0
    end

    if type(rawVal) ~= "string" then
        return 0, 0
    end

    local text = rawVal:gsub("<[bB][rR]%s*/?>", "\n"):gsub("<[^>]+>", "")
    local bestTier, bestValue = 0, 0

    for line in text:gmatch("[^\n\r]+") do
        local value = parseValueLine(line)
        if value > 0 then
            local tier = line:lower():find("/s", 1, true) and 2 or 1
            if tier > bestTier or (tier == bestTier and value > bestValue) then
                bestTier = tier
                bestValue = value
            end
        end
    end

    return bestTier, bestValue
end

local function extractInfoAndValue(obj, attachPos, bbCache)
    local stats = {}
    local seen = {}
    local bestTier, bestVal, bestSource = 0, 0, nil
    local displayName = obj.Name

    local function processEntry(key, rawVal)
        local tier, num = classifyValue(key, rawVal)
        if tier > bestTier or (tier == bestTier and num > bestVal) then
            bestTier = tier
            bestVal = num
            bestSource = (key ~= "" and (key .. ": ") or "") .. tostring(rawVal)
        end

        local text = tostring(rawVal):gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1")
        if text ~= "" and not seen[key .. text] then
            seen[key .. text] = true
            if key ~= "" then
                table.insert(stats, "• **" .. key .. ":** " .. text)
            else
                table.insert(stats, "• " .. text)
            end
        end
    end

    local function scanInstance(target)
        if not target then return end
        for attrName, attrVal in pairs(target:GetAttributes()) do
            processEntry(attrName, attrVal)
            local lowKey = attrName:lower()
            if lowKey:find("name") or lowKey:find("animal") or lowKey:find("pet") then
                displayName = tostring(attrVal)
            end
        end

        for _, desc in ipairs(target:GetDescendants()) do
            if desc:IsA("StringValue") or desc:IsA("NumberValue") or desc:IsA("IntValue") then
                processEntry(desc.Name, desc.Value)
            elseif desc:IsA("TextLabel") and desc.Text ~= "" then
                processEntry("", desc.Text)
            elseif desc:IsA("ProximityPrompt") and desc.ObjectText ~= "" then
                displayName = desc.ObjectText
                processEntry("Target", desc.ObjectText)
            end
        end
    end

    scanInstance(obj)

    if attachPos and bbCache then
        local matches = {}
        local nearest = math.huge

        for _, entry in ipairs(bbCache) do
            local dx = entry.pos.X - attachPos.X
            local dz = entry.pos.Z - attachPos.Z
            local dy = math.abs(entry.pos.Y - attachPos.Y)
            local horizDist = math.sqrt(dx * dx + dz * dz)

            if horizDist <= BILLBOARD_MAX_DIST and dy <= 16 then
                table.insert(matches, { entry = entry, dist = horizDist })
                if horizDist < nearest then
                    nearest = horizDist
                end
            end
        end

        for _, m in ipairs(matches) do
            if m.dist <= nearest + BILLBOARD_TOLERANCE then
                for _, t in ipairs(m.entry.texts) do
                    processEntry("", t)
                end
            end
        end
    end

    local statText = (#stats > 0) and string.sub(table.concat(stats, "\n"), 1, 1000) or "Tidak ada statistik tambahan"
    return displayName, statText, bestVal, bestSource
end

-- ==========================================
-- DETEKSI CARRIEDANIMALS & WEBHOOK DISCORD
-- ==========================================
local function isMyCarriedAnimal(obj)
    if not Character or not RootPart then return false end

    if obj.Name == LocalPlayer.Name or obj.Name == tostring(LocalPlayer.UserId) then
        return true
    end
    if obj.Parent and (obj.Parent.Name == LocalPlayer.Name or obj.Parent.Name == tostring(LocalPlayer.UserId)) then
        return true
    end

    local ownerAttr = obj:GetAttribute("Owner") or obj:GetAttribute("Player") or obj:GetAttribute("Carrier")
    if ownerAttr and (tostring(ownerAttr) == LocalPlayer.Name or tostring(ownerAttr) == tostring(LocalPlayer.UserId)) then
        return true
    end

    for _, desc in ipairs(obj:GetDescendants()) do
        if desc:IsA("Weld") or desc:IsA("WeldConstraint") or desc:IsA("Motor6D") then
            if (desc.Part0 and desc.Part0:IsDescendantOf(Character)) or (desc.Part1 and desc.Part1:IsDescendantOf(Character)) then
                return true
            end
        end
    end

    local pos = getWorldPosition(obj)
    if pos and (pos - RootPart.Position).Magnitude <= 14 then
        return true
    end

    return false
end

local function isCurrentlyCarrying()
    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    if not carriedFolder then return false end

    for _, child in ipairs(carriedFolder:GetChildren()) do
        if isMyCarriedAnimal(child) then
            return true
        end
    end
    return false
end

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
            footer = { text = "Zone 1 Auto Carry • " .. os.date("%d/%m/%Y %H:%M:%S") },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }}
    }

    pcall(function()
        httpRequest({
            Url = State.WebhookURL,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload)
        })
    end)
end

local function handleCarriedObject(targetObj)
    if not targetObj or not targetObj.Parent then return end

    local now = tick()
    if sentCache[targetObj] and (now - sentCache[targetObj]) < State.WebhookCooldown then
        return
    end
    sentCache[targetObj] = now

    task.wait(0.25)
    if not targetObj or not targetObj.Parent then return end
    if not isMyCarriedAnimal(targetObj) then return end

    local actualAnimal = targetObj
    if targetObj.Name == LocalPlayer.Name and #targetObj:GetChildren() > 0 then
        actualAnimal = targetObj:GetChildren()[1]
    end

    local pos = getWorldPosition(actualAnimal)
    local bbCache = buildBillboardCache()
    local animalName, extraData, detectedVal = extractInfoAndValue(actualAnimal, pos, bbCache)

    -- Simpan nilai tertinggi antara hasil scan model carried dan target yang baru saja diambil
    local finalVal = math.max(detectedVal, lastAttemptedValue)
    if finalVal > 0 then
        State.CurrentCarriedValue = finalVal
    end
    State.CurrentCarriedName = (animalName ~= "" and animalName or lastAttemptedName)

    if State.WebhookEnabled then
        local webhookStat = extraData
        if detectedVal == 0 and finalVal > 0 then
            webhookStat = string.format("• **Value:** $%s/s\n%s", formatShortNumber(finalVal), extraData)
        end
        postToDiscord("🐾 Pet Zone 1 Berhasil Di-Carry!", State.CurrentCarriedName, webhookStat)
    end
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

        for _, existing in ipairs(carriedFolder:GetChildren()) do
            if existing:IsA("Folder") or existing.Name == LocalPlayer.Name then
                existing.ChildAdded:Connect(function(subChild)
                    task.spawn(handleCarriedObject, subChild)
                end)
            end
        end
    end
end)

-- ==========================================
-- FILTER KETAT PROXIMITYPROMPT (KHUSUS PET ZONE 1)
-- ==========================================
local BlacklistedKeywords = {
    "fuse", "fusion", "sell", "shop", "index", "wheel",
    "spin", "upgrade", "rebirth", "quest", "trade", "gift", "craft", "booth"
}

local function containsBlacklistedWord(text)
    local low = tostring(text):lower()
    for _, word in ipairs(BlacklistedKeywords) do
        if low:find(word, 1, true) then
            return true
        end
    end
    return false
end

local function isValidAnimalPrompt(prompt)
    if not prompt or not prompt.Parent then return false end

    local actionLow = tostring(prompt.ActionText):lower()
    local objectLow = tostring(prompt.ObjectText):lower()
    local fullPathLow = prompt:GetFullName():lower()

    if containsBlacklistedWord(actionLow)
        or containsBlacklistedWord(objectLow)
        or containsBlacklistedWord(fullPathLow) then
        return false
    end

    local allowed = actionLow:find("steal", 1, true)
        or actionLow:find("carry", 1, true)
        or actionLow:find("buy", 1, true)
        or actionLow:find("grab", 1, true)
        or actionLow:find("pick", 1, true)
        or actionLow:find("take", 1, true)
        or actionLow:find("hold", 1, true)

    return allowed ~= nil
end

local function getPromptPart(prompt)
    if not prompt or not prompt.Parent then return nil end
    if prompt.Parent:IsA("BasePart") then
        return prompt.Parent
    end
    return prompt:FindFirstAncestorWhichIsA("BasePart")
end

local MAX_CONTAINER_CLIMB = 4

local function shortText(text, maxLen)
    if not text then return "-" end
    local flat = tostring(text):gsub("%s+", " ")
    if #flat > maxLen then
        flat = flat:sub(1, maxLen) .. "..."
    end
    return flat
end

local function pickAnimalContainer(attachPart, partCount)
    local container = attachPart
    local inst = attachPart.Parent
    local climbed = 0

    while inst and inst ~= workspace and climbed < MAX_CONTAINER_CLIMB do
        if partCount[inst] ~= 1 then break end
        if inst:IsA("Model") and Players:GetPlayerFromCharacter(inst) then break end
        container = inst
        inst = inst.Parent
        climbed = climbed + 1
    end

    return container
end

-- minRequiredOverride: jika sedang carry, diisi dengan State.CurrentCarriedValue + 1
local function scanZone1Prompts(ignoreValueThreshold, minRequiredOverride)
    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    local rideFolder = workspace:FindFirstChild("RideMounts")
    local zone1Folder = getZone1Folder()
    local bbCache = buildBillboardCache()

    local totalZone1Pets = 0
    local highestSeenVal = 0
    local highestSeenName = "-"
    local highestSeenSource = nil

    local bestMatch = nil
    local bestVal = 0

    local candidates = {}
    local partCount = {}
    local countedPart = {}

    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("ProximityPrompt") and isValidAnimalPrompt(desc) then
            local isExcluded = false
            if carriedFolder and desc:IsDescendantOf(carriedFolder) then isExcluded = true end
            if rideFolder and desc:IsDescendantOf(rideFolder) then isExcluded = true end
            if Character and desc:IsDescendantOf(Character) then isExcluded = true end

            if not isExcluded then
                local attachPart = getPromptPart(desc)
                if attachPart and isTargetInZone1(desc, attachPart, zone1Folder) then
                    table.insert(candidates, { prompt = desc, part = attachPart })

                    if not countedPart[attachPart] then
                        countedPart[attachPart] = true
                        local inst = attachPart
                        while inst and inst ~= workspace do
                            partCount[inst] = (partCount[inst] or 0) + 1
                            inst = inst.Parent
                        end
                    end
                end
            end
        end
    end

    for _, cand in ipairs(candidates) do
        local desc = cand.prompt
        local attachPart = cand.part
        local container = pickAnimalContainer(attachPart, partCount)

        totalZone1Pets = totalZone1Pets + 1

        local name, _, val, source = extractInfoAndValue(container, attachPart.Position, bbCache)
        if desc.ObjectText ~= "" then
            name = desc.ObjectText
        end

        if val > highestSeenVal then
            highestSeenVal = val
            highestSeenName = name
            highestSeenSource = source
        end

        local passesThreshold = false
        if ignoreValueThreshold then
            passesThreshold = true
        elseif minRequiredOverride then
            passesThreshold = (val >= State.MinTargetNumber) and (val > minRequiredOverride)
        else
            passesThreshold = (val >= State.MinTargetNumber)
        end

        if passesThreshold and val >= bestVal then
            bestVal = val
            bestMatch = {
                prompt = desc,
                part = attachPart,
                container = container,
                name = name,
                value = val,
                source = source
            }
        end
    end

    return bestMatch, totalZone1Pets, highestSeenVal, highestSeenName, highestSeenSource
end

-- ==========================================
-- TELEPORT INSTAN KE SAFEZONE & KEMBALI KE ZONE 1
-- ==========================================
local function instantCFrame(targetCF)
    if not RootPart or not RootPart.Parent or not targetCF then return end
    RootPart.AssemblyLinearVelocity = Vector3.zero
    RootPart.AssemblyAngularVelocity = Vector3.zero
    RootPart.CFrame = targetCF
end

local function depositCarriedToSafeZone()
    if not State.SafeZoneCFrame then
        Rayfield:Notify({
            Title = "Titik SafeZone Belum Dikunci!",
            Content = "Pergi ke dalam garis SafeZone lalu tekan tombol 'Kunci Titik SafeZone'.",
            Duration = 4
        })
        return false
    end

    -- 1. Pindah instan ke dalam garis SafeZone agar pet otomatis tersimpan
    instantCFrame(State.SafeZoneCFrame)

    -- 2. Tunggu hingga server memproses penyimpanan (CarriedAnimals kosong)
    local startWait = tick()
    local nudged = false
    while isCurrentlyCarrying() and (tick() - startWait) < 2.5 do
        -- Geser sedikit di sekitar titik SafeZone jika batas garis belum terpicu
        if not nudged and (tick() - startWait) > 0.65 then
            nudged = true
            instantCFrame(State.SafeZoneCFrame * CFrame.new(0, 0, -2.5))
            task.wait(0.1)
            instantCFrame(State.SafeZoneCFrame)
        end
        task.wait(0.08)
    end

    local deposited = not isCurrentlyCarrying()
    if deposited then
        State.CurrentCarriedValue = 0
        State.CurrentCarriedName = "-"
        task.wait(0.15)
    end

    -- 3. Kembali ke titik diam di Zone 1
    if State.Zone1CFrame then
        instantCFrame(State.Zone1CFrame)
        task.wait(0.2)
    end

    return deposited
end

-- ==========================================
-- EKSEKUSI CARRY DIAM DI TEMPAT (ZONE 1)
-- ==========================================
local function carryStationaryPrompt(targetData)
    local prompt = targetData.prompt
    local attachPart = targetData.part
    if not prompt or not prompt.Parent or not attachPart then return end

    lastAttemptedValue = targetData.value or 0
    lastAttemptedName = targetData.name or "Pet"

    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    local initialCarriedCount = carriedFolder and #carriedFolder:GetChildren() or 0

    prompt.Enabled = true
    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance or 10, 150)

    pcall(function() prompt:InputHoldBegin() end)
    if fireproximityprompt then
        pcall(function() fireproximityprompt(prompt) end)
    end

    local totalWait = math.max((prompt.HoldDuration or 0) + 0.4, State.HoldDuration)
    local startTime = tick()

    while (tick() - startTime) < totalWait do
        if not prompt or not prompt.Parent then
            break
        end
        if carriedFolder and #carriedFolder:GetChildren() > initialCarriedCount then
            break
        end
        if isCurrentlyCarrying() then
            break
        end

        prompt.Enabled = true
        prompt.MaxActivationDistance = 150
        task.wait(0.08)
    end

    if prompt and prompt.Parent then
        pcall(function() prompt:InputHoldEnd() end)
        if fireproximityprompt then
            pcall(function() fireproximityprompt(prompt) end)
        end
    end

    task.wait(0.2)

    if isCurrentlyCarrying() then
        State.CurrentCarriedValue = math.max(State.CurrentCarriedValue, lastAttemptedValue)
        if State.CurrentCarriedName == "-" then
            State.CurrentCarriedName = lastAttemptedName
        end
    end
end

-- ==========================================
-- PEMBUATAN MENU RAYFIELD UI
-- ==========================================
local Window = Rayfield:CreateWindow({
    Name = "Break & Steal an Egg | Zone 1 + SafeZone",
    LoadingTitle = "Memuat Script...",
    LoadingSubtitle = "Auto Swap SafeZone & Webhook",
    ConfigurationSaving = {
        Enabled = false
    }
})

-- TAB 1: AUTO CARRY ZONE 1 & SAFEZONE
local MainTab = Window:CreateTab("Zone 1 Carry", 4483362458)

local StatusParagraph = MainTab:CreateParagraph({
    Title = "Status Pet & Koordinat",
    Content = "Memindai pet di Zone 1..."
})

local ToggleAutoGrab = MainTab:CreateToggle({
    Name = "Aktifkan Auto Carry Zone 1 (Diam di Tempat)",
    CurrentValue = State.AutoGrab,
    Flag = "ToggleAutoGrab",
    Callback = function(Value)
        State.AutoGrab = Value
        saveConfig()
        if Value and RootPart then
            Rayfield:Notify({
                Title = "Auto Carry Zone 1 Aktif",
                Content = "Menunggu pet >= " .. State.TargetValueRaw .. " di Zone 1.",
                Duration = 3
            })
        end
    end
})

local ToggleAutoSafeZone = MainTab:CreateToggle({
    Name = "Auto ke SafeZone Jika Ada Pet Lebih Bernilai",
    CurrentValue = State.AutoSafeZoneSwap,
    Flag = "ToggleAutoSafeZone",
    Callback = function(Value)
        State.AutoSafeZoneSwap = Value
        saveConfig()
    end
})

local InputTargetVal = MainTab:CreateInput({
    Name = "Target Minimal Value (Tekan Enter setelah ketik)",
    PlaceholderText = "Saat ini: " .. State.TargetValueRaw,
    RemoveTextAfterFocusLost = false,
    Callback = function(Text)
        local parsed = parseValue(Text)
        if parsed > 0 then
            State.TargetValueRaw = Text
            State.MinTargetNumber = parsed
            saveConfig()
            Rayfield:Notify({
                Title = "Value Tersimpan",
                Content = "Target minimal: " .. Text .. " (" .. formatShortNumber(parsed) .. ")",
                Duration = 3
            })
        else
            Rayfield:Notify({
                Title = "Format Tidak Valid",
                Content = "Gunakan angka atau suffix (contoh: 10B, 100T, 1Qa).",
                Duration = 3
            })
        end
    end
})

MainTab:CreateButton({
    Name = "1. Kunci Titik Diam Zone 1 (Posisi Sekarang)",
    Callback = function()
        if RootPart then
            State.Zone1CFrame = RootPart.CFrame
            saveConfig()
            Rayfield:Notify({
                Title = "Titik Zone 1 Tersimpan",
                Content = "Karakter akan diam dan kembali ke titik Zone 1 ini.",
                Duration = 3
            })
        end
    end
})

MainTab:CreateButton({
    Name = "2. Kunci Titik SafeZone (Berdiri di Dalam Garis)",
    Callback = function()
        if RootPart then
            State.SafeZoneCFrame = RootPart.CFrame
            saveConfig()
            Rayfield:Notify({
                Title = "Titik SafeZone Tersimpan",
                Content = "Koordinat penyimpanan otomatis di dalam SafeZone terkunci.",
                Duration = 3
            })
        end
    end
})

local SliderHoldTime = MainTab:CreateSlider({
    Name = "Durasi Tahan Tombol Carry (Detik)",
    Range = {0.5, 8},
    Increment = 0.5,
    Suffix = " Detik",
    CurrentValue = State.HoldDuration,
    Flag = "SliderHoldTime",
    Callback = function(Value)
        State.HoldDuration = Value
        saveConfig()
    end
})

local SliderZoneRadius = MainTab:CreateSlider({
    Name = "Radius Deteksi Pet Diantarkan (Studs)",
    Range = {20, 200},
    Increment = 5,
    Suffix = " Studs",
    CurrentValue = State.ZoneRadius,
    Flag = "SliderZoneRadius",
    Callback = function(Value)
        State.ZoneRadius = Value
        saveConfig()
    end
})

MainTab:CreateButton({
    Name = "Test Carry Pet Terdekat di Zone 1 (Abaikan Value)",
    Callback = function()
        if isBusy then return end
        local nearest = scanZone1Prompts(true, nil)
        if nearest then
            isBusy = true
            Rayfield:Notify({
                Title = "Menguji Carry Zone 1",
                Content = string.format("Target: %s ($%s/s)", tostring(nearest.name), formatShortNumber(nearest.value)),
                Duration = 2.5
            })
            task.spawn(function()
                carryStationaryPrompt(nearest)
                isBusy = false
            end)
        else
            Rayfield:Notify({
                Title = "Tidak Ditemukan",
                Content = "Belum ada pet di area Zone 1.",
                Duration = 3
            })
        end
    end
})

-- TAB 2: WEBHOOK DISCORD
local WebhookTab = Window:CreateTab("Webhook", 4483362458)

local ToggleWebhook = WebhookTab:CreateToggle({
    Name = "Aktifkan Webhook CarriedAnimals",
    CurrentValue = State.WebhookEnabled,
    Flag = "ToggleWebhook",
    Callback = function(Value)
        State.WebhookEnabled = Value
        saveConfig()
    end
})

local InputWebhookURL = WebhookTab:CreateInput({
    Name = "URL Webhook Discord",
    PlaceholderText = (State.WebhookURL ~= "" and "URL Tersimpan (Klik untuk ubah)" or "https://discord.com/api/webhooks/..."),
    RemoveTextAfterFocusLost = false,
    Callback = function(Text)
        State.WebhookURL = Text:gsub("^%s*(.-)%s*$", "%1")
        saveConfig()
        Rayfield:Notify({
            Title = "Webhook Tersimpan",
            Content = "URL Webhook Discord otomatis disimpan ke config.",
            Duration = 2.5
        })
    end
})

local InputPingText = WebhookTab:CreateInput({
    Name = "Tag / Mention (Opsional)",
    PlaceholderText = (State.PingText ~= "" and ("Tersimpan: " .. State.PingText) or "Contoh: @everyone atau <@&ID_ROLE>"),
    RemoveTextAfterFocusLost = false,
    Callback = function(Text)
        State.PingText = Text
        saveConfig()
    end
})

WebhookTab:CreateButton({
    Name = "Test Kirim Webhook",
    Callback = function()
        if State.WebhookURL == "" then
            Rayfield:Notify({
                Title = "URL Kosong",
                Content = "Masukkan URL Webhook Discord terlebih dahulu.",
                Duration = 3
            })
            return
        end
        postToDiscord("🔔 Test Koneksi Webhook", "Pet Zone 1 ($100T/s)", "• **Status:** Webhook berhasil terhubung!")
        Rayfield:Notify({
            Title = "Test Terkirim",
            Content = "Silakan cek channel Discord kamu.",
            Duration = 3
        })
    end
})

WebhookTab:CreateButton({
    Name = "Reset Config ke Default",
    Callback = function()
        State.AutoGrab = false
        State.AutoSafeZoneSwap = true
        State.TargetValueRaw = "10B"
        State.MinTargetNumber = 1e10
        State.HoldDuration = 5.0
        State.ZoneRadius = 75
        State.SafeZoneCFrame = nil
        State.WebhookEnabled = true
        State.WebhookURL = ""
        State.PingText = ""

        pcall(function() ToggleAutoGrab:Set(false) end)
        pcall(function() ToggleAutoSafeZone:Set(true) end)
        pcall(function() InputTargetVal:Set("10B") end)
        pcall(function() SliderHoldTime:Set(5.0) end)
        pcall(function() SliderZoneRadius:Set(75) end)
        pcall(function() ToggleWebhook:Set(true) end)
        pcall(function() InputWebhookURL:Set("") end)
        pcall(function() InputPingText:Set("") end)

        saveConfig()
        Rayfield:Notify({
            Title = "Config Direset",
            Content = "Seluruh pengaturan dikembalikan ke bawaan.",
            Duration = 3
        })
    end
})

-- ==========================================
-- LOOP UTAMA PEMINDAIAN, AUTO-SWAP SAFEZONE & STATUS UI
-- ==========================================
task.spawn(function()
    while task.wait(0.35) do
        if RootPart and RootPart.Parent then
            local carrying = isCurrentlyCarrying()

            -- Reset pencatat value jika tangan sudah kosong (misal pet sudah disetor manual)
            if not carrying and State.CurrentCarriedValue > 0 and not isBusy then
                State.CurrentCarriedValue = 0
                State.CurrentCarriedName = "-"
            end

            -- Jika sedang carry dan fitur swap aktif, cari pet yang nilainya STRICTLY > pet yang sedang di-carry
            local minOverride = (carrying and State.AutoSafeZoneSwap) and State.CurrentCarriedValue or nil
            local match, totalPets, highestVal, highestName = scanZone1Prompts(false, minOverride)

            local carryStatus = carrying
                and string.format("Carry: %s ($%s/s)", shortText(State.CurrentCarriedName, 18), formatShortNumber(State.CurrentCarriedValue))
                or "Tangan Kosong"

            local szStatus = State.SafeZoneCFrame and "Terkunci" or "BELUM DIKUNCI"

            pcall(function()
                StatusParagraph:Set({
                    Title = "Status Pet & Koordinat",
                    Content = string.format(
                        "Target: %s | SafeZone: %s\nStatus: %s\nPet Zone 1: %d | Tertinggi: %s ($%s/s)",
                        State.TargetValueRaw,
                        szStatus,
                        carryStatus,
                        totalPets,
                        tostring(highestName),
                        formatShortNumber(highestVal)
                    )
                })
            end)

            if State.AutoGrab and not isBusy and match then
                if not carrying then
                    -- KASUS 1: Tangan kosong -> langsung carry diam di tempat di Zone 1
                    isBusy = true

                    Rayfield:Notify({
                        Title = "Pet Target Ditemukan!",
                        Content = string.format("Carry %s ($%s/s)", tostring(match.name), formatShortNumber(match.value)),
                        Duration = 2.5
                    })

                    carryStationaryPrompt(match)

                    task.wait(0.15)
                    isBusy = false

                elseif State.AutoSafeZoneSwap and tick() >= depositCooldownUntil then
                    -- KASUS 2: Sedang carry pet, tapi muncul pet dengan value LEBIH TINGGI
                    isBusy = true

                    Rayfield:Notify({
                        Title = "Pet Lebih Tinggi Terdeteksi!",
                        Content = string.format(
                            "Amankan ($%s/s) ke SafeZone -> Ambil %s ($%s/s)",
                            formatShortNumber(State.CurrentCarriedValue),
                            tostring(match.name),
                            formatShortNumber(match.value)
                        ),
                        Duration = 3
                    })

                    local savedOk = depositCarriedToSafeZone()
                    if savedOk then
                        -- Pindai ulang Zone 1 setelah kembali untuk memastikan mengambil pet tertinggi yang tersedia
                        local bestAfterReturn = scanZone1Prompts(false, nil)
                        local nextTarget = bestAfterReturn or match
                        if nextTarget and nextTarget.prompt and nextTarget.prompt.Parent then
                            carryStationaryPrompt(nextTarget)
                        end
                    else
                        depositCooldownUntil = tick() + 3
                    end

                    task.wait(0.15)
                    isBusy = false
                end
            end
        end
    end
end)

if configFound then
    pcall(function() ToggleAutoSafeZone:Set(State.AutoSafeZoneSwap) end)
    pcall(function() InputTargetVal:Set(State.TargetValueRaw) end)
    pcall(function() SliderZoneRadius:Set(State.ZoneRadius) end)
    pcall(function() InputWebhookURL:Set(State.WebhookURL) end)
    pcall(function() InputPingText:Set(State.PingText) end)

    Rayfield:Notify({
        Title = "Config Dimuat",
        Content = string.format("Target: %s | SafeZone: %s | Webhook: %s",
            State.TargetValueRaw,
            (State.SafeZoneCFrame and "Tersimpan" or "Belum Dikunci"),
            (State.WebhookURL ~= "" and "Tersimpan" or "Kosong")
        ),
        Duration = 4
    })
end
