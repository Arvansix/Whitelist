local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Server")
local hitWallRemote = Remotes:WaitForChild("HitWall")
local clickRemote = Remotes:WaitForChild("Click")
local EventSell = Remotes:WaitForChild("SellLoot")
local EventSurface = Remotes:WaitForChild("GotoSurface")

-- Databases
local ItemsList = require(ReplicatedStorage:WaitForChild("Databases"):WaitForChild("ItemsList"))
local StagesList = nil
pcall(function() StagesList = require(ReplicatedStorage:WaitForChild("Databases"):WaitForChild("StagesList")) end)
local TotalStages = (StagesList and #StagesList) or 30

-- ==========================================
-- SISTEM REMOTE WHITELIST
-- ==========================================
local WhitelistUrl = "https://raw.githubusercontent.com/Arvansix/Whitelist/main/listku.txt"
local success, whitelistContent = pcall(function() return game:HttpGet(WhitelistUrl) end)

if not success or not whitelistContent then
    LocalPlayer:Kick("Gagal memuat data keamanan Whitelist. Periksa koneksi internetmu!")
    return
end

local isWhitelisted = false
for username in string.gmatch(whitelistContent, "[^\r\n]+") do
    username = username:gsub("^%s*(.-)%s*$", "%1")
    if username == LocalPlayer.Name then isWhitelisted = true break end
end

if not isWhitelisted then
    LocalPlayer:Kick("Akses Ditolak: Username kamu belum terdaftar dalam whitelist Arkala Nexus!")
    return
end

-- Anti AFK
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- ==========================================
-- VARIABEL GLOBAL
-- ==========================================
local AutoGiftActive, SelectedGiftItem, GiftAmount, TargetUSN, IsGiftingTick = false, "", 1, "", false
local GiftMode = "Nama Item"
local AutoSellActive, SelectedSellItem, SellAmountTarget, CurrentSellCount, SellMode, SelectedSellRarity = false, "All Items", 0, 0, "Nama Item", ""
local ScanIsRunning, PotatoModeActive = false, false

-- Variabel Farming & Collect
local AutoBreakActive, AutoCollectActive, AutoClickActive = false, false, false
local AutoCollectMode = "Nama Item"
local CurrentStage = 1
local IsReturningTick = false
local IsCollectingProcessRunning = false
local BlacklistedItems = {}
local BreakInterval = 0.05 
local ClickInterval = 0.12 

-- Sorting Data Item
local SelectedCollectItems = {}
local SelectedCollectRarities = {}

local SortedItems, AvailableRarities, rarityTracker = {}, {}, {}
for name, info in pairs(ItemsList) do 
    table.insert(SortedItems, info)
    local rarity = info.Rarity and tostring(info.Rarity) or "Unknown"
    if not rarityTracker[rarity] then rarityTracker[rarity] = true; table.insert(AvailableRarities, rarity) end
end
table.sort(SortedItems, function(a, b) return (a.Revenue or 0) > (b.Revenue or 0) end)
table.sort(AvailableRarities)

if #SortedItems > 0 then SelectedGiftItem = SortedItems[1].Name end
if #AvailableRarities > 0 then SelectedGiftRarity = AvailableRarities[1]; SelectedSellRarity = AvailableRarities[1] end

-- ==========================================
-- FUNGSI UTILITAS
-- ==========================================
local function YieldCheck(startTime)
    if os.clock() - startTime > 0.008 then task.wait(); return os.clock() end
    return startTime
end

local function DapatkanDaftarPlayer()
    local tbl = {}
    for _, p in pairs(Players:GetPlayers()) do if p ~= LocalPlayer then table.insert(tbl, p.Name) end end
    return tbl
end

local function DapatkanDaftarItem(includeAll)
    local tbl = includeAll and {"All Items"} or {}
    for _, item in pairs(SortedItems) do table.insert(tbl, item.Name) end
    return tbl
end

local function GetStagePosition(stageId)
    if StagesList and StagesList[stageId] and StagesList[stageId].Folder then
        local anchor = StagesList[stageId].Folder:FindFirstChild("Hitbox") or StagesList[stageId].Folder:FindFirstChildWhichIsA("BasePart")
        if anchor then return anchor.Position end
    end
    return nil
end

-- [OPTIMASI SUPER] Cache UI Tas agar tidak lag saat scan GUI tiap detik
local cachedBagUI = nil

local function DapatkanJumlahTasAsliGame()
    local currentBag = 0
    local maxBag = 20
    local foundUI = false

    -- 1. CEK CACHE DULU (Mencegah Lag CPU yang Parah)
    if cachedBagUI and cachedBagUI.Parent and cachedBagUI.Visible then
        local teks = cachedBagUI.Text
        if teks then
            local plainText = string.gsub(teks, "<[^>]+>", "")
            local c, m = string.match(plainText, "^%s*(%d+)%s*/%s*(%d+)%s*$")
            if c and m then
                return tonumber(c), tonumber(m)
            elseif string.find(string.lower(plainText), "full") then
                return maxBag, maxBag
            end
        end
    end

    -- 2. JIKA CACHE HILANG/KOSONG, BARU SCAN GUI (Lebih Hemat CPU)
    for _, gui in pairs(PlayerGui:GetDescendants()) do
        if (gui:IsA("TextLabel") or gui:IsA("TextBox")) and gui.Visible then
            local teks = gui.Text
            if teks and type(teks) == "string" and teks ~= "" then
                local plainText = string.gsub(teks, "<[^>]+>", "")
                local c, m = string.match(plainText, "^%s*(%d+)%s*/%s*(%d+)%s*$")
                
                if c and m then
                    local parsedCurrent = tonumber(c)
                    local parsedMax = tonumber(m)
                    if parsedMax > 0 and parsedMax <= 200 then
                        currentBag = parsedCurrent
                        maxBag = parsedMax
                        foundUI = true
                        cachedBagUI = gui -- Simpan ke Cache agar tidak usah scan lagi!
                        break 
                    end
                elseif string.find(string.lower(plainText), "inventory full") or string.find(string.lower(plainText), "backpack full") then
                    cachedBagUI = gui
                    return maxBag, maxBag 
                end
            end
        end
    end

    -- 3. CADANGAN: Hitung fisik item jika UI benar-benar tidak ada
    if not foundUI then
        local physicalCount = 0
        local function hitungLoot(parent)
            if not parent then return end
            for _, obj in pairs(parent:GetChildren()) do
                if obj:IsA("Tool") and ItemsList[obj.Name] then
                    physicalCount = physicalCount + 1
                end
            end
        end
        
        hitungLoot(LocalPlayer:FindFirstChild("Backpack"))
        if LocalPlayer.Character then hitungLoot(LocalPlayer.Character) end
        
        currentBag = physicalCount
    end
    
    return currentBag, maxBag
end

local function DapatkanIsiInventori()
    local itemCounts, totalItems = {}, 0
    local t = os.clock()
    local function hitungItem(parent)
        if not parent then return end
        for _, obj in pairs(parent:GetChildren()) do
            t = YieldCheck(t)
            if obj:IsA("Tool") and ItemsList[obj.Name] then
                itemCounts[obj.Name] = (itemCounts[obj.Name] or 0) + 1
                totalItems += 1
            end
        end
    end
    hitungItem(LocalPlayer:FindFirstChild("Backpack"))
    if LocalPlayer.Character then hitungItem(LocalPlayer.Character) end
    return itemCounts, totalItems
end

local function DapatkanNamaItem(prompt)
    local parent = prompt.Parent; if not parent then return nil, nil end
    if ItemsList[parent.Name] then return parent.Name, parent end
    local grandParent = parent.Parent; if grandParent and ItemsList[grandParent.Name] then return grandParent.Name, parent end
    return nil, nil
end

local function CariKarakterDanPromptTarget(username)
    if username == "" then return nil, nil end
    local targetPlayer = Players:FindFirstChild(username)
    local targetChar = targetPlayer and targetPlayer.Character
    local targetHrp = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
    if not targetHrp then return nil, nil end
    
    local foundPrompt = targetChar:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not foundPrompt then
        local t = os.clock()
        for _, obj in pairs(Workspace:GetDescendants()) do
            t = YieldCheck(t)
            if obj:IsA("ProximityPrompt") and obj.Parent and obj.Parent:IsA("BasePart") then
                if (obj.Parent.Position - targetHrp.Position).Magnitude < 12 then
                    foundPrompt = obj
                    break
                end
            end
        end
    end
    return foundPrompt, targetHrp
end

local function IsItemMatchForCollect(itemName, rarityStr)
    if AutoCollectMode == "Nama Item" then
        if itemName then
            for _, v in ipairs(SelectedCollectItems) do
                if string.lower(itemName) == string.lower(v) then 
                    return true 
                end
            end
        end
    elseif AutoCollectMode == "Berdasarkan Rarity" then
        if rarityStr then
            for _, v in ipairs(SelectedCollectRarities) do
                if tostring(rarityStr) == tostring(v) then 
                    return true 
                end
            end
        end
    end
    return false
end

-- ==========================================
-- UI RAYFIELD
-- ==========================================
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
local Window = Rayfield:CreateWindow({
   Name = "Arkala Nexus Hub",
   LoadingTitle = "Arkala Nexus",
   LoadingSubtitle = "Premium Edition",
   ConfigurationSaving = {Enabled = false},
   KeySystem = false
})

-- TAB SETTINGS (Diperbarui dengan Optimalisasi Ekstrem)
local SettingsTab = Window:CreateTab("Settings", 4483362458)
local LagStatusParagraph = SettingsTab:CreateParagraph({Title = "Performance", Content = "Atur visual untuk menghentikan lag/perangkat panas."})

SettingsTab:CreateButton({
    Name = "Aktifkan Extreme Potato Mode",
    Callback = function() 
        PotatoModeActive = true
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 9e9 -- Hilangkan kabut
        
        -- Hapus Langit dan Efek
        for _, v in pairs(Lighting:GetChildren()) do 
            if v:IsA("PostEffect") or v:IsA("Sky") or v:IsA("Atmosphere") then 
                v:Destroy() 
            end 
        end
        
        -- Matikan Bayangan Part & Partikel secara asinkron (Anti-Freeze)
        task.spawn(function()
            local t = os.clock()
            for _, obj in pairs(Workspace:GetDescendants()) do
                t = YieldCheck(t)
                if obj:IsA("BasePart") then 
                    obj.Material = Enum.Material.SmoothPlastic 
                    obj.CastShadow = false -- Matikan bayangan per part
                    obj.Reflectance = 0
                elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") then
                    obj.Enabled = false -- Matikan partikel (sangat ampuh)
                elseif obj:IsA("Decal") or obj:IsA("Texture") then
                    obj.Transparency = 1 -- Sembunyikan tekstur
                end
            end
        end)
        LagStatusParagraph:Set({Title = "Selesai", Content = "Extreme Potato Mode Aktif! GPU/RAM lebih lega."})
    end,
})

SettingsTab:CreateButton({
    Name = "Aktifkan Black Screen",
    Callback = function() 
        -- Membuat layar hitam agar GPU beristirahat saat AFK
        local blackScreen = Instance.new("ScreenGui")
        blackScreen.Name = "AFKSaver"
        blackScreen.IgnoreGuiInset = true
        blackScreen.ZIndexBehavior = Enum.ZIndexBehavior.Global
        
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 1, 0)
        frame.BackgroundColor3 = Color3.new(0, 0, 0)
        frame.ZIndex = 999999
        frame.Parent = blackScreen
        
        local text = Instance.new("TextLabel")
        text.Text = "Afk Mode Aktif\nKlik layar untuk menutup mode ini."
        text.Size = UDim2.new(1, 0, 1, 0)
        text.BackgroundTransparency = 1
        text.TextColor3 = Color3.new(1, 1, 1)
        text.TextSize = 25
        text.Font = Enum.Font.SourceSansBold
        text.Parent = frame
        
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 1, 0)
        btn.BackgroundTransparency = 1
        btn.Text = ""
        btn.Parent = frame
        
        btn.MouseButton1Click:Connect(function()
            blackScreen:Destroy()
        end)
        
        blackScreen.Parent = CoreGui
        LagStatusParagraph:Set({Title = "Selesai", Content = "Black Screen Aktif!"})
    end,
})

