-- Магазин (v3): вкладки Продать / Припасы / Материалы / Детали / Патроны / Оружие, ремонт автобуса за
-- деньги и выбор класса (в лобби — только запоминается, в депо до отправления — смена набора).
-- v5: набор класса — PlayerData.ClassKit (со стартовым набором для проверки); купленный переносимый
-- объект (колесо, стена) появляется на земле рядом с игроком.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local WeaponDefs = require(Shared.Weapons)
local Classes = require(Shared.Classes)
local Net = require(Shared.Net)

local Shop = {}
local S
local PD
local lastAction = {}

local GREEN = Color3.fromRGB(120, 230, 120)
local RED = Color3.fromRGB(255, 110, 100)

-- Вкладки магазина с предметами из Items.Shop (сам товар ищется по всем спискам)
local ITEM_CATEGORIES = { item = true, supplies = true, materials = true, parts = true, part = true, ammo = true }

local function findShopItem(id)
	for _, list in pairs(Items.Shop) do
		for _, e in ipairs(list) do
			if e.id == id then
				return e
			end
		end
	end
	return nil
end

local function throttled(player)
	local now = os.clock()
	if now - (lastAction[player] or 0) < 0.12 then
		return true
	end
	lastAction[player] = now
	return false
end

-- возврат денег без учёта в статистике «заработано»
local function refund(player, amount)
	local d = PD.Get(player)
	if d and amount > 0 then
		d.Money = d.Money + amount
		player:SetAttribute("Money", d.Money)
	end
end

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

local function buy(player, category, id)
	if not PD.IsActive(player) or throttled(player) then
		return
	end
	if not S.Stations.NearTrader(player) then
		PD.Notify(player, "Подойдите к торговцу", RED)
		return
	end
	if ITEM_CATEGORIES[category] then
		local entry = findShopItem(id)
		local item = Items.List[id]
		if not entry or not item then
			return
		end
		-- переносимый объект (колесо, стена — Items grab) появляется на земле рядом с игроком, а не в слотах
		local spawnNear = isGrabItem(id) and lootFn("SpawnGrabNear") or nil
		if spawnNear and not S.Loot.GroundCFrame(player, 3) then
			return
		end
		if not PD.SpendMoney(player, entry.price) then
			PD.Notify(player, "Не хватает денег", RED)
			return
		end
		if spawnNear then
			if not spawnNear(player, id, item.pack or 1) then
				refund(player, entry.price)
				PD.Notify(player, "Некуда положить покупку — деньги возвращены", RED)
				return
			end
			PD.Notify(player, "Куплено: " .. item.name .. " — лежит рядом: возьмите (ЛКМ) и прикрепите к автобусу (Z)", GREEN)
		else
			PD.AddItem(player, id, item.pack or 1)
			if item.wall then
				PD.Notify(player, "Куплено: " .. item.name .. " — поставьте её в пустой проём автобуса", GREEN)
			elseif item.cat == "buspart" then
				PD.Notify(player, "Куплено: " .. item.name .. " — прикрепите деталь к автобусу", GREEN)
			else
				PD.Notify(player, "Куплено: " .. item.name, GREEN)
			end
		end
	elseif category == "weapon" then
		local def = WeaponDefs.List[id]
		if not def or not def.price or def.price <= 0 or def.kind == "throw" then
			return
		end
		local d = PD.Get(player)
		if not d then
			return
		end
		if d.Weapons[id] then
			PD.Notify(player, "У вас уже есть " .. def.name, RED)
			return
		end
		-- оружие занимает целый слот: без свободного слота деньги не списываем
		if not PD.FindFreeSlot(player) then
			PD.Notify(player, "Инвентарь полон — освободите слот", RED)
			return
		end
		if not PD.SpendMoney(player, def.price) then
			PD.Notify(player, "Не хватает денег", RED)
			return
		end
		PD.GiveWeapon(player, id)
		PD.Notify(player, "Куплено оружие: " .. def.name, GREEN)
	elseif category == "upgrade" then
		PD.Notify(player, "Улучшений автобуса больше нет: купите или изготовьте деталь и прикрепите её к автобусу", RED)
	elseif category == "repair" then
		if not S.Bus.Root then
			PD.Notify(player, "Автобуса сейчас нет", RED)
			return
		end
		if S.Bus.HP >= S.Bus.MaxHP then
			PD.Notify(player, "Автобус цел", RED)
			return
		end
		if not PD.SpendMoney(player, Items.RepairService.price) then
			PD.Notify(player, "Не хватает денег", RED)
			return
		end
		S.Bus.Repair(Items.RepairService.hp)
		PD.NotifyAll(player.DisplayName .. " оплатил(а) ремонт автобуса", GREEN)
	end
