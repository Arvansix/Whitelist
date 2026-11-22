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
    -- Auto Carry & Instant TP
    AutoGrab = false,
    TargetValueRaw = "10B",
    MinTargetNumber = 1e10,
    OffsetY = 2.0,

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
-- PET YANG SEDANG DIBAWA & PET YANG TERLEPAS (JANGAN DIAMBIL LAGI)
-- ==========================================
-- Pet yang sedang kita bawa. value = 0 berarti tidak membawa apa-apa.
local Carry = {
    obj = nil,
    value = 0,
    name = "-",
    releasing = false,   -- true saat kita SENGAJA melepas pet di Safe Zone
    pending = nil,       -- info target yang sedang diambil (dipakai webhook)
    cooldownUntil = 0    -- jeda sebelum mencoba menukar pet lagi jika gagal melepas
}

local IgnoredAnimals = setmetatable({}, { __mode = "k" })
local trackedCarried = setmetatable({}, { __mode = "k" })

-- Deteksi tambahan lewat attribute / nama path ("Dropped", "Hit", "Stunned", ...).
-- Dimatikan: pet yang diantar script lain ke Zone1 bisa saja bertanda "dropped" dan harus tetap bisa diambil.
-- Pet yang lepas dari bawaan KITA sendiri tetap otomatis tidak diambil lagi (lihat trackMyCarried).
local DETECT_DROP_FLAGS = false

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

local function ignoreAnimal(obj)
    if obj then
        IgnoredAnimals[obj] = true
    end
end

-- True jika prompt milik pet yang pernah terlepas dari bawaan kita (drop / terkena hit)
local function isDroppedOrHit(prompt, attachPart, animalModel)
    local inst = prompt
    while inst and inst ~= workspace do
        if IgnoredAnimals[inst] then
            return true
        end
        inst = inst.Parent
    end

    if DETECT_DROP_FLAGS and (
        hasDroppedFlag(prompt)
        or hasDroppedFlag(attachPart)
        or hasDroppedFlag(animalModel)
        or prompt:GetFullName():lower():find("dropped", 1, true)
    ) then
        if attachPart then
            IgnoredAnimals[attachPart] = true
        end
        return true
    end

    return false
end

local function isStillCarried(obj)
    if not obj or not obj.Parent then return false end
    local folder = workspace:FindFirstChild("CarriedAnimals")
    return folder ~= nil and obj:IsDescendantOf(folder)
end

local function clearCarry()
    Carry.obj = nil
    Carry.value = 0
    Carry.name = "-"
end

-- Pantau pet yang sedang kita bawa. Kalau lepas dari CarriedAnimals bukan karena kita
-- sengaja melepasnya (Carry.releasing), berarti terkena hit / di-drop: pet itu tidak diambil lagi.
local function trackMyCarried(animal, animalName)
    if not animal or trackedCarried[animal] then return end
    trackedCarried[animal] = true

    local carriedFolder = workspace:FindFirstChild("CarriedAnimals")
    local conn
    conn = animal.AncestryChanged:Connect(function()
        if carriedFolder and animal:IsDescendantOf(carriedFolder) then return end
        conn:Disconnect()

        if Carry.obj == animal then
            clearCarry()
        end

        ignoreAnimal(animal)

        if not Carry.releasing then
            pcall(function()
                Rayfield:Notify({
                    Title = "Pet Terlepas (Drop / Hit)",
                    Content = tostring(animalName) .. " tidak akan diambil lagi.",
                    Duration = 3
                })
            end)
        end
    end)
end

-- Notifikasi dengan jeda, supaya tidak spam saat kondisi yang sama berulang
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
            Duration = 4
        })
    end)
end

-- Objek di CarriedAnimals bisa berupa wadah bernama pemain yang berisi hewannya
local function resolveCarriedAnimal(child)
    if child.Name == LocalPlayer.Name and #child:GetChildren() > 0 then
        return child:GetChildren()[1]
    end
    return child
end

-- Catat isi CarriedAnimals sebelum mengambil pet, untuk mengenali pet yang baru kita bawa
local function snapshotCarried()
    local set = {}
    local folder = workspace:FindFirstChild("CarriedAnimals")
    if folder then
        for _, child in ipairs(folder:GetChildren()) do
            set[child] = true
            if child:IsA("Folder") or child.Name == LocalPlayer.Name then
                for _, sub in ipairs(child:GetChildren()) do
                    set[sub] = true
                end
            end
        end
    end
    return set
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

