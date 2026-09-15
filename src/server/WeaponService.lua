-- Предметы в руках на сервере (v4): инструменты по слотам хотбара (1..10), экипировка и активный слот,
-- использование предмета из руки, оружие (ближний бой, огнестрел, лук, арбалет, бросок), удары «по всему»
-- (зомби, разрушаемые завалы, любые поверхности с эффектом по материалу и толчком незакреплённых деталей),
-- перезарядка, уровни оружия, выбрасывание/передача, режим камеры (первое лицо в заезде, от третьего — в лобби).
-- После каждого удара/попадания клиентам уходит HitFx {pos, kind, weaponId, attacker, hits, heavy, dir, normal}.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponDefs = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local ItemModels = require(Shared.ItemModels)
local Items = require(Shared.Items)
local Classes = require(Shared.Classes)
local Recipes = require(Shared.Recipes)
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local WS = {}
local S
local PD
local states = {}
local rng = Random.new()

local GREEN = Color3.fromRGB(120, 230, 120)
local RED = Color3.fromRGB(255, 110, 100)
local GREY = Color3.fromRGB(200, 200, 200)
local ORANGE = Color3.fromRGB(255, 180, 90)

local HOTBAR = (Config.Inventory and Config.Inventory.HotbarSlots) or 10
local GIVE_DISTANCE = 16
local HITFX_RADIUS = 220
local MAX_FX_HITS = 8
local MAX_BREAKABLES_PER_SWING = 3
local USE_GAP = 0.3
local MELEE_RADIUS = 0.8

-- метательное оружие по id предмета (бутылка в слоте = оружие «molotov»)
local THROW_BY_ITEM = {}
for id, def in pairs(WeaponDefs.List) do
	if def.kind == "throw" and type(def.item) == "string" then
		THROW_BY_ITEM[def.item] = id
	end
end

local function getState(player)
	local st = states[player]
	if not st then
		st = {
			last = {}, combo = {}, comboTime = {}, drawStart = nil, drawTool = nil, lastTransfer = 0,
			lastUse = 0, lastHint = 0, syncing = false, charConns = {}, lastToolChange = 0,
		}
		states[player] = st
	end
	return st
end

local function inLobby()
	return S ~= nil and S.Run ~= nil and S.Run.Mode == "lobby"
end

local function isPlayer(v)
	return typeof(v) == "Instance" and v:IsA("Player")
end

-- Необязательное API PlayerData (слоты v4): пока INV не добавил функцию — nil
local function pdApi(name)
	local f = PD and PD[name]
	if type(f) == "function" then
		return f
	end
	return nil
end

local warnedOnce = {}
local function warnOnce(key, err)
	if not warnedOnce[key] then
		warnedOnce[key] = true
		warn("[Weapons] " .. key .. ": " .. tostring(err))
	end
end

local function isSleeping(player)
	return S.Sleep ~= nil and S.Sleep.IsSleeping(player) == true
end

-- Анимация у других игроков (includeSelf — и у самого игрока: подтверждённое сервером действие)
local function broadcastAnim(player, name, weaponId, duration, includeSelf)
	local remote = Net.Get("PlayAnim")
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player or includeSelf then
			remote:FireClient(other, player, name, weaponId, duration)
		end
	end
end

-- except — игрок, которому не отправлять: свой выстрел клиент уже нарисовал и озвучил сам
-- (у огнестрела это всегда стрелявший: попадания пуль клиент считает сам)
local function sendHitFx(info, except)
	if typeof(info.pos) ~= "Vector3" then
		return
	end
	if not except and info.gun then
		except = info.attacker
	end
	if not except then
		Net.FireNear("HitFx", info.pos, HITFX_RADIUS, info)
		return
	end
	local remote = Net.Get("HitFx")
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr ~= except and plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - info.pos).Magnitude <= HITFX_RADIUS then
			remote:FireClient(plr, info)
		end
	end
end

-- Камера: первое лицо в заезде, от третьего лица в лобби
local function applyCameraMode(player)
	if not S or not S.Run then
		return
	end
	local want
	if S.Run.Mode == "run" then
		want = Enum.CameraMode.LockFirstPerson
	elseif S.Run.Mode == "lobby" then
		want = Enum.CameraMode.Classic
	end
	if want and player.CameraMode ~= want then
		player.CameraMode = want
	end
end

-- Слоты и инструменты ------------------------------------------------------------------------

local function validEntry(entry)
	return type(entry) == "table" and (entry.kind == "weapon" or entry.kind == "item") and type(entry.id) == "string"
end

-- Слоты игрока {[i] = entry} и признак настоящих слотов v4. Без слотов в данных (старый PlayerData)
-- собираем виртуальный хотбар из оружия и метательного.
local function playerSlots(player, d)
	if type(d.Slots) == "table" then
		return d.Slots, true
	end
	local getSlots = pdApi("GetSlots")
	if getSlots then
		local ok, slots = pcall(getSlots, player)
		if ok and type(slots) == "table" then
			return slots, true
		end
	end
	local list = {}
	local n = 0
	for _, id in ipairs(d.WeaponOrder or {}) do
		if n < HOTBAR and WeaponDefs.List[id] then
			n = n + 1
			list[n] = { kind = "weapon", id = id, level = d.WeaponLevels and d.WeaponLevels[id] or 0, mag = d.Mags and d.Mags[id] or 0 }
		end
	end
	local bottles = d.Inventory and tonumber(d.Inventory.molotov) or 0
	if bottles > 0 and n < HOTBAR then
		n = n + 1
		list[n] = { kind = "item", id = "molotov", count = bottles }
	end
	return list, false
end

local function slotEntry(player, d, index)
	local slots = playerSlots(player, d)
	local entry = slots[index]
	if validEntry(entry) then
		return entry
	end
	return nil
end

local function activeIndex(player)
	local getActive = pdApi("GetActive")
	if not getActive then
		return nil
	end
	local ok, index = pcall(getActive, player)
	if ok and type(index) == "number" then
		return index
	end
	return nil
end

local function toolKey(tool)
	local kind = tool:GetAttribute("ItemKind")
	local id = tool:GetAttribute("ItemId")
	if (kind == "weapon" or kind == "item") and type(id) == "string" then
		return kind .. ":" .. id
	end
	return nil
end

local function toolContainers(player)
	return { player.Character, player:FindFirstChildOfClass("Backpack") }
end

