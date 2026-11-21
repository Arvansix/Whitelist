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

local State = {
    -- Auto Grab & Instant TP
    AutoGrab = false,
    TargetValueRaw = "10B",
    MinTargetNumber = 1e10,
    HoldDuration = 5.0,
    OffsetY = 2.0,
    -- Titik pulang. Hanya berubah lewat tombol "Kunci Ulang Titik Awal Diam".
    -- Nilai awal = posisi saat script dijalankan.
    SavedStandCFrame = RootPart.CFrame,

    -- Webhook Discord
    WebhookEnabled = true,
    WebhookURL = "",
    PingText = "",
    WebhookCooldown = 2
}

local isBusy = false
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
-- KONVERSI SUFFIX VALUE (K, M, B, T, QA, QI...)
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

-- Baca SATU baris teks sebagai value. Seluruh baris harus berupa angka + suffix
-- (contoh: "$1.8M/s", "10B", "1,500"). Teks biasa yang kebetulan memuat angka
-- (nama pemain, timer, level, dll) tidak ikut terbaca sebagai value.
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

-- ==========================================
-- SISTEM AUTO SAVE & LOAD CONFIG (JSON)
-- ==========================================
local function saveConfig()
    if not isLoaded or not writefile then return end

    local dataToSave = {
        AutoGrab = State.AutoGrab,
        TargetValueRaw = State.TargetValueRaw,
        HoldDuration = State.HoldDuration,
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
        if type(result.TargetValueRaw) == "string" and result.TargetValueRaw ~= "" then
            local parsed = parseValue(result.TargetValueRaw)
            if parsed > 0 then
                State.TargetValueRaw = result.TargetValueRaw
                State.MinTargetNumber = parsed
            end
        end
        if type(result.HoldDuration) == "number" then State.HoldDuration = result.HoldDuration end
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
-- PEMETAAN BILLBOARDGUI & EKSTRAKSI DATA
-- ==========================================
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

local function buildBillboardCache()
    local cache = {}

    local function processBillboard(bb)
        if not bb:IsA("BillboardGui") then return end
        local host = bb.Adornee or bb.Parent
        local pos = getWorldPosition(host)
        if not pos then return end

        local texts = {}

        for _, d in ipairs(bb:GetDescendants()) do
            if d:IsA("TextLabel") and d.Visible and d.Text ~= "" then
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

local BILLBOARD_MAX_DIST = 7.5   -- jarak mendatar maksimum billboard dari hewan
local BILLBOARD_TOLERANCE = 2.5  -- hanya billboard yang selisih jaraknya <= ini dari yang terdekat ikut dibaca

-- Nama attribute angka yang dianggap value income hewan
local IncomeKeyHints = { "income", "persec", "per_sec", "pps", "earn", "production", "yield" }

-- Beri nilai sumber value. Tier 2 = paling bisa dipercaya, tier 1 = cadangan, tier 0 = diabaikan.
--   Tier 2: teks berisi "/s" (mis. "$1.8M/s") atau attribute angka bernama income
--   Tier 1: teks lain yang terbaca sebagai angka dengan suffix / "$"
-- Angka mentah lain (ID, timestamp, dsb) TIDAK dihitung supaya tidak menaikkan value palsu.
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
            elseif desc:IsA("TextLabel") and desc.Visible and desc.Text ~= "" then
                processEntry("", desc.Text)
            elseif desc:IsA("ProximityPrompt") and desc.ObjectText ~= "" then
                displayName = desc.ObjectText
                processEntry("Target", desc.ObjectText)
            end
        end
    end

    scanInstance(obj)

    -- Cocokkan BillboardGui yang melayang di atas hewan ini. Hanya billboard terdekat
    -- (dan yang jaraknya hampir sama) yang dibaca, supaya value hewan di sebelahnya tidak ikut terbaca.
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
-- HEWAN DI-DROP / TERKENA HIT (JANGAN DIAMBIL LAGI)
-- ==========================================
local HOME_RADIUS = 30          -- hewan yang lepas dari CarriedAnimals lebih jauh dari ini dari titik pulang dianggap di-drop
local DROP_SPOT_RADIUS = 15     -- area di sekitar titik drop yang ikut di-skip (jika game membuat ulang model hewannya)
local DROP_SPOT_SECONDS = 300   -- lama area drop di-skip

local IgnoredAnimals = setmetatable({}, { __mode = "k" })
local IgnoredSpots = {}
local trackedCarried = setmetatable({}, { __mode = "k" })

-- Nama attribute yang menandakan hewan sedang di-drop / kena hit (nilai harus true)
local DroppedFlagNames = {
    dropped = true, isdropped = true, wasdropped = true,
    hit = true, ishit = true, washit = true,
    stunned = true, isstunned = true,
    ragdoll = true, ragdolled = true, isragdolled = true
}

local function hasDroppedFlag(target)
    if not target then return false end
    for attrName, attrVal in pairs(target:GetAttributes()) do
        if attrVal == true and DroppedFlagNames[attrName:lower()] then
            return true
        end
    end
    return false
end

local function ignoreAnimal(obj, pos)
    if obj then
        IgnoredAnimals[obj] = true
    end
    if pos then
        table.insert(IgnoredSpots, { pos = pos, time = tick() })
    end
end

local function isIgnoredSpot(pos)
    local now = tick()
    for i = #IgnoredSpots, 1, -1 do
        local spot = IgnoredSpots[i]
        if now - spot.time > DROP_SPOT_SECONDS then
            table.remove(IgnoredSpots, i)
        elseif pos and (pos - spot.pos).Magnitude <= DROP_SPOT_RADIUS then
            return true
        end
    end
    return false
end

-- True jika prompt milik hewan yang pernah di-drop / terkena hit
local function isDroppedOrHit(prompt, attachPart, animalModel)
    local inst = prompt
    while inst and inst ~= workspace do
        if IgnoredAnimals[inst] then
            return true
        end
        inst = inst.Parent
    end

    if hasDroppedFlag(prompt)
        or hasDroppedFlag(attachPart)
        or hasDroppedFlag(animalModel)
        or prompt:GetFullName():lower():find("dropped", 1, true) then
        -- Sekali terdeteksi, hewan ini tidak diambil lagi walau flag-nya hilang
        if attachPart then
            IgnoredAnimals[attachPart] = true
        end
        return true
    end

    return attachPart ~= nil and isIgnoredSpot(attachPart.Position)
end

-- Pantau hewan yang sedang kita bawa. Jika lepas dari CarriedAnimals jauh dari
-- titik pulang (artinya tidak sampai disimpan ke base), anggap di-drop / kena hit.
local function trackMyCarried(animal, animalName)
    if not animal or trackedCarried[animal] then return end
    trackedCarried[animal] = true

    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    local conn
    conn = animal.AncestryChanged:Connect(function()
        if carriedFolder and animal:IsDescendantOf(carriedFolder) then return end
        conn:Disconnect()

        local okPos, dropPos = pcall(getWorldPosition, animal)
        if not okPos or not dropPos then
            dropPos = RootPart and RootPart.Position or nil
        end
        if not dropPos then return end

        local homePos = State.SavedStandCFrame.Position
        if (dropPos - homePos).Magnitude > HOME_RADIUS then
            ignoreAnimal(animal, dropPos)
            pcall(function()
                Rayfield:Notify({
                    Title = "Hewan Terlepas (Drop / Hit)",
                    Content = tostring(animalName) .. " tidak akan diambil lagi.",
                    Duration = 3
                })
            end)
        end
    end)
end

-- ==========================================
-- FUNGSI WEBHOOK DISCORD (CARRIEDANIMALS)
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
                    name = "🦁 Hewan / Item",
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

    local animalName, extraData = extractInfoAndValue(actualAnimal, nil, nil)

    -- Pelacakan drop berjalan terpisah dari webhook, jadi tetap aktif walau webhook dimatikan
    trackMyCarried(actualAnimal, animalName)

    if State.WebhookEnabled then
        postToDiscord("🐾 Hewan Berhasil Dipegang!", animalName, extraData)
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
-- FILTER KETAT PROXIMITYPROMPT (ANTI FUSE / SHOP)
-- ==========================================
local BlacklistedKeywords = {
    "fuse", "fusion", "sell", "shop", "index", "wheel",
    "spin", "upgrade", "rebirth", "quest", "trade", "gift", "craft"
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
        or actionLow:find("buy", 1, true)
        or actionLow:find("grab", 1, true)
        or actionLow:find("pick", 1, true)
        or actionLow:find("take", 1, true)

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

-- Potong teks panjang jadi satu baris pendek untuk ditampilkan di UI
local function shortText(text, maxLen)
    if not text then return "-" end
    local flat = tostring(text):gsub("%s+", " ")
    if #flat > maxLen then
        flat = flat:sub(1, maxLen) .. "..."
    end
    return flat
end

-- Cari wadah (container) satu hewan: ancestor terbesar yang hanya berisi SATU part prompt hewan.
-- Dengan begitu value hewan lain di base yang sama tidak ikut terbaca.
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

local function scanAnimalPrompts(ignoreValueThreshold)
    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    local rideFolder = workspace:FindFirstChild("RideMounts")
    local bbCache = buildBillboardCache()

    local totalAnimalPrompts = 0
    local skippedDropped = 0
    local highestSeenVal = 0
    local highestSeenName = "-"
    local highestSeenSource = nil

    local bestMatch = nil
    local bestDistance = math.huge

    -- Tahap 1: kumpulkan semua prompt hewan, lalu hitung ada berapa part prompt di dalam tiap ancestor
    local candidates = {}
    local partCount = {}
    local countedPart = {}

    -- Tidak memfilter prompt.Enabled di sini karena StealPromptVisibilityController mematikannya saat di Safe Zone
    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("ProximityPrompt") and isValidAnimalPrompt(desc) then
            local isExcluded = false
            if carriedFolder and desc:IsDescendantOf(carriedFolder) then isExcluded = true end
            if rideFolder and desc:IsDescendantOf(rideFolder) then isExcluded = true end
            if Character and desc:IsDescendantOf(Character) then isExcluded = true end

            if not isExcluded then
                local attachPart = getPromptPart(desc)
                if attachPart then
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

    -- Tahap 2: baca value tiap hewan hanya dari wadahnya sendiri, lalu pilih yang sesuai target
    for _, cand in ipairs(candidates) do
        local desc = cand.prompt
        local attachPart = cand.part
        local container = pickAnimalContainer(attachPart, partCount)

        if isDroppedOrHit(desc, attachPart, container) then
            skippedDropped = skippedDropped + 1
        else
            totalAnimalPrompts = totalAnimalPrompts + 1

            local name, _, val, source = extractInfoAndValue(container, attachPart.Position, bbCache)

            if desc.ObjectText ~= "" then
                name = desc.ObjectText
            end

            if val > highestSeenVal then
                highestSeenVal = val
                highestSeenName = name
                highestSeenSource = source
            end

            if ignoreValueThreshold or val >= State.MinTargetNumber then
                local dist = RootPart and (RootPart.Position - attachPart.Position).Magnitude or 0
                if dist < bestDistance then
                    bestDistance = dist
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
        end
    end

    return bestMatch, totalAnimalPrompts, highestSeenVal, highestSeenName, skippedDropped, highestSeenSource
end

-- ==========================================
-- EKSEKUSI TELEPORT + HOLD PROXIMITYPROMPT
-- ==========================================
local function instantCFrame(targetCF)
    if not RootPart or not RootPart.Parent then return end
    RootPart.AssemblyLinearVelocity = Vector3.zero
    RootPart.AssemblyAngularVelocity = Vector3.zero
    RootPart.CFrame = targetCF
end

local function holdAndStealPrompt(targetData)
    local prompt = targetData.prompt
    local attachPart = targetData.part
    if not prompt or not prompt.Parent or not attachPart then return end

    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    local initialCarriedCount = carriedFolder and #carriedFolder:GetChildren() or 0
    local grabPos = attachPart.CFrame * CFrame.new(0, State.OffsetY, 1.5)

    instantCFrame(grabPos)
    task.wait(0.3)
    if not prompt or not prompt.Parent then return end

    -- Paksa aktifkan prompt meskipun StealPromptVisibilityController sempat menonaktifkannya
    prompt.Enabled = true
    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = 25

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
        -- Hewan target tiba-tiba kena hit / di-drop saat kita menahan tombol: berhenti
        if isDroppedOrHit(prompt, attachPart, targetData.container) then
            break
        end

        prompt.Enabled = true
        instantCFrame(grabPos)
        task.wait(0.08)
    end

    if prompt and prompt.Parent then
        pcall(function() prompt:InputHoldEnd() end)
        if fireproximityprompt then
            pcall(function() fireproximityprompt(prompt) end)
        end
    end

    task.wait(0.2)
end

-- ==========================================
-- PEMBUATAN MENU RAYFIELD UI
-- ==========================================
local Window = Rayfield:CreateWindow({
    Name = "Break & Steal an Egg | Hub",
    LoadingTitle = "Memuat Script...",
    LoadingSubtitle = "Controller Bypass & Auto-Save",
    ConfigurationSaving = {
        Enabled = false
    }
})

-- TAB 1: INSTANT TELEPORT & AUTO GRAB
local MainTab = Window:CreateTab("Auto Grab", 4483362458)

local StatusParagraph = MainTab:CreateParagraph({
    Title = "Status Scanner & Target Aktif",
    Content = "Memindai hewan di map..."
})

local ToggleAutoGrab = MainTab:CreateToggle({
    Name = "Aktifkan Auto Grab (Instant TP + Hold)",
    CurrentValue = State.AutoGrab,
    Flag = "ToggleAutoGrab",
    Callback = function(Value)
        State.AutoGrab = Value
        saveConfig()
        if Value then
            Rayfield:Notify({
                Title = "Auto Grab Aktif",
                Content = "Mencari hewan >= " .. State.TargetValueRaw,
                Duration = 3
            })
        end
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
                Content = "Target aktif sekarang: " .. Text .. " (" .. formatShortNumber(parsed) .. ")",
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

local SliderHoldTime = MainTab:CreateSlider({
    Name = "Durasi Tahan Tombol Steal (Detik)",
    Range = {1, 8},
    Increment = 0.5,
    Suffix = " Detik",
    CurrentValue = State.HoldDuration,
    Flag = "SliderHoldTime",
    Callback = function(Value)
        State.HoldDuration = Value
        saveConfig()
    end
})

MainTab:CreateButton({
    Name = "Test Steal Hewan Terdekat (Abaikan Value)",
    Callback = function()
        if isBusy then return end
        local nearest = scanAnimalPrompts(true)
        if nearest then
            isBusy = true
            -- Hanya untuk test: kembali ke posisi sebelum test, titik pulang yang terkunci tidak diubah
            local returnCF = RootPart.CFrame
            Rayfield:Notify({
                Title = "Menguji Steal Hewan",
                Content = string.format("Target: %s ($%s/s)", tostring(nearest.name), formatShortNumber(nearest.value)),
                Duration = 2.5
            })
            task.spawn(function()
                holdAndStealPrompt(nearest)
                instantCFrame(returnCF)
                isBusy = false
            end)
        else
            Rayfield:Notify({
                Title = "Tidak Ditemukan",
                Content = "Belum ada base pemain lain yang memiliki hewan.",
                Duration = 3
            })
        end
    end
})

MainTab:CreateButton({
    Name = "Kunci Ulang Titik Awal Diam (Posisi Sekarang)",
    Callback = function()
        if RootPart then
            State.SavedStandCFrame = RootPart.CFrame
            Rayfield:Notify({
                Title = "Titik Pulang Diperbarui",
                Content = "Karakter akan kembali ke titik ini setelah mengambil hewan.",
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
        postToDiscord("🔔 Test Koneksi Webhook", "Alien Jellyfish ($79.5B/s)", "• **Status:** Webhook berhasil terhubung!")
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
        State.TargetValueRaw = "10B"
        State.MinTargetNumber = 1e10
        State.HoldDuration = 5.0
        State.WebhookEnabled = true
        State.WebhookURL = ""
        State.PingText = ""

        pcall(function() ToggleAutoGrab:Set(false) end)
        pcall(function() InputTargetVal:Set("10B") end)
        pcall(function() SliderHoldTime:Set(5.0) end)
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
-- LOOP UTAMA PEMINDAIAN & UPDATE STATUS UI
-- ==========================================
task.spawn(function()
    while task.wait(0.45) do
        if RootPart and RootPart.Parent then
            local match, totalAnimals, highestVal, highestName, skipped, highestSource = scanAnimalPrompts(false)

            pcall(function()
                StatusParagraph:Set({
                    Title = "Status Scanner & Target Aktif",
                    Content = string.format(
                        "Target Aktif: %s (%s)\nHewan Terdeteksi: %d | Tertinggi: %s ($%s/s)\nSumber value: %s\nDi-skip (drop/hit): %d",
                        State.TargetValueRaw,
                        formatShortNumber(State.MinTargetNumber),
                        totalAnimals,
                        tostring(highestName),
                        formatShortNumber(highestVal),
                        shortText(highestSource, 45),
                        skipped
                    )
                })
            end)

            if State.AutoGrab and not isBusy and match then
                isBusy = true

                Rayfield:Notify({
                    Title = "Hewan Target Ditemukan!",
                    Content = string.format("Mengambil %s ($%s/s)\nSumber: %s", tostring(match.name), formatShortNumber(match.value), shortText(match.source, 50)),
                    Duration = 2.5
                })

                holdAndStealPrompt(match)

                instantCFrame(State.SavedStandCFrame)
                task.wait(0.25)
                isBusy = false
            end
        end
    end
end)

if configFound then
    pcall(function() InputTargetVal:Set(State.TargetValueRaw) end)
    pcall(function() InputWebhookURL:Set(State.WebhookURL) end)
    pcall(function() InputPingText:Set(State.PingText) end)

    Rayfield:Notify({
        Title = "Config Dimuat",
        Content = string.format("Target: %s | Hold: %.1fs | Webhook: %s",
            State.TargetValueRaw,
            State.HoldDuration,
            (State.WebhookURL ~= "" and "Tersimpan" or "Kosong")
        ),
        Duration = 4
    })
end