-- Cari pet yang baru muncul di CarriedAnimals (dibanding snapshot) dan dibawa oleh kita
local function findNewCarried(before)
    local folder = workspace:FindFirstChild("CarriedAnimals")
    if not folder then return nil end

    for _, child in ipairs(folder:GetChildren()) do
        if not before[child] and isMyCarriedAnimal(child) then
            return resolveCarriedAnimal(child)
        end
        if child:IsA("Folder") or child.Name == LocalPlayer.Name then
            for _, sub in ipairs(child:GetChildren()) do
                if not before[sub] and isMyCarriedAnimal(sub) then
                    return sub
                end
            end
        end
    end
    return nil
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

    -- Saat script sedang mengambil pet, objek baru di CarriedAnimals dianggap milik kita
    local pending = Carry.pending
    if not pending and not isMyCarriedAnimal(targetObj) then return end

    if not State.WebhookEnabled then return end

    local actualAnimal = resolveCarriedAnimal(targetObj)
    local animalName, extraData = extractInfoAndValue(actualAnimal, nil, nil)

    -- Pakai nama & value dari hasil scan Zone1 jika tersedia (lebih akurat dari isi model yang dibawa)
    if pending then
        animalName = tostring(pending.name or animalName)
        extraData = string.format("• **Value:** $%s/s\n", formatShortNumber(pending.value or 0))
            .. string.sub(extraData, 1, 950)
    end

    postToDiscord("🐾 Hewan Berhasil Dipegang!", animalName, extraData)
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
-- FILTER PROXIMITYPROMPT (HANYA AKSI CARRY, ANTI FUSE / SHOP)
-- ==========================================
local BlacklistedKeywords = {
    "fuse", "fusion", "sell", "shop", "index", "wheel",
    "spin", "upgrade", "rebirth", "quest", "trade", "gift", "craft"
}

-- Prompt pet hanya dianggap valid jika ActionText-nya memuat salah satu kata ini.
-- Ubah daftar ini jika tombol carry di game memakai kata lain.
local CarryActionWords = { "carry", "pick", "grab", "take", "steal" }

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

    -- ActionText kosong (teks bisa diisi game belakangan): tetap jadi kandidat.
    -- Prompt lain di Zone1 (telur, dll) tersaring oleh syarat value.
    if actionLow == "" then
        return true
    end

    for _, word in ipairs(CarryActionWords) do
        if actionLow:find(word, 1, true) then
            return true
        end
    end
    return false
end

local function getPromptPart(prompt)
    if not prompt or not prompt.Parent then return nil end
    if prompt.Parent:IsA("BasePart") then
        return prompt.Parent
    end
    return prompt:FindFirstAncestorWhichIsA("BasePart")
end

-- ==========================================
-- AREA ZONE1 (Workspace > Build > ZoneBuilds > Zone1)
-- ==========================================
local ZONE_MARGIN = 12            -- toleransi mendatar di sekitar batas Zone1 (studs)
local ZONE_VERTICAL_MARGIN = 40   -- toleransi tinggi di sekitar batas Zone1 (studs)

local zoneRef = nil
local function getZone1()
    if zoneRef and zoneRef.Parent then
        return zoneRef
    end
    local build = workspace:FindFirstChild("Build")
    local zoneBuilds = build and build:FindFirstChild("ZoneBuilds")
    zoneRef = zoneBuilds and zoneBuilds:FindFirstChild("Zone1") or nil
    return zoneRef
end

-- Info area Zone1 (kotak batas). Dihitung ulang tiap 3 detik supaya scan tetap ringan
-- tapi cepat mengikuti bagian map yang baru termuat (StreamingEnabled).
local zoneInfoCache, zoneInfoTime = nil, 0
local function getZone1Info()
    local zone = getZone1()
    if not zone then
        zoneInfoCache = nil
        return nil
    end

    if zoneInfoCache and zoneInfoCache.zone == zone and (tick() - zoneInfoTime) < 3 then
        return zoneInfoCache
    end

    local info = { zone = zone }
    if zone:IsA("Model") then
        local okBox, cf, size = pcall(function()
            return zone:GetBoundingBox()
        end)
        if okBox and cf and size then
            info.cf = cf
            info.half = size / 2
        end
    end

    zoneInfoCache = info
    zoneInfoTime = tick()
    return info
end

