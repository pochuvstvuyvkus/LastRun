-- Верстак (v3): крафт по рецептам (включая детали автобуса), улучшение оружия; укрепления
-- (баррикады, капканы) и инструменты (ремкомплект, фонарь). Прокачки автобуса уровнями больше нет —
-- детали изготавливаются здесь и прикрепляются к автобусу. Контракт — docs/SPEC_v3.md, 3.1.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Items)
local Recipes = require(Shared.Recipes)
local WeaponDefs = require(Shared.Weapons)
local Progression = require(Shared.Progression)
local Classes = require(Shared.Classes)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Workbench = {}
local S
local PD

local BENCH_RANGE = 14 -- studs от игрока до верстака
local MAX_PLACEABLES = 6 -- укреплений на игрока
local TRAP_RADIUS = 3
local KEEP_DISTANCE = 700 -- укрепления дальше этого от всех игроков и автобуса убираются

local GREEN = Color3.fromRGB(120, 230, 120)
local RED = Color3.fromRGB(255, 110, 100)
local GREY = Color3.fromRGB(200, 200, 200)
local YELLOW = Color3.fromRGB(255, 220, 90)
local WOOD = Color3.fromRGB(140, 100, 60)
local WOOD_DARK = Color3.fromRGB(62, 46, 30)
local STEEL = Color3.fromRGB(120, 122, 130)

local BENCH_NAMES = {
	bus = "Верстак в автобусе",
	depot = "Верстак депо",
	station = "Верстак станции",
}

local benches = {} -- { part, kind, name, prompt }
local placeables = {} -- { kind, owner, model, root, position, ... }
local lanterns = {} -- [player] = время окончания (server time)
local lastAction = {}
local fastAcc = 0
local slowAcc = 0

local function placeablesFolder()
	local f = workspace:FindFirstChild("Placeables")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Placeables"
		f.Parent = workspace
	end
	return f
end

local function rootOf(player)
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Верстаки ---------------------------------------------------------------------------

local function removeBench(bench)
	for i, b in ipairs(benches) do
		if b == bench then
			table.remove(benches, i)
			return
		end
	end
end

function Workbench.RegisterBench(part, kind)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		return nil
	end
	kind = type(kind) == "string" and kind or "bench"
	for _, b in ipairs(benches) do
		if b.part == part then
			return b.prompt
		end
	end
	local name = BENCH_NAMES[kind] or "Верстак"
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "WorkbenchPrompt"
	prompt.ActionText = "Изготовить"
	prompt.ObjectText = name
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	-- метка в мире «ИЗГОТОВИТЬ 46m» (рисует ObjectivesUI)
	part:SetAttribute("WaypointLabel", "ИЗГОТОВИТЬ")
	if part:GetAttribute("WaypointMaxDistance") == nil then
		part:SetAttribute("WaypointMaxDistance", 120)
	end
	if not CollectionService:HasTag(part, "LR_Waypoint") then
		CollectionService:AddTag(part, "LR_Waypoint")
	end
	local bench = { part = part, kind = kind, name = name, prompt = prompt }
	table.insert(benches, bench)
	prompt.Triggered:Connect(function(player)
		if PD.IsActive(player) then
			Net.Get("OpenWorkbench"):FireClient(player, { kind = kind, name = name, part = part })
		end
	end)
	part.Destroying:Connect(function()
		removeBench(bench)
	end)
	return prompt
end

local function distanceToPart(part, position)
	local lp = part.CFrame:PointToObjectSpace(position)
	local half = part.Size * 0.5
	local dx = math.max(0, math.abs(lp.X) - half.X)
	local dy = math.max(0, math.abs(lp.Y) - half.Y)
	local dz = math.max(0, math.abs(lp.Z) - half.Z)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Игрок не дальше BENCH_RANGE от любого живого верстака
function Workbench.NearBench(player)
	local root = rootOf(player)
	if not root then
		return false
	end
	for _, b in ipairs(benches) do
		local part = b.part
		if part.Parent and part:IsDescendantOf(workspace) and distanceToPart(part, root.Position) <= BENCH_RANGE then
			return true, b
		end
	end
	return false
end

-- Материалы и деньги ---------------------------------------------------------------------

