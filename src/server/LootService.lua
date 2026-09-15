-- Добыча: предметы на земле, подбор, использование, выбрасывание, передача, сейфы.
-- Память чанков: ключи добычи (World: IsLootTaken / MarkLootTaken), чтобы не фармить выгрузкой.
-- v4: подобранное кладётся в хотбар и сразу берётся в руки (PlayerData.SetActive); модели предметов
-- на земле — shared/ItemModels.MakeDisplay, если модуль есть (иначе прежний вид).
-- v5: подобравшему — событие PickupFx; предметы grab (колёса, стены) — физические объекты для переноса
-- мышью (S.Grab), в инвентарь не кладутся (Loot.IsGrabItem, Loot.SpawnGrabNear).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Items)
local WeaponDefs = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local Classes = require(Shared.Classes)
local Recipes = require(Shared.Recipes)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Loot = {}
local S
local PD
local rng = Random.new()
local lastGive = {}

local WHITE = Color3.new(1, 1, 1)
local GREY = Color3.fromRGB(200, 200, 200)
local GREEN = Color3.fromRGB(120, 230, 120)
local RED = Color3.fromRGB(255, 110, 100)

local GIVE_DISTANCE = 16

-- Модели предметов (shared/ItemModels.lua): если модуля нет или он падает — прежний вид
local ItemModels = nil
do
	local module = Shared:FindFirstChild("ItemModels")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			ItemModels = result
		else
			warn("[Loot] ItemModels не загрузился: " .. tostring(result))
		end
	end
end

local displayWarned = false
-- Модель предмета на земле из ItemModels -> model, основная деталь (или nil)
local function displayModel(itemId, cf)
	local make = ItemModels and ItemModels.MakeDisplay
	if type(make) ~= "function" then
		return nil
	end
	local ok, model = pcall(make, itemId, cf)
	if not ok then
		if not displayWarned then
			displayWarned = true
			warn("[Loot] ItemModels.MakeDisplay(" .. tostring(itemId) .. "): " .. tostring(model))
		end
		return nil
	end
	if typeof(model) ~= "Instance" then
		return nil
	end
	if not model:IsA("Model") then
		model:Destroy()
		return nil
	end
	local body = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not body then
		model:Destroy()
		return nil
	end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
		end
	end
	model.PrimaryPart = body
	return model, body
end

local function lootLabel(item, amount)
	local rarity = Items.Rarities[item.rarity] or Items.Rarities.common
	return item.name .. (amount > 1 and (" x" .. amount) or "") .. " • " .. rarity.name
end

local function isTaken(key)
	if type(key) ~= "string" or type(S.World.IsLootTaken) ~= "function" then
		return false
	end
	return S.World.IsLootTaken(key) == true
end

local function markTaken(key)
	if type(key) == "string" and type(S.World.MarkLootTaken) == "function" then
		S.World.MarkLootTaken(key)
	end
end

local function lootFolder()
	return workspace:FindFirstChild("Loot")
end