-- TAB SCANNER
local ScannerTab = Window:CreateTab("Scanner", 4483362458)
local ScanResultParagraph = ScannerTab:CreateParagraph({Title = "Inventori", Content = "Klik scan untuk memulai."})
ScannerTab:CreateButton({
    Name = "Scan Inventori",
    Callback = function()
        local counts, total = DapatkanIsiInventori()
        local content = total == 0 and "Tas kosong." or ""
        if total > 0 then
            for itemName, count in pairs(counts) do content = content .. "- " .. itemName .. " : " .. count .. "x\n" end
            content = content .. "\nTotal: " .. total
        end
        ScanResultParagraph:Set({Title = "Hasil (" .. total .. ")", Content = content})
    end,
})

-- TAB FARM
local FarmTab = Window:CreateTab("Auto Farm", 4483362458)

FarmTab:CreateToggle({
    Name = "Auto Break", CurrentValue = false,
    Callback = function(val) 
        AutoBreakActive = val 
        if not val then
            local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if hrp then hrp.Anchored = false end
        end
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Train", CurrentValue = false,
    Callback = function(val) AutoClickActive = val end,
})

FarmTab:CreateToggle({
    Name = "Auto Collect Items", CurrentValue = false,
    Callback = function(val) AutoCollectActive = val end,
})