local function sortedNeeds(needs)
	local list = {}
	for id, n in pairs(needs or {}) do
		if n > 0 then
			table.insert(list, { id = id, n = n })
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

local function missingText(player, needs)
	local parts = {}
	for _, e in ipairs(sortedNeeds(needs)) do
		local have = PD.Count(player, e.id)
		if have < e.n then
			local item = Items.List[e.id]
			table.insert(parts, string.format("%s %d/%d", item and item.name or e.id, have, e.n))
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ", ")
end

local function giveItems(player, list)
	for id, n in pairs(list) do
		PD.AddItem(player, id, n)
	end
end

local function takeItems(player, needs)
	local taken = {}
	for _, e in ipairs(sortedNeeds(needs)) do
		if PD.RemoveItem(player, e.id, e.n) then
			taken[e.id] = e.n
		else
			giveItems(player, taken)
			return false, nil
		end
	end
	return true, taken
end

-- возврат без учёта в статистике «заработано»
local function refundMoney(player, amount)
	local d = PD.Get(player)
	if d and amount > 0 then
		d.Money = d.Money + amount
		player:SetAttribute("Money", d.Money)
	end
end

local function checkAccess(player)
	if not PD.IsActive(player) then
		return false
	end
	local now = os.clock()
	if now - (lastAction[player] or 0) < 0.25 then
		return false
	end
	lastAction[player] = now
	if not Workbench.NearBench(player) then
		PD.Notify(player, "Подойдите к верстаку", RED)
		return false
	end
	return true
end

local function canPay(player, price, materials)
	local d = PD.Get(player)
	if not d then
		return false
	end
	if d.Money < price then
		PD.Notify(player, string.format("Не хватает денег: нужно $%d, у вас $%d", price, d.Money), RED)
		return false
	end
	local missing = missingText(player, materials)
	if missing then
		PD.Notify(player, "Не хватает материалов: " .. missing, RED)
		return false
	end
	return true
end

-- Списать деньги и материалы. Возвращает taken (для возврата) или nil
local function pay(player, price, materials)
	if not PD.SpendMoney(player, price) then
		return nil
	end
	local ok, taken = takeItems(player, materials)
	if not ok then
		refundMoney(player, price)
		return nil
	end
	return taken
end

-- Удалённые вызовы -------------------------------------------------------------------

-- Функция LootService (в старой версии модуля её может не быть)
local function lootFn(name)
	local loot = S and S.Loot
	local fn = loot and loot[name]
	return type(fn) == "function" and fn or nil
end

-- Переносимый объект (Items grab: колесо, стена) — появляется в мире, а не в слотах
local function isGrabItem(id)
	local fn = lootFn("IsGrabItem")
	return fn ~= nil and fn(id) == true
end

local function craft(player, recipeId)
	if type(recipeId) ~= "string" then
		return
	end
	local recipe = Recipes.List[recipeId]
	if not recipe or not checkAccess(player) then
		return
	end
	local missing = missingText(player, recipe.inputs)
	if missing then
		PD.Notify(player, "Не хватает: " .. missing, RED)
		return
	end
	-- переносимые объекты (колёса, стены — Items grab) появляются на земле рядом, а не в слотах
	local spawnNear = lootFn("SpawnGrabNear")
	local isGrab = false
	for id in pairs(recipe.outputs) do
		if isGrabItem(id) then
			isGrab = true
		end
	end
	if isGrab and (not spawnNear or not S.Loot.GroundCFrame(player, 3)) then
		return
	end
	local ok, taken = takeItems(player, recipe.inputs)
	if not ok then
		return
	end
	if isGrab then
		for id, n in pairs(recipe.outputs) do
			if isGrabItem(id) and not spawnNear(player, id, n) then
				giveItems(player, taken)
				PD.Notify(player, "Некуда положить готовую деталь — материалы возвращены", RED)
				return
			end
		end
	end
	for id, n in pairs(recipe.outputs) do
		if not isGrabItem(id) then
			PD.AddItem(player, id, n)
		end
	end
	S.Profile.AddXP(player, Progression.XP.craft, "craft")
	local isPart, isWall = false, false
	local kinds, lastId, lastN = 0, nil, 0
	for id, n in pairs(recipe.outputs) do
		local item = Items.List[id]
		kinds = kinds + 1
		lastId, lastN = id, n
		if item and item.cat == "buspart" then
			isPart = true
			isWall = isWall or item.wall == true
		end
	end
	-- одна штука одного предмета — называем по предмету (v5: «Деревянная стена», а не старое имя рецепта)
	local label = recipe.name
	if kinds == 1 and lastN == 1 and Items.List[lastId] then
		label = Items.List[lastId].name
	end
	if isGrab then
		PD.Notify(player, "Изготовлено: " .. label .. " — лежит рядом: возьмите (ЛКМ) и прикрепите к автобусу (Z)", GREEN)
	elseif isWall then
		PD.Notify(player, "Изготовлено: " .. label .. " — поставьте её в пустой проём автобуса", GREEN)
	elseif isPart then
		PD.Notify(player, "Изготовлено: " .. label .. " — прикрепите деталь к автобусу", GREEN)
	else
		PD.Notify(player, "Изготовлено: " .. label, GREEN)
	end