local function findSlotTool(player, index)
	for _, c in ipairs(toolContainers(player)) do
		if c then
			for _, t in ipairs(c:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("Slot") == index then
					return t
				end
			end
		end
	end
	return nil
end

local function findTool(player, weaponId)
	for _, c in ipairs(toolContainers(player)) do
		if c then
			for _, t in ipairs(c:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("WeaponId") == weaponId then
					return t
				end
			end
		end
	end
	return nil
end

-- Удалить все инструменты игрока (рюкзак и руки)
local function removeAllTools(player)
	for _, c in ipairs(toolContainers(player)) do
		for _, t in ipairs(c and c:GetChildren() or {}) do
			if t:IsA("Tool") then
				t:Destroy()
			end
		end
	end
end

-- "Катана +2"
function WS.DisplayName(weaponId, level)
	local def = WeaponDefs.List[weaponId]
	local name = def and def.name or tostring(weaponId)
	if level and level > 0 then
		name = name .. " +" .. level
	end
	return name
end

-- Размер магазина с учётом уровня (nil для оружия без магазина)
function WS.MaxMag(player, weaponId)
	local def = WeaponDefs.List[weaponId]
	if not def or not def.mag then
		return nil
	end
	return Recipes.WeaponMagBonus(def.mag, PD.GetWeaponLevel(player, weaponId) or 0)
end

-- Множитель кулдауна и перезарядки с учётом уровня
function WS.CooldownMult(player, weaponId)
	return Recipes.WeaponCooldownMult(PD.GetWeaponLevel(player, weaponId) or 0)
end

local function toolLevel(tool)
	local level = tool:GetAttribute("Level")
	return type(level) == "number" and level or 0
end

local function makeTool(entry)
	if entry.kind == "weapon" then
		local def = WeaponDefs.List[entry.id]
		if not def then
			return nil
		end
		local tool = WeaponModels.MakeTool(entry.id, def.name)
		tool:SetAttribute("Kind", def.kind)
		tool:SetAttribute("ItemKind", "weapon")
		tool:SetAttribute("ItemId", entry.id)
		return tool
	end
	if not Items.List[entry.id] then
		return nil
	end
	local tool = ItemModels.MakeTool(entry.id, entry.count)
	local throwId = THROW_BY_ITEM[entry.id]
	if throwId then
		tool:SetAttribute("WeaponId", throwId)
		tool:SetAttribute("Kind", "throw")
	end
	return tool
end

local function applyEntry(tool, entry, index, d)
	if tool:GetAttribute("Slot") ~= index then
		tool:SetAttribute("Slot", index)
	end
	if entry.kind == "weapon" then
		local def = WeaponDefs.List[entry.id]
		local level = math.floor(tonumber(entry.level) or (d.WeaponLevels and d.WeaponLevels[entry.id]) or 0)
		local name = WS.DisplayName(entry.id, level)
		if tool.Name ~= name then
			tool.Name = name
			tool.ToolTip = name
		end
		tool:SetAttribute("Level", level)
		if def and def.mag then
			local maxMag = Recipes.WeaponMagBonus(def.mag, level)
			local mag = tonumber(entry.mag) or (d.Mags and d.Mags[entry.id]) or maxMag
			mag = math.clamp(math.floor(mag), 0, maxMag)
			tool:SetAttribute("MaxMag", maxMag)
			tool:SetAttribute("Mag", mag)
		end
	else
		local count = math.max(1, math.floor(tonumber(entry.count) or 1))
		if tool:GetAttribute("Count") ~= count then
			tool:SetAttribute("Count", count)
		end
	end
end

-- Синхронизировать инструменты с хотбаром: создать/обновить/удалить, активный слот — в руках.
-- В лобби инструментов нет.
function WS.RefreshTools(player)
	if not isPlayer(player) then
		return
	end
	applyCameraMode(player)
	if inLobby() then
		removeAllTools(player)
		return
	end
	local d = PD.Get(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not d or not backpack then
		return
	end
	local char = player.Character
	local st = getState(player)
	st.syncing = true
	local slots, slotMode = playerSlots(player, d)

	-- существующие инструменты по ключу "вид:id" (сначала тот, что в руках)
	local pool = {}
	for _, container in ipairs({ char, backpack }) do
		if container then
			for _, t in ipairs(container:GetChildren()) do
				if t:IsA("Tool") then
					local key = toolKey(t)
					if key then
						pool[key] = pool[key] or {}
						table.insert(pool[key], t)
					else
						t:Destroy()
					end
				end
			end
		end
	end

	local bySlot = {}
	for i = 1, HOTBAR do
		local entry = slots[i]
		if validEntry(entry) then
			local key = entry.kind .. ":" .. entry.id
			local list = pool[key]
			local tool
			if list then
				for j, t in ipairs(list) do
					if t:GetAttribute("Slot") == i then
						tool = table.remove(list, j)
						break
					end
				end
				if not tool and #list > 0 then
					tool = table.remove(list, 1)
				end
			end
			if not tool then
				local ok, made = pcall(makeTool, entry)
				if ok and made then
					tool = made
					tool.Parent = backpack
				elseif not ok then
					warnOnce("MakeTool " .. key, made)
				end
			end
			if tool then
				applyEntry(tool, entry, i, d)
				bySlot[i] = tool
			end
		end
	end
	for _, list in pairs(pool) do
		for _, t in ipairs(list) do
			t:Destroy()
		end
	end

	-- активный слот (v4): в руках ровно его инструмент
	local active = slotMode and activeIndex(player) or nil
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if active ~= nil and hum and hum.Health > 0 and not d.Downed and not d.Dead and not isSleeping(player) then
		local want = bySlot[active]
		local held = char:FindFirstChildOfClass("Tool")
		if want and held ~= want then
			hum:EquipTool(want)
		elseif not want and held then
			hum:UnequipTools()
		end
	end
	st.syncing = false
end

-- Отложенная пересборка (несколько изменений за кадр — одна пересборка)
function WS.QueueRefresh(player)
	if not isPlayer(player) then
		return
	end
	local st = getState(player)
	if st.refreshQueued then
		return
	end
	st.refreshQueued = true
	task.defer(function()
		st.refreshQueued = false
		if player.Parent then
			WS.RefreshTools(player)
		end
	end)
end

-- Совместимость со старым API (PlayerData/Workbench v3)
function WS.RefreshThrowables(player)
	WS.QueueRefresh(player)
end

function WS.CreateTool(player, weaponId)
	WS.QueueRefresh(player)
	return findTool(player, weaponId)
end

-- Обновить инструмент после улучшения: имя, Level, MaxMag
function WS.ApplyLevel(player, _weaponId)
	WS.RefreshTools(player)
end

-- Взять в руки слот хотбара (0 — убрать из рук). Вызывается PlayerData.SetActive и сервером.
function WS.EquipSlot(player, index)
	if not isPlayer(player) or inLobby() then
		return false
	end
	index = math.floor(tonumber(index) or 0)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local d = PD.Get(player)
	if not hum or hum.Health <= 0 or not d or d.Downed or d.Dead or isSleeping(player) then
		return false
	end
	local held = char:FindFirstChildOfClass("Tool")
	if index < 1 or index > HOTBAR then
		if held then
			hum:UnequipTools()
		end
		return true
	end
	local tool = findSlotTool(player, index)
	if not tool then
		WS.RefreshTools(player)
		tool = findSlotTool(player, index)
	end
	if not tool then
		if held then
			hum:UnequipTools()
		end
		return false
	end
	if held ~= tool then
		hum:EquipTool(tool)
	end
	return true
end

-- Клиент сам взял/убрал инструмент (Humanoid:EquipTool) — сообщаем PlayerData активный слот
local function syncActiveFromCharacter(player, char)
	local st = getState(player)
	if st.syncing or player.Character ~= char or inLobby() then
		return
	end
	local setActive = pdApi("SetActive")
	if not setActive then
		return
	end
	local d = PD.Get(player)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not d or d.Dead or not hum or hum.Health <= 0 then
		return
	end
	local held = char:FindFirstChildOfClass("Tool")
	local index = 0
	if held then
		index = held:GetAttribute("Slot")
		if type(index) ~= "number" then
			return
		end
	elseif d.Downed or isSleeping(player) then
		-- инструмент убрали из-за обморока или сна — активный слот не сбрасываем
		return
	end
	if activeIndex(player) == index then
		return
	end
	local ok, err = pcall(setActive, player, index)
	if not ok then
		warnOnce("SetActive", err)
	end
end

local function scheduleActiveSync(player, char)
	local st = getState(player)
	st.lastToolChange = os.clock()
	if st.activeQueued then
		return
	end
	st.activeQueued = true
	task.defer(function()
		st.activeQueued = false
		if player.Parent then
			syncActiveFromCharacter(player, char)
		end
	end)
end

local function hookCharacter(player, char)
	applyCameraMode(player)
	local st = getState(player)
	for _, conn in ipairs(st.charConns) do
		conn:Disconnect()
	end
	st.charConns = {
		char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				scheduleActiveSync(player, char)
			end
		end),
		char.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				scheduleActiveSync(player, char)
			end
		end),
	}
end

-- Использование предмета из слота ---------------------------------------------------------------

local function hint(player, st, text, color)
	local now = os.clock()
	if now - st.lastHint < 1.2 then
		return
	end
	st.lastHint = now
	PD.Notify(player, text, color or GREY)
end

local function useItem(player, d, entry, index)
	local st = getState(player)
	local now = os.clock()
	if now - st.lastUse < USE_GAP then
		return false
	end
	st.lastUse = now
	local id = entry.id
	local item = Items.List[id]
	if not item then
		return false
	end
	local cat = item.cat
	if cat == "throwable" then
		if index <= HOTBAR then
			return WS.EquipSlot(player, index)
		end
		hint(player, st, "Переложите " .. item.name .. " в хотбар (1–0), чтобы бросать")
		return false
	elseif cat == "fuel" then
		if not S.Bus.Root or not S.Bus.IsNearTank(player) then
			hint(player, st, "Подойдите к печи автобуса, чтобы закинуть: " .. item.name, ORANGE)
			return false
		end
		-- RefuelWith сам сообщает игроку результат; анимация — только при успехе
		local ok = S.Bus.RefuelWith(player, id)
		if ok then
			-- id предмета уходит клиенту: руки от первого лица берут по нему модель и звук
			broadcastAnim(player, "throw_in", id, 0.7, true)
		end
		return ok == true
	elseif cat == "buspart" then
		if not S.Bus.Root then
			hint(player, st, item.name .. ": прикрепляется к автобусу", GREY)
			return false
		end
		local ok = S.Bus.AttachItem(player, id)
		if ok then
			broadcastAnim(player, "attach", id, 0.8, true)
		end
		return ok == true
	elseif cat == "valuable" then
		local rarity = Items.Rarities[item.rarity] or Items.Rarities.common
		Net.Get("Toast"):FireClient(player, item.name, string.format("%s · продать за $%d у стойки «ПРОДАТЬ» или торговца", rarity.name, item.sell or 0), rarity.color)
		broadcastAnim(player, "inspect", id, 1.2, true)
		return true
	elseif cat == "ammo" then
		hint(player, st, item.name .. (item.desc and (" (" .. item.desc .. ")") or "") .. " — тратятся при перезарядке (R)")
		broadcastAnim(player, "inspect", id, 1, true)
		return true
	elseif cat == "material" and not (S.Bus.Root and S.Bus.IsNear(player, 25)) then
		hint(player, st, item.name .. ": " .. (item.desc or "материал"))
		broadcastAnim(player, "inspect", id, 1, true)
		return true
	elseif cat == "quest" then
		hint(player, st, item.name .. ": " .. (item.desc or "нужен для цели биома"))
		broadcastAnim(player, "inspect", id, 1, true)
		return true
	end
	-- еда, медицина, инструменты, укрепления, ремонт материалами — общая логика LootService
	-- (третий аргумент — слот: расходуется именно этот предмет)
	if S.Loot and S.Loot.UseItem then
		S.Loot.UseItem(player, id, index)
		WS.QueueRefresh(player)
		return true
	end
	return false
end

-- Использовать предмет из слота как из рук (InventoryAction "use", ЛКМ с предметом в руке)
function WS.UseSlot(player, index)
	index = math.floor(tonumber(index) or 0)
	if not isPlayer(player) or index < 1 or inLobby() then
		return false
	end
	local d = PD.Get(player)
	if not d or not PD.IsActive(player) then
		return false
	end
	local entry = slotEntry(player, d, index)
	if not entry then
		return false
	end
	if entry.kind == "weapon" then
		return WS.EquipSlot(player, index)
	end
	return useItem(player, d, entry, index)
end

-- Проверки и магазин ------------------------------------------------------------------------

local function ownsWeapon(d, tool, id)
	if d.Weapons and d.Weapons[id] then
		return true
	end
	local slot = tool:GetAttribute("Slot")
	local slots = type(d.Slots) == "table" and d.Slots or nil
	local e = slots and type(slot) == "number" and slots[slot]
	return type(e) == "table" and e.kind == "weapon" and e.id == id
end

-- Проверка, что игрок может использовать это оружие прямо сейчас
local function validTool(player, tool)
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") or inLobby() then
		return nil
	end
	local char = player.Character
	if not char or tool.Parent ~= char then
		return nil
	end
	local id = tool:GetAttribute("WeaponId")
	local def = WeaponDefs.List[id]
	local d = PD.Get(player)
	if not def or not d or d.Downed or d.Dead or isSleeping(player) then
		return nil
	end
	local hum = Util.AliveHumanoid(char)
	if not hum then
		return nil
	end
	if def.kind == "throw" then
		if PD.Count(player, def.item or id) <= 0 then
			return nil
		end
	elseif not ownsWeapon(d, tool, id) then
		return nil
	end
	return def, id, char, hum, d
end

-- Магазин хранится в записи слота (v4) и дублируется в d.Mags (совместимость) и атрибуте Mag
local function weaponEntry(d, tool, id)
	local slot = tool:GetAttribute("Slot")
	local slots = type(d.Slots) == "table" and d.Slots or nil
	local e = slots and type(slot) == "number" and slots[slot]
	if type(e) == "table" and e.kind == "weapon" and e.id == id then
		return e
	end
	return nil
end

local function getMag(d, tool, id)
	local e = weaponEntry(d, tool, id)
	if e then
		return math.max(0, math.floor(tonumber(e.mag) or 0))
	end
	return d.Mags and d.Mags[id] or 0
end

local function setMag(d, tool, id, value)
	local e = weaponEntry(d, tool, id)
	if e then
		e.mag = value
	end
	if d.Mags then
		d.Mags[id] = value
	end
	tool:SetAttribute("Mag", value)
end

local function checkCooldown(st, id, cd)
	local now = os.clock()
	if now - (st.last[id] or 0) < cd * 0.8 then
		return false
	end
	st.last[id] = now
	return true
end

local function applySpread(dir, degrees)
	if degrees <= 0 then
		return dir
	end
	local angle = math.rad(degrees) * math.sqrt(rng:NextNumber())
	local spin = rng:NextNumber() * math.pi * 2
	local cf = CFrame.lookAt(Vector3.zero, dir)
	return (cf * CFrame.Angles(0, 0, spin) * CFrame.Angles(angle, 0, 0)).LookVector
end

-- Направление прицела от клиента (точка aim): разумное расстояние и не за спиной персонажа
-- (в первом лице персонаж повёрнут за камерой). Иначе — запасное направление.
-- Единичный вектор вместо точки (старые клиенты, тестовые пробы) принимается как направление:
-- иначе выстрел уходил бы к началу координат мира.
local function aimDirection(char, origin, aim, fallback)
	if typeof(aim) == "Vector3" then
		local delta = aim - origin
		local aimMag = aim.Magnitude
		if aimMag > 0.98 and aimMag < 1.02 and delta.Magnitude > 4 then
			delta = aim
		end
		local mag = delta.Magnitude
		if mag == mag and mag > 0.3 and mag < 5000 then
			local dir = delta / mag
			local root = char:FindFirstChild("HumanoidRootPart")
			local look = root and Util.Flat(root.CFrame.LookVector)
			local flat = Util.Flat(dir)
			if not look or look.Magnitude < 0.01 or flat.Magnitude < 0.05 or look.Unit:Dot(flat.Unit) > -0.25 then
				return dir
			end
		end
	end
	return fallback
end

local function muzzlePosition(tool, fallback)
	local handle = tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	if muzzle then
		return muzzle.WorldPosition
	end
	return fallback
end

local function folderList(names)
	local list = {}
	for _, name in ipairs(names) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

local function addCharacters(list)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(list, plr.Character)
		end
	end
	return list
end

-- Пули пролетают сквозь добычу, эффекты, игроков, автобус (стреляют из салона) и укрепления
local function shotExcludeList()
	local exclude = addCharacters(folderList({ "Loot", "Effects", "Placeables" }))
	if S.Bus.Model then
		table.insert(exclude, S.Bus.Model)
	end
	return exclude
end

-- Ближний бой задевает всё, кроме игроков, добычи и эффектов; зомби считаются отдельно
local function meleeExcludeList()
	return addCharacters(folderList({ "Loot", "Effects", "Zombies" }))
end

local function rayParams(exclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return params
end

-- Разрушаемые объекты и толчки ----------------------------------------------------------------

-- Модель-предок с атрибутом Breakable = true
local function breakableOf(part)
	local cur = part and part.Parent
	while cur and cur ~= workspace do
		if cur:IsA("Model") and cur:GetAttribute("Breakable") == true then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

-- Урон завалу через Props. Возвращает destroyed, kind
local function damageBreakable(model, amount, player)
	local props = S.Props
	if not props or type(props.DamageBreakable) ~= "function" or not model.Parent or amount <= 0 then
		return false, nil
	end
	local ok, destroyed, kind = pcall(props.DamageBreakable, model, amount, player)
	if not ok then
		warnOnce("DamageBreakable", destroyed)
		return false, nil
	end
	kind = WeaponDefs.ValidKind(kind)
	if kind == "flesh" or kind == "air" then
		kind = nil
	end
	return destroyed == true, kind
end

-- Ближайшая к точке точка детали
local function closestPoint(part, point)
	local rel = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	return part.CFrame:PointToWorldSpace(Vector3.new(
		math.clamp(rel.X, -half.X, half.X),
		math.clamp(rel.Y, -half.Y, half.Y),
		math.clamp(rel.Z, -half.Z, half.Z)
	))
end

-- Толчок незакреплённой детали (мусор, обломки, ящики). Персонажей, зомби и автобус не двигаем.
local function pushPart(part, dir, strength, position)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part.Anchored or strength <= 0 then
		return
	end
	if S.Bus.Model and part:IsDescendantOf(S.Bus.Model) then
		return
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end
	local root = part.AssemblyRootPart
	if root and root.Anchored then
		return
	end
	local mass = part.AssemblyMass
	if not (mass > 0) or mass > 800 then
		return
	end
	local ok, err = pcall(function()
		part:ApplyImpulseAtPosition(dir * strength * math.min(mass, 40), position)
	end)
	if not ok then
		warnOnce("ApplyImpulse", err)
	end
end

local KIND_RANK = { flesh = 3, metal = 2, wood = 2, stone = 2, glass = 2, dirt = 1, air = 0 }

-- Щит элиты спереди звенит металлом
local function zombieHitKind(z, fromDir)
	local shield = type(z.def) == "table" and z.def.shield
	if shield and z.root then
		local zl = Util.Flat(z.root.CFrame.LookVector)
		if zl.Magnitude > 0.01 and zl.Unit:Dot(-fromDir) > (shield.dot or 0.35) then
			return "metal"
		end
	end
	return "flesh"
end

-- Нет ли стены между головой игрока и зомби (достаточно видеть голову или корпус)
local function clearLine(origin, targets, radius, params)
	for _, part in ipairs(targets) do
		if part and part.Parent then
			local to = part.Position - origin
			local dist = to.Magnitude
			if dist < 0.5 then
				return true
			end
			local hit = workspace:Raycast(origin, to, params)
			if not hit or (hit.Position - origin).Magnitude >= dist - radius - 0.4 then
				return true
			end
		end
	end
	return false
end

-- Ближний бой ------------------------------------------------------------------------------

-- Удар из головы по взгляду: зомби в дуге (с прямой видимостью), завалы, любая поверхность.
local function meleeStrike(player, def, id, origin, dir, flatDir, mult, finisher, seq)
	local range = def.range
	local cosHalf = math.cos(math.rad(math.min(def.arc, 359) / 2))
	local hits, primary = {}, nil
	local function addHit(pos, kind, dist, normal)
		if #hits < MAX_FX_HITS then
			table.insert(hits, { pos = pos, kind = kind, normal = normal })
		end
		local rank = KIND_RANK[kind] or 1
		if not primary or rank > primary.rank or (rank == primary.rank and dist < primary.dist) then
			primary = { pos = pos, kind = kind, dist = dist, rank = rank, normal = normal }
		end
	end
	local exclude = meleeExcludeList()
	local params = rayParams(exclude)

	-- 1. зомби
	local zombieHits = 0
	for _, z in ipairs(S.Zombies.List()) do
		if not z.dead and z.root and z.root.Parent then
			local center = z.root.Position
			local offset = center - origin
			local flat = Util.Flat(offset)
			local radius = z.radius or 1.2
			local dist = flat.Magnitude - radius
			if dist <= range and math.abs(center.Y - (origin.Y - 1.5)) < 6 + radius then
				local inArc = def.arc >= 360 or flat.Magnitude < 2 or flat.Unit:Dot(flatDir) >= cosHalf
				if inArc and clearLine(origin, z.head and { z.head, z.root } or { z.root }, radius, params) then
					local knockDir = flat.Magnitude > 0.1 and flat.Unit or flatDir
					local hitPos = center - knockDir * math.min(radius, flat.Magnitude) * 0.7 + Vector3.new(0, 0.8, 0)
					addHit(hitPos, zombieHitKind(z, knockDir), math.max(0, dist), -knockDir)
					zombieHits = zombieHits + 1
					S.Combat.DamageZombie(z, def.damage * mult, {
						attacker = player,
						kind = finisher and "crit" or "normal",
						knockDir = knockDir,
						knockback = (def.knockback or 0) * (finisher and 1.4 or 1),
						stun = def.stun,
						weapon = id,
					})
				end
			end
		end
	end

	-- 2. поверхность по взгляду: сфера вдоль луча (у самой стены — обычный луч)
	local surface
	local okCast, cast = pcall(function()
		return workspace:Spherecast(origin, MELEE_RADIUS, dir * range, params)
	end)
	if okCast and cast then
		surface = cast
	else
		surface = workspace:Raycast(origin, dir * range, params)
	end

	-- 3. разрушаемые завалы: попавший по взгляду и все в дуге удара
	local candidates = {}
	if surface then
		local model = breakableOf(surface.Instance)
		if model then
			candidates[model] = { part = surface.Instance, pos = surface.Position, dist = (surface.Position - origin).Magnitude, normal = surface.Normal }
		end
	end
	local base = origin - Vector3.new(0, 1.5, 0)
	local reach = def.aoe or range
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = exclude
	overlap.MaxParts = 80
	local okQuery, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(base, reach + 6, overlap)
	end)
	if okQuery and type(parts) == "table" then
		for _, part in ipairs(parts) do
			local model = breakableOf(part)
			if model then
				local cp = closestPoint(part, base)
				local off = cp - base
				local flat = Util.Flat(off)
				if flat.Magnitude <= reach and math.abs(off.Y) < 7 then
					local inArc = def.arc >= 360 or flat.Magnitude < 2.5 or flat.Unit:Dot(flatDir) >= cosHalf
					local prev = candidates[model]
					if inArc and (not prev or flat.Magnitude < prev.dist) then
						candidates[model] = { part = part, pos = cp, dist = flat.Magnitude }
					end
				end
			end
		end
	end
	local ordered = {}
	for model, b in pairs(candidates) do
		b.model = model
		table.insert(ordered, b)
	end
	table.sort(ordered, function(a, b)
		return a.dist < b.dist
	end)
	local damaged = {}
	for i = 1, math.min(#ordered, MAX_BREAKABLES_PER_SWING) do
		local b = ordered[i]
		local _, kind = damageBreakable(b.model, def.damage * mult * (def.breakMult or 1), player)
		addHit(b.pos, kind or WeaponDefs.MaterialKind(b.part.Material), b.dist, b.normal)
		damaged[b.model] = true
	end

	-- 4. без зомби: удар о любую поверхность (эффект по материалу) и толчок незакреплённого
	if zombieHits == 0 and surface then
		local model = breakableOf(surface.Instance)
		if not (model and damaged[model]) then
			addHit(surface.Position, WeaponDefs.SurfaceKind(surface.Instance, surface.Material), (surface.Position - origin).Magnitude, surface.Normal)
		end
		pushPart(surface.Instance, dir, math.max(8, (def.knockback or 10) * 0.8), surface.Position)
	elseif zombieHits == 0 and not primary and def.aoe then
		local down = workspace:Raycast(origin + flatDir * 2, Vector3.new(0, -9, 0), params)
		if down then
			addHit(down.Position, WeaponDefs.SurfaceKind(down.Instance, down.Material), 2, down.Normal)
		end
	end

	-- seq — номер удара у клиента: атакующий сверяет его со своим предсказанием и не повторяет звук
	local info = {
		weaponId = id,
		attacker = player,
		heavy = finisher or def.heavy == true,
		dir = dir,
		hits = hits,
		seq = seq,
	}
	if primary then
		info.pos = primary.pos
		info.kind = primary.kind
		info.normal = primary.normal
	else
		info.pos = origin + dir * range * 0.6
		info.kind = "air"
	end
	sendHitFx(info)

	if def.aoe then
		local ground = workspace:Raycast(origin, Vector3.new(0, -9, 0), params)
		local at = ground and ground.Position or (origin - Vector3.new(0, 4.5, 0))
		Net.FireNear("Explosion", at, 300, at + Vector3.new(0, 0.1, 0), def.aoe, "slam")
	end
end

local function doMelee(player, tool, def, id, char, hum, d, data)
	local st = getState(player)
	local cooldown = def.cooldown * Recipes.WeaponCooldownMult(toolLevel(tool))
	if not checkCooldown(st, id, cooldown) then
		return
	end
	local now = os.clock()
	if now - (st.comboTime[id] or 0) > cooldown + 0.6 then
		st.combo[id] = 0
	end
	st.combo[id] = ((st.combo[id] or 0) % #def.combo) + 1
	st.comboTime[id] = now
	local index = st.combo[id]
	local finisher = #def.combo > 1 and index == #def.combo
	broadcastAnim(player, def.combo[index], id, cooldown)
	local aim = data.aim
	-- номер удара у клиента возвращается в HitFx: так атакующий не дублирует предсказанный звук
	local seq = (type(data.seq) == "number" and data.seq == data.seq) and math.floor(data.seq) or nil
	task.delay(def.hitDelay or 0.15, function()
		if not char.Parent or tool.Parent ~= char or d.Downed or d.Dead or hum.Health <= 0 then
			return
		end
		local head = char:FindFirstChild("Head")
		local root = char:FindFirstChild("HumanoidRootPart")
		if not head or not root then
			return
		end
		local origin = head.Position
		local look = root.CFrame.LookVector
		local dir = aimDirection(char, origin, aim, look)
		local flatDir = Util.Flat(dir)
		if flatDir.Magnitude < 0.05 then
			flatDir = Util.Flat(look)
		end
		if flatDir.Magnitude < 0.01 then
			return
		end
		local mult = PD.DamageMult(player, def)
		if finisher then
			mult = mult * (def.comboBonus or 1)
		end
		meleeStrike(player, def, id, origin, dir, flatDir.Unit, mult, finisher, seq)
	end)
end

-- Огнестрел --------------------------------------------------------------------------------

function WS.StartReload(player, tool)
	local def, id, _, _, d = validTool(player, tool)
	if not def or not def.mag then
		return
	end
	if tool:GetAttribute("Reloading") then
		return
	end
	local level = toolLevel(tool)
	local maxMag = Recipes.WeaponMagBonus(def.mag, level) or def.mag
	if getMag(d, tool, id) >= maxMag then
		return
	end
	if PD.Count(player, def.ammo) <= 0 then
		local ammo = Items.List[def.ammo]
		PD.Notify(player, "Нет патронов: " .. (ammo and ammo.name or tostring(def.ammo)), RED)
		return
	end
	local time = def.reload * Classes.Perk(d.ClassId, "reloadMult", 1) * Recipes.WeaponCooldownMult(level)
	tool:SetAttribute("Reloading", true)
	tool:SetAttribute("ReloadEnd", Util.Now() + time)
	broadcastAnim(player, "reload", id, time)
	task.delay(time, function()
		if not tool.Parent then
			return
		end
		tool:SetAttribute("Reloading", false)
		if tool.Parent ~= player.Character or d.Dead or not ownsWeapon(d, tool, id) then
			return
		end
		local cap = Recipes.WeaponMagBonus(def.mag, toolLevel(tool)) or def.mag
		local take = math.min(cap - getMag(d, tool, id), PD.Count(player, def.ammo))
		if take > 0 and PD.RemoveItem(player, def.ammo, take) then
			setMag(d, tool, id, getMag(d, tool, id) + take)
			PD.SyncInventory(player)
		end
	end)
end

local function doGun(player, tool, def, id, char, hum, d, data)
	local st = getState(player)
	if tool:GetAttribute("Reloading") then
		return
	end
	local cooldown = def.cooldown * Recipes.WeaponCooldownMult(toolLevel(tool))
	if not checkCooldown(st, id, cooldown) then
		return
	end
	local mag = getMag(d, tool, id)
	if mag <= 0 then
		WS.StartReload(player, tool)
		return
	end
	setMag(d, tool, id, mag - 1)

	local head = char:FindFirstChild("Head")
	if not head then
		return
	end
	local origin = head.Position
	local dir = aimDirection(char, origin, data.aim, head.CFrame.LookVector)
	local scoped = data.scoped == true
	local spread = scoped and (def.aimSpread or def.spread) or def.spread
	if hum.MoveDirection.Magnitude > 0.1 then
		spread = spread * 1.35
	end
	local mult = PD.DamageMult(player, def)
	local zombiesFolder = workspace:FindFirstChild("Zombies")
	local exclude = shotExcludeList()
	local ends = {}
	local fxHits = {}

	for _ = 1, def.pellets or 1 do
		local params = rayParams(exclude)
		local pdir = applySpread(dir, spread)
		local start = origin
		local remaining = def.range
		local pierceLeft = def.pierce or 1
		local endPos = origin + pdir * def.range
		for _ = 1, 10 do
			if remaining <= 0 then
				break
			end
			local result = workspace:Raycast(start, pdir * remaining, params)
			if not result then
				break
			end
			local zModel = zombiesFolder and Util.ModelIn(result.Instance, zombiesFolder)
			if zModel then
				params:AddToFilter(zModel)
				local z = S.Zombies.Active[zModel]
				-- зомби, уже добитый предыдущей дробиной (Died ещё не сработал), не поглощает дробь
				local alive = z ~= nil and not z.dead and z.humanoid ~= nil and z.humanoid.Health > 0
				if alive then
					local dmg = def.damage * mult
					local kind = "normal"
					if result.Instance.Name == "Head" then
						dmg = dmg * (def.headshot or 1)
						kind = "headshot"
					end
					local traveled = (result.Position - origin).Magnitude
					if def.pellets and traveled > 40 then
						dmg = dmg * math.max(0.35, 1 - (traveled - 40) / 80)
					end
					S.Combat.DamageZombie(z, dmg, {
						attacker = player,
						kind = kind,
						position = result.Position,
						knockDir = pdir,
						knockback = def.knockback,
						weapon = id,
					})
					if #fxHits < MAX_FX_HITS then
						table.insert(fxHits, { pos = result.Position, kind = zombieHitKind(z, pdir), normal = result.Normal })
					end
					pierceLeft = pierceLeft - 1
					if pierceLeft <= 0 then
						endPos = result.Position
						break
					end
				end
				remaining = remaining - (result.Position - start).Magnitude
				start = result.Position
			else
				endPos = result.Position
				local model = breakableOf(result.Instance)
				local kind
				if model then
					local _, bkind = damageBreakable(model, def.damage * mult * (def.breakMult or 0.25), player)
					kind = bkind
				end
				if #fxHits < MAX_FX_HITS then
					table.insert(fxHits, { pos = result.Position, kind = kind or WeaponDefs.SurfaceKind(result.Instance, result.Material), normal = result.Normal })
				end
				pushPart(result.Instance, pdir, (def.knockback or 6) * 0.6 + 4, result.Position)
				break
			end
		end
		table.insert(ends, endPos)
	end

	local muzzle = muzzlePosition(tool, origin)
	local tracer = Net.Get("Tracer")
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			tracer:FireClient(other, muzzle, ends, id)
		end
	end
	if #fxHits > 0 then
		sendHitFx({
			pos = fxHits[1].pos,
			kind = fxHits[1].kind,
			weaponId = id,
			attacker = player,
			hits = fxHits,
			dir = dir,
			gun = true,
		})
	end
	broadcastAnim(player, "recoil", id, cooldown)
	-- выстрел слышно: зомби рядом сбегаются
	S.Zombies.Alert(origin, def.id == "sniper" and 130 or 90)
end

-- Попадание стрелы/болта: ProjectileService передаёт деталь и вид поверхности. Урон завалу,
-- толчок незакреплённого, эффект попадания. pierce — прошил насквозь и полетел дальше.
local function projectileImpact(player, id, damage, breakMult, pierce)
	return function(position, normal, hitPart, kind)
		if typeof(position) ~= "Vector3" then
			return
		end
		local n = (typeof(normal) == "Vector3" and normal.Magnitude > 0.1) and normal.Unit or Vector3.yAxis
		kind = WeaponDefs.ValidKind(kind)
		if kind ~= "flesh" and typeof(hitPart) == "Instance" and hitPart:IsA("BasePart") then
			local model = breakableOf(hitPart)
			if model and player.Parent then
				local _, bkind = damageBreakable(model, damage * breakMult, player)
				kind = bkind or kind
			end
			kind = kind or WeaponDefs.SurfaceKind(hitPart, hitPart.Material)
			pushPart(hitPart, -n, 6, position)
		end
		if not kind then
			return -- время полёта истекло в воздухе: без эффекта
		end
		sendHitFx({ pos = position, kind = kind, weaponId = id, attacker = player, projectile = true, pierce = pierce, normal = n })
	end
end

-- Арбалет ----------------------------------------------------------------------------------
local function doCrossbow(player, tool, def, id, char, hum, d, data)
	local st = getState(player)
	if tool:GetAttribute("Reloading") then
		return
	end
	local cooldown = def.cooldown * Recipes.WeaponCooldownMult(toolLevel(tool))
	if not checkCooldown(st, id, cooldown) then
		return
	end
	local mag = getMag(d, tool, id)
	if mag <= 0 then
		WS.StartReload(player, tool)
		return
	end
	setMag(d, tool, id, mag - 1)
	local head = char:FindFirstChild("Head")
	if not head then
		return
	end
	local dir = aimDirection(char, head.Position, data.aim, head.CFrame.LookVector)
	local origin = muzzlePosition(tool, head.Position + dir * 2)
	local damage = def.damage * PD.DamageMult(player, def)
	S.Projectiles.Fire({
		kind = "bolt",
		origin = origin,
		velocity = dir * def.speed,
		gravity = def.gravity,
		owner = player,
		damage = damage,
		pierce = def.pierce,
		headshot = def.headshot,
		knockback = def.knockback,
		hitsZombies = true,
		weaponId = id,
		onImpact = projectileImpact(player, id, damage, def.breakMult or 0.4),
		onPierce = projectileImpact(player, id, damage, def.breakMult or 0.4, true),
	})
	broadcastAnim(player, "recoil", id, cooldown)
	task.delay(0.3, function()
		if tool.Parent == char and hum.Health > 0 and getMag(d, tool, id) <= 0 then
			WS.StartReload(player, tool)
		end
	end)
end

-- Лук: натяжение начинается по нажатию, выстрел по отпусканию ----------------------------------
local function startDraw(player, tool, def, id, d)
	local st = getState(player)
	if os.clock() - (st.last[id] or 0) < def.cooldown * Recipes.WeaponCooldownMult(toolLevel(tool)) * 0.8 then
		return
	end
	if PD.Count(player, def.ammo) <= 0 then
		PD.Notify(player, "Нет стрел", RED)
		return
	end
	st.drawStart = os.clock()
	st.drawTool = tool
	broadcastAnim(player, "bow_draw", id, def.drawTime * Classes.Perk(d.ClassId, "drawMult", 1))
end

local function releaseBow(player, tool, data)
	local st = getState(player)
	if st.drawTool ~= tool or not st.drawStart then
		return
	end
	data = type(data) == "table" and data or {}
	-- отмена натяжения (окно, обморок, сон, смена предмета): без выстрела и расхода стрел.
	-- Анимацию снимаем до validTool — он отказывает лежачим/спящим/убравшим лук.
	if data.cancel then
		st.drawStart = nil
		st.drawTool = nil
		broadcastAnim(player, "bow_release", tool:GetAttribute("WeaponId"), 0.3)
		return
	end
	local def, id, char, _, d = validTool(player, tool)
	local started = st.drawStart
	st.drawStart = nil
	st.drawTool = nil
	if not def or def.kind ~= "bow" then
		return
	end
	st.last[id] = os.clock()
	local drawTime = def.drawTime * Classes.Perk(d.ClassId, "drawMult", 1)
	local charge = math.clamp((os.clock() - started) / drawTime, 0, 1)
	broadcastAnim(player, "bow_release", id, 0.3)
	if charge < 0.15 then
		return
	end
	if not PD.RemoveItem(player, def.ammo, 1) then
		return
	end
	local head = char:FindFirstChild("Head")
	if not head then
		return
	end
	local dir = aimDirection(char, head.Position, data.aim, head.CFrame.LookVector)
	local damage = Util.Lerp(def.damageMin, def.damageMax, charge ^ 1.4) * PD.DamageMult(player, def)
	local speed = Util.Lerp(def.speedMin, def.speedMax, charge)
	S.Projectiles.Fire({
		kind = "arrow",
		origin = head.Position + dir * 2,
		velocity = dir * speed,
		gravity = def.gravity,
		owner = player,
		damage = damage,
		pierce = def.pierce,
		headshot = def.headshot,
		knockback = def.knockback,
		hitsZombies = true,
		weaponId = id,
		critKind = charge >= 0.98 and "crit" or nil,
		onImpact = projectileImpact(player, id, damage, def.breakMult or 0.4),
		onPierce = projectileImpact(player, id, damage, def.breakMult or 0.4, true),
	})
end

-- Бросок (бутылка из активного слота) ---------------------------------------------------------
local function doThrow(player, tool, def, id, char, hum, d, data)
	local st = getState(player)
	if not checkCooldown(st, id, def.cooldown) then
		return
	end
	local itemId = def.item or id
	local consumed = false
	local slot = tool:GetAttribute("Slot")
	local consumeActive = pdApi("ConsumeActive")
	if consumeActive and type(slot) == "number" and activeIndex(player) == slot then
		local ok, result = pcall(consumeActive, player, 1)
		consumed = ok and result == true
	end
	if not consumed then
		consumed = PD.RemoveItem(player, itemId, 1, true) == true
	end
	if not consumed then
		return
	end
	broadcastAnim(player, "throw", id, 0.5)
	WS.QueueRefresh(player)
	local head = char:FindFirstChild("Head")
	if not head or hum.Health <= 0 then
		return
	end
	local dir = aimDirection(char, head.Position, data.aim, head.CFrame.LookVector)
	S.Projectiles.Fire({
		kind = "molotov",
		origin = head.Position + dir * 2 + Vector3.new(0, 0.5, 0),
		velocity = dir * def.speed + Vector3.new(0, 16, 0),
		gravity = def.gravity,
		owner = player,
		damage = 10,
		pierce = 1,
		hitsZombies = true,
		maxTime = 5,
		onImpact = function(position)
			S.Combat.FireZone(position, def.radius, def.burnDps, def.burnTime, player)
			Net.FireNear("Explosion", position, 400, position, def.radius, "fire")
		end,
	})
end

-- ЛКМ с инструментом в руке: оружие — атака, предмет — использование
local function onAttack(player, tool, data)
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then
		return
	end
	if type(data) ~= "table" then
		data = {}
	end
	local char = player.Character
	if inLobby() or not char or tool.Parent ~= char then
		return
	end
	local weaponId = tool:GetAttribute("WeaponId")
	if tool:GetAttribute("ItemKind") == "item" and not WeaponDefs.List[weaponId] then
		local slot = tool:GetAttribute("Slot")
		if type(slot) == "number" then
			WS.UseSlot(player, slot)
		end
		return
	end
	local def, id, _, hum, d = validTool(player, tool)
	if not def then
		return
	end
	if def.kind == "melee" then
		doMelee(player, tool, def, id, char, hum, d, data)
	elseif def.kind == "gun" then
		doGun(player, tool, def, id, char, hum, d, data)
	elseif def.kind == "bow" then
		startDraw(player, tool, def, id, d)
	elseif def.kind == "crossbow" then
		doCrossbow(player, tool, def, id, char, hum, d, data)
	elseif def.kind == "throw" then
		doThrow(player, tool, def, id, char, hum, d, data)
	end
end

-- Выбрасывание и передача оружия (совместимость; в v4 основной путь — InventoryAction) ---------

local function rootOf(player)
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function transferAllowed(player)
	local st = getState(player)
	local now = os.clock()
	if now - (st.lastTransfer or 0) < 0.35 then
		return false
	end
	st.lastTransfer = now
	return true
end

function WS.DropWeapon(player, weaponId)
	if type(weaponId) ~= "string" or inLobby() then
		return
	end
	local def = WeaponDefs.List[weaponId]
	local d = PD.Get(player)
	if not def or def.kind == "throw" or not d or not d.Weapons[weaponId] then
		return
	end
	if not PD.IsActive(player) or not transferAllowed(player) then
		return
	end
	local cf, surface = S.Loot.GroundCFrame(player, 3)
	if not cf then
		return
	end
	local info = PD.RemoveWeapon(player, weaponId)
	if not info then
		return
	end
	local model = S.Loot.SpawnWeapon(weaponId, cf, workspace:FindFirstChild("Loot"), {
		level = info.level,
		mag = info.mag,
		dropped = true,
	})
	if model and surface then
		S.Loot.AttachToSurface(model, surface)
	end
	PD.Notify(player, "Выброшено: " .. WS.DisplayName(weaponId, info.level), GREY)
end

function WS.GiveWeapon(player, target, weaponId)
	if type(weaponId) ~= "string" or not isPlayer(target) or target == player or inLobby() then
		return
	end
	local def = WeaponDefs.List[weaponId]
	local d = PD.Get(player)
	local td = PD.Get(target)
	if not def or def.kind == "throw" or not d or not td or not d.Weapons[weaponId] then
		return
	end
	if not PD.IsActive(player) or not transferAllowed(player) then
		return
	end
	if not PD.IsActive(target) then
		PD.Notify(player, target.DisplayName .. " сейчас не может принять оружие", RED)
		return
	end
	local a, b = rootOf(player), rootOf(target)
	if not a or not b or (a.Position - b.Position).Magnitude > GIVE_DISTANCE then
		PD.Notify(player, "Подойдите ближе к " .. target.DisplayName, RED)
		return
	end
	if td.Weapons[weaponId] then
		PD.Notify(player, "У " .. target.DisplayName .. " уже есть " .. def.name, RED)
		return
	end
	local info = PD.RemoveWeapon(player, weaponId)
	if not info then
		return
	end
	local name = WS.DisplayName(weaponId, info.level)
	if PD.GiveWeapon(target, weaponId, info) then
		PD.Notify(player, "Вы передали " .. target.DisplayName .. ": " .. name, GREEN)
		PD.Notify(target, player.DisplayName .. " передал(а) вам: " .. name, GREEN)
	else
		-- не получилось — возвращаем владельцу
		PD.GiveWeapon(player, weaponId, info)
	end
end

-- После обморока/сна снова взять в руки активный слот (2 Гц)
local restoreAcc = 0
local function updateRestore(dt)
	restoreAcc = restoreAcc + dt
	if restoreAcc < 0.5 then
		return
	end
	restoreAcc = 0
	if not S.Run or S.Run.Mode ~= "run" then
		return
	end
	for player, st in pairs(states) do
		local d = player.Parent and PD.Get(player)
		if d then
			if d.Downed or isSleeping(player) then
				st.restoreActive = true
			elseif st.restoreActive then
				st.restoreActive = false
				local index = activeIndex(player)
				local char = player.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if index and index > 0 and hum and hum.Health > 0 and not d.Dead and not char:FindFirstChildOfClass("Tool") then
					WS.EquipSlot(player, index)
				end
			end
		end
	end
end

function WS.Init(services)
	S = services
	PD = S.PlayerData
	Net.Get("Attack").OnServerEvent:Connect(onAttack)
	Net.Get("Release").OnServerEvent:Connect(function(player, tool, data)
		if typeof(tool) == "Instance" then
			releaseBow(player, tool, data)
		end
	end)
	Net.Get("Reload").OnServerEvent:Connect(function(player, tool)
		WS.StartReload(player, tool)
	end)
	-- угол прицела и режим прицеливания (для поз оружия у других игроков)
	Net.Get("AimPitch").OnServerEvent:Connect(function(player, pitch, aiming)
		if type(pitch) == "number" and pitch == pitch then
			local char = player.Character
			if char then
				char:SetAttribute("AimPitch", math.clamp(pitch, -80, 80))
				char:SetAttribute("Aiming", aiming == true)
			end
		end
	end)
	Net.Get("DropWeapon").OnServerEvent:Connect(function(player, weaponId)
		WS.DropWeapon(player, weaponId)
	end)
	Net.Get("GiveWeapon").OnServerEvent:Connect(function(player, target, weaponId)
		WS.GiveWeapon(player, target, weaponId)
	end)

	local function onPlayer(player)
		player.CharacterAdded:Connect(function(char)
			hookCharacter(player, char)
		end)
		if player.Character then
			hookCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local st = states[player]
		if st then
			for _, conn in ipairs(st.charConns) do
				conn:Disconnect()
			end
		end
		states[player] = nil
	end)
	RunService.Heartbeat:Connect(updateRestore)
end

return WS
