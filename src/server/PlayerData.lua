-- Данные игроков (v4): инвентарь-слоты (хотбар «в руках» 1..10 + рюкзак 11..28), деньги, голод,
-- эффекты, класс, нокаут и возрождение. Бодрости, микроснов и обмороков больше нет.
-- Контракт — docs/SPEC_v4.md, 2.1. v5 (docs/SPEC_v5.md 2.4, 2.8): регенерация здоровья за счёт сытости,
-- набор класса со стартовым набором для проверки (PD.ClassKit), переносимые объекты не попадают в слоты.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local WeaponDefs = require(Shared.Weapons)
local Classes = require(Shared.Classes)
local StatusEffects = require(Shared.StatusEffects)
local Recipes = require(Shared.Recipes)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local PD = {}
local S
local data = {}
local rng = Random.new()

local GREEN = Color3.fromRGB(120, 230, 120)
local RED = Color3.fromRGB(255, 90, 90)
local YELLOW = Color3.fromRGB(255, 220, 90)
local GREY = Color3.fromRGB(200, 200, 200)

local INVENTORY = Config.Inventory or {}
local HOTBAR = INVENTORY.HotbarSlots or 10
local TOTAL = HOTBAR + (INVENTORY.BackpackSlots or 18)
PD.HotbarSlots = HOTBAR
PD.TotalSlots = TOTAL

function PD.Init(services)
	S = services
	Net.Get("Sprint").OnServerEvent:Connect(function(player, on)
		local d = data[player]
		if d then
			d.Sprint = on == true
		end
	end)
	Net.Get("SelfRevive").OnServerEvent:Connect(function(player)
		PD.TrySelfRevive(player)
	end)
	Net.Get("InventoryAction").OnServerEvent:Connect(function(player, action, payload)
		PD.HandleInventoryAction(player, action, payload)
	end)
end

function PD.Get(player)
	return data[player]
end

function PD.All()
	return data
end

function PD.Notify(player, text, color)
	Net.Get("Notify"):FireClient(player, text, color or Color3.new(1, 1, 1))
end

function PD.NotifyAll(text, color)
	Net.Get("Notify"):FireAllClients(text, color or Color3.new(1, 1, 1))
end

-- Инвентарь-слоты ------------------------------------------------------------
-- Источник правды — d.Slots. d.Inventory (id -> сумма), d.Weapons (id -> true), d.WeaponOrder,
-- d.WeaponLevels — производные, обновляются на месте; d.Mags — представление e.mag оружия в слотах.
-- Одно оружие каждого вида на игрока (как раньше).

local warned = {}
local function warnOnce(key, text)
	if not warned[key] then
		warned[key] = true
		warn("[PlayerData] " .. text)
	end
end

-- Необязательная функция другого сервиса (в его текущей версии её может не быть)
local function optional(service, name)
	local fn = service and service[name]
	return type(fn) == "function" and fn or nil
end

-- Целое из произвольного значения: nil для не-чисел, NaN и бесконечностей
local function toInt(v)
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.floor(v)
end

local function validSlot(i)
	i = toInt(i)
	if i and i >= 1 and i <= TOTAL then
		return i
	end
	return nil
end

function PD.StackSize(itemId)
	local item = Items.List[itemId]
	return item and math.max(1, math.floor(item.stack or 1)) or 1
end

local function weaponEntry(d, weaponId)
	for i = 1, TOTAL do
		local e = d.Slots[i]
		if e and e.kind == "weapon" and e.id == weaponId then
			return e, i
		end
	end
	return nil, nil
end

-- d.Mags[weaponId] читает и пишет e.mag оружия в слотах (старый код WeaponService работает как раньше)
local function makeMags(d)
	return setmetatable({}, {
		__index = function(_, weaponId)
			local e = weaponEntry(d, weaponId)
			return e and e.mag or nil
		end,
		__newindex = function(_, weaponId, value)
			local e = weaponEntry(d, weaponId)
			local n = toInt(value)
			if e and n then
				e.mag = math.max(0, n)
			end
		end,
	})
end

-- Обновить таблицу на месте (удаление ключей во время обхода допустимо, добавление — после)
local function syncMap(target, source)
	for k in pairs(target) do
		if source[k] == nil then
			target[k] = nil
		end
	end
	for k, v in pairs(source) do
		if target[k] ~= v then
			target[k] = v
		end
	end
end

local function rebuild(d)
	local counts, owned, levels, order = {}, {}, {}, {}
	for i = 1, TOTAL do
		local e = d.Slots[i]
		if e then
			if e.kind == "weapon" then
				if not owned[e.id] then
					owned[e.id] = true
					levels[e.id] = e.level or 0
					table.insert(order, e.id)
				end
			else
				counts[e.id] = (counts[e.id] or 0) + e.count
			end
		end
	end
	syncMap(d.Inventory, counts)
	syncMap(d.Weapons, owned)
	syncMap(d.WeaponLevels, levels)
	local list = d.WeaponOrder
	for i = #list, #order + 1, -1 do
		list[i] = nil
	end
	for i, id in ipairs(order) do
		list[i] = id
	end
end

-- Активный слот должен быть непустым слотом хотбара
local function fixActive(d)
	local a = d.Active
	if type(a) ~= "number" or a < 0 or a > HOTBAR or (a > 0 and not d.Slots[a]) then
		d.Active = 0
	end
end

-- Слоты для клиента: массив ровно из TOTAL элементов, пустой слот = false
-- (nil-дыры в массиве портят передачу таблицы через RemoteEvent)
local function slotsPayload(d)
	local out = {}
	for i = 1, TOTAL do
		local e = d.Slots[i]
		if not e then
			out[i] = false
		elseif e.kind == "weapon" then
			out[i] = { kind = "weapon", id = e.id, level = e.level or 0, mag = e.mag or 0 }
		else
			out[i] = { kind = "item", id = e.id, count = e.count }
		end
	end
	return out
end