end

local function sell(player, id, count)
	if not PD.IsActive(player) or throttled(player) or not S.Stations.NearTrader(player) then
		return
	end
	local item = Items.List[id]
	if not item or (item.sell or 0) <= 0 then
		return
	end
	if id == "bus_wheel" and S.Bus.Root and (S.Bus.Wheels or 0) < 4 then
		PD.Notify(player, "Колёса нужны автобусу — сначала прикрепите все четыре", RED)
		return
	end
	local have = PD.Count(player, id)
	if have <= 0 then
		return
	end
	count = tonumber(count) or 1
	if count ~= count then
		return
	end
	count = math.clamp(math.floor(count), 1, have)
	if PD.RemoveItem(player, id, count) then
		local total = item.sell * count
		PD.AddMoney(player, total)
		PD.Notify(player, string.format("Продано: %s x%d  +$%d", item.name, count, total), GREEN)
	end
end

local function sellAll(player)
	if not PD.IsActive(player) or throttled(player) or not S.Stations.NearTrader(player) then
		return
	end
	local d = PD.Get(player)
	if not d then
		return
	end
	local total = 0
	local toSell = {}
	for id, count in pairs(d.Inventory) do
		local item = Items.List[id]
		if item and item.cat == "valuable" and count > 0 then
			toSell[id] = count
		end
	end
	for id, count in pairs(toSell) do
		if PD.RemoveItem(player, id, count) then
			total = total + Items.List[id].sell * count
		end
	end
	if total > 0 then
		PD.AddMoney(player, total)
		PD.Notify(player, "Все ценности проданы: +$" .. total, GREEN)
	else
		PD.Notify(player, "Нечего продавать", RED)
	end
end

-- Выбор класса -------------------------------------------------------------------------
-- Стартовый набор выдаётся один раз: PD.ApplyClass (вход игрока, ResetForRun) создаёт новые
-- таблицы d.Inventory/d.Weapons и кладёт полный набор класса d.ClassId. Смена класса в депо
-- не вызывает ApplyClass (он обнулил бы покупки и вернул бы проданный набор), а меняет
-- набор на набор: забирает выданное прежним классом и выдаёт новое. Сменить класс можно,
-- только пока выданный набор цел — иначе продажа/выбрасывание набора и повторный выбор
-- давали бы бесконечные деньги и предметы.
local kits = {} -- [player] = { inv = d.Inventory, classId, items = {id = n}, weapons = {id, ...} }

local function currentKit(player, d)
	local rec = kits[player]
	-- новая таблица инвентаря = был ApplyClass (новый заезд/вход): выдан полный набор класса
	if rec and rec.inv == d.Inventory and rec.classId == d.ClassId then
		return rec
	end
	-- набор класса вместе со стартовым набором для проверки (Config.TestKit) — ровно то, что выдал ApplyClass
	local kit = PD.ClassKit(d.ClassId)
	rec = { inv = d.Inventory, classId = kit.id, items = kit.items, weapons = kit.weapons }
	kits[player] = rec
	return rec
end

local function missingKitPart(d, rec)
	for id, n in pairs(rec.items) do
		if (d.Inventory[id] or 0) < n then
			local item = Items.List[id]
			return item and item.name or id
		end
	end
	for _, w in ipairs(rec.weapons) do
		if not d.Weapons[w] then
			return WeaponDefs.List[w] and WeaponDefs.List[w].name or w
		end
	end
	return nil
end