-- Сдержанное оформление добычи (v3): тонкая тёмная «подложка» на земле и слабый свет только у редких
-- предметов. Никаких неоновых колец и Highlight (лимит 31 на клиент).
local function rarityStyle(model, cf, rarity, lightPart)
	local base = Util.Part({
		Name = "Base",
		Shape = "Cylinder",
		Size = Vector3.new(0.05, 2, 2),
		CFrame = CFrame.new(cf.Position + Vector3.new(0, 0.03, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(22, 22, 22),
		Material = Enum.Material.SmoothPlastic,
		Transparency = 0.45,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = model,
	})
	if rarity.order >= 3 then
		local light = Instance.new("PointLight")
		light.Name = "RarityLight"
		light.Color = rarity.color
		light.Range = 4 + rarity.order
		light.Brightness = 0.35
		light.Shadows = false
		light.Parent = (lightPart and lightPart:IsA("BasePart")) and lightPart or base
	end
	return base
end

local function decoPart(model, props)
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	props.Parent = model
	return Util.Part(props)
end

-- Колесо автобуса лежит на земле плашмя: шина + диск. Возвращает основную деталь (для подсказки)
local function wheelModel(model, cf)
	local center = cf * CFrame.new(0, 0.65, 0) * CFrame.Angles(0, 0, math.rad(90))
	local tire = decoPart(model, {
		Name = "Body",
		Shape = "Cylinder",
		Size = Vector3.new(1.2, 3.6, 3.6),
		CFrame = center,
		Color = Color3.fromRGB(26, 26, 26),
		Material = Enum.Material.Rubber,
	})
	decoPart(model, {
		Name = "Rim",
		Shape = "Cylinder",
		Size = Vector3.new(1.3, 1.9, 1.9),
		CFrame = center,
		Color = Color3.fromRGB(104, 98, 90),
		Material = Enum.Material.CorrodedMetal,
	})
	decoPart(model, {
		Name = "Cap",
		Shape = "Cylinder",
		Size = Vector3.new(1.4, 0.7, 0.7),
		CFrame = center,
		Color = Color3.fromRGB(40, 38, 36),
		Material = Enum.Material.Metal,
	})
	return tire
end

-- Кучка угля: число кусков зависит от количества пачек
local function coalModel(model, cf, packs)
	local body = nil
	local n = math.clamp(2 + (packs or 1), 3, 6)
	for i = 1, n do
		local a = (i / n) * math.pi * 2
		local r = i == 1 and 0 or 0.55
		local lump = decoPart(model, {
			Name = i == 1 and "Body" or "Lump",
			Size = Vector3.new(0.8, 0.55, 0.7) * (i == 1 and 1.2 or 1),
			CFrame = cf * CFrame.new(math.cos(a) * r, 0.35 + (i == 1 and 0.1 or 0), math.sin(a) * r) * CFrame.Angles(0.3 * i, a, 0.2),
			Color = Color3.fromRGB(32, 32, 34),
			Material = Enum.Material.Slate,
		})
		body = body or lump
	end
	return body
end

local function addPrompt(part, action, object, model)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootPrompt"
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		Loot.Pickup(player, model)
	end)
	return prompt
end

-- Точка на земле перед игроком: CFrame (смотрит туда же, куда игрок) и деталь-поверхность
function Loot.GroundCFrame(player, forward)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, nil
	end
	local look = Util.Flat(root.CFrame.LookVector)
	if look.Magnitude < 0.01 then
		look = Vector3.new(0, 0, -1)
	end
	look = look.Unit
	local exclude = { char }
	for _, name in ipairs({ "Zombies", "Loot", "Effects", "Placeables" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character and plr.Character ~= char then
			table.insert(exclude, plr.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local base = root.Position + look * (forward or 3)
	local result = workspace:Raycast(base + Vector3.new(0, 2.5, 0), Vector3.new(0, -12, 0), params)
	local y = result and result.Position.Y or (root.Position.Y - 3)
	local pos = Vector3.new(base.X, y, base.Z)
	return CFrame.lookAt(pos, pos + look), result and result.Instance or nil
end

-- Если добыча лежит на движущейся детали (пол автобуса), приварить её, чтобы ехала вместе
function Loot.AttachToSurface(model, part)
	if typeof(model) ~= "Instance" or typeof(part) ~= "Instance" or not part:IsA("BasePart") or part.Anchored then
		return
	end
	-- переносимый объект не приваривается: его берут мышью (S.Grab)
	if model:GetAttribute("Grab") then
		return
	end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.Massless = true
			p.CanCollide = false
			-- сварка хранится внутри детали добычи и исчезает вместе с ней
			Util.Weld(p, part)
		end
	end
end

local function itemModel(itemId, packs, amount, cf, parent, key)
	local item = Items.List[itemId]
	if not item or typeof(cf) ~= "CFrame" then
		return nil
	end
	local rarity = Items.Rarities[item.rarity] or Items.Rarities.common
	local model, body = displayModel(itemId, cf)
	if not model then
		model = Instance.new("Model")
		local size = item.size or Vector3.new(1, 1, 1)
		if itemId == "bus_wheel" then
			body = wheelModel(model, cf)
		elseif itemId == "coal" then
			body = coalModel(model, cf, packs)
		else
			body = Util.Part({
				Name = "Body",
				Size = size,
				Color = item.color,
				Material = item.material or Enum.Material.SmoothPlastic,
				CFrame = cf * CFrame.new(0, size.Y / 2 + 0.1, 0),
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				Parent = model,
			})
			if item.shape == "Cylinder" then
				body.Shape = Enum.PartType.Cylinder
				body.Size = Vector3.new(size.Y, size.X, size.Z)
				body.CFrame = cf * CFrame.new(0, size.Y / 2 + 0.1, 0) * CFrame.Angles(0, 0, math.rad(90))
			elseif item.shape == "Ball" then
				body.Shape = Enum.PartType.Ball
			end
		end
	end
	model.Name = "Loot_" .. itemId
	rarityStyle(model, cf, rarity, body)
	addPrompt(body, "Подобрать", lootLabel(item, amount), model)
	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("Count", packs)
	model:SetAttribute("Amount", amount)
	if type(key) == "string" then
		model:SetAttribute("LootKey", key)
	end
	model.PrimaryPart = body
	model.Parent = parent or lootFolder()
	return model
end

-- Переносимые объекты (v5, SPEC 2.7/2.8) ------------------------------------------------------------
-- Предмет с grab = true (колёса, стены автобуса) в инвентарь не кладётся: он лежит в мире физическим
-- объектом (S.Grab.MakeGrabbable), его берут мышью и прикрепляют к автобусу; подсказки «Подобрать» нет.
-- Без сервиса переноса такие предметы остаются обычной добычей, как раньше.

local MAX_GRAB_SPAWN = 8 -- объектов за один вызов

local function grabMaker()
	local grab = S and S.Grab
	local make = type(grab) == "table" and grab.MakeGrabbable or nil
	return type(make) == "function" and make or nil
end

-- Предмет переносится мышью (объект в мире), а не хранится в слотах
function Loot.IsGrabItem(itemId)
	local item = type(itemId) == "string" and Items.List[itemId] or nil
	return item ~= nil and item.grab == true and grabMaker() ~= nil
end

-- Модель переносимого объекта: ItemModels.MakeDisplay, иначе прежний вид. Все детали сварены с основной
-- (закрепление снимает MakeGrabbable), видны лучу наведения и сталкиваются с миром
local function grabModel(itemId, item, cf)
	local model, body = nil, nil
	local make = ItemModels and ItemModels.MakeDisplay
	if type(make) == "function" then
		local ok, result = pcall(make, itemId, cf)
		if ok and typeof(result) == "Instance" then
			body = result:IsA("Model") and (result.PrimaryPart or result:FindFirstChildWhichIsA("BasePart", true)) or nil
			if body then
				model = result
			else
				result:Destroy()
			end
		elseif not ok and not displayWarned then
			displayWarned = true
			warn("[Loot] ItemModels.MakeDisplay(" .. tostring(itemId) .. "): " .. tostring(result))
		end
	end
	if not model then
		model = Instance.new("Model")
		if itemId == "bus_wheel" then
			body = wheelModel(model, cf)
		else
			local size = item.size or Vector3.new(1, 1, 1)
			body = Util.Part({
				Name = "Body",
				Size = size,
				Color = item.color,
				Material = item.material or Enum.Material.SmoothPlastic,
				CFrame = cf * CFrame.new(0, size.Y / 2 + 0.1, 0),
				Parent = model,
			})
		end
	end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.CanCollide = true
			p.CanQuery = true
			p.CanTouch = false
			if p ~= body and not p:FindFirstChildWhichIsA("WeldConstraint") then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = body
				weld.Part1 = p
				weld.Parent = p
			end
		end
	end
	model.PrimaryPart = body
	return model
end

local grabWarned = false
-- Один переносимый объект на земле (cf — точка на земле). -> model или nil
local function spawnGrab(itemId, item, cf, key, dropped)
	local make = grabMaker()
	if not make then
		return nil
	end
	local model = grabModel(itemId, item, cf * CFrame.new(0, 0.15, 0))
	model.Name = "Loot_" .. itemId
	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("Count", 1)
	model:SetAttribute("Amount", 1)
	model:SetAttribute("Grab", true)
	if dropped then
		model:SetAttribute("Dropped", true)
	end
	-- всегда в общей папке добычи: объект уносят далеко, и он не должен пропасть с выгрузкой чанка;
	-- поэтому место из памяти чанка сразу считается взятым (иначе при возврате к чанку появится копия)
	model.Parent = lootFolder() or workspace
	markTaken(key)
	local ok, err = pcall(make, model, itemId, item.name)
	if not ok and not grabWarned then
		grabWarned = true
		warn("[Loot] Grab.MakeGrabbable(" .. tostring(itemId) .. "): " .. tostring(err))
	end
	return model
end

-- Переносимый объект рядом с игроком (покупка, крафт, выдача): n штук на земле перед ним.
-- -> первая модель или nil (предмет не переносимый, нет персонажа)
function Loot.SpawnGrabNear(player, itemId, n)
	if not Loot.IsGrabItem(itemId) then
		return nil
	end
	local cf = Loot.GroundCFrame(player, 3.5)
	if not cf then
		return nil
	end
	local count = tonumber(n) or 1
	if count ~= count then
		count = 1
	end
	return Loot.SpawnItem(itemId, 1, cf, nil, nil, { amount = math.clamp(math.floor(count), 1, MAX_GRAB_SPAWN), dropped = true })
end

-- count — число пачек (для патронов в пачке item.pack штук).
-- opts (необязательно): amount — точное число штук (вместо count * pack), dropped — выброшено игроком.
-- Переносимый предмет (grab) — отдельный физический объект на каждую штуку (не больше MAX_GRAB_SPAWN).
function Loot.SpawnItem(itemId, count, cf, parent, key, opts)
	local item = Items.List[itemId]
	if not item or isTaken(key) then
		return nil
	end
	count = tonumber(count) or 1
	if count ~= count or count == math.huge then
		count = 1
	end
	count = math.max(1, math.floor(count))
	local amount = count * (item.pack or 1)
	opts = type(opts) == "table" and opts or nil
	local exact = opts and tonumber(opts.amount)
	if exact and exact == exact and exact >= 1 and exact < math.huge then
		amount = math.floor(exact)
		count = math.max(1, math.floor(amount / (item.pack or 1)))
	end
	if item.grab and grabMaker() then
		if typeof(cf) ~= "CFrame" then
			return nil
		end
		local n = math.clamp(amount, 1, MAX_GRAB_SPAWN)
		local first = nil
		for i = 1, n do
			local spot = cf * CFrame.new((i - (n + 1) / 2) * 3, 0, 0)
			local model = spawnGrab(itemId, item, spot, i == 1 and key or nil, opts ~= nil and opts.dropped == true)
			first = first or model
		end
		return first
	end
	local model = itemModel(itemId, count, amount, cf, parent, key)
	if model and opts and opts.dropped then
		-- выброшенное не засчитывается целям «собрать» при повторном подборе
		model:SetAttribute("Dropped", true)
	end
	return model
end

-- opts: level, mag, dropped (выброшено игроком), key (память чанка)
function Loot.SpawnWeapon(weaponId, cf, parent, opts)
	local def = WeaponDefs.List[weaponId]
	if not def or typeof(cf) ~= "CFrame" then
		return nil
	end
	opts = type(opts) == "table" and opts or {}
	if isTaken(opts.key) then
		return nil
	end
	local level = math.clamp(math.floor(tonumber(opts.level) or 0), 0, Recipes.WeaponMaxLevel)
	local rarity = Items.Rarities[def.rarity] or Items.Rarities.common
	local display = WeaponModels.MakeDisplay(weaponId, cf * CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.rad(90)))
	for _, p in ipairs(display:GetDescendants()) do
		if p:IsA("BasePart") then
			p.CanQuery = false
			p.CanCollide = false
			p.CanTouch = false
		end
	end
	rarityStyle(display, cf, rarity, display.PrimaryPart)
	local name = def.name .. (level > 0 and (" +" .. level) or "")
	addPrompt(display.PrimaryPart, "Подобрать оружие", name .. " • " .. rarity.name, display)
	display.Name = "Loot_" .. weaponId
	display:SetAttribute("WeaponId", weaponId)
	display:SetAttribute("Level", level)
	if type(opts.mag) == "number" then
		display:SetAttribute("Mag", math.max(0, math.floor(opts.mag)))
	end
	if opts.dropped then
		display:SetAttribute("Dropped", true)
	end
	if type(opts.key) == "string" then
		display:SetAttribute("LootKey", opts.key)
	end
	display.Parent = parent or lootFolder()
	return display
end

-- spots — список CFrame (на полу/полках), содержимое определяется таблицей.
-- keyPrefix — стабильный ключ места: взятые предметы не появятся снова.
-- Случайные числа тратятся одинаково, взят предмет или нет, — генерация остаётся детерминированной.
function Loot.SpawnFromTable(tableName, spots, random, parent, keyPrefix)
	local t = Items.LootTables[tableName]
	if not t or type(spots) ~= "table" or #spots == 0 then
		return
	end
	random = random or rng
	local rolls = random:NextInteger(t.rolls[1], t.rolls[2])
	local order = {}
	for i = 1, #spots do
		order[i] = i
	end
	for i = #order, 2, -1 do
		local j = random:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	for i = 1, rolls do
		local entry = Util.Weighted(random, t.entries)
		local spot = spots[order[((i - 1) % #spots) + 1]]
		local cf = spot * CFrame.new(random:NextNumber(-0.7, 0.7), 0, random:NextNumber(-0.7, 0.7)) * CFrame.Angles(0, random:NextNumber(0, math.pi * 2), 0)
		local key = type(keyPrefix) == "string" and (keyPrefix .. "#" .. i) or nil
		if entry then
			if string.sub(entry, 1, 2) == "w:" then
				Loot.SpawnWeapon(string.sub(entry, 3), cf, parent, { key = key })
			else
				Loot.SpawnItem(entry, 1, cf, parent, key)
			end
		end
	end
end

function Loot.SpawnSafe(cf, parent, random, key)
	random = random or rng
	-- собственное зерно содержимого: при возврате к чанку открытый сейф покажет те же (невзятые) предметы
	local lootSeed = random:NextInteger(1, 1000000000)
	parent = parent or lootFolder()
	local model = Instance.new("Model")
	model.Name = "Safe"
	local body = Util.Part({
		Name = "SafeBody",
		Size = Vector3.new(3, 3.4, 2.6),
		CFrame = cf * CFrame.new(0, 1.7, 0),
		Color = Color3.fromRGB(50, 54, 60),
		Material = Enum.Material.DiamondPlate,
		Parent = model,
	})
	local door = Util.Part({
		Name = "Door",
		Size = Vector3.new(2.4, 2.8, 0.2),
		CFrame = body.CFrame * CFrame.new(0, 0, -1.35),
		Color = Color3.fromRGB(70, 74, 82),
		Material = Enum.Material.Metal,
		Parent = model,
	})
	local dial = Util.Part({
		Name = "Dial",
		Shape = "Cylinder",
		Size = Vector3.new(0.2, 0.8, 0.8),
		CFrame = door.CFrame * CFrame.new(0.5, 0.3, -0.15) * CFrame.Angles(0, math.rad(90), 0),
		Color = Color3.fromRGB(200, 180, 90),
		Material = Enum.Material.Metal,
		Parent = model,
	})
	local safeKey = type(key) == "string" and key or nil

	local function openVisual()
		local opened = door.CFrame * CFrame.new(-1.2, 0, -1.2) * CFrame.Angles(0, math.rad(-80), 0)
		local dialOffset = door.CFrame:ToObjectSpace(dial.CFrame)
		door.CFrame = opened
		dial.CFrame = opened * dialOffset
	end

	local function spawnContents()
		local front = body.CFrame * CFrame.new(0, -1.6, -3)
		local spots = { front, front * CFrame.new(1.2, 0, 0), front * CFrame.new(-1.2, 0, 0) }
		Loot.SpawnFromTable("safe", spots, Random.new(lootSeed), parent, safeKey and (safeKey .. ":loot") or nil)
	end

	if isTaken(safeKey) then
		openVisual()
		model.Parent = parent
		spawnContents()
		return model
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Взломать сейф (шумно!)"
	prompt.ObjectText = "Сейф"
	prompt.HoldDuration = 4
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = body
	prompt.Triggered:Connect(function(player)
		if not PD.IsActive(player) or prompt.Parent == nil then
			return
		end
		prompt:Destroy()
		openVisual()
		markTaken(safeKey)
		spawnContents()
		S.Zombies.Alert(body.Position, 120)
		local noise = Random.new(lootSeed + 7)
		for i = 1, noise:NextInteger(2, 4) do
			local a = noise:NextNumber(0, math.pi * 2)
			local p = body.Position + Vector3.new(math.cos(a) * 30, 0, math.sin(a) * 30)
			local free
			if S.Zombies.IsSpotFree then
				free = S.Zombies.IsSpotFree(p, 3)
			else
				free = not S.Obstacles.IsBlocked(p.X, p.Z, 3)
			end
			if free then
				S.Zombies.Spawn("walker", Vector3.new(p.X, 0, p.Z), { aggro = true })
			end
			if i == 1 then
				PD.Notify(player, "Сейф вскрыт! Шум привлёк зомби", Color3.fromRGB(255, 170, 80))
			end
		end
	end)
	model.Parent = parent
	return model
end

-- Позиция модели добычи (для эффекта подбора у клиента)
local function lootPosition(model)
	local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.Position
	end
	return model:GetPivot().Position
end

-- v5: подобравшему — PickupFx(id, count, kind "item"|"weapon", position): анимация руки и звук подбора (ARMS)
local function pickupFx(player, id, count, kind, position)
	Net.Get("PickupFx"):FireClient(player, id, count, kind, position)
end

-- Подбор (v4): предмет — в хотбар (стопки, свободный слот 1..10, затем рюкзак) и сразу в руки.
-- Не влезло ничего — «Инвентарь полон», предмет остаётся лежать; влезла часть — остаток лежит.
function Loot.Pickup(player, model)
	if typeof(model) ~= "Instance" or not model.Parent or model:GetAttribute("Taken") then
		return
	end
	if not PD.IsActive(player) then
		return
	end
	local d = PD.Get(player)
	if not d then
		return
	end
	local hotbar = PD.HotbarSlots or 10
	local key = model:GetAttribute("LootKey")
	local position = lootPosition(model)
	local weaponId = model:GetAttribute("WeaponId")
	if weaponId then
		local def = WeaponDefs.List[weaponId]
		if not def then
			model:Destroy()
			return
		end
		local rarity = Items.Rarities[def.rarity] or Items.Rarities.common
		local level = tonumber(model:GetAttribute("Level")) or 0
		local name = def.name .. (level > 0 and (" +" .. level) or "")
		if d.Weapons[weaponId] then
			if model:GetAttribute("Dropped") then
				-- выброшенное оружие не превращается в патроны/деньги: оно остаётся лежать
				PD.Notify(player, "У вас уже есть " .. def.name .. " — сначала выбросьте своё (Q)", GREY)
				return
			end
			model:SetAttribute("Taken", true)
			local ammo = def.ammo and Items.List[def.ammo]
			if ammo then
				local amount = (ammo.pack or 5) * 2
				PD.AddItem(player, def.ammo, amount)
				PD.Notify(player, "Уже есть " .. def.name .. " — забрали патроны (" .. amount .. ")", GREY)
				pickupFx(player, def.ammo, amount, "item", position)
			else
				local money = math.floor((def.price or 0) * 0.3)
				PD.AddMoney(player, money)
				PD.Notify(player, "Уже есть " .. def.name .. " — сдали за $" .. money, GREY)
				pickupFx(player, weaponId, 1, "weapon", position)
			end
		else
			if not PD.FindFreeSlot(player) then
				PD.Notify(player, "Инвентарь полон", RED)
				return
			end
			local ok, index = PD.GiveWeapon(player, weaponId, { level = level, mag = model:GetAttribute("Mag") })
			if not ok then
				return
			end
			model:SetAttribute("Taken", true)
			if type(index) == "number" and index <= hotbar then
				PD.SetActive(player, index)
			end
			PD.Notify(player, "Новое оружие: " .. name, rarity.color)
			pickupFx(player, weaponId, 1, "weapon", position)
		end
	else
		local id = model:GetAttribute("ItemId")
		local item = Items.List[id]
		if not item then
			model:Destroy()
			return
		end
		-- переносимый объект берут мышью (S.Grab), в инвентарь он не кладётся
		if model:GetAttribute("Grab") then
			return
		end
		local amount = tonumber(model:GetAttribute("Amount")) or ((tonumber(model:GetAttribute("Count")) or 1) * (item.pack or 1))
		if amount ~= amount or amount == math.huge then
			amount = 1
		end
		amount = math.max(1, math.floor(amount + 0.5))
		local added, _, slot = PD.AddItem(player, id, amount, { pickup = true, noDrop = true })
		if not added or added <= 0 then
			PD.Notify(player, "Инвентарь полон", RED)
			return
		end
		local rest = amount - added
		-- атрибуты модели меняем до экипировки (она может уступить поток другому подбору)
		if rest > 0 then
			-- остаток лежит без ключа памяти: при перезагрузке чанка взятое не появится снова
			markTaken(key)
			model:SetAttribute("LootKey", nil)
			model:SetAttribute("Amount", rest)
			model:SetAttribute("Count", math.max(1, math.floor(rest / (item.pack or 1))))
			local prompt = model:FindFirstChild("LootPrompt", true)
			if prompt and prompt:IsA("ProximityPrompt") then
				prompt.ObjectText = lootLabel(item, rest)
			end
		else
			model:SetAttribute("Taken", true)
		end
		if type(slot) == "number" and slot <= hotbar then
			PD.SetActive(player, slot)
		end
		local rarity = Items.Rarities[item.rarity] or Items.Rarities.common
		PD.Notify(player, "+ " .. item.name .. (added > 1 and (" x" .. added) or ""), rarity.color)
		pickupFx(player, id, added, "item", position)
		if rest > 0 then
			PD.Notify(player, "Инвентарь полон: осталось лежать " .. rest .. " шт.", GREY)
		end
		-- модель передаётся источником: цели не засчитывают выброшенные игроками предметы (Dropped)
		local ok, err = pcall(S.Objectives.OnItemPickup, player, id, added, model)
		if not ok then
			warn("[Loot] Objectives.OnItemPickup: " .. tostring(err))
		end
		if rest > 0 then
			return
		end
	end
	markTaken(key)
	model:Destroy()
end

local function broadcastAnim(player, name, duration)
	local remote = Net.Get("PlayAnim")
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			remote:FireClient(other, player, name, nil, duration)
		end
	end
end

-- Израсходовать 1 шт.: из указанного слота, если там этот предмет, иначе обычный порядок PlayerData
local function consume(player, itemId, slot)
	if slot then
		local slots = PD.GetSlots(player)
		local e = slots and slots[slot]
		if e and e.kind == "item" and e.id == itemId and PD.RemoveFromSlot(player, slot, 1) then
			return true
		end
	end
	return PD.RemoveItem(player, itemId, 1)
end

-- slot (необязательно) — слот инвентаря, из которого используют предмет
function Loot.UseItem(player, itemId, slot)
	local item = Items.List[itemId]
	local d = PD.Get(player)
	if not item or not d or d.Dead then
		return
	end
	if PD.Count(player, itemId) <= 0 then
		return
	end
	if type(slot) ~= "number" or slot ~= slot or slot % 1 ~= 0 or slot < 1 or slot > (PD.TotalSlots or 28) then
		slot = nil
	end
	if d.Downed then
		if itemId == "adrenaline" then
			PD.TrySelfRevive(player)
		end
		return
	end
	if S.Sleep.IsSleeping(player) then
		return
	end
	local hum = Util.AliveHumanoid(player.Character)
	if not hum then
		return
	end

	if item.cat == "food" then
		local wantsHeal = (item.heal or 0) > 0 and hum.Health < hum.MaxHealth - 0.5
		if not item.effect and not wantsHeal and d.Hunger >= 99 then
			PD.Notify(player, item.heal and "Вы сыты и здоровы" or "Вы не голодны", GREY)
			return
		end
		if not consume(player, itemId, slot) then
			return
		end
		local before = d.Hunger
		d.Hunger = math.min(100, d.Hunger + (item.hunger or 0))
		if wantsHeal then
			local amount = math.min(hum.MaxHealth - hum.Health, item.heal)
			hum.Health = hum.Health + amount
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root and amount > 0 then
				S.Combat.SendNumber(root.Position + Vector3.new(0, 3, 0), amount, "heal", player)
			end
		end
		if item.effect then
			PD.AddEffect(player, item.effect, item.effectTime or 60)
		end
		-- энергетик: после эффекта — упадок сил (PlayerData.Update)
		if type(item.crash) == "number" and item.crash > 0 then
			d.CrashAt = os.clock() + (item.effectTime or 8)
			d.CrashTime = item.crash
		end
		broadcastAnim(player, "eat", 0.8)
		local gained = math.floor(d.Hunger - before + 0.5)
		PD.Notify(player, (item.drink and "Вы выпили: " or "Вы съели: ") .. item.name .. (gained > 0 and string.format(" (+%d сытости)", gained) or ""), WHITE)
	elseif item.cat == "medical" then
		if item.revive then
			if not consume(player, itemId, slot) then
				return
			end
			PD.AddEffect(player, "Adrenaline", 14)
			PD.Notify(player, "Адреналин! (лучше приберечь на случай, если упадёте)", Color3.fromRGB(255, 220, 90))
			return
		end
		if hum.Health >= hum.MaxHealth - 0.5 then
			PD.Notify(player, "Здоровье и так полное", GREY)
			return
		end
		if d.Using then
			return
		end
		if not consume(player, itemId, slot) then
			return
		end
		d.Using = true
		local mult = Classes.Perk(d.ClassId, "healMult", 1)
		local duration = item.useTime / mult
		player:SetAttribute("UseEnd", Util.Now() + duration)
		player:SetAttribute("UseName", item.name)
		broadcastAnim(player, "heal", duration)
		task.delay(duration, function()
			d.Using = false
			player:SetAttribute("UseEnd", nil)
			local h = Util.AliveHumanoid(player.Character)
			if h and not d.Downed then
				local amount = math.min(h.MaxHealth - h.Health, item.heal * mult)
				h.Health = h.Health + amount
				local root = player.Character:FindFirstChild("HumanoidRootPart")
				if root and amount > 0 then
					S.Combat.SendNumber(root.Position + Vector3.new(0, 3, 0), amount, "heal", player)
				end
			end
		end)
	elseif item.cat == "fuel" then
		S.Bus.RefuelWith(player, itemId)
	elseif item.cat == "material" then
		S.Bus.RepairWith(player)
	elseif item.cat == "tool" then
		S.Workbench.UseTool(player, itemId)
	elseif item.cat == "placeable" then
		S.Workbench.Place(player, itemId)
	elseif item.cat == "quest" then
		PD.Notify(player, item.name .. ": " .. (item.desc or "нужен для цели биома"), GREY)
	elseif item.cat == "throwable" then
		PD.Notify(player, "Возьмите бутылку в руки и бросайте ЛКМ", GREY)
	elseif item.cat == "buspart" then
		if not S.Bus.AttachItem(player, itemId) then
			return
		end
	elseif item.cat == "valuable" then
		PD.Notify(player, string.format("%s: продаётся за $%d у стойки «ПРОДАТЬ» в депо и у торговцев станций", item.name, item.sell or 0), GREY)
	elseif item.cat == "ammo" then
		PD.Notify(player, "Патроны расходуются при перезарядке (R)", GREY)
	end
end

function Loot.DropItem(player, itemId, count)
	local item = Items.List[itemId]
	local d = PD.Get(player)
	if not item or not d or not PD.IsActive(player) then
		return
	end
	local have = PD.Count(player, itemId)
	-- not (have >= 1) отсекает и NaN
	if not (have >= 1) then
		return
	end
	-- NaN/inf с клиента: math.floor и math.clamp пропускают NaN, и RemoveItem записал бы NaN в стек
	count = tonumber(count) or 1
	if count ~= count or math.abs(count) == math.huge then
		return
	end
	count = math.clamp(math.floor(count), 1, have)
	local cf, surface = Loot.GroundCFrame(player, 3.5)
	if not cf then
		return
	end
	if not PD.RemoveItem(player, itemId, count) then
		return
	end
	-- переносимый предмет — физический объект перед игроком (по одному на штуку)
	if item.grab and grabMaker() then
		Loot.SpawnItem(itemId, 1, cf, nil, nil, { amount = count, dropped = true })
		return
	end
	local pack = item.pack or 1
	local packs = math.max(1, math.floor(count / pack))
	-- точное количество штук хранится в атрибуте Amount
	local model = itemModel(itemId, packs, count, cf, lootFolder(), nil)
	if model then
		-- выброшенный предмет не засчитывается целям «собрать» при повторном подборе
		model:SetAttribute("Dropped", true)
	end
	if model and surface then
		Loot.AttachToSurface(model, surface)
	end
end

function Loot.GiveItem(player, target, itemId, count)
	if typeof(target) ~= "Instance" or not target:IsA("Player") or target == player or type(itemId) ~= "string" then
		return
	end
	local item = Items.List[itemId]
	if not item or not PD.Get(player) or not PD.Get(target) then
		return
	end
	if not PD.IsActive(player) then
		return
	end
	local now = os.clock()
	if now - (lastGive[player] or 0) < 0.25 then
		return
	end
	lastGive[player] = now
	local have = PD.Count(player, itemId)
	if have <= 0 then
		return
	end
	count = tonumber(count) or 1
	if count ~= count then
		return
	end
	count = math.clamp(math.floor(count), 1, have)
	if not PD.IsActive(target) then
		PD.Notify(player, target.DisplayName .. " сейчас не может принять предмет", RED)
		return
	end
	local a = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local b = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not a or not b or (a.Position - b.Position).Magnitude > GIVE_DISTANCE then
		PD.Notify(player, "Подойдите ближе к " .. target.DisplayName, RED)
		return
	end
	-- передаём только то, что поместится у получателя
	local space = PD.SpaceFor(target, itemId)
	if space <= 0 then
		PD.Notify(player, "У " .. target.DisplayName .. " нет места в инвентаре", RED)
		return
	end
	count = math.min(count, space)
	if not PD.RemoveItem(player, itemId, count) then
		return
	end
	local added = PD.AddItem(target, itemId, count, { noDrop = true })
	if not added then
		PD.AddItem(player, itemId, count)
		return
	end
	if added < count then
		PD.AddItem(player, itemId, count - added)
		count = added
	end
	local label = item.name .. (count > 1 and (" x" .. count) or "")
	PD.Notify(player, "Вы передали " .. target.DisplayName .. ": " .. label, GREEN)
	PD.Notify(target, player.DisplayName .. " передал(а) вам: " .. label, GREEN)
end

function Loot.Clear()
	local folder = lootFolder()
	if folder then
		folder:ClearAllChildren()
	end
end

function Loot.Init(services)
	S = services
	PD = S.PlayerData
	Net.Get("UseItem").OnServerEvent:Connect(function(player, itemId)
		if type(itemId) == "string" then
			Loot.UseItem(player, itemId)
		end
	end)
	Net.Get("DropItem").OnServerEvent:Connect(function(player, itemId, count)
		if type(itemId) == "string" then
			Loot.DropItem(player, itemId, count)
		end
	end)
	Net.Get("GiveItem").OnServerEvent:Connect(function(player, target, itemId, count)
		Loot.GiveItem(player, target, itemId, count)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastGive[player] = nil
	end)
end

return Loot