FarmTab:CreateDropdown({
    Name = "Mode Collect", 
    Options = {"Nama Item", "Berdasarkan Rarity"}, 
    CurrentOption = "Nama Item", 
    MultipleOptions = false,
    Callback = function(Option) AutoCollectMode = Option[1] or "Nama Item" end,
})

FarmTab:CreateDropdown({
    Name = "Collect by Item Name (Multi-Select)", 
    Options = DapatkanDaftarItem(false),
    CurrentOption = {}, 
    MultipleOptions = true,
    Callback = function(Options) SelectedCollectItems = Options end,
})

FarmTab:CreateDropdown({
    Name = "Collect by Rarity (Multi-Select)", 
    Options = AvailableRarities, 
    CurrentOption = {}, 
    MultipleOptions = true,
    Callback = function(Options) SelectedCollectRarities = Options end,
})

-- TAB AUTO SELL
local SellTab = Window:CreateTab("Auto Sell", 4483362458)
local SellStatusParagraph = SellTab:CreateParagraph({Title = "Status", Content = "Siap"})

SellTab:CreateDropdown({Name = "Mode Sell", Options = {"Nama Item", "Berdasarkan Rarity"}, CurrentOption = "Nama Item", MultipleOptions = false, Callback = function(Option) SellMode = Option[1] or "Nama Item" end})
SellTab:CreateDropdown({Name = "Pilih Rarity Sell", Options = AvailableRarities, CurrentOption = SelectedSellRarity, MultipleOptions = false, Callback = function(Option) SelectedSellRarity = Option[1] or "" end})
SellTab:CreateDropdown({Name = "Item Dijual", Options = DapatkanDaftarItem(true), CurrentOption = "All Items", MultipleOptions = false, Callback = function(Option) SelectedSellItem = Option[1] or "All Items" end})
SellTab:CreateInput({Name = "Jumlah (0 = Semua)", PlaceholderText = "Ketik Jumlah", RemoveTextAfterFocusLost = false, Callback = function(Text) SellAmountTarget = tonumber(Text) and math.max(0, math.floor(tonumber(Text))) or 0 end})
getgenv().SellToggleStatus = SellTab:CreateToggle({
   Name = "Auto Sell", CurrentValue = false,
   Callback = function(Value)
      AutoSellActive = Value
      if Value then CurrentSellCount = 0; SellStatusParagraph:Set({Title = "ON", Content = "Menyiapkan antrean..."})
      else SellStatusParagraph:Set({Title = "OFF", Content = "Berhenti."}) end
   end,
})