-- Инструменты хотбара пересобирает WeaponService (один раз на пачку изменений)
local function flushTools(player, d)
	if not d.ToolsDirty then
		return
	end
	d.ToolsDirty = false
	if not player.Parent or not S.Weapons then
		return
	end
	local ok, err = pcall(S.Weapons.RefreshTools, player)
	if not ok then
		warnOnce("RefreshTools", "RefreshTools: " .. tostring(err))
	end
end

-- Событие Inventory: (countsMap, weaponOrder, weaponLevels, slots, active)
function PD.SyncInventory(player)
	local d = data[player]
	if not d or d.SyncQueued then
		return
	end
	d.SyncQueued = true
	task.defer(function()
		d.SyncQueued = false
		if not player.Parent or data[player] ~= d then
			return
		end
		flushTools(player, d)
		fixActive(d)
		Net.Get("Inventory"):FireClient(player, d.Inventory, d.WeaponOrder, d.WeaponLevels, slotsPayload(d), d.Active)
	end)
end

local function changed(player, d, hotbar)
	fixActive(d)
	rebuild(d)
	if hotbar then
		d.ToolsDirty = true
	end
	PD.SyncInventory(player)
end

local function firstEmpty(d, from, to)
	for i = from, to do
		if not d.Slots[i] then
			return i
		end
	end
	return nil
end

-- Положить предмет в слоты. pickup: стопки хотбара -> свободный хотбар -> стопки рюкзака -> свободный рюкзак;
-- иначе: стопки хотбара -> стопки рюкзака -> свободный хотбар -> свободный рюкзак.
-- Возвращает: сколько положено, слот (первый получивший в хотбаре, иначе первый вообще), затронут ли хотбар
local function insertItem(d, id, count, pickup)
	local stack = PD.StackSize(id)
	local left = count
	local firstHotbar, firstAny = nil, nil
	local function put(i)
		local e = d.Slots[i]
		local room = e and (stack - e.count) or stack
		local n = math.min(room, left)
		if n <= 0 then
			return
		end
		if e then
			e.count = e.count + n
		else
			d.Slots[i] = { kind = "item", id = id, count = n }
		end
		left = left - n
		firstAny = firstAny or i
		if i <= HOTBAR then
			firstHotbar = firstHotbar or i
		end
	end
	local function stacks(a, b)
		for i = a, b do
			if left <= 0 then
				return
			end
			local e = d.Slots[i]
			if e and e.kind == "item" and e.id == id and e.count < stack then
				put(i)
			end
		end
	end
	local function empties(a, b)
		for i = a, b do
			if left <= 0 then
				return
			end
			if not d.Slots[i] then
				put(i)
			end
		end
	end
	stacks(1, HOTBAR)
	if pickup then
		empties(1, HOTBAR)
		stacks(HOTBAR + 1, TOTAL)
	else
		stacks(HOTBAR + 1, TOTAL)
		empties(1, HOTBAR)
	end
	empties(HOTBAR + 1, TOTAL)
	return count - left, firstHotbar or firstAny, firstHotbar ~= nil
end

-- Выбросить на землю (entry: {kind="item", id, count} или {kind="weapon", id, level, mag}); cf — точка на земле
local function spawnDrop(player, entry, cf, surface)
	local loot = S.Loot
	if not loot then
		return nil
	end
	if not cf then
		cf, surface = loot.GroundCFrame(player, 3)
		if not cf then
			return nil
		end
	end
	local folder = workspace:FindFirstChild("Loot")
	local model
	if entry.kind == "weapon" then
		model = loot.SpawnWeapon(entry.id, cf, folder, { level = entry.level, mag = entry.mag, dropped = true })
	else
		model = loot.SpawnItem(entry.id, 1, cf, folder, nil, { amount = entry.count, dropped = true })
	end
	if model and surface then
		loot.AttachToSurface(model, surface)
	end
	return model
end

function PD.Count(player, id)
	local d = data[player]
	return d and (d.Inventory[id] or 0) or 0
end

-- Слоты игрока (не изменять снаружи — только через API ниже)
function PD.GetSlots(player)
	local d = data[player]
	return d and d.Slots or nil
end

-- -> index (0 — пустые руки), entry
function PD.GetActive(player)
	local d = data[player]
	if not d then
		return 0, nil
	end
	fixActive(d)
	if d.Active > 0 then
		return d.Active, d.Slots[d.Active]
	end
	return 0, nil
end

function PD.FindFreeHotbar(player)
	local d = data[player]
	return d and firstEmpty(d, 1, HOTBAR) or nil
end

-- Первый свободный слот: хотбар, затем рюкзак
function PD.FindFreeSlot(player)
	local d = data[player]
	return d and (firstEmpty(d, 1, HOTBAR) or firstEmpty(d, HOTBAR + 1, TOTAL)) or nil
end

-- Переносимый объект (Items grab: колёса, стены) в слоты не кладётся. Если в LootService нет этих
-- функций (старая версия модуля) — обычный предмет
local function isGrabItem(id)
	local isGrab = optional(S and S.Loot, "IsGrabItem")
	return isGrab ~= nil and isGrab(id) == true
end

-- Сколько штук предмета ещё поместится в слоты
function PD.SpaceFor(player, itemId)
	local d = data[player]
	-- переносимые объекты (колёса, стены) в слоты не кладутся
	if not d or not Items.List[itemId] or isGrabItem(itemId) then
		return 0
	end
	local stack = PD.StackSize(itemId)
	local n = 0
	for i = 1, TOTAL do
		local e = d.Slots[i]
		if not e then
			n = n + stack
		elseif e.kind == "item" and e.id == itemId then
			n = n + math.max(0, stack - e.count)
		end
	end
	return n
end