-- Part dianggap di Zone1 jika menjadi bagian dari model Zone1 atau posisinya di dalam kotak batas Zone1
local function isInZone1(info, part)
    if part:IsDescendantOf(info.zone) then
        return true
    end
    if info.cf then
        local rel = info.cf:PointToObjectSpace(part.Position)
        return math.abs(rel.X) <= info.half.X + ZONE_MARGIN
            and math.abs(rel.Y) <= info.half.Y + ZONE_VERTICAL_MARGIN
            and math.abs(rel.Z) <= info.half.Z + ZONE_MARGIN
    end
    return false
end

-- ==========================================
-- SAFE ZONE (Workspace > Build > ZoneHitboxes > SafeZone)
-- ==========================================
-- Jika game memakai StreamingEnabled, bagian Zone1 bisa belum termuat saat karakter diam jauh darinya.
-- Minta game memuat area Zone1 secara berkala supaya pet yang baru datang langsung terdeteksi.
local lastStreamRequest = 0
local function keepZoneStreamed(info)
    if not workspace.StreamingEnabled or not info or not info.cf then return end
    if (tick() - lastStreamRequest) < 5 then return end
    lastStreamRequest = tick()

    task.spawn(function()
        pcall(function()
            LocalPlayer:RequestStreamAroundAsync(info.cf.Position)
        end)
    end)
end

local safeZoneRef = nil
local function getSafeZone()
    if safeZoneRef and safeZoneRef.Parent then
        return safeZoneRef
    end
    local build = workspace:FindFirstChild("Build")
    local hitboxes = build and build:FindFirstChild("ZoneHitboxes")
    safeZoneRef = hitboxes and hitboxes:FindFirstChild("SafeZone") or nil
    return safeZoneRef
end

-- Titik berdiri di tengah Safe Zone: ray dijatuhkan dari atas area ke tanah,
-- lalu karakter berdiri sedikit di atas tanah itu (tetap di dalam area Safe Zone).
local function getSafeZoneCFrame()
    local zone = getSafeZone()
    if not zone then return nil end

    local cf, size
    if zone:IsA("BasePart") then
        cf, size = zone.CFrame, zone.Size
    elseif zone:IsA("Model") then
        local okBox, boxCF, boxSize = pcall(function()
            return zone:GetBoundingBox()
        end)
        if okBox then
            cf, size = boxCF, boxSize
        end
    end
    if not cf then return nil end

    local top = cf.Position + Vector3.new(0, size.Y / 2, 0)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.RespectCanCollide = true
    params.FilterDescendantsInstances = { zone.Parent, Character }

    local result = workspace:Raycast(top, Vector3.new(0, -(size.Y + 200), 0), params)
    if result then
        return CFrame.new(result.Position + Vector3.new(0, 3, 0))
    end
    return CFrame.new(top + Vector3.new(0, 3, 0))
end

-- ==========================================
-- SCAN PET DI ZONE1
-- ==========================================
local MAX_CONTAINER_CLIMB = 4
local RETRY_BASE_DELAY = 1.0    -- jeda (detik) setelah gagal pertama; naik sebesar ini tiap gagal berikutnya
local RETRY_MAX_DELAY = 6       -- batas jeda terpanjang (detik)

-- Prompt yang baru gagal diambil: dilewati sampai waktu yang tercatat
local RetryAfter = setmetatable({}, { __mode = "k" })
local RetryFails = setmetatable({}, { __mode = "k" })

local function markPromptFailed(prompt)
    local fails = (RetryFails[prompt] or 0) + 1
    RetryFails[prompt] = fails
    RetryAfter[prompt] = tick() + math.min(RETRY_BASE_DELAY * fails, RETRY_MAX_DELAY)
end

local function markPromptSucceeded(prompt)
    RetryFails[prompt] = nil
    RetryAfter[prompt] = nil
end

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
-- Dengan begitu value hewan lain di area yang sama tidak ikut terbaca.
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