-- TAB AUTO GIFT
local GiftTab = Window:CreateTab("Auto Gift", 4483362458)
local GiftStatusParagraph = GiftTab:CreateParagraph({Title = "Status", Content = "Pilih target"})
local PlayerDropdown = GiftTab:CreateDropdown({
   Name = "Target Player", Options = DapatkanDaftarPlayer(), CurrentOption = "", MultipleOptions = false,
   Callback = function(Option) TargetUSN = Option[1] or ""; GiftStatusParagraph:Set({Title = "Target", Content = TargetUSN}) end,
})
GiftTab:CreateButton({Name = "Refresh Players", Callback = function() PlayerDropdown:Refresh(DapatkanDaftarPlayer()) end})
GiftTab:CreateDropdown({
    Name = "Mode Gift", 
    Options = {"Nama Item", "Berdasarkan Rarity"}, 
    CurrentOption = GiftMode, 
    MultipleOptions = false, 
    Callback = function(Option) GiftMode = Option[1] or "Nama Item" end
})
GiftTab:CreateDropdown({Name = "Pilih Rarity", Options = AvailableRarities, CurrentOption = SelectedGiftRarity, MultipleOptions = false, Callback = function(Option) SelectedGiftRarity = Option[1] or "" end})
GiftTab:CreateDropdown({Name = "Pilih Item", Options = DapatkanDaftarItem(false), CurrentOption = SelectedGiftItem, MultipleOptions = false, Callback = function(Option) SelectedGiftItem = Option[1] or "" end})
GiftTab:CreateInput({Name = "Jumlah", PlaceholderText = "Ketik Jumlah", RemoveTextAfterFocusLost = false, Callback = function(Text) GiftAmount = tonumber(Text) and math.floor(tonumber(Text)) or 1 end})
getgenv().GiftToggleStatus = GiftTab:CreateToggle({
   Name = "Auto Gift", CurrentValue = false,
   Callback = function(Value)
      if Value and TargetUSN == "" then
         Rayfield:Notify({Title = "Error", Content = "Lengkapi target player!", Duration = 3})
         getgenv().GiftToggleStatus:Set(false)
         return
      end
      AutoGiftActive = Value
   end,
})
Players.PlayerAdded:Connect(function() PlayerDropdown:Refresh(DapatkanDaftarPlayer()) end)
Players.PlayerRemoving:Connect(function() PlayerDropdown:Refresh(DapatkanDaftarPlayer()) end)