-- Добавить предметы. -> число положенных в слоты штук (0 — всё выпало на землю), число выпавших, слот.
-- false — неверные аргументы или предметы некуда деть. Не влезшее выпадает на землю у игрока.
-- opts: pickup (порядок подбора — сначала хотбар), noDrop (не влезшее не выбрасывать)
-- v5: переносимые объекты (Items grab — колёса, стены) в слоты не кладутся: появляются на земле рядом
-- с игроком (-> 0, count); с noDrop — false
function PD.AddItem(player, id, count, opts)
	local d = data[player]
	if not d or type(id) ~= "string" or not Items.List[id] then
		return false
	end
	if count == nil then
		count = 1
	end
	count = toInt(count)
	if not count or count < 1 then
		return false
	end
	opts = type(opts) == "table" and opts or {}
	if isGrabItem(id) then
		local spawnNear = optional(S.Loot, "SpawnGrabNear")
		if opts.noDrop or not spawnNear or not spawnNear(player, id, count) then
			return false
		end
		return 0, count, nil
	end
	local added, slot, hotbar = insertItem(d, id, count, opts.pickup == true)
	if added > 0 then
		changed(player, d, hotbar)
	end
	local left = count - added
	local dropped = 0
	if left > 0 and not opts.noDrop and S.Loot then
		local cf, surface = S.Loot.GroundCFrame(player, 2.5)
		if cf then
			cf = cf * CFrame.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-0.6, 0.6))
			if spawnDrop(player, { kind = "item", id = id, count = left }, cf, surface) then
				dropped = left
				PD.Notify(player, string.format("Инвентарь полон: %s x%d — на земле рядом", Items.List[id].name, left), YELLOW)
			end
		end
	end
	if added <= 0 and dropped <= 0 then
		return false
	end
	return added, dropped, slot
end

-- Забрать предметы: сначала из рюкзака, потом из хотбара, активный слот — последним.
-- preferActive = true — наоборот, сначала из активного слота (расход «из руки»)
function PD.RemoveItem(player, id, count, preferActive)
	local d = data[player]
	if count == nil then
		count = 1
	end
	count = toInt(count)
	if not count or count < 1 or not d or type(id) ~= "string" or (d.Inventory[id] or 0) < count then
		return false
	end
	fixActive(d)
	local left = count
	local hotbar = false
	local function take(i)
		local e = d.Slots[i]
		if left > 0 and e and e.kind == "item" and e.id == id then
			local n = math.min(e.count, left)
			e.count = e.count - n
			left = left - n
			if e.count <= 0 then
				d.Slots[i] = nil
			end
			if i <= HOTBAR then
				hotbar = true
			end
		end
	end
	local active = d.Active
	if preferActive == true and active > 0 then
		take(active)
	end
	for i = TOTAL, HOTBAR + 1, -1 do
		take(i)
	end
	for i = HOTBAR, 1, -1 do
		if i ~= active then
			take(i)
		end
	end
	if active > 0 then
		take(active)
	end
	changed(player, d, hotbar)
	return true
end

-- Забрать n штук из конкретного слота
function PD.RemoveFromSlot(player, index, n)
	local d = data[player]
	index = validSlot(index)
	if n == nil then
		n = 1
	end
	n = toInt(n)
	if not d or not index or not n or n < 1 then
		return false
	end
	local e = d.Slots[index]
	if not e or e.kind ~= "item" or e.count < n then
		return false
	end
	e.count = e.count - n
	if e.count <= 0 then
		d.Slots[index] = nil
	end
	changed(player, d, index <= HOTBAR)
	return true
end

-- Израсходовать n штук предмета в руках
function PD.ConsumeActive(player, n)
	local d = data[player]
	if not d then
		return false
	end
	fixActive(d)
	if d.Active <= 0 then
		return false
	end
	return PD.RemoveFromSlot(player, d.Active, n)
end

-- opts: level (уровень улучшения, по умолчанию 0), mag (патронов в магазине).
-- -> true, слот | false (нет такого оружия, уже есть, или нет свободного слота)
function PD.GiveWeapon(player, weaponId, opts)
	opts = type(opts) == "table" and opts or {}
	local d = data[player]
	local def = WeaponDefs.List[weaponId]
	if not d or not def or def.kind == "throw" or d.Weapons[weaponId] then
		return false
	end
	local index = firstEmpty(d, 1, HOTBAR) or firstEmpty(d, HOTBAR + 1, TOTAL)
	if not index then
		return false
	end
	local level = math.clamp(toInt(opts.level) or 0, 0, Recipes.WeaponMaxLevel)
	local maxMag = Recipes.WeaponMagBonus(def.mag, level)
	local mag = maxMag and math.clamp(toInt(opts.mag) or maxMag, 0, maxMag) or 0
	d.Slots[index] = { kind = "weapon", id = weaponId, level = level, mag = mag }
	changed(player, d, index <= HOTBAR)
	return true, index
end

-- Забирает оружие у игрока (для выбрасывания/передачи). Возвращает {level, mag} или nil
function PD.RemoveWeapon(player, weaponId)
	local d = data[player]
	local e, index = nil, nil
	if d then
		e, index = weaponEntry(d, weaponId)
	end
	if not e then
		return nil
	end
	d.Slots[index] = nil
	changed(player, d, index <= HOTBAR)
	return { level = e.level or 0, mag = e.mag or 0 }
end

function PD.GetWeaponLevel(player, weaponId)
	local d = data[player]
	return d and d.WeaponLevels[weaponId] or 0
end

function PD.SetWeaponLevel(player, weaponId, level)
	local d = data[player]
	level = toInt(level)
	local e, index = nil, nil
	if d then
		e, index = weaponEntry(d, weaponId)
	end
	if not e or not level then
		return false
	end
	e.level = math.clamp(level, 0, Recipes.WeaponMaxLevel)
	changed(player, d, index <= HOTBAR)
	return true
end

-- Экипировка инструмента слота через WeaponService (EquipSlot), иначе — сами через Humanoid
local function equipTool(player, d, index)
	flushTools(player, d)
	local equipSlot = optional(S.Weapons, "EquipSlot")
	if equipSlot then
		equipSlot(player, index)
		return
	end
	local char = player.Character
	local hum = Util.AliveHumanoid(char)
	if not hum then
		return
	end
	local e = index > 0 and d.Slots[index] or nil
	local found = nil
	if e then
		for _, container in ipairs({ char, player:FindFirstChildOfClass("Backpack") }) do
			for _, t in ipairs(container:GetChildren()) do
				if t:IsA("Tool") and (t:GetAttribute("Slot") == index or (e.kind == "weapon" and t:GetAttribute("WeaponId") == e.id)) then
					found = t
					break
				end
			end
			if found then
				break
			end
		end
	end
	if found then
		if found.Parent ~= char then
			hum:EquipTool(found)
		end
	else
		hum:UnequipTools()
	end