end

local function upgradeWeapon(player, weaponId)
	if type(weaponId) ~= "string" then
		return
	end
	local def = WeaponDefs.List[weaponId]
	if not def or def.kind == "throw" or not checkAccess(player) then
		return
	end
	local d = PD.Get(player)
	if not d or not d.Weapons[weaponId] then
		PD.Notify(player, "У вас нет этого оружия", RED)
		return
	end
	local level = PD.GetWeaponLevel(player, weaponId)
	local price, materials, nextLevel = Recipes.WeaponUpgradeFor(level, def.rarity)
	if not price then
		PD.Notify(player, def.name .. " уже максимального уровня", GREY)
		return
	end
	if not canPay(player, price, materials) then
		return
	end
	if not pay(player, price, materials) then
		return
	end
	PD.SetWeaponLevel(player, weaponId, nextLevel)
	S.Weapons.ApplyLevel(player, weaponId)
	S.Profile.AddXP(player, Progression.XP.craft, "craft")
	PD.Notify(player, string.format("%s улучшено до уровня %d", def.name, nextLevel), GREEN)
end

-- Укрепления ------------------------------------------------------------------------------

local function countOwned(player)
	local n = 0
	for _, e in ipairs(placeables) do
		if e.owner == player and not e.removed then
			n = n + 1
		end
	end
	return n
end

local function removePlaceable(entry, effect)
	if entry.removed then
		return
	end
	entry.removed = true
	for i, e in ipairs(placeables) do
		if e == entry then
			table.remove(placeables, i)
			break
		end
	end
	if entry.ob then
		S.Obstacles.Remove(entry.ob)
	end
	if effect then
		Net.FireNear("Explosion", entry.position, 300, entry.position, 4, "crash")
	end
	if entry.model then
		entry.model:Destroy()
	end
end

local function decoPart(model, props)
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	props.Parent = model
	return Util.Part(props)
end