-- ==========================================
-- AUTO SELL LOGIC
-- ==========================================
local function IsValidUUID(str)
    return type(str) == "string" and #str == 36 and string.match(str, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
end

local function PindaiDanJualItemTas(SellStatusParagraph)
    if not AutoSellActive or ScanIsRunning then return end
    ScanIsRunning = true 
    local uuidsUntukDijual, t = {}, os.clock()
    
    -- [PERBAIKAN] Logika Pencocokan Exact Match (Anti Jual Salah Rarity)
    local function isItemMatch(exactName)
        if not exactName then return false end
        
        if SellMode == "Nama Item" then
            if SelectedSellItem == "All Items" then return true end
            -- Pencocokan nama item persis 100%
            return string.lower(exactName) == string.lower(SelectedSellItem)
        else
            -- Pencocokan Rarity yang sangat aman! 
            -- Hanya cek rarity jika nama itemnya BENAR-BENAR TERDAFTAR persis di database.
            local dbInfo = ItemsList[exactName]
            if dbInfo then
                return tostring(dbInfo.Rarity) == SelectedSellRarity
            end
            return false
        end
    end

    for _, child in pairs(LocalPlayer:GetChildren()) do
        if child:IsA("Folder") or child:IsA("Configuration") then
            for _, val in ipairs(child:GetDescendants()) do
                t = YieldCheck(t)
                if val:IsA("StringValue") and IsValidUUID(val.Value) then
                    
                    -- [PERBAIKAN] Jangan digabung string-nya! 
                    -- Cek masing-masing apakah 'nama value' atau 'nama parent' adalah item yang valid di database.
                    local match = false
                    if ItemsList[val.Name] and isItemMatch(val.Name) then
                        match = true
                    elseif val.Parent and ItemsList[val.Parent.Name] and isItemMatch(val.Parent.Name) then
                        match = true
                    end
                    
                    if match then table.insert(uuidsUntukDijual, val.Value) end
                end
            end
        end
    end
    
    local physicalItems = {}
    if LocalPlayer:FindFirstChild("Backpack") then for _, obj in pairs(LocalPlayer.Backpack:GetChildren()) do if obj:IsA("Tool") then table.insert(physicalItems, obj) end end end
    if LocalPlayer.Character then for _, obj in pairs(LocalPlayer.Character:GetChildren()) do if obj:IsA("Tool") then table.insert(physicalItems, obj) end end end
    
    for _, item in pairs(physicalItems) do
        -- Karena physical item pasti namanya akurat, langsung cek!
        if isItemMatch(item.Name) then
            for _, subObj in pairs(item:GetDescendants()) do
                t = YieldCheck(t)
                if subObj:IsA("StringValue") and IsValidUUID(subObj.Value) then table.insert(uuidsUntukDijual, subObj.Value) end
            end
            for _, value in pairs(item:GetAttributes()) do
                if IsValidUUID(value) then table.insert(uuidsUntukDijual, value) end
            end
        end
    end

    if #uuidsUntukDijual == 0 then
        AutoSellActive = false
        if getgenv().SellToggleStatus then getgenv().SellToggleStatus:Set(false) end
        SellStatusParagraph:Set({Title = "OFF", Content = "Item habis / tidak ada yang cocok."})
        ScanIsRunning = false
        return
    end

    local batchCount = 0
    for _, uuid in pairs(uuidsUntukDijual) do
        if not AutoSellActive then break end 
        if SellAmountTarget > 0 and CurrentSellCount >= SellAmountTarget then
            AutoSellActive = false
            if getgenv().SellToggleStatus then getgenv().SellToggleStatus:Set(false) end
            SellStatusParagraph:Set({Title = "Selesai", Content = "Target tercapai!"})
            break
        end
        task.spawn(function() pcall(function() EventSell:FireServer(uuid) end) end)
        CurrentSellCount += 1; batchCount += 1
        if batchCount >= 10 then batchCount = 0; task.wait(0.05) end
    end
    ScanIsRunning = false 