end

-- Взять в руки слот хотбара (0 — убрать из рук). Пустой слот = пустые руки. -> true, если в руках то, что просили
function PD.SetActive(player, index)
	local d = data[player]
	index = toInt(index)
	if not d or not index or index < 0 or index > HOTBAR then
		return false
	end
	local want = index
	if index > 0 and not d.Slots[index] then
		index = 0
	end
	local prev = d.Active
	d.Active = index
	-- WeaponService может вызвать SetActive изнутри EquipSlot: тогда только запоминаем
	if not d.Equipping then
		d.Equipping = true
		local ok, err = pcall(equipTool, player, d, index)
		d.Equipping = false
		if not ok then
			warnOnce("EquipSlot", "экипировка слота: " .. tostring(err))
		end
	end
	if d.Active ~= prev then
		PD.SyncInventory(player)
	end
	return index == want
end

-- Перенос / обмен / слияние / деление (count — сколько штук перенести, nil — всю стопку)
function PD.MoveSlot(player, from, to, count)
	local d = data[player]
	from, to = validSlot(from), validSlot(to)
	if not d or not from or not to or from == to then
		return false
	end
	local src = d.Slots[from]
	if not src then
		return false
	end
	fixActive(d)
	local dst = d.Slots[to]
	local oldActive = d.Active
	local held = oldActive > 0 and d.Slots[oldActive] or nil
	if src.kind == "item" then
		local total = src.count
		local n = total
		if count ~= nil then
			n = toInt(count)
			if not n or n < 1 then
				return false
			end
			n = math.min(n, total)
		end
		if not dst then
			if n >= total then
				d.Slots[to] = src
				d.Slots[from] = nil
			else
				d.Slots[to] = { kind = "item", id = src.id, count = n }
				src.count = total - n
			end
		elseif dst.kind == "item" and dst.id == src.id then
			local room = PD.StackSize(src.id) - dst.count
			if room <= 0 then
				return false
			end
			local m = math.min(room, n)
			dst.count = dst.count + m
			src.count = total - m
			if src.count <= 0 then
				d.Slots[from] = nil
			end
		else
			-- разделить стопку можно только в пустой слот или в такую же стопку
			if n < total then
				return false
			end
			d.Slots[to], d.Slots[from] = src, dst
		end
	else
		d.Slots[to], d.Slots[from] = src, dst
	end
	-- Что теперь в руках: предмет из рук, переложенный внутри хотбара, остаётся в руках;
	-- на место убранного из рук встал другой — в руках он; стопка из рук влилась в стопку хотбара — в руках она
	if held then
		local newActive = 0
		for i = 1, HOTBAR do
			if d.Slots[i] == held then
				newActive = i
				break
			end
		end
		if newActive == 0 then
			if d.Slots[oldActive] then
				newActive = oldActive
			elseif from == oldActive and to <= HOTBAR then
				local t = d.Slots[to]
				if t and t.kind == "item" and t.id == held.id then
					newActive = to
				end
			end
		end
		d.Active = newActive
	end
	changed(player, d, from <= HOTBAR or to <= HOTBAR)
	if d.Active ~= oldActive or (d.Active > 0 and d.Slots[d.Active] ~= held) then
		PD.SetActive(player, d.Active)
	end
	return true
end

-- Выбросить содержимое слота перед игроком (count — для стопки; оружие целиком)
function PD.DropSlot(player, index, count)
	local d = data[player]
	index = validSlot(index)
	if not d or not index or not S.Loot then
		return false
	end
	local e = d.Slots[index]
	if not e then
		return false
	end
	local n = 1
	if e.kind == "item" then
		n = e.count
		if count ~= nil then
			n = toInt(count)
			if not n or n < 1 then
				return false
			end
			n = math.min(n, e.count)
		end
	end
	local cf, surface = S.Loot.GroundCFrame(player, 3.5)
	if not cf then
		return false
	end
	local dropEntry
	if e.kind == "weapon" then
		dropEntry = e
		d.Slots[index] = nil
	else
		dropEntry = { kind = "item", id = e.id, count = n }
		e.count = e.count - n
		if e.count <= 0 then
			d.Slots[index] = nil
		end
	end
	changed(player, d, index <= HOTBAR)
	spawnDrop(player, dropEntry, cf, surface)
	return true
end

-- Данные игрока -----------------------------------------------------------------

local function newData(player)
	local d = {
		Player = player,
		Slots = {}, -- [1..TOTAL] = nil | {kind="item", id, count} | {kind="weapon", id, level, mag}
		Active = 0, -- активный слот хотбара (1..HOTBAR) или 0 — пустые руки
		-- производные (обновляются на месте при каждом изменении слотов)
		Inventory = {},
		Weapons = {},
		WeaponOrder = {},
		WeaponLevels = {},
		ClassId = "survivor",
		Money = Config.Player.StartMoney,
		Hunger = 100,
		-- бодрости больше нет: поле оставлено только для старого кода, который его читает (всегда 100)
		Energy = 100,
		LastDamage = 0,
		Downed = false,
		DownedUntil = 0,
		Dead = false,
		Sprint = false,
		Kills = 0,
		Earned = 0,
		Revives = 0,
		CrashAt = nil,
		CrashTime = 0,
		SentHunger = -1,
	}
	d.Mags = makeMags(d)
	return d
end

function PD.MaxHP(player)
	local d = data[player]
	local base = Classes.Perk(d and d.ClassId or "survivor", "maxHP", Config.Player.MaxHP)
	local perks = S.Profile.LevelPerks(player)
	return base + (perks and perks.bonusHP or 0)
end

local function setAttrs(player, d)
	player:SetAttribute("Money", d.Money)
	player:SetAttribute("ClassId", d.ClassId)
	player:SetAttribute("Downed", d.Downed)
	player:SetAttribute("Kills", d.Kills)
	player:SetAttribute("Hunger", math.floor(d.Hunger + 0.5))
end