local function buildBarricade(player, cf, item)
	local model = Instance.new("Model")
	model.Name = "Barricade"
	local base = cf * CFrame.new(0, 2.6, 0)
	local wall = Util.Part({
		Name = "Wall",
		Size = Vector3.new(8, 5, 0.8),
		CFrame = base,
		Color = WOOD,
		Material = Enum.Material.WoodPlanks,
		CanTouch = false,
		CollisionGroup = "World",
		Parent = model,
	})
	for i, y in ipairs({ -1.5, 0, 1.5 }) do
		decoPart(model, {
			Name = "Board",
			Size = Vector3.new(8.8, 0.9, 0.3),
			CFrame = base * CFrame.new(0, y, 0.55) * CFrame.Angles(0, 0, math.rad(i == 2 and 7 or -5)),
			Color = WOOD:Lerp(WOOD_DARK, 0.25),
			Material = Enum.Material.Wood,
		})
	end
	for _, x in ipairs({ -3.7, 3.7 }) do
		decoPart(model, {
			Name = "Post",
			Size = Vector3.new(0.7, 5.8, 0.7),
			CFrame = base * CFrame.new(x, 0.3, -0.2),
			Color = WOOD_DARK,
			Material = Enum.Material.Wood,
		})
		decoPart(model, {
			Name = "Spike",
			Size = Vector3.new(0.3, 0.3, 2.2),
			CFrame = base * CFrame.new(x * 0.6, 1.6, 1.2) * CFrame.Angles(math.rad(-25), 0, 0),
			Color = STEEL,
			Material = Enum.Material.Metal,
		})
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "HPBar"
	gui.Size = UDim2.fromOffset(90, 9)
	gui.StudsOffset = Vector3.new(0, 3.5, 0)
	gui.MaxDistance = 70
	gui.AlwaysOnTop = false
	gui.Enabled = false
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	back.BorderSizePixel = 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(230, 170, 60)
	fill.BorderSizePixel = 0
	fill.Parent = back
	gui.Parent = wall

	model.PrimaryPart = wall
	model.Parent = placeablesFolder()

	local hp = item.placeHP or 300
	local entry = {
		kind = "barricade",
		owner = player,
		model = model,
		root = wall,
		position = wall.Position,
		hp = hp,
		maxHp = hp,
	}
	-- Автобус не сталкивается с группой World и едет только по сетке Obstacles:
	-- баррикада — мягкое препятствие, которое автобус сносит (как баррикада налётчиков)
	entry.ob = S.Obstacles.AddBox(nil, wall.CFrame, 4.4, 0.6, { hard = false, model = model, kind = "barricade" })
	-- Зомби бьют баррикаду: placeable.Damage(amount)
	entry.Damage = function(amount)
		if entry.removed or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
			return
		end
		entry.hp = entry.hp - amount
		if entry.hp <= 0 then
			removePlaceable(entry, true)
			local owner = entry.owner
			if owner and owner.Parent then
				PD.Notify(owner, "Ваша баррикада разрушена", YELLOW)
			end
			return
		end
		local frac = math.clamp(entry.hp / entry.maxHp, 0, 1)
		fill.Size = UDim2.fromScale(frac, 1)
		gui.Enabled = true
		wall.Color = WOOD:Lerp(WOOD_DARK, 1 - frac)
	end
	return entry
end

local function buildTrap(player, cf, item)
	local model = Instance.new("Model")
	model.Name = "Trap"
	local plate = decoPart(model, {
		Name = "Plate",
		Shape = "Cylinder",
		Size = Vector3.new(0.2, 2.4, 2.4),
		CFrame = cf * CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(80, 80, 86),
		Material = Enum.Material.DiamondPlate,
	})
	for _, z in ipairs({ -0.85, 0.85 }) do
		decoPart(model, {
			Name = "Jaw",
			Size = Vector3.new(2.2, 0.35, 0.18),
			CFrame = cf * CFrame.new(0, 0.3, z) * CFrame.Angles(math.rad(z > 0 and 35 or -35), 0, 0),
			Color = STEEL,
			Material = Enum.Material.Metal,
		})
	end
	decoPart(model, {
		Name = "Trigger",
		Size = Vector3.new(0.6, 0.12, 0.6),
		CFrame = cf * CFrame.new(0, 0.25, 0),
		Color = Color3.fromRGB(200, 60, 50),
		Material = Enum.Material.SmoothPlastic,
	})
	model.PrimaryPart = plate
	model.Parent = placeablesFolder()
	return {
		kind = "trap",
		owner = player,
		model = model,
		root = plate,
		position = cf.Position,
		damage = item.trapDamage or 60,
		rootTime = item.trapRoot or 3,
	}
end