end

task.spawn(function()
    while true do 
        task.wait(1.5)
        if AutoSellActive and not IsGiftingTick then pcall(PindaiDanJualItemTas, SellStatusParagraph) end
    end
end)

-- ==============================================================
-- LOGIKA AUTO TRAIN (AUTO CLICKER)
-- ==============================================================
task.spawn(function()
    while true do
        task.wait(ClickInterval)
        if AutoClickActive and not IsGiftingTick and not IsReturningTick then
            pcall(function() clickRemote:FireServer() end)
        end
    end
end)

-- ==============================================================
-- CORE INDEPENDEN: AUTO SURFACE Cepat (TAS PENUH)
-- ==============================================================
task.spawn(function()
    while true do
        task.wait(1)
        if not IsGiftingTick and not IsReturningTick and (AutoBreakActive or AutoCollectActive) then
            local currentTas, maxTas = DapatkanJumlahTasAsliGame()
            if currentTas >= maxTas and maxTas > 0 then
                IsReturningTick = true
                local char = LocalPlayer.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then hrp.Anchored = false end
                
                -- Teleport ke permukaan
                pcall(function() EventSurface:FireServer() end)
                CurrentStage = 1 
                
                task.wait(0.5) 
                
                -- Cek tas dengan interval sangat cepat
                local safetyTimeout = 0
                while safetyTimeout < 30 do -- Sekitar 6 detik maksimal
                    local cekTas, _ = DapatkanJumlahTasAsliGame()
                    if cekTas < maxTas then break end
                    task.wait(0.2) 
                    safetyTimeout = safetyTimeout + 1
                end
                
                IsReturningTick = false
            end
        end
    end
end)

-- ==============================================================
-- FUNGSI COLLECT (Hybrid Cache: 0% Lag & 100% Akurat)
-- ==============================================================
local activePrompts = {} -- Hanya menyimpan memori prompt mentah

-- Deteksi prompt yang baru muncul tanpa mengecek namanya dulu
local function OnDescendantAdded(obj)
    if obj:IsA("ProximityPrompt") then
        activePrompts[obj] = true
    end
end

-- Deteksi jika item sudah diambil/hilang
local function OnDescendantRemoving(obj)
    if activePrompts[obj] then
        activePrompts[obj] = nil
    end
end

-- Scan awal (1x saja)
task.spawn(function()
    local t = os.clock()
    for _, obj in pairs(Workspace:GetDescendants()) do
        t = YieldCheck(t)
        OnDescendantAdded(obj)
    end
end)

Workspace.DescendantAdded:Connect(OnDescendantAdded)
Workspace.DescendantRemoving:Connect(OnDescendantRemoving)