function PD.OnPlayerAdded(player)
	if data[player] then
		return
	end
	-- профиль (уровень, билеты, ежедневные награды) грузится до создания персонажа
	S.Profile.OnPlayerAdded(player)
	if not player.Parent then
		return
	end
	local d = newData(player)
	data[player] = d
	PD.ApplyClass(player, "survivor")
	setAttrs(player, d)
	player.CharacterAdded:Connect(function(char)
		PD.OnCharacterAdded(player, char)
	end)
	PD.SpawnCharacter(player)
	if S.Run.State == "Depot" then
		task.delay(2.5, function()
			if player.Parent then
				Net.Get("OpenClassSelect"):FireClient(player)
			end
		end)
	end
end

function PD.OnPlayerRemoving(player)
	if S.Sleep.IsSleeping(player) then
		S.Sleep.Wake(player, "left")
	end
	S.Profile.OnPlayerRemoving(player)
	data[player] = nil
	task.defer(function()
		S.Run.CheckWipe()
	end)
end

function PD.SpawnCharacter(player)
	local d = data[player]
	if not d or not player.Parent then
		return
	end
	d.Dead = false
	d.Downed = false
	player:SetAttribute("Downed", false)
	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn("LoadCharacter: " .. tostring(err))
	end
end

function PD.OnCharacterAdded(player, char)
	local d = data[player]
	if not d then
		return
	end
	-- новый персонаж: инструменты пересоздаются в рюкзаке, в руках пусто
	d.Active = 0
	local hum = char:WaitForChild("Humanoid", 10)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if not hum or not root then
		return
	end
	local maxHP = PD.MaxHP(player)
	hum.MaxHealth = maxHP
	hum.Health = maxHP
	hum.WalkSpeed = Config.Player.WalkSpeed
	d.LastDamage = 0

	task.defer(function()
		local cf = S.Run.GetSpawnCFrame(player)
		if cf and char.Parent then
			char:PivotTo(cf)
		end
	end)

	hum.Died:Connect(function()
		PD.OnDied(player, char)
	end)

	-- Подсказки: поднять упавшего / разбудить спящего
	local revive = Instance.new("ProximityPrompt")
	revive.Name = "RevivePrompt"
	revive.ActionText = "Поднять"
	revive.ObjectText = player.DisplayName
	revive.HoldDuration = Config.Player.ReviveTime
	revive.MaxActivationDistance = 10
	revive.RequiresLineOfSight = false
	revive.Enabled = false
	revive.Parent = root
	revive.Triggered:Connect(function(by)
		if by ~= player and PD.IsActive(by) then
			PD.Revive(player, by)
		end
	end)

	local wake = Instance.new("ProximityPrompt")
	wake.Name = "WakePrompt"
	wake.ActionText = "Разбудить"
	wake.ObjectText = player.DisplayName
	wake.HoldDuration = 0.4
	wake.MaxActivationDistance = 10
	wake.RequiresLineOfSight = false
	wake.Enabled = false
	wake.Parent = root
	wake.Triggered:Connect(function(by)
		if by ~= player and PD.IsActive(by) and S.Sleep.IsSleeping(player) then
			S.Sleep.Wake(player, "friend")
		end
	end)

	d.ToolsDirty = true
	PD.SyncInventory(player)
	-- повторно: рюкзак может пересоздаться чуть позже появления персонажа
	task.delay(1, function()
		if player.Character == char and data[player] == d then
			S.Weapons.RefreshTools(player)
		end
	end)
end

function PD.IsActive(player)
	local d = data[player]
	if not d or d.Dead or d.Downed then
		return false
	end
	if S.Sleep.IsSleeping(player) then
		return false
	end
	return Util.AliveHumanoid(player.Character) ~= nil
end

-- Живой (в том числе при смерти или спит)
function PD.IsAlive(player)
	local d = data[player]
	return d ~= nil and not d.Dead and Util.AliveHumanoid(player.Character) ~= nil
end

local function setPrompt(player, name, enabled)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local prompt = root and root:FindFirstChild(name)
	if prompt then
		prompt.Enabled = enabled
	end
end
PD.SetPrompt = setPrompt

function PD.SetDowned(player)
	local d = data[player]
	if not d or d.Downed or d.Dead then
		return
	end
	local hum = Util.AliveHumanoid(player.Character)
	if not hum then
		return
	end
	if S.Sleep.IsSleeping(player) then
		S.Sleep.Wake(player, "downed")
	end
	if hum.SeatPart then
		hum.Sit = false
		local weld = hum.SeatPart:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end
	hum:UnequipTools()
	PD.SetActive(player, 0)
	d.Downed = true
	d.DownedUntil = Util.Now() + Config.Player.DownedTime
	hum.Health = 1
	player:SetAttribute("Downed", true)
	player:SetAttribute("DownedUntil", d.DownedUntil)
	setPrompt(player, "RevivePrompt", true)
	local extra = ""
	if (d.Inventory.adrenaline or 0) > 0 then
		extra = " (есть адреналин)"
	end
	PD.NotifyAll(player.DisplayName .. " при смерти! Поднимите его" .. extra, RED)
end

function PD.Revive(player, reviver, hp)
	local d = data[player]
	if not d or not d.Downed then
		return
	end
	local hum = Util.AliveHumanoid(player.Character)
	if not hum then
		return
	end
	d.Downed = false
	player:SetAttribute("Downed", false)
	setPrompt(player, "RevivePrompt", false)
	local heal = hp or Config.Player.ReviveHealth
	if reviver then
		local rd = data[reviver]
		heal = heal * Classes.Perk(rd and rd.ClassId or "survivor", "reviveMult", 1)
		if rd then
			rd.Revives = rd.Revives + 1
		end
		S.Profile.AddXP(reviver, 40, "revive")
		PD.NotifyAll(reviver.DisplayName .. " поднял(а) " .. player.DisplayName, GREEN)
	end
	hum.Health = math.min(hum.MaxHealth, heal)
	d.LastDamage = os.clock()
end

function PD.TrySelfRevive(player)
	local d = data[player]
	if not d or not d.Downed then
		return
	end
	if PD.RemoveItem(player, "adrenaline", 1) then
		PD.Revive(player, nil, 50)
		PD.AddEffect(player, "Adrenaline", Config.Sleep.AdrenalineDuration)
		PD.Notify(player, "Укол адреналина! Вы снова на ногах", YELLOW)
	end