function Workbench.Place(player, itemId)
	local item = Items.List[itemId]
	if not item or item.cat ~= "placeable" then
		return
	end
	if not PD.IsActive(player) or PD.Count(player, itemId) <= 0 then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = rootOf(player)
	if not hum or not root then
		return
	end
	if hum.SeatPart then
		PD.Notify(player, "Сначала встаньте", RED)
		return
	end
	if countOwned(player) >= MAX_PLACEABLES then
		PD.Notify(player, "Можно поставить не больше " .. MAX_PLACEABLES .. " укреплений", RED)
		return
	end
	local isBarricade = item.placeHP ~= nil
	local forward = isBarricade and 4.5 or 3
	local cf, surface = S.Loot.GroundCFrame(player, forward)
	if not cf or not surface or not surface.Anchored then
		PD.Notify(player, "Здесь нельзя поставить", RED)
		return
	end
	if math.abs(cf.Position.Y - root.Position.Y) > 7 then
		PD.Notify(player, "Здесь нельзя поставить: слишком крутой склон", RED)
		return
	end
	if S.Bus.Root and (S.Bus.IsInside(cf.Position) or S.Bus.IsInside(cf.Position + Vector3.new(0, 2.5, 0))) then
		PD.Notify(player, "Внутри автобуса ставить нельзя", RED)
		return
	end
	-- между игроком и местом установки не должно быть стены
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { char }
	for _, name in ipairs({ "Zombies", "Loot", "Effects" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	params.FilterDescendantsInstances = exclude
	local target = cf.Position + Vector3.new(0, 2, 0)
	local hit = workspace:Raycast(root.Position, target - root.Position, params)
	if hit and (hit.Position - target).Magnitude > 1 then
		PD.Notify(player, "Мешает препятствие", RED)
		return
	end
	for _, e in ipairs(placeables) do
		if not e.removed and Util.FlatDist(e.position, cf.Position) < (isBarricade and 3 or 2) then
			PD.Notify(player, "Слишком близко к другому укреплению", RED)
			return
		end
	end
	if not PD.RemoveItem(player, itemId, 1) then
		return
	end
	local entry
	if isBarricade then
		entry = buildBarricade(player, cf, item)
	else
		entry = buildTrap(player, cf, item)
	end
	table.insert(placeables, entry)
	PD.Notify(player, "Установлено: " .. item.name, GREEN)
end

-- Ближайшая баррикада в радиусе (для ZombieService): { position, Damage(amount) } или nil
function Workbench.FindPlaceableNear(pos, radius)
	if typeof(pos) ~= "Vector3" then
		return nil
	end
	radius = tonumber(radius) or 5
	local best, bestDist = nil, radius
	for _, e in ipairs(placeables) do
		if e.kind == "barricade" and not e.removed and e.root.Parent then
			local dist = distanceToPart(e.root, pos)
			if dist <= bestDist then
				best, bestDist = e, dist
			end
		end
	end
	return best
end

-- Инструменты -----------------------------------------------------------------------------

local function ensureLantern(player)
	local root = rootOf(player)
	if not root or root:FindFirstChild("LanternLight") then
		return
	end
	local light = Instance.new("PointLight")
	light.Name = "LanternLight"
	light.Color = Color3.fromRGB(255, 214, 140)
	light.Range = 32
	light.Brightness = 1.8
	light.Shadows = true
	light.Parent = root
end

local function removeLantern(player)
	local root = rootOf(player)
	local light = root and root:FindFirstChild("LanternLight")
	if light then
		light:Destroy()
	end
	lanterns[player] = nil
	if player.Parent then
		player:SetAttribute("LanternUntil", nil)
	end
end

function Workbench.UseTool(player, itemId)
	local item = Items.List[itemId]
	if not item or item.cat ~= "tool" then
		return
	end
	if not PD.IsActive(player) or PD.Count(player, itemId) <= 0 then
		return
	end
	if item.busRepair then
		if not S.Bus.Root or not S.Bus.IsNear(player, 25) then
			PD.Notify(player, "Подойдите к автобусу, чтобы применить ремкомплект", RED)
			return
		end
		if S.Bus.HP >= S.Bus.MaxHP then
			PD.Notify(player, "Автобус и так цел", GREY)
			return
		end
		if not PD.RemoveItem(player, itemId, 1) then
			return
		end
		local d = PD.Get(player)
		local amount = math.floor(item.busRepair * Classes.Perk(d and d.ClassId or "survivor", "repairMult", 1))
		S.Bus.Repair(amount)
		PD.NotifyAll(string.format("%s применил(а) ремкомплект: +%d прочности автобуса", player.DisplayName, amount), GREEN)
	elseif item.lightTime then
		if not PD.RemoveItem(player, itemId, 1) then
			return
		end
		local now = Util.Now()
		local untilT = math.max(lanterns[player] or 0, now) + item.lightTime
		lanterns[player] = untilT
		player:SetAttribute("LanternUntil", untilT)
		ensureLantern(player)
		PD.Notify(player, string.format("Фонарь горит: %d с", math.floor(untilT - now)), YELLOW)
	end
end

-- Обновление -------------------------------------------------------------------------------

local function updateTraps()
	local zombies = S.Zombies.List()
	if #zombies == 0 then
		return
	end
	for i = #placeables, 1, -1 do
		local e = placeables[i]
		if e and e.kind == "trap" and not e.removed then
			for _, z in ipairs(zombies) do
				if not z.dead and z.root then
					local p = z.root.Position
					local dx, dz = p.X - e.position.X, p.Z - e.position.Z
					local r = TRAP_RADIUS + (z.radius or 1) * 0.5
					if dx * dx + dz * dz <= r * r and math.abs(p.Y - e.position.Y) < 9 then
						local owner = e.owner
						if owner and not owner.Parent then
							owner = nil
						end
						Net.FireNear("Explosion", e.position, 250, e.position, 3, "slam")
						removePlaceable(e, false)
						S.Combat.DamageZombie(z, e.damage, { attacker = owner, kind = "normal", weapon = "trap" })
						if not z.dead then
							S.Zombies.Stun(z, e.rootTime)
						end
						break
					end
				end
			end
		end
	end
end

-- Баррикады, которые снёс автобус: smashSoft убрал препятствие и сам удалит модель;
-- на всякий случай сносим и баррикаду, оказавшуюся внутри автобуса
local function updateBusSmash()
	local busRoot = S.Bus.Root
	for i = #placeables, 1, -1 do
		local e = placeables[i]
		if e and e.kind == "barricade" and not e.removed then
			local smashed = false
			if e.ob and e.ob.removed then
				e.removed = true
				table.remove(placeables, i)
				smashed = true
			elseif busRoot and S.Bus.IsInside(e.position) then
				removePlaceable(e, true)
				smashed = true
			end
			local owner = e.owner
			if smashed and owner and owner.Parent then
				PD.Notify(owner, "Автобус снёс вашу баррикаду", YELLOW)
			end
		end
	end
end

local function cleanupFar()
	local anchors = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local root = rootOf(plr)
		if root then
			table.insert(anchors, root.Position)
		end
	end
	if S.Bus.Root then
		table.insert(anchors, S.Bus.Root.Position)
	end
	for i = #placeables, 1, -1 do
		local e = placeables[i]
		if e then
			local near = false
			if e.model and e.model.Parent then
				for _, a in ipairs(anchors) do
					if Util.FlatDist(a, e.position) < KEEP_DISTANCE then
						near = true
						break
					end
				end
			end
			if not near then
				removePlaceable(e, false)
			end
		end
	end
end

local function updateLanterns()
	local now = Util.Now()
	for player, untilT in pairs(lanterns) do
		if not player.Parent then
			lanterns[player] = nil
		elseif now >= untilT then
			removeLantern(player)
			PD.Notify(player, "Фонарь погас", GREY)
		else
			ensureLantern(player)
		end
	end
end

function Workbench.Update(dt)
	fastAcc = fastAcc + dt
	slowAcc = slowAcc + dt
	if fastAcc >= 0.2 then
		fastAcc = 0
		if #placeables > 0 then
			updateBusSmash()
			updateTraps()
		end
	end
	if slowAcc >= 1 then
		slowAcc = 0
		if #placeables > 0 then
			cleanupFar()
		end
		updateLanterns()
		for i = #benches, 1, -1 do
			if benches[i].part.Parent == nil then
				table.remove(benches, i)
			end
		end
	end
end

function Workbench.Clear()
	for i = #placeables, 1, -1 do
		removePlaceable(placeables[i], false)
	end
	placeables = {}
	placeablesFolder():ClearAllChildren()
	for player in pairs(lanterns) do
		removeLantern(player)
	end
	lanterns = {}
	lastAction = {}
	for i = #benches, 1, -1 do
		if benches[i].part.Parent == nil then
			table.remove(benches, i)
		end
	end
end

function Workbench.Init(services)
	S = services
	PD = S.PlayerData
	placeablesFolder()
	Net.Get("Craft").OnServerEvent:Connect(craft)
	Net.Get("UpgradeWeapon").OnServerEvent:Connect(upgradeWeapon)
	Players.PlayerRemoving:Connect(function(player)
		lanterns[player] = nil
		lastAction[player] = nil
	end)
end

return Workbench