-- aboveValue: hanya pet dengan value LEBIH TINGGI dari angka ini yang dianggap target
-- (dipakai untuk membandingkan dengan pet yang sedang dibawa). ignoreValueThreshold = true
-- melewati semua filter value dan memilih pet terdekat (untuk tombol test).
local function scanAnimalPrompts(ignoreValueThreshold, aboveValue)
    local zoneInfo = getZone1Info()
    if not zoneInfo then
        return nil, 0, 0, "-", 0, nil, false
    end

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
    local bestValue = 0

    -- Tahap 1: kumpulkan semua prompt carry di Zone1, lalu hitung ada berapa part prompt di dalam tiap ancestor
    local candidates = {}
    local partCount = {}
    local countedPart = {}
    local now = tick()
    local outsideZone, waitingRetry = 0, 0

    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("ProximityPrompt") and isValidAnimalPrompt(desc) then
            local isExcluded = false
            if carriedFolder and desc:IsDescendantOf(carriedFolder) then isExcluded = true end
            if rideFolder and desc:IsDescendantOf(rideFolder) then isExcluded = true end
            if Character and desc:IsDescendantOf(Character) then isExcluded = true end
            if RetryAfter[desc] and now < RetryAfter[desc] then
                isExcluded = true
                waitingRetry = waitingRetry + 1
            end

            if not isExcluded then
                local attachPart = getPromptPart(desc)
                if attachPart and not isInZone1(zoneInfo, attachPart) then
                    outsideZone = outsideZone + 1
                elseif attachPart then
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

    -- Tahap 2: baca value tiap pet hanya dari wadahnya sendiri, lalu pilih yang sesuai target
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

            local passes = ignoreValueThreshold
                or (val >= State.MinTargetNumber and val > (aboveValue or 0))

            if passes then
                local dist = RootPart and (RootPart.Position - attachPart.Position).Magnitude or 0
                local better
                if ignoreValueThreshold then
                    better = dist < bestDistance
                else
                    -- Pilih value tertinggi; jika sama, yang terdekat
                    better = val > bestValue or (val == bestValue and dist < bestDistance)
                end

                if better then
                    bestDistance = dist
                    bestValue = val
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

    return bestMatch, totalAnimalPrompts, highestSeenVal, highestSeenName, skippedDropped, highestSeenSource, true, outsideZone, waitingRetry
end

-- ==========================================
-- EKSEKUSI TELEPORT + TAHAN PROXIMITYPROMPT
-- ==========================================
local RELEASE_WAIT = 3            -- detik menunggu pet lepas setelah sampai di Safe Zone
local SWAP_RETRY_DELAY = 15       -- jeda (detik) sebelum mencoba menukar lagi jika gagal melepas pet
local HOLD_MARGIN = 0.6           -- tambahan waktu (detik) di atas HoldDuration prompt saat menahan

local function instantCFrame(targetCF)
    if not RootPart or not RootPart.Parent then return end
    RootPart.AssemblyLinearVelocity = Vector3.zero
    RootPart.AssemblyAngularVelocity = Vector3.zero
    RootPart.CFrame = targetCF
end

-- Teleport ke pet lalu tahan prompt-nya. Kembalikan pet yang berhasil dibawa (nil jika gagal).
-- Lama tahan diambil otomatis dari prompt (mis. 3 detik) ditambah HOLD_MARGIN, dan berhenti
-- lebih awal begitu pet sudah terbawa. Posisi dijaga di dekat pet selama menahan.
local function grabPrompt(targetData)
    local prompt = targetData.prompt
    local attachPart = targetData.part
    if not prompt or not prompt.Parent or not attachPart then return nil end

    local before = snapshotCarried()
    local grabPos = attachPart.CFrame * CFrame.new(0, State.OffsetY, 1.5)

    instantCFrame(grabPos)
    task.wait(0.3)
    if not prompt.Parent then return nil end

    local holdTime = (prompt.HoldDuration or 0) + HOLD_MARGIN

    -- Paksa aktifkan prompt walau game sempat menonaktifkannya (HoldDuration tidak diubah)
    prompt.Enabled = true
    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = 25

    pcall(function() prompt:InputHoldBegin() end)
    if fireproximityprompt then
        pcall(function() fireproximityprompt(prompt) end)
    end

    local animal = nil
    local startTime = tick()
    while (tick() - startTime) < holdTime do
        animal = findNewCarried(before)
        if animal then
            break
        end
        -- Pet target hilang / ditandai terlepas saat kita menahan tombol: berhenti
        if not prompt.Parent or isDroppedOrHit(prompt, attachPart, targetData.container) then
            break
        end

        prompt.Enabled = true
        instantCFrame(grabPos)
        task.wait(0.08)
    end

    if prompt.Parent then
        pcall(function() prompt:InputHoldEnd() end)
        if fireproximityprompt then
            pcall(function() fireproximityprompt(prompt) end)
        end
    end

    if not animal then
        task.wait(0.2)
        animal = findNewCarried(before)
    end
    return animal
end