end

function PD.Kill(player)
	local d = data[player]
	if not d then
		return
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		d.Downed = false
		hum.Health = 0
	end
end

function PD.OnDied(player, char)
	local d = data[player]
	if not d or d.Dead then
		return
	end
	if player.Character ~= char then
		return
	end
	if S.Sleep.IsSleeping(player) then
		S.Sleep.Wake(player, "died")
	end
	d.Dead = true
	d.Downed = false
	d.Active = 0
	player:SetAttribute("Downed", false)
	local lost = math.floor(d.Money * Config.Player.DeathMoneyLoss)
	if lost > 0 then
		PD.AddMoney(player, -lost)
	end
	PD.NotifyAll(player.DisplayName .. " погиб(ла)" .. (lost > 0 and (" и потерял(а) $" .. lost) or ""), RED)
	S.Run.CheckWipe()
	task.delay(Config.Player.RespawnDelay, function()
		if player.Parent and data[player] == d and d.Dead and S.Run.CanRespawn() then
			PD.SpawnCharacter(player)
		end
	end)
end

function PD.AddMoney(player, amount)
	local d = data[player]
	if not d then
		return
	end
	amount = math.floor(amount + 0.5)
	d.Money = math.max(0, d.Money + amount)
	if amount > 0 then
		d.Earned = d.Earned + amount
	end
	player:SetAttribute("Money", d.Money)
end

function PD.SpendMoney(player, amount)
	local d = data[player]
	if not d or d.Money < amount then
		return false
	end
	d.Money = d.Money - amount
	player:SetAttribute("Money", d.Money)
	return true
end

-- Эффекты -------------------------------------------------------------------

function PD.AddEffect(player, id, duration)
	if not StatusEffects.List[id] then
		return
	end
	local now = Util.Now()
	local cur = player:GetAttribute("Eff_" .. id) or 0
	player:SetAttribute("Eff_" .. id, math.max(cur, now + duration))
end

function PD.HasEffect(player, id)
	local t = player:GetAttribute("Eff_" .. id)
	return t ~= nil and t > Util.Now()
end

function PD.ClearEffect(player, id)
	player:SetAttribute("Eff_" .. id, nil)
end

function PD.DamageMult(player, weaponDef)
	local d = data[player]
	if not d then
		return 1
	end
	local m = 1
	for id, e in pairs(StatusEffects.List) do
		if e.damageMult and PD.HasEffect(player, id) then
			m = m * e.damageMult
		end
	end
	if weaponDef then
		if weaponDef.kind == "gun" then
			m = m * Classes.Perk(d.ClassId, "gunMult", 1)
		elseif weaponDef.kind == "bow" or weaponDef.kind == "crossbow" then
			m = m * Classes.Perk(d.ClassId, "bowMult", 1)
		end
	end
	local perks = S.Profile.LevelPerks(player)
	if perks then
		m = m * (1 + (perks.damageBonus or 0))
	end
	if weaponDef and weaponDef.id then
		m = m * Recipes.WeaponLevelMult(d.WeaponLevels[weaponDef.id] or 0)
	end
	return m
end

-- Класс ---------------------------------------------------------------------

-- порядок предметов набора в слотах (после оружия)
local KIT_ORDER = { ammo = 1, throwable = 2, medical = 3, food = 4, fuel = 5, tool = 6, placeable = 7, material = 8, buspart = 9, valuable = 10, quest = 11 }

-- Набор класса (v5): оружие и предметы класса, а при Config.TestKit.Enabled — ещё набор для проверки
-- (TestKit.Weapons, TestKit.Items). Неизвестное оружие и предметы пропускаются (например, пока пистолета
-- нет в Weapons.List); переносимые объекты (Items grab = true) в слоты не кладутся.
-- -> { id, weapons = { weaponId, ... }, items = { itemId = n } } — новые таблицы при каждом вызове
function PD.ClassKit(classId)
	local c = Classes.Get(classId)
	local kit = { id = c.id, weapons = {}, items = {} }
	local seen = {}
	local function addWeapon(w)
		local def = type(w) == "string" and WeaponDefs.List[w] or nil
		if def and def.kind ~= "throw" and not seen[w] then
			seen[w] = true
			table.insert(kit.weapons, w)
		end
	end
	local function addItems(list)
		if type(list) ~= "table" then
			return
		end
		for id, n in pairs(list) do
			local item = type(id) == "string" and Items.List[id] or nil
			local count = toInt(n)
			if item and not item.grab and count and count >= 1 then
				kit.items[id] = (kit.items[id] or 0) + count
			end
		end
	end
	for _, w in ipairs(c.weapons or {}) do
		addWeapon(w)
	end
	addItems(c.items)
	local test = Config.TestKit
	if type(test) == "table" and test.Enabled == true then
		if type(test.Weapons) == "table" then
			for _, w in ipairs(test.Weapons) do
				addWeapon(w)
			end
		end
		addItems(test.Items)
	end
	return kit
end

-- Набор класса: оружие — первым в хотбар (класса, затем для проверки), затем предметы (хотбар, остаток — рюкзак).
-- ВАЖНО: d.Inventory и d.Weapons заменяются НОВЫМИ таблицами только здесь. ShopService (kits[player].inv)
-- по идентичности таблицы понимает, что выдан свежий полный набор. Остальной код обновляет их на месте.
function PD.ApplyClass(player, classId)
	local d = data[player]
	if not d then
		return
	end
	local kit = PD.ClassKit(classId)
	d.ClassId = kit.id
	d.Slots = {}
	d.Active = 0
	d.Inventory = {}
	d.Weapons = {}
	d.WeaponOrder = {}
	d.WeaponLevels = {}
	d.Mags = makeMags(d)
	local index = 0
	for _, w in ipairs(kit.weapons) do
		local def = WeaponDefs.List[w]
		if index < TOTAL then
			index = index + 1
			d.Slots[index] = { kind = "weapon", id = w, level = 0, mag = def.mag or 0 }
		end
	end
	local ids = {}
	for id in pairs(kit.items) do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ca = KIT_ORDER[Items.List[a].cat] or 99
		local cb = KIT_ORDER[Items.List[b].cat] or 99
		if ca ~= cb then
			return ca < cb
		end
		return a < b
	end)
	for _, id in ipairs(ids) do
		insertItem(d, id, kit.items[id], false)
	end
	rebuild(d)
	d.ToolsDirty = true
	player:SetAttribute("ClassId", d.ClassId)
	local hum = Util.AliveHumanoid(player.Character)
	if hum then
		local maxHP = PD.MaxHP(player)
		hum.MaxHealth = maxHP
		hum.Health = maxHP
		flushTools(player, d)
	end
	PD.SyncInventory(player)