local function JalankanAutoCollectGlobal()
    if IsCollectingProcessRunning then return end
    if not AutoCollectActive or IsGiftingTick or IsReturningTick then return end
    
    local modeValid = false
    if AutoCollectMode == "Nama Item" and #SelectedCollectItems > 0 then modeValid = true end
    if AutoCollectMode == "Berdasarkan Rarity" and #SelectedCollectRarities > 0 then modeValid = true end
    if not modeValid then return end
    
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    IsCollectingProcessRunning = true
    local charPos = hrp.Position
    
    local adaItemYangDisedot = false
    local targetTeleport = nil
    local jarakTeleportTerdekat = math.huge
    local microDelay = 0

    -- [REAL-TIME SCAN] Baca langsung dari memori tanpa GetDescendants!
    for prompt, _ in pairs(activePrompts) do
        if prompt and prompt.Parent and not BlacklistedItems[prompt] then
            -- Pengecekan nama dilakukan secara real-time di sini!
            local namaItem, parentPart = DapatkanNamaItem(prompt)
            
            if namaItem and parentPart then
                local rarityStr = ItemsList[namaItem] and tostring(ItemsList[namaItem].Rarity or "Unknown")
                
                if IsItemMatchForCollect(namaItem, rarityStr) then
                    local delta = parentPart.Position - charPos
                    
                    -- Filter Bawah (Anti tembus stage)
                    local stageData = StagesList and StagesList[CurrentStage]
                    local stageBelumHancur = false
                    if stageData and stageData.Stages then
                        for _, wallData in pairs(stageData.Stages) do
                            if wallData and wallData.Wall and wallData.Wall.Parent and wallData.Wall.Transparency < 1 then
                                stageBelumHancur = true break
                            end
                        end
                    end
                    if delta.Y < -12 and stageBelumHancur then continue end
                    
                    local distToChar = delta.Magnitude
                    
                    -- LOGIKA STAGGERED VACUUM
                    if distToChar < 12 then
                        adaItemYangDisedot = true
                        BlacklistedItems[prompt] = true
                        
                        task.delay(microDelay, function()
                            if prompt and prompt.Parent then
                                pcall(function() fireproximityprompt(prompt) end)
                            end
                            task.delay(0.3, function() if prompt then BlacklistedItems[prompt] = nil end end)
                        end)
                        
                        microDelay = microDelay + 0.03 -- Jeda jaringan anti-kick
                    else
                        if distToChar < jarakTeleportTerdekat then
                            jarakTeleportTerdekat = distToChar
                            targetTeleport = {prompt = prompt, part = parentPart}
                        end
                    end
                end
            end
        end
    end

    -- TELEPORT JIKA TIDAK ADA YANG DEKAT
    if not adaItemYangDisedot and targetTeleport then
        local targetPrompt = targetTeleport.prompt
        
        BlacklistedItems[targetPrompt] = true
        local savedCFrame = hrp.CFrame
        local wasAnchored = hrp.Anchored
        
        hrp.Anchored = true 
        hrp.CFrame = targetTeleport.part.CFrame * CFrame.new(0, 1.5, 0)
        task.wait(0.05) 
        
        pcall(function() fireproximityprompt(targetPrompt) end)
        task.wait(0.05) 
        
        hrp.CFrame = savedCFrame
        hrp.Anchored = wasAnchored
        
        task.delay(0.3, function() if targetPrompt then BlacklistedItems[targetPrompt] = nil end end)
    end
    
    IsCollectingProcessRunning = false
end

-- [GANTI JUGA LOOP PEMANGGIL INI DI BAWAH FUNGSINYA]
task.spawn(function()
    while true do
        task.wait(0.05) -- Dipercepat drastis! (dari 0.25 jadi 0.05 detik)
        if AutoCollectActive and not IsGiftingTick and not IsReturningTick then
            JalankanAutoCollectGlobal()
        end
    end
end)