local function selectClass(player, classId)
	if type(classId) ~= "string" or not Classes.List[classId] then
		return
	end
	if throttled(player) then
		return
	end
	local d = PD.Get(player)
	if not d then
		return
	end
	-- Лобби: только запоминаем выбор. Набор класса выдаст ResetForRun в начале заезда;
	-- инструменты в лобби не выдаются (RefreshTools здесь не вызываем)
	if S.Run.Mode == "lobby" then
		local c = Classes.Get(classId)
		if d.ClassId == c.id then
			PD.Notify(player, "Этот класс уже выбран", GREEN)
			return
		end
		d.ClassId = c.id
		player:SetAttribute("ClassId", c.id)
		kits[player] = nil
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			local maxHP = PD.MaxHP(player)
			local frac = hum.MaxHealth > 0 and math.clamp(hum.Health / hum.MaxHealth, 0, 1) or 1
			hum.MaxHealth = maxHP
			hum.Health = math.max(1, maxHP * frac)
		end
		PD.Notify(player, "Класс выбран: " .. c.name .. ". Стартовый набор выдадут в начале заезда", GREEN)
		return
	end
	if S.Run.State ~= "Depot" or (S.Bus.S or 0) > Config.DepotLength then
		PD.Notify(player, "Класс выбирается в лобби или в депо до отправления", RED)
		return
	end
	if d.Dead or d.Downed then
		return
	end
	if d.ClassId == classId then
		PD.Notify(player, "Этот класс уже выбран", GREEN)
		return
	end
	local rec = currentKit(player, d)
	local missing = missingKitPart(d, rec)
	if missing then
		PD.Notify(player, "Класс можно сменить, только пока стартовый набор цел (не хватает: " .. missing .. ")", RED)
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local oldMax = PD.MaxHP(player)
	-- забрать набор прежнего класса (купленное и найденное остаётся)
	for id, n in pairs(rec.items) do
		PD.RemoveItem(player, id, n)
	end
	for _, w in ipairs(rec.weapons) do
		-- улучшенное на верстаке оружие остаётся у игрока: за улучшение заплачено
		if d.Weapons[w] and PD.GetWeaponLevel(player, w) <= 0 then
			PD.RemoveWeapon(player, w)
		end
	end
	-- выдать набор нового класса (со стартовым набором для проверки, если он включён);
	-- оружие первым — чтобы оно заняло хотбар раньше предметов, как при ApplyClass
	local c = Classes.Get(classId)
	local kit = PD.ClassKit(c.id)
	d.ClassId = c.id
	player:SetAttribute("ClassId", c.id)
	local newRec = { inv = d.Inventory, classId = c.id, items = {}, weapons = {} }
	for _, w in ipairs(kit.weapons) do
		-- уже имеющееся (купленное/улучшенное) оружие не выдаётся повторно и не заберётся при смене
		if PD.GiveWeapon(player, w) then
			table.insert(newRec.weapons, w)
		end
	end
	for id, n in pairs(kit.items) do
		if PD.AddItem(player, id, n) then
			newRec.items[id] = n
		end
	end
	kits[player] = newRec
	if hum and hum.Health > 0 then
		local maxHP = PD.MaxHP(player)
		local frac = oldMax > 0 and math.clamp(hum.Health / oldMax, 0, 1) or 1
		hum.MaxHealth = maxHP
		hum.Health = math.max(1, maxHP * frac)
		S.Weapons.RefreshTools(player)
	end
	PD.SyncInventory(player)
	PD.Notify(player, "Ваш класс: " .. c.name, GREEN)
end

function Shop.Init(services)
	S = services
	PD = S.PlayerData
	Net.Get("ShopBuy").OnServerEvent:Connect(function(player, category, id)
		if type(category) == "string" and type(id) == "string" then
			buy(player, category, id)
		end
	end)
	Net.Get("ShopSell").OnServerEvent:Connect(function(player, id, count)
		if type(id) == "string" then
			sell(player, id, count)
		end
	end)
	Net.Get("SellAll").OnServerEvent:Connect(sellAll)
	Net.Get("SelectClass").OnServerEvent:Connect(selectClass)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
		kits[player] = nil
	end)
end

return Shop