end

function PD.ResetForRun(player)
	local d = data[player]
	if not d then
		return
	end
	d.Money = Config.Player.StartMoney
	d.Hunger = 100
	d.Kills = 0
	d.Earned = 0
	d.Revives = 0
	d.Dead = false
	d.Downed = false
	d.CrashAt = nil
	for id in pairs(StatusEffects.List) do
		PD.ClearEffect(player, id)
	end
	-- очищает слоты и выдаёт набор класса
	PD.ApplyClass(player, d.ClassId)
	setAttrs(player, d)
end

-- Скорость с учётом эффектов
function PD.ComputeSpeed(player, d, hum)
	if d.Downed then
		return 3
	end
	local sp = Config.Player.WalkSpeed
	if d.Sprint and d.Hunger > 0 and hum.MoveDirection.Magnitude > 0.1 then
		sp = sp * Config.Player.SprintMult
	end
	for id, e in pairs(StatusEffects.List) do
		if e.speedMult and PD.HasEffect(player, id) then
			sp = sp * e.speedMult
		end
	end
	return sp
end

-- Голод и здоровье (v5, docs/SPEC_v5.md 2.4) ---------------------------------------------------
-- Сытость тратится Config.Player.HungerDrain в секунду (на бегу — x SprintHungerMult, во сне — медленнее).
-- Здоровье восстанавливается само только сытым (сытость >= RegenMinHunger) и спустя RegenDelay секунд
-- без урона: RegenRate HP/с, и каждое HP стоит RegenHungerCost сытости. При нулевой сытости —
-- StarveDamage HP/с. Во сне лечит SleepService — тоже за счёт сытости (PD.HealWithHunger).

local SLEEP_HUNGER_MULT = 0.4 -- во сне голод идёт медленнее

-- Состояния, в которых персонаж не бежит, даже если зажат бег
local NOT_RUNNING = {
	[Enum.HumanoidStateType.Seated] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.GettingUp] = true,
	[Enum.HumanoidStateType.Dead] = true,
}

-- Бежит ли игрок на самом деле: зажат бег, есть ввод движения, персонаж на ногах, и сервер дал ему
-- скорость бега (ComputeSpeed: голодный, опутанный или замедленный уже не бежит)
local function isSprinting(d, hum)
	if not d.Sprint or d.Downed or hum.SeatPart or hum.MoveDirection.Magnitude <= 0.1 then
		return false
	end
	if NOT_RUNNING[hum:GetState()] then
		return false
	end
	return hum.WalkSpeed > Config.Player.WalkSpeed + 0.5
end

-- Лечение за счёт сытости (регенерация, сон): до amount HP, каждое HP стоит RegenHungerCost сытости,
-- поэтому лечит не больше, чем хватает сытости. free = true — бесплатно (лобби). -> восстановлено HP
function PD.HealWithHunger(player, amount, free)
	local d = data[player]
	if not d or d.Dead or d.Downed or type(amount) ~= "number" or not (amount > 0) then
		return 0
	end
	local hum = Util.AliveHumanoid(player.Character)
	if not hum then
		return 0
	end
	local heal = math.min(amount, hum.MaxHealth - hum.Health)
	local cost = Config.Player.RegenHungerCost or 0
	local paid = free ~= true and cost > 0
	if paid then
		heal = math.min(heal, d.Hunger / cost)
	end
	if not (heal > 0) then
		return 0
	end
	hum.Health = math.min(hum.MaxHealth, hum.Health + heal)
	if paid then
		d.Hunger = math.max(0, d.Hunger - heal * cost)
	end
	return heal
end

-- Предупреждения о голоде: один раз при пересечении порога (с запасом, чтобы не повторялись)
local function hungerNotices(player, d)
	local minHunger = Config.Player.RegenMinHunger
	if d.Hunger < minHunger then
		if not d.WarnedNoRegen then
			d.WarnedNoRegen = true
			PD.Notify(player, string.format("Сытость ниже %d%%: здоровье больше не восстанавливается. Поешьте (F)", math.floor(minHunger)), YELLOW)
		end
	elseif d.Hunger >= minHunger + 5 then
		d.WarnedNoRegen = false
	end
	if d.Hunger <= 0 then
		if not d.WarnedStarve then
			d.WarnedStarve = true
			PD.Notify(player, "Вы умираете от голода: здоровье убывает! Срочно поешьте", RED)
		end
	elseif d.Hunger >= 5 then
		d.WarnedStarve = false
	end
end