-- ==============================================================
-- AUTO STAGE & BREAK (Otomatis Turun & Menunggu di Ruang Terakhir)
-- ==============================================================
task.spawn(function()
    while true do
        task.wait(BreakInterval)
        
        if AutoBreakActive and not IsGiftingTick and not ScanIsRunning and not IsReturningTick and not IsCollectingProcessRunning then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            
            if hrp then
                local maxT = TotalStages or 30
                if CurrentStage > maxT then CurrentStage = 1 end
                
                local stageData = StagesList and StagesList[CurrentStage]
                local stagePos = GetStagePosition(CurrentStage)
                
                if not stageData or not stagePos then
                    if CurrentStage < maxT then
                        CurrentStage = CurrentStage + 1
                    end
                    continue
                end

                local adaDindingValid = false
                local stageHancur = true
                
                for wallId = 1, 3 do
                    local wallData = stageData.Stages and stageData.Stages[wallId]
                    if wallData and wallData.Wall and wallData.Wall.Parent then
                        adaDindingValid = true
                        if wallData.Wall.Transparency < 1 then
                            stageHancur = false
                            break 
                        end
                    end
                end
                
                if stageHancur or not adaDindingValid then
                    if CurrentStage < maxT then
                        CurrentStage = CurrentStage + 1
                    else
                        hrp.Anchored = false
                    end
                else
                    hrp.Anchored = true
                    hrp.CFrame = CFrame.new(stagePos + Vector3.new(0, 7, 0)) * hrp.CFrame.Rotation
                    
                    for wallId = 1, 3 do
                        local wallData = stageData.Stages and stageData.Stages[wallId]
                        if wallData and wallData.Wall and wallData.Wall.Parent then
                            if wallData.Wall.Transparency < 1 then
                                pcall(function() hitWallRemote:FireServer(CurrentStage, wallId) end)
                                break 
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ==============================================================
-- LOGIKA AUTO GIFT (Anti-Stuck & Timeout)
-- ==============================================================
task.spawn(function()
    while task.wait(0.2) do
        if not AutoGiftActive or IsGiftingTick then continue end
        
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum then continue end

        local promptGift, partTarget = CariKarakterDanPromptTarget(TargetUSN)
        if partTarget then
            IsGiftingTick = true
            local asalPosisi = hrp.CFrame
            GiftStatusParagraph:Set({Title = "Mencari...", Content = "Teleportasi ke " .. TargetUSN})
            
            task.spawn(function()
                hrp.CFrame = partTarget.CFrame * CFrame.new(0, 1.2, -3)
                task.wait(0.3)
                
                local giftsSent = 0
                for k = 1, GiftAmount do
                    if not AutoGiftActive or not partTarget or not partTarget.Parent then break end
                    
                    local targetTool = nil
                    if GiftMode == "Nama Item" then
                        targetTool = LocalPlayer:FindFirstChild("Backpack") and LocalPlayer.Backpack:FindFirstChild(SelectedGiftItem) or char:FindFirstChild(SelectedGiftItem)
                    else
                        local function findByRarity(parent)
                            if not parent then return nil end
                            for _, obj in pairs(parent:GetChildren()) do
                                if obj:IsA("Tool") then
                                    local info = ItemsList[obj.Name]
                                    if info and tostring(info.Rarity) == SelectedGiftRarity then
                                        return obj
                                    end
                                end
                            end
                            return nil
                        end
                        targetTool = findByRarity(char) or findByRarity(LocalPlayer:FindFirstChild("Backpack"))
                    end
                    
                    if targetTool then
                        hum:EquipTool(targetTool)
                        local equipWait = os.clock()
                        while targetTool.Parent ~= char and os.clock() - equipWait < 1.5 do
                            task.wait(0.05)
                        end
                        
                        if targetTool.Parent == char then
                            local function triggerPrompt()
                                if promptGift then
                                    pcall(fireproximityprompt, promptGift)
                                else
                                    pcall(function()
                                        for _, p in pairs(partTarget.Parent:GetDescendants()) do
                                            if p:IsA("ProximityPrompt") then fireproximityprompt(p) end
                                        end
                                    end)
                                end
                            end
                            triggerPrompt()
                            
                            local confirmWait = os.clock()
                            while targetTool.Parent == char and os.clock() - confirmWait < 1.5 do
                                task.wait(0.1)
                                triggerPrompt() 
                            end
                            
                            if targetTool.Parent ~= char then
                                giftsSent += 1
                            else
                                hum:UnequipTools() 
                            end
                        end
                    else
                        GiftStatusParagraph:Set({Title = "Gagal", Content = "Item habis!"})
                        break
                    end
                end
                
                GiftStatusParagraph:Set({Title = giftsSent > 0 and "Berhasil" or "Gagal", Content = "Terkirim: " .. giftsSent})
                task.wait(0.2) 
                if hrp then hrp.CFrame = asalPosisi end 
                task.wait(0.6) 
                
                AutoGiftActive = false
                if getgenv().GiftToggleStatus then getgenv().GiftToggleStatus:Set(false) end
                
                task.wait(0.2) 
                IsGiftingTick = false
            end)
        else
            GiftStatusParagraph:Set({Title = "Error", Content = "Player tidak ditemukan!"})
            AutoGiftActive = false
            if getgenv().GiftToggleStatus then getgenv().GiftToggleStatus:Set(false) end
        end
    end
end)