-- Cari tombol "Drop" di layar (muncul saat membawa pet)
local function findDropButton()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return nil end

    for _, d in ipairs(playerGui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Visible then
            local text = d.Text:gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"):lower()
            if text == "drop" then
                local screen = d:FindFirstAncestorWhichIsA("ScreenGui")
                if not screen or screen.Enabled then
                    local btn = d:IsA("GuiButton") and d or d:FindFirstAncestorWhichIsA("GuiButton")
                    if btn then
                        return btn
                    end
                end
            end
        end
    end
    return nil
end

-- Tekan tombol Drop dengan memicu event klik-nya. True jika tombol ditemukan.
local function pressDropButton()
    local btn = findDropButton()
    if not btn then return false end

    for _, signalName in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up" }) do
        pcall(function()
            if getconnections then
                for _, conn in ipairs(getconnections(btn[signalName])) do
                    pcall(function() conn:Fire() end)
                end
            elseif firesignal then
                firesignal(btn[signalName])
            end
        end)
    end
    return true
end

-- Lepaskan pet yang sedang dibawa: bawa ke Safe Zone lalu tekan tombol Drop. True jika pet sudah lepas.
local function releaseCarried(returnCF)
    local carried = Carry.obj
    if not carried or not isStillCarried(carried) then
        clearCarry()
        return true
    end

    local safeCF = getSafeZoneCFrame()
    if not safeCF then
        notifyThrottled(
            "nosafezone",
            "Safe Zone Tidak Ditemukan",
            "Workspace > Build > ZoneHitboxes > SafeZone tidak ada. Pet akan di-drop di tempat sekarang."
        )
    end

    Carry.releasing = true
    local startTime = tick()
    local lastDrop = 0
    if safeCF then
        instantCFrame(safeCF)
    end

    while (tick() - startTime) < RELEASE_WAIT and isStillCarried(carried) do
        task.wait(0.15)
        if safeCF then
            instantCFrame(safeCF)
        end
        -- Beri jeda singkat agar posisi baru diterima server, lalu tekan Drop berulang
        if (tick() - startTime) > 0.4 and (tick() - lastDrop) > 0.6 then
            lastDrop = tick()
            pressDropButton()
        end
    end

    -- Beri waktu agar event "pet terlepas" selesai diproses sebelum flag dimatikan
    task.wait(0.2)
    Carry.releasing = false

    if isStillCarried(carried) then
        instantCFrame(returnCF)
        notifyThrottled(
            "releasefail",
            "Pet Tidak Lepas",
            "Pet masih dibawa setelah menekan Drop di Safe Zone. Penukaran ditunda sementara."
        )
        return false
    end

    clearCarry()
    return true
end

-- Carry pet target. Jika sedang membawa pet lain (yang value-nya lebih rendah), lepaskan dulu di Safe Zone.
-- Setelah selesai, karakter kembali ke tempat ia berdiri sebelum teleport (titik diam).
local function carryPet(match)
    local returnCF = RootPart.CFrame

    if Carry.obj and isStillCarried(Carry.obj) then
        if not releaseCarried(returnCF) then
            Carry.cooldownUntil = tick() + SWAP_RETRY_DELAY
            return false
        end
    end

    if not match.prompt or not match.prompt.Parent then
        instantCFrame(returnCF)
        return false
    end

    local pending = { name = match.name, value = match.value }
    Carry.pending = pending
    local animal = grabPrompt(match)
    task.delay(2, function()
        if Carry.pending == pending then
            Carry.pending = nil
        end
    end)

    instantCFrame(returnCF)

    if animal then
        Carry.obj = animal
        Carry.value = match.value
        Carry.name = match.name
        trackMyCarried(animal, match.name)
        return true
    end
    return false
end

-- ==========================================
-- PEMBUATAN MENU RAYFIELD UI
-- ==========================================
local Window = Rayfield:CreateWindow({
    Name = "Break & Steal an Egg | Hub",
    LoadingTitle = "Memuat Script...",
    LoadingSubtitle = "Lurkala Hub",
    ConfigurationSaving = {
        Enabled = false
    }
})

-- TAB 1: AUTO CARRY ZONE1
local MainTab = Window:CreateTab("Auto Carry", 4483362458)

local StatusParagraph = MainTab:CreateParagraph({
    Title = "Status Auto Carry",
    Content = "Memindai pet di Zone1..."
})

local ToggleAutoGrab = MainTab:CreateToggle({
    Name = "Aktifkan Auto Carry Zone1",
    CurrentValue = State.AutoGrab,
    Flag = "ToggleAutoGrab",
    Callback = function(Value)
        State.AutoGrab = Value
        saveConfig()
        if Value then
            Rayfield:Notify({
                Title = "Auto Carry Aktif",
                Content = "Menunggu pet >= " .. State.TargetValueRaw .. " di Zone1.",
                Duration = 3
            })
        end
    end
})

local InputTargetVal = MainTab:CreateInput({
    Name = "Target Minimal Value",
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

MainTab:CreateButton({
    Name = "Test Carry Pet Terdekat di Zone1 (Abaikan Value)",
    Callback = function()
        if isBusy then return end
        if Carry.obj and isStillCarried(Carry.obj) then
            Rayfield:Notify({
                Title = "Sedang Membawa Pet",
                Content = "Lepaskan pet yang dibawa sebelum melakukan test.",
                Duration = 3
            })
            return
        end

        local nearest = scanAnimalPrompts(true)
        if nearest then
            isBusy = true
            Rayfield:Notify({
                Title = "Menguji Carry Pet",
                Content = string.format("Target: %s ($%s/s)", tostring(nearest.name), formatShortNumber(nearest.value)),
                Duration = 2.5
            })
            task.spawn(function()
                pcall(carryPet, nearest)
                isBusy = false
            end)
        else
            Rayfield:Notify({
                Title = "Tidak Ditemukan",
                Content = "Belum ada pet dengan tombol carry di Zone1.",
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
        State.WebhookEnabled = true
        State.WebhookURL = ""
        State.PingText = ""

        pcall(function() ToggleAutoGrab:Set(false) end)
        pcall(function() InputTargetVal:Set("10B") end)
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
-- LOOP UTAMA: PINDAI ZONE1, CARRY / TUKAR PET, UPDATE STATUS UI
-- ==========================================
task.spawn(function()
    while task.wait(0.45) do
        if RootPart and RootPart.Parent then
            -- Sinkronkan status bawaan (misalnya pet terlepas karena terkena hit)
            if Carry.obj and not isStillCarried(Carry.obj) then
                clearCarry()
            end

            -- Hanya pet dengan value LEBIH TINGGI dari yang dibawa yang dianggap target
            keepZoneStreamed(getZone1Info())
            local match, totalPets, highestVal, highestName, skipped, highestSource, zoneFound, outsideZone, waitingRetry = scanAnimalPrompts(false, Carry.value)

            pcall(function()
                local carryText = Carry.obj
                    and string.format("%s ($%s/s)", tostring(Carry.name), formatShortNumber(Carry.value))
                    or "Tidak membawa pet"

                local zoneText = zoneFound
                    and string.format(
                        "Pet di Zone1: %d | Tertinggi: %s ($%s/s)",
                        totalPets,
                        tostring(highestName),
                        formatShortNumber(highestVal)
                    )
                    or "Zone1 tidak ditemukan (Workspace > Build > ZoneBuilds > Zone1)"

                StatusParagraph:Set({
                    Title = "Status Auto Carry (Zone1)",
                    Content = string.format(
                        "Dibawa: %s\nTarget Aktif: %s (%s)\n%s\nSumber value: %s\nSafe Zone: %s | Di-skip: %d\nDi luar Zone1: %d | Tunggu retry: %d",
                        carryText,
                        State.TargetValueRaw,
                        formatShortNumber(State.MinTargetNumber),
                        zoneText,
                        shortText(highestSource, 45),
                        getSafeZone() and "ditemukan" or "TIDAK ditemukan",
                        skipped,
                        outsideZone or 0,
                        waitingRetry or 0
                    )
                })
            end)

            -- Jika penukaran baru saja gagal, tunggu dulu sebelum mencoba lagi
            local swapBlocked = Carry.obj ~= nil and tick() < Carry.cooldownUntil

            if State.AutoGrab and not isBusy and match and not swapBlocked then
                isBusy = true

                Rayfield:Notify({
                    Title = Carry.obj and "Pet Lebih Bernilai Ditemukan!" or "Pet Target Ditemukan!",
                    Content = string.format("%s ($%s/s)\nSumber: %s", tostring(match.name), formatShortNumber(match.value), shortText(match.source, 50)),
                    Duration = 2.5
                })

                local okRun, result = pcall(carryPet, match)
                if not okRun then
                    warn("[AutoCarry] " .. tostring(result))
                end
                if okRun and result then
                    markPromptSucceeded(match.prompt)
                else
                    markPromptFailed(match.prompt)
                end

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
        Content = string.format("Target: %s | Webhook: %s",
            State.TargetValueRaw,
            (State.WebhookURL ~= "" and "Tersimpan" or "Kosong")
        ),
        Duration = 4
    })
end