local acc = 0
function PD.Update(dt)
	acc = acc + dt
	if acc < 0.2 then
		return
	end
	local step = acc
	acc = 0
	local now = Util.Now()
	local clock = os.clock()
	local P = Config.Player
	-- в лобби голод не расходуется (нет еды и смысла), а здоровье восстанавливается бесплатно
	local inLobby = S.Run ~= nil and S.Run.Mode == "lobby"

	for player, d in pairs(data) do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 and not d.Dead then
			local sleeping = S.Sleep.IsSleeping(player)

			-- Голод: HungerDrain в секунду; на бегу — быстрее, во сне — медленнее
			if not inLobby then
				local drain = P.HungerDrain
				if sleeping then
					drain = drain * SLEEP_HUNGER_MULT
				elseif isSprinting(d, hum) then
					drain = drain * P.SprintHungerMult
				end
				d.Hunger = math.max(0, d.Hunger - drain * step)
			end

			-- Энергетик выветрился: упадок сил
			if d.CrashAt and clock >= d.CrashAt then
				d.CrashAt = nil
				if (d.CrashTime or 0) > 0 then
					PD.AddEffect(player, "Crash", d.CrashTime)
					PD.Notify(player, "Энергетик выветрился: упадок сил", GREY)
				end
			end

			if not d.Downed then
				local poisoned = PD.HasEffect(player, "Poison")
				if poisoned then
					S.Combat.DamagePlayer(player, 3 * step, { kind = "poison", silent = true, noSleepWake = true })
				end
				-- голодание: урон, пока сытость на нуле
				if d.Hunger <= 0 and not inLobby then
					S.Combat.DamagePlayer(player, P.StarveDamage * step, { kind = "starve", silent = true, noSleepWake = true })
				end
				-- регенерация (во сне лечит SleepService): только сытым, не отравленным и спустя RegenDelay без урона
				local canRegen = not sleeping and not poisoned and d.Hunger >= P.RegenMinHunger
				if canRegen and clock - d.LastDamage >= P.RegenDelay and hum.Health < hum.MaxHealth then
					PD.HealWithHunger(player, P.RegenRate * step, inLobby)
				end
			end
			if not inLobby then
				hungerNotices(player, d)
			end

			if d.Downed and now >= d.DownedUntil then
				PD.Kill(player)
			end

			if not sleeping then
				hum.WalkSpeed = PD.ComputeSpeed(player, d, hum)
				if d.Downed then
					hum.JumpPower = 0
					hum.JumpHeight = 0
				else
					hum.JumpPower = 50
					hum.JumpHeight = 7.2
				end
			end

			-- Атрибут для HUD — только при изменении целого значения; 0 — только когда сытость
			-- действительно кончилась (тогда и идёт урон от голода)
			local h = d.Hunger > 0 and math.max(1, math.floor(d.Hunger + 0.5)) or 0
			if h ~= d.SentHunger then
				d.SentHunger = h
				player:SetAttribute("Hunger", h)
			end
		end

		-- Истёкшие эффекты
		for id in pairs(StatusEffects.List) do
			local t = player:GetAttribute("Eff_" .. id)
			if t and t <= now then
				player:SetAttribute("Eff_" .. id, nil)
			end
		end
	end
end

-- Удалённое событие InventoryAction(action, data) ---------------------------------
-- equip {slot}, unequip, move {from, to, count}, drop {slot, count}, use {slot}, split {from, to, count}

local ACTION_RATE = 15 -- действий в секунду в среднем
local ACTION_BURST = 12

local function allowAction(d)
	local now = os.clock()
	local tokens = math.min(ACTION_BURST, (d.ActionTokens or ACTION_BURST) + (now - (d.ActionAt or now)) * ACTION_RATE)
	d.ActionAt = now
	if tokens < 1 then
		d.ActionTokens = tokens
		return false
	end
	d.ActionTokens = tokens - 1
	return true
end

-- Пустой слот в том же разделе (хотбар/рюкзак), иначе в другом
local function emptyNear(d, index)
	if index <= HOTBAR then
		return firstEmpty(d, 1, HOTBAR) or firstEmpty(d, HOTBAR + 1, TOTAL)
	end
	return firstEmpty(d, HOTBAR + 1, TOTAL) or firstEmpty(d, 1, HOTBAR)
end

local function canRearrange(player, d)
	return not d.Downed and not S.Sleep.IsSleeping(player)
end

function PD.HandleInventoryAction(player, action, payload)
	local d = data[player]
	if not d or type(action) ~= "string" then
		return
	end
	if payload == nil then
		payload = {}
	elseif type(payload) ~= "table" then
		return
	end
	if not allowAction(d) then
		return
	end
	if action == "unequip" then
		if d.Active ~= 0 then
			PD.SetActive(player, 0)
		end
		return
	end
	-- в лобби предметов в руках нет; мёртвым — ничего
	if d.Dead or (S.Run and S.Run.Mode == "lobby") then
		return
	end
	if action == "equip" then
		local slot = toInt(payload.slot)
		if slot and slot >= 0 and slot <= HOTBAR and PD.IsActive(player) then
			PD.SetActive(player, slot)
		end
	elseif action == "move" then
		local from, to = validSlot(payload.from), validSlot(payload.to)
		if not from or not to or not canRearrange(player, d) then
			return
		end
		if payload.count ~= nil and not toInt(payload.count) then
			return
		end
		PD.MoveSlot(player, from, to, payload.count)
	elseif action == "split" then
		local from = validSlot(payload.from)
		local e = from and d.Slots[from]
		if not e or e.kind ~= "item" or e.count < 2 or not canRearrange(player, d) then
			return
		end
		local n
		if payload.count == nil then
			n = math.floor(e.count / 2)
		else
			n = toInt(payload.count)
		end
		if not n or n < 1 or n >= e.count then
			return
		end
		local to
		if payload.to == nil then
			to = emptyNear(d, from)
		else
			to = validSlot(payload.to)
		end
		if to and to ~= from then
			PD.MoveSlot(player, from, to, n)
		end
	elseif action == "drop" then
		local slot = validSlot(payload.slot)
		if not slot or not PD.IsActive(player) then
			return
		end
		if payload.count ~= nil and not toInt(payload.count) then
			return
		end
		PD.DropSlot(player, slot, payload.count)
	elseif action == "use" then
		local slot = validSlot(payload.slot)
		local e = slot and d.Slots[slot]
		if not e then
			return
		end
		if d.Downed then
			-- лёжа при смерти можно только вколоть адреналин
			if e.kind == "item" and e.id == "adrenaline" then
				PD.TrySelfRevive(player)
			end
			return
		end
		if not PD.IsActive(player) then
			return
		end
		local useSlot = optional(S.Weapons, "UseSlot")
		if useSlot then
			useSlot(player, slot)
		elseif e.kind == "weapon" then
			if slot <= HOTBAR then
				PD.SetActive(player, slot)
			end
		elseif S.Loot then
			S.Loot.UseItem(player, e.id, slot)
		end
	end
end

return PD
