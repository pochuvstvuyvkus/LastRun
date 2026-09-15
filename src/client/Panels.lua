-- Окна (v5): инвентарь Tab, магазин торговца, выбор класса, итоги заезда.
-- Инвентарь — компактная панель в стиле оригинала: внизу по центру, прямо над хотбаром HUD,
-- поверх мира без размытия и затемнения. Слева плитки «Здоровье» / «Сытость» / «Деньги»,
-- 3D-персонаж и счётчик заполненности; справа — рюкзак 6×3 (слоты 11–28), в пустых слотах крестик.
-- Второй ряд «в руках» не дублируется: единственный хотбар — в HUD, и пока открыт Tab он интерактивный
-- (перетаскивание, ПКМ, двойной щелчок, цифры 1–0). Сведения о предмете — подсказка у курсора.
-- Управление: ЛКМ — взять/выбрать, перетаскивание — переложить (Shift — половина стопки, мимо панели —
-- выбросить), ПКМ — быстрый перенос хотбар ↔ рюкзак, двойной щелчок — использовать, Q — выбросить,
-- T — передать. Открытие Tab перехватывается ContextActionService с высоким приоритетом (Sink),
-- закрытие — Tab / Esc / меню Roblox; курсор освобождается сразу (Modal), IsOpen() верен в тот же кадр.
-- Здесь же центр данных инвентаря: событие Inventory (counts, weaponOrder, weaponLevels, slots, active)
-- -> C.State (Inventory, WeaponOrder, WeaponLevels, Slots, Active) -> подписчики Panels.OnInventory.
-- Перенос и выброс предсказываются на клиенте (откат через ~1 с, если сервер не подтвердил).
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Weapons = require(Shared.Weapons)
local Classes = require(Shared.Classes)
local BusParts = require(Shared.BusParts)
local Recipes = require(Shared.Recipes)
local StatusEffects = require(Shared.StatusEffects)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Panels = {}
local C, UI
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

local HOTBAR = (Config.Inventory and Config.Inventory.HotbarSlots) or 10
local BACKPACK = (Config.Inventory and Config.Inventory.BackpackSlots) or 18
local TOTAL = HOTBAR + BACKPACK
local GIVE_DISTANCE = 16
local DOUBLE_CLICK = 0.35
local DRAG_START = 6
local EQUIP_GAP = 0.12
local LONG_PRESS = 0.45
local PREDICT_TIME = 1.2
local PREDICT_MISMATCH = 0.6
local HOVER_SOUND_GAP = 0.07
local TOGGLE_GAP = 0.15
local INPUT_PRIORITY = Enum.ContextActionPriority.High.Value + 20
local TAB_ACTION = "LastRunInventoryPanel"
local KEYS_ACTION = "LastRunInventoryKeys"

-- Раскладка панели
local GRID_COLS = 6
local GRID_ROWS = math.max(1, math.ceil(BACKPACK / GRID_COLS))
local SLOT_SIZE, SLOT_GAP = 64, 6
local TILE_SIZE, TILE_GAP = 64, 6
local PAD = 8
local BLOCK_GAP = 6
local AVATAR_W = 140
local GRID_W = GRID_COLS * SLOT_SIZE + (GRID_COLS - 1) * SLOT_GAP
local GRID_H = GRID_ROWS * SLOT_SIZE + (GRID_ROWS - 1) * SLOT_GAP
local PANEL_H = math.max(GRID_H, 3 * TILE_SIZE + 2 * TILE_GAP) + PAD * 2
local LEFT_W = PAD + TILE_SIZE + TILE_GAP + AVATAR_W + PAD
local RIGHT_W = GRID_W + PAD * 2
local PANEL_W = LEFT_W + BLOCK_GAP + RIGHT_W
local PANEL_LIFT = 12 -- зазор между панелью и хотбаром

local gui
local openName = nil
local inv = {}
local shop = {}
local classes = {}
local ending = {}
local picker = {}
local shopTab = "sell"

local extraWindows = {}
local scaleObjects = {}
local inventoryListeners = {}
local openListeners = {}
local synthesized = false
local listenerWarned = false
local dragWarned = false
local lastToggle = 0

local bagSlots = {} -- [11..28] = UI.ItemSlot
local hoverIndex = nil
local selectedIndex = nil
local drag = nil -- { from, input, mouse, touch, start, lastPos, t0, started, over, half, count, valid, ghost }
local lastClickIndex, lastClickTime = nil, 0
local lastHoverSound = 0
local predicted = nil -- { slots, stamp, untilT }
local activeOverride = nil -- { value, untilT, fromPrediction }

local function uiSound(key)
	local fx = C and C.SoundFX
	if fx and fx.Play then
		pcall(fx.Play, key)
	end
end

-- Окна --------------------------------------------------------------------------------------------

-- Другие модули с окнами (верстак, лобби, награды) регистрируются здесь, чтобы
-- камера и руки от первого лица отпускали мышь, пока окно открыто
function Panels.RegisterWindow(isOpenFn, closeFn)
	table.insert(extraWindows, { isOpen = isOpenFn, close = closeFn })
end

function Panels.IsOpen()
	if openName ~= nil then
		return true
	end
	for _, w in ipairs(extraWindows) do
		local ok, result = pcall(w.isOpen)
		if ok and result then
			return true
		end
	end
	return false
end

function Panels.IsInventoryOpen()
	return openName == "inventory"
end

-- Подписка на открытие/закрытие инвентаря (HUD показывает хотбар в интерактивном режиме)
function Panels.OnOpenChanged(fn)
	if type(fn) == "function" then
		table.insert(openListeners, fn)
	end
end

local function notifyOpen(open)
	for _, fn in ipairs(openListeners) do
		pcall(fn, open)
	end
end

function Panels.CloseAll()
	Panels.Close()
	for _, w in ipairs(extraWindows) do
		pcall(w.close)
	end
end

-- Масштаб интерфейса: clamp(min(vp.X/1280, vp.Y/720), 0.55, 1)
function Panels.ScaleValue()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	if vp.X < 1 or vp.Y < 1 then
		return 1
	end
	return math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1)
end

-- Добавить UIScale к фиксированной панели (обновляется при смене размера экрана)
function Panels.AttachScale(frame, maxScale)
	local s = Instance.new("UIScale")
	s.Parent = frame
	table.insert(scaleObjects, { scale = s, max = maxScale or 1 })
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	s.Scale = (vp.X > 1 and vp.Y > 1) and math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, maxScale or 1) or 1
	return s
end

local function updateScales()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local raw = (vp.X > 1 and vp.Y > 1) and math.min(vp.X / 1280, vp.Y / 720) or 1
	for i = #scaleObjects, 1, -1 do
		local e = scaleObjects[i]
		if e.scale.Parent then
			e.scale.Scale = math.clamp(raw, 0.55, math.max(0.55, e.max))
		else
			table.remove(scaleObjects, i)
		end
	end
end

-- Разбор атрибута Upgrades: "armor:2,ram:1" -> { armor = 2, ram = 1 }
function Panels.ParseUpgrades(str)
	local levels = {}
	if type(str) ~= "string" then
		return levels
	end
	for token in string.gmatch(str, "[^,]+") do
		local id, lvl = string.match(token, "^%s*([%w_]+)%s*:%s*(%d+)%s*$")
		if id then
			levels[id] = tonumber(lvl)
		else
			local plain = string.match(token, "^%s*([%w_]+)%s*$")
			if plain then
				levels[plain] = math.max(levels[plain] or 0, 1)
			end
		end
	end
	return levels
end

local function weaponLevels()
	local st = C.State
	return st.WeaponLevels or {}
end

local function money()
	local m = player:GetAttribute("Money")
	return type(m) == "number" and m or 0
end

local function rarityColor(r)
	return UI.RarityColor(r)
end

local function inLobby()
	return Net.State():GetAttribute("Mode") == "lobby"
end

local function localHumanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function shiftDown()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- Данные инвентаря ------------------------------------------------------------------------------

-- Подписка на изменение инвентаря (вызывается после обновления C.State)
function Panels.OnInventory(fn)
	if type(fn) == "function" then
		table.insert(inventoryListeners, fn)
	end
end

-- Показываем предсказанное состояние, пока сервер не ответил (иначе — данные сервера)
local function slotsTable()
	if predicted and os.clock() < predicted.untilT then
		return predicted.slots
	end
	local st = C.State
	return st.Slots or {}
end

function Panels.GetSlots()
	return slotsTable()
end

-- Слоты могут прийти массивом, словарём со строковыми ключами или списком записей с полем slot
local function normalizeSlots(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for k, v in pairs(raw) do
		if type(v) == "table" and type(v.id) == "string" then
			local idx = tonumber(v.slot) or tonumber(v.index) or tonumber(k)
			if idx and idx >= 1 and idx <= TOTAL and idx == math.floor(idx) then
				out[idx] = v
			end
		end
	end
	return out
end

-- Сервер без слотов (старый формат события): разложить оружие и предметы только для показа
local function synthesizeSlots(counts, order, levels)
	local out, n = {}, 0
	for _, id in ipairs(order) do
		if Weapons.List[id] and n < TOTAL then
			n = n + 1
			out[n] = { kind = "weapon", id = id, level = levels[id] or 0 }
		end
	end
	local ids = {}
	for id, count in pairs(counts) do
		if type(count) == "number" and count > 0 and Items.List[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		if n >= TOTAL then
			break
		end
		n = n + 1
		out[n] = { kind = "item", id = id, count = counts[id] }
	end
	return out
end

local function entryCount(entry)
	local n = tonumber(entry and entry.count)
	return (n and n >= 1) and math.floor(n) or 1
end

local function copySlots(src)
	local out = {}
	for i, e in pairs(src) do
		if type(e) == "table" then
			local copy = {}
			for k, v in pairs(e) do
				copy[k] = v
			end
			out[i] = copy
		end
	end
	return out
end

local function sameSlots(a, b)
	for i = 1, TOTAL do
		local x, y = a[i], b[i]
		if (x == nil) ~= (y == nil) then
			return false
		end
		if x and (x.id ~= y.id or UI.EntryKind(x) ~= UI.EntryKind(y) or entryCount(x) ~= entryCount(y)) then
			return false
		end
	end
	return true
end

local function notifyInventory()
	for _, fn in ipairs(inventoryListeners) do
		local ok, err = pcall(fn)
		if not ok and not listenerWarned then
			listenerWarned = true
			warn("[Panels] " .. tostring(err))
		end
	end
end

local function applyInventory(counts, order, levels, slots, active)
	local st = C.State
	st.Inventory = type(counts) == "table" and counts or {}
	st.WeaponOrder = type(order) == "table" and order or {}
	st.WeaponLevels = type(levels) == "table" and levels or {}
	if type(slots) == "table" then
		st.Slots = normalizeSlots(slots)
		synthesized = false
	else
		st.Slots = synthesizeSlots(st.Inventory, st.WeaponOrder, st.WeaponLevels)
		synthesized = true
	end
	local a = tonumber(active)
	st.Active = (a and a >= 0 and a <= HOTBAR) and math.floor(a) or 0
	local now = os.clock()
	-- предсказание снимаем, когда сервер прислал то же самое (или разошёлся с нами)
	if predicted and (sameSlots(predicted.slots, st.Slots) or now - predicted.stamp > PREDICT_MISMATCH or now >= predicted.untilT) then
		predicted = nil
	end
	if activeOverride and (activeOverride.value == st.Active or now >= activeOverride.untilT or (activeOverride.fromPrediction and not predicted)) then
		activeOverride = nil
	end
	notifyInventory()
end

-- Активный слот для показа: сразу после нажатия — запрошенный (до ответа сервера)
function Panels.GetActive()
	if activeOverride and os.clock() < activeOverride.untilT then
		return activeOverride.value
	end
	local st = C.State
	return st.Active or 0
end

-- Действия со слотами ---------------------------------------------------------------------------

local function invAction(action, data)
	Net.Get("InventoryAction"):FireServer(action, data or {})
end

local function canAct()
	local hum = localHumanoid()
	if not hum or hum.Health <= 0 then
		return false
	end
	return not player:GetAttribute("Downed") and not player:GetAttribute("Sleeping")
end

-- Старый сервер без InventoryAction: взять инструмент в руки локально
local function equipToolFallback(index)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not hum then
		return
	end
	if index == 0 then
		hum:UnequipTools()
		return
	end
	local entry = slotsTable()[index]
	if not entry or not backpack then
		return
	end
	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:IsA("Tool") and (tool:GetAttribute("Slot") == index or tool:GetAttribute("WeaponId") == entry.id) then
			hum:EquipTool(tool)
			return
		end
	end
end

local wcWarned = false
local equipQueued, lastEquipAt = nil, 0

local function transmitEquip(index)
	lastEquipAt = os.clock()
	if synthesized then
		equipToolFallback(index)
	elseif index == 0 then
		invAction("unequip")
	else
		invAction("equip", { slot = index })
	end
end

-- Отправка с ограничением частоты (колесо мыши): последний запрос уходит через EQUIP_GAP
local function sendEquip(index)
	activeOverride = { value = index, untilT = os.clock() + 0.8 }
	local wc = C.WeaponClient
	if wc and type(wc.EquipSlot) == "function" then
		local ok, err = pcall(wc.EquipSlot, index)
		if not ok and not wcWarned then
			wcWarned = true
			warn("[Panels] WeaponClient.EquipSlot: " .. tostring(err))
		end
	end
	local wait = EQUIP_GAP - (os.clock() - lastEquipAt)
	if wait <= 0 and equipQueued == nil then
		transmitEquip(index)
		return
	end
	local scheduled = equipQueued ~= nil
	equipQueued = index
	if not scheduled then
		task.delay(math.max(0.01, wait), function()
			local i = equipQueued
			equipQueued = nil
			if i ~= nil then
				transmitEquip(i)
			end
		end)
	end
end

-- Экипировать слот хотбара 1..10 (повторно — убрать из рук, 0 — пустые руки)
function Panels.EquipSlot(index)
	index = math.floor(tonumber(index) or -1)
	if index < 0 or index > HOTBAR or inLobby() or not canAct() then
		return false
	end
	if index > 0 and not slotsTable()[index] then
		return false
	end
	if index == Panels.GetActive() then
		index = 0
	end
	sendEquip(index)
	return true
end

-- Следующий/предыдущий непустой слот хотбара (колесо мыши, геймпад)
function Panels.CycleSlot(step)
	local slots = slotsTable()
	local current = Panels.GetActive()
	local start = current > 0 and current or (step > 0 and 0 or HOTBAR + 1)
	for n = 1, HOTBAR do
		local i = ((start - 1 + step * n) % HOTBAR) + 1
		if slots[i] then
			if i ~= current then
				return Panels.EquipSlot(i)
			end
			return false
		end
	end
	return false
end

local function stackSize(id)
	local item = Items.List[id]
	local n = item and tonumber(item.stack)
	return (n and n >= 1) and math.floor(n) or 1
end

local function firstFree(from, to)
	local slots = slotsTable()
	for i = from, to do
		if not slots[i] then
			return i
		end
	end
	return nil
end

-- Правила переноса — те же, что у PD.MoveSlot на сервере (count — часть стопки или nil)
local function moveValid(from, to, count)
	if type(from) ~= "number" or type(to) ~= "number" or from == to then
		return false
	end
	local slots = slotsTable()
	local src, dst = slots[from], slots[to]
	if not src then
		return false
	end
	if not dst then
		return true
	end
	local srcItem = UI.EntryKind(src) == "item"
	if srcItem and UI.EntryKind(dst) == "item" and src.id == dst.id then
		return stackSize(src.id) - entryCount(dst) > 0
	end
	-- обмен целиком: половину стопки в чужой слот сервер не примет
	return not srcItem or count == nil or count >= entryCount(src)
end

local function setPrediction(slots, active)
	local now = os.clock()
	predicted = { slots = slots, stamp = now, untilT = now + PREDICT_TIME }
	activeOverride = { value = active, untilT = now + PREDICT_TIME, fromPrediction = true }
end

local function predictMove(from, to, count)
	local slots = copySlots(slotsTable())
	local src, dst = slots[from], slots[to]
	if not src then
		return
	end
	local active = Panels.GetActive()
	local held = active > 0 and slots[active] or nil
	if UI.EntryKind(src) == "item" then
		local total = entryCount(src)
		local n = count and math.clamp(math.floor(count), 1, total) or total
		if not dst then
			if n >= total then
				slots[to], slots[from] = src, nil
			else
				slots[to] = { kind = "item", id = src.id, count = n }
				src.count = total - n
			end
		elseif UI.EntryKind(dst) == "item" and dst.id == src.id then
			local m = math.min(stackSize(src.id) - entryCount(dst), n)
			dst.count = entryCount(dst) + m
			src.count = total - m
			if src.count <= 0 then
				slots[from] = nil
			end
		else
			slots[to], slots[from] = src, dst
		end
	else
		slots[to], slots[from] = src, dst
	end
	-- что теперь в руках (как на сервере): предмет из рук следует за собой
	local newActive = active
	if held then
		newActive = 0
		for i = 1, HOTBAR do
			if slots[i] == held then
				newActive = i
				break
			end
		end
		if newActive == 0 then
			if slots[active] then
				newActive = active
			elseif from == active and to <= HOTBAR then
				local t = slots[to]
				if t and t.id == held.id then
					newActive = to
				end
			end
		end
	end
	setPrediction(slots, newActive)
end

local function predictRemove(index, count)
	local slots = copySlots(slotsTable())
	local e = slots[index]
	if not e then
		return
	end
	local active = Panels.GetActive()
	if UI.EntryKind(e) == "item" and entryCount(e) > count then
		e.count = entryCount(e) - count
	else
		slots[index] = nil
		if index == active then
			active = 0
		end
	end
	setPrediction(slots, active)
end

-- Объявлены заранее: ссылаются друг на друга
local flashHint, renderIndex, renderAll, refreshTooltip, cancelDrag, closePicker, openPicker, setSelected

local function moveSlot(from, to, count)
	if synthesized or not moveValid(from, to, count) then
		return false
	end
	predictMove(from, to, count)
	if count then
		invAction("move", { from = from, to = to, count = count })
	else
		invAction("move", { from = from, to = to })
	end
	uiSound("ui_move")
	notifyInventory()
	return true
end

-- ПКМ: хотбар -> первый свободный слот рюкзака, рюкзак -> первый свободный слот хотбара
function Panels.QuickTransfer(index)
	index = tonumber(index)
	if not index or index < 1 or index > TOTAL or inLobby() or synthesized then
		return false
	end
	if not slotsTable()[index] then
		return false
	end
	if not canAct() then
		flashHint("Сейчас нельзя перекладывать", true)
		return false
	end
	local toHotbar = index > HOTBAR
	local to = toHotbar and firstFree(1, HOTBAR) or firstFree(HOTBAR + 1, TOTAL)
	if not to then
		flashHint(toHotbar and "В руках нет места: освободите слот 1–0" or "Рюкзак полон", true)
		return false
	end
	local ok = moveSlot(index, to)
	if ok then
		if selectedIndex == index then
			selectedIndex = to
		end
		refreshTooltip()
	end
	return ok
end

-- В руки: слот хотбара — экипировать, слот рюкзака — перенести в хотбар и взять
local function toHands(index)
	local slots = slotsTable()
	if not slots[index] or not canAct() or inLobby() then
		return
	end
	if index <= HOTBAR then
		if index ~= Panels.GetActive() then
			Panels.EquipSlot(index)
		end
		return
	end
	local target = firstFree(1, HOTBAR)
	if not target then
		local active = Panels.GetActive()
		target = active > 0 and active or 1
	end
	if moveSlot(index, target) then
		if selectedIndex == index then
			selectedIndex = target
		end
		-- события приходят на сервер по порядку: сначала перенос, затем «в руки»
		sendEquip(target)
		refreshTooltip()
	end
end

local function useSlot(index)
	local info = UI.EntryInfo(slotsTable()[index])
	if not info or inLobby() then
		return
	end
	if player:GetAttribute("Downed") == true then
		-- лёжа при смерти можно только вколоть адреналин
		if info.id == "adrenaline" then
			invAction("use", { slot = index })
			uiSound("ui_click")
		else
			flashHint("Вы при смерти", true)
		end
		return
	end
	if not canAct() then
		flashHint("Сейчас нельзя", true)
		return
	end
	if info.kind == "item" and UI.UseVerb(info) then
		invAction("use", { slot = index })
		uiSound("ui_click")
	else
		toHands(index)
	end
end

local function dropSlot(index, whole, count)
	local info = UI.EntryInfo(slotsTable()[index])
	if not info then
		return
	end
	if not canAct() then
		flashHint("Сейчас нельзя", true)
		return
	end
	local n = count or (whole and info.count or 1)
	n = math.clamp(math.floor(n), 1, info.count)
	predictRemove(index, n)
	invAction("drop", { slot = index, count = n })
	uiSound("drop_item")
	notifyInventory()
	refreshTooltip()
end

local function giveSlot(index, whole)
	local info = UI.EntryInfo(slotsTable()[index])
	if not info then
		return
	end
	if info.kind == "weapon" then
		openPicker("weapon", info.id)
	else
		openPicker("item", info.id, whole and info.count or 1)
	end
	uiSound("ui_click")
end

-- Клавиша 1–0 при открытом инвентаре: предмет под курсором (или выбранный) — в этот слот хотбара
function Panels.HandleNumberKey(index)
	if openName ~= "inventory" or type(index) ~= "number" or index < 1 or index > HOTBAR then
		return false
	end
	local from = hoverIndex or selectedIndex
	if not from or from == index or not slotsTable()[from] then
		return false
	end
	if not moveValid(from, index) then
		flashHint("Сюда не переложить", true)
		return true
	end
	if moveSlot(from, index) and selectedIndex == from then
		selectedIndex = index
	end
	refreshTooltip()
	return true
end

-- Передача: выбор получателя --------------------------------------------------------------

local function nearbyPlayers()
	local result = {}
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return result
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local oc = other.Character
			local oroot = oc and oc:FindFirstChild("HumanoidRootPart")
			local hum = oc and oc:FindFirstChildOfClass("Humanoid")
			if oroot and hum and hum.Health > 0 then
				local dist = (oroot.Position - root.Position).Magnitude
				if dist <= GIVE_DISTANCE then
					table.insert(result, { player = other, dist = dist })
				end
			end
		end
	end
	table.sort(result, function(a, b)
		return a.dist < b.dist
	end)
	return result
end

closePicker = function()
	if picker.frame then
		picker.frame.Visible = false
	end
	picker.kind = nil
	picker.id = nil
end

local function refreshPicker()
	if not picker.frame or not picker.frame.Visible then
		return
	end
	local list = picker.list
	UI.Clear(list)
	UI.List(list, 6)
	local title
	if picker.kind == "item" then
		local item = Items.List[picker.id]
		local have = (C.State.Inventory or {})[picker.id] or 0
		if not item or have <= 0 then
			closePicker()
			return
		end
		picker.amount = math.clamp(picker.amount or 1, 1, have)
		title = "Передать: " .. item.name .. " ×" .. picker.amount
	else
		local def = Weapons.List[picker.id]
		local owned = false
		for _, w in ipairs(C.State.WeaponOrder or {}) do
			if w == picker.id then
				owned = true
			end
		end
		if not def or not owned then
			closePicker()
			return
		end
		local level = weaponLevels()[picker.id] or 0
		title = "Передать: " .. def.name .. (level > 0 and (" +" .. level) or "")
	end
	picker.title.Text = title

	local near = nearbyPlayers()
	for i, e in ipairs(near) do
		UI.ActionButton(list, {
			Size = UDim2.new(1, -4, 0, 34),
			LayoutOrder = i,
			Text = string.format("%s  (%d m)", e.player.DisplayName, math.floor(e.dist + 0.5)),
			TextSize = 14,
		}, "good", function()
			if picker.kind == "item" then
				Net.Get("GiveItem"):FireServer(e.player, picker.id, picker.amount or 1)
			elseif picker.kind == "weapon" then
				Net.Get("GiveWeapon"):FireServer(e.player, picker.id)
			end
			uiSound("ui_click")
			closePicker()
		end)
	end
	if #near == 0 then
		UI.Label(list, { Size = UDim2.new(1, -4, 0, 50), Text = "Рядом никого нет. Подойдите к игроку ближе чем на " .. GIVE_DISTANCE .. " m", TextWrapped = true, TextSize = 13, TextColor3 = UI.V5.muted, TextStrokeTransparency = 1 })
	end
end

openPicker = function(kind, id, amount)
	if not picker.frame then
		return
	end
	picker.kind = kind
	picker.id = id
	picker.amount = amount or 1
	picker.frame.Visible = true
	refreshPicker()
end

local function buildPicker(parent)
	local V = UI.V5
	local frame = UI.Frame(parent, {
		Name = "GivePicker",
		Size = UDim2.fromOffset(340, 300),
		Position = UDim2.new(0.5, 0, 0.5, -40),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = V.panel,
		BackgroundTransparency = 0.04,
		ZIndex = 20,
		Visible = false,
	})
	UI.AddScale(frame)
	UI.Corner(frame, V.corner)
	UI.Stroke(frame, V.line, 1, 0.7)
	picker.frame = frame
	picker.title = UI.Label(frame, { Size = UDim2.new(1, -24, 0, 26), Position = UDim2.fromOffset(12, 10), TextSize = 16, Font = UI.Theme.fontBlack, TextColor3 = V.text, TextStrokeTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd })
	picker.list = UI.Scroller(frame, { Size = UDim2.new(1, -24, 1, -98), Position = UDim2.fromOffset(12, 42) })
	UI.ActionButton(frame, { Size = UDim2.new(0.5, -15, 0, 32), Position = UDim2.new(0, 12, 1, -44), Text = "Обновить", TextSize = 14 }, "normal", function()
		refreshPicker()
	end)
	UI.ActionButton(frame, { Size = UDim2.new(0.5, -15, 0, 32), Position = UDim2.new(0.5, 3, 1, -44), Text = "Отмена", TextSize = 14 }, "danger", function()
		closePicker()
	end)
end

-- Отрисовка слотов ------------------------------------------------------------------------------

-- Состояние слота для UI.ItemSlot (нужно и HUD-хотбару, и рюкзаку)
function Panels.SlotVisualState(index)
	local open = openName == "inventory"
	local dragging = drag ~= nil and drag.started
	local entry = slotsTable()[index]
	local state = {
		open = open,
		active = index <= HOTBAR and entry ~= nil and index == Panels.GetActive(),
		hover = open and not dragging and index == hoverIndex,
		selected = open and not dragging and index == selectedIndex and index ~= hoverIndex,
		dim = dragging and drag.from == index,
	}
	if dragging and drag.over == index and drag.from ~= index then
		state.target = drag.valid and "ok" or "bad"
	end
	return state
end

local function renderBag(index)
	local w = bagSlots[index]
	if w then
		w:Set(slotsTable()[index], Panels.SlotVisualState(index))
	end
end

local function refreshHotbar()
	local hud = C.HUD
	if hud and hud.RefreshHotbar then
		hud.RefreshHotbar(true)
	end
end

renderIndex = function(index)
	if type(index) ~= "number" then
		return
	end
	if index <= HOTBAR then
		refreshHotbar()
	else
		renderBag(index)
	end
end

renderAll = function()
	for i = HOTBAR + 1, TOTAL do
		renderBag(i)
	end
	refreshHotbar()
end

setSelected = function(index)
	if selectedIndex == index then
		return
	end
	local old = selectedIndex
	selectedIndex = index
	renderIndex(old)
	renderIndex(index)
	refreshTooltip()
end

-- Подсказка о предмете у курсора -----------------------------------------------------------------

local function hexColor(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

-- Строчная первая буква (для «2×ЛКМ — съесть»)
local function lowerFirst(text)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	local ok, code = pcall(utf8.codepoint, text, 1)
	if not ok or not code then
		return text
	end
	local nextByte = utf8.offset(text, 2)
	local rest = nextByte and string.sub(text, nextByte) or ""
	if code >= 0x0410 and code <= 0x042F then
		code = code + 0x20
	elseif code == 0x0401 then
		code = 0x0451
	elseif code >= 65 and code <= 90 then
		code = code + 32
	end
	return utf8.char(code) .. rest
end

local function ammoCount(id)
	local counts = C.State.Inventory or {}
	return math.floor(tonumber(counts[id]) or 0)
end

-- 2–3 характеристики предмета: { {название, значение, цвет}, ... }
local function statRows(info, entry)
	local rows = {}
	local function add(label, value, color)
		if #rows < 3 then
			table.insert(rows, { label, value, color })
		end
	end
	if info.kind == "weapon" then
		local w = info.def
		if w then
			local mult = Recipes.WeaponLevelMult(info.level)
			local ammoName = w.ammo and Items.List[w.ammo] and Items.List[w.ammo].name or ""
			if w.kind == "melee" then
				add("Урон", tostring(math.floor((w.damage or 0) * mult + 0.5)))
				add("Скорость", string.format("%.1f уд/с", 1 / math.max(0.05, (w.cooldown or 1) * Recipes.WeaponCooldownMult(info.level))))
			elseif w.kind == "gun" then
				add("Урон", math.floor((w.damage or 0) * mult + 0.5) .. (w.pellets and (" ×" .. w.pellets) or ""))
				local mag = tonumber(entry.mag)
				add("Магазин", (mag and (math.floor(mag) .. " / ") or "") .. Recipes.WeaponMagBonus(w.mag or 0, info.level))
				add(ammoName, tostring(ammoCount(w.ammo)))
			elseif w.kind == "bow" then
				add("Урон", string.format("%d–%d", math.floor((w.damageMin or 0) * mult + 0.5), math.floor((w.damageMax or 0) * mult + 0.5)))
				add("Натяжение", string.format("%.2f с", w.drawTime or 0))
				add(ammoName, tostring(ammoCount(w.ammo)))
			elseif w.kind == "crossbow" then
				add("Урон", tostring(math.floor((w.damage or 0) * mult + 0.5)))
				add("Пробивает", tostring(w.pierce or 1))
				add(ammoName, tostring(ammoCount(w.ammo)))
			elseif w.kind == "throw" then
				add("Огонь", string.format("%d/с · %d с", w.burnDps or 0, w.burnTime or 0))
				add("Радиус", tostring(w.radius or 0))
			end
			if info.level > 0 and #rows < 3 then
				add("Уровень", "+" .. info.level .. " / " .. Recipes.WeaponMaxLevel)
			end
		end
		return rows
	end
	local item = info.item
	if not item then
		return rows
	end
	if type(item.hunger) == "number" and item.hunger > 0 then
		add("Сытость", "+" .. item.hunger)
	end
	if type(item.heal) == "number" and item.heal > 0 then
		add("Здоровье", "+" .. item.heal)
	end
	if type(item.fuel) == "number" then
		add("Топливо", "+" .. item.fuel)
	end
	if type(item.busRepair) == "number" then
		add("Ремонт автобуса", "+" .. item.busRepair)
	end
	if type(item.placeHP) == "number" then
		add("Прочность", tostring(item.placeHP))
	end
	if type(item.effect) == "string" then
		local e = StatusEffects.List[item.effect]
		if e then
			add("Эффект", e.name .. (type(item.effectTime) == "number" and (" · " .. item.effectTime .. " с") or ""))
		end
	end
	if item.cat == "buspart" then
		local part = BusParts.List[info.id]
		local slot = part and BusParts.Slots[part.slot]
		if slot then
			add("Слот", slot.name)
		end
	end
	if info.stack > 1 then
		add("В стопке", info.count .. " / " .. info.stack)
	end
	if type(item.sell) == "number" and item.sell > 0 then
		add("Продажа", "$" .. item.sell * info.count, UI.V5.money)
	end
	return rows
end

local function tooltipHints(index, info)
	local muted = hexColor(UI.V5.muted)
	local function part(key, text)
		return string.format('<b>%s</b> <font color="%s">%s</font>', key, muted, text)
	end
	local parts = { part("ПКМ", index <= HOTBAR and "в рюкзак" or "в руки") }
	local verb = UI.UseVerb(info)
	if verb then
		table.insert(parts, part("2×ЛКМ", lowerFirst(verb)))
	elseif index > HOTBAR or index ~= Panels.GetActive() then
		table.insert(parts, part("2×ЛКМ", "в руки"))
	end
	table.insert(parts, part("Q", "выбросить"))
	table.insert(parts, part("T", "передать"))
	return table.concat(parts, "   ")
end

local function positionTooltip()
	local tip = inv.tooltip
	if not tip or not tip.frame.Visible then
		return
	end
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local size = tip.frame.AbsoluteSize
	local pos = UserInputService:GetMouseLocation()
	local anchor = tip.anchor
	if anchor then
		pos = Vector2.new(anchor.X, anchor.Y)
	end
	local x = pos.X + 18
	local y = pos.Y + 20
	if x + size.X > vp.X - 10 then
		x = pos.X - 16 - size.X
	end
	if y + size.Y > vp.Y - 10 then
		y = pos.Y - 16 - size.Y
	end
	tip.frame.Position = UDim2.fromOffset(math.max(8, math.floor(x)), math.max(8, math.floor(y)))
end

refreshTooltip = function()
	local tip = inv.tooltip
	if not tip then
		return
	end
	local index = hoverIndex
	if openName ~= "inventory" or (drag and drag.started) then
		index = nil
	end
	local entry = index and slotsTable()[index] or nil
	local info = UI.EntryInfo(entry)
	if not info then
		tip.frame.Visible = false
		tip.key = nil
		tip.anchor = nil
		return
	end
	local key = table.concat({ index, info.kind, info.id, info.count, info.level, tostring(entry.mag), Panels.GetActive() }, ":")
	if key ~= tip.key then
		tip.key = key
		tip.name.Text = info.name .. (info.level > 0 and (" +" .. info.level) or "")
		tip.name.TextColor3 = info.rarityColor
		local category = info.kind == "weapon" and "Оружие" or (info.item and Items.Categories[info.item.cat] or "Предмет")
		tip.sub.Text = info.rarity.name .. " · " .. category .. (index <= HOTBAR and " · в руках" or " · рюкзак")
		local rows = statRows(info, entry)
		for i = 1, #tip.rows do
			local row = tip.rows[i]
			local data = rows[i]
			row.frame.Visible = data ~= nil
			if data then
				row.label.Text = data[1]
				row.value.Text = data[2]
				row.value.TextColor3 = data[3] or UI.V5.text
			end
		end
		local desc = info.kind == "weapon" and (info.def and info.def.desc or "") or (info.item and info.item.desc or "")
		tip.desc.Text = desc
		tip.desc.Visible = desc ~= "" and #rows < 3
		tip.hints.Text = tooltipHints(index, info)
	end
	-- на сенсорном экране курсора нет: подсказку ставим над слотом рюкзака
	local widget = bagSlots[index]
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled and widget then
		local p = widget.button.AbsolutePosition
		tip.anchor = Vector2.new(p.X, p.Y - 8)
	else
		tip.anchor = nil
	end
	tip.frame.Visible = true
	positionTooltip()
end

-- Перетаскивание ---------------------------------------------------------------------------------

local function pointerPosition(input)
	if input and input.UserInputType == Enum.UserInputType.Touch then
		local inset = GuiService:GetGuiInset()
		return Vector2.new(input.Position.X, input.Position.Y) + inset
	end
	return UserInputService:GetMouseLocation()
end

local function inside(obj, pos, pad)
	if not obj then
		return false
	end
	pad = pad or 0
	local p, s = obj.AbsolutePosition, obj.AbsoluteSize
	return pos.X >= p.X - pad and pos.X <= p.X + s.X + pad and pos.Y >= p.Y - pad and pos.Y <= p.Y + s.Y + pad
end

local function hotbarWidget(index)
	local hud = C.HUD
	if hud and hud.GetHotbarSlot then
		return hud.GetHotbarSlot(index)
	end
	return nil
end

local function hitSlot(pos)
	for i = HOTBAR + 1, TOTAL do
		local w = bagSlots[i]
		if w and inside(w.button, pos) then
			return i
		end
	end
	for i = 1, HOTBAR do
		local w = hotbarWidget(i)
		if w and w.button.Visible and inside(w.button, pos) then
			return i
		end
	end
	return nil
end

-- Панель и полоса хотбара: отпустить мимо них — выбросить предмет
local function overInventoryArea(pos)
	if inside(inv.panel, pos, 6) then
		return true
	end
	local first, last = hotbarWidget(1), hotbarWidget(HOTBAR)
	if first and last then
		local p1 = first.button.AbsolutePosition
		local p2 = last.button.AbsolutePosition
		local s2 = last.button.AbsoluteSize
		local pad = 14
		local left = math.min(p1.X, p2.X) - 64
		local right = math.max(p1.X, p2.X) + s2.X + pad
		local top = math.min(p1.Y, p2.Y) - pad
		local bottom = math.max(p1.Y, p2.Y) + s2.Y + pad
		if pos.X >= left and pos.X <= right and pos.Y >= top and pos.Y <= bottom then
			return true
		end
	end
	return false
end

local function halfCount(index)
	local e = slotsTable()[index]
	if e and UI.EntryKind(e) == "item" and entryCount(e) > 1 then
		return math.floor(entryCount(e) / 2)
	end
	return nil
end

local function makeGhost(index)
	local V = UI.V5
	local entry = slotsTable()[index]
	local widget = index <= HOTBAR and hotbarWidget(index) or bagSlots[index]
	local box = widget and widget.button.AbsoluteSize or Vector2.new(SLOT_SIZE, SLOT_SIZE)
	local size = math.max(28, math.floor(math.max(box.X, box.Y)))
	local frame = UI.Frame(gui, {
		Name = "DragGhost",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = V.slot,
		BackgroundTransparency = 0.3,
		ZIndex = 70,
	})
	UI.Corner(frame, V.corner)
	local stroke = UI.Stroke(frame, V.line, 1.5, 0.35)
	local pad = math.floor(size * 0.1)
	local vp = UI.IconViewport(frame, {
		Position = UDim2.fromOffset(pad, pad),
		Size = UDim2.new(1, -pad * 2, 1, -pad * 2),
		ImageTransparency = 0.1,
		ZIndex = 71,
	})
	UI.SetItemIcon(vp, entry)
	local count = UI.Label(frame, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -4, 1, -2), Size = UDim2.fromOffset(50, 16), Text = "", TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 0.15, ZIndex = 72 })
	local dropLabel = UI.Label(frame, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 4), Size = UDim2.fromOffset(140, 16), Text = "Выбросить", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = V.bad, TextStrokeTransparency = 0.3, ZIndex = 72, Visible = false })
	local info = UI.EntryInfo(entry)
	count.Text = (info and info.count > 1) and tostring(info.count) or ""
	return { frame = frame, stroke = stroke, count = count, dropLabel = dropLabel }
end

local function startDrag(d)
	d.started = true
	d.ghost = makeGhost(d.from)
	lastClickIndex = nil
	closePicker()
	refreshTooltip()
	renderIndex(d.from)
	if hoverIndex then
		renderIndex(hoverIndex)
	end
end

local function updateDrag()
	local d = drag
	if not d then
		return
	end
	local pos = (d.touch and d.lastPos) or UserInputService:GetMouseLocation()
	if not slotsTable()[d.from] then
		cancelDrag()
		return
	end
	if not d.started then
		if (pos - d.start).Magnitude >= DRAG_START then
			startDrag(d)
		elseif d.touch and not d.longDone and os.clock() - d.t0 >= LONG_PRESS then
			-- долгое касание на телефоне = ПКМ
			d.longDone = true
			Panels.QuickTransfer(d.from)
			return
		else
			return
		end
	end
	local ghost = d.ghost
	ghost.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
	local over = hitSlot(pos)
	if over == nil and not overInventoryArea(pos) then
		over = "drop"
	end
	local half = shiftDown()
	if over ~= d.over or half ~= d.half then
		local old = d.over
		d.over, d.half = over, half
		d.count = half and halfCount(d.from) or nil
		local info = UI.EntryInfo(slotsTable()[d.from])
		ghost.count.Text = d.count and tostring(d.count) or ((info and info.count > 1) and tostring(info.count) or "")
		local color, transparency = UI.V5.line, 0.35
		if over == "drop" then
			d.valid = true
			color, transparency = UI.V5.bad, 0
		elseif type(over) == "number" and over ~= d.from then
			d.valid = moveValid(d.from, over, d.count)
			color, transparency = d.valid and UI.V5.ok or UI.V5.bad, 0
		else
			d.valid = false
		end
		ghost.stroke.Color = color
		ghost.stroke.Transparency = transparency
		ghost.dropLabel.Visible = over == "drop"
		if type(old) == "number" then
			renderIndex(old)
		end
		if type(over) == "number" then
			renderIndex(over)
		end
	end
end

cancelDrag = function()
	local d = drag
	if not d then
		return
	end
	drag = nil
	if d.ghost then
		d.ghost.frame:Destroy()
	end
	if d.started then
		renderAll()
	end
end

local function finishPress()
	local d = drag
	if not d then
		return
	end
	if d.started then
		updateDrag()
		local from, over, count, valid = d.from, d.over, d.count, d.valid
		cancelDrag()
		if over == "drop" then
			dropSlot(from, count == nil, count)
		elseif type(over) == "number" and over ~= from then
			if valid then
				if moveSlot(from, over, count) and selectedIndex == from then
					selectedIndex = over
				end
			else
				local dst = slotsTable()[over]
				flashHint(count and "Половину стопки — только в пустой слот" or (dst and "Стопка уже заполнена" or "Сюда не переложить"), true)
			end
		end
		refreshTooltip()
		return
	end
	drag = nil
	if d.longDone then
		return
	end
	local now = os.clock()
	if lastClickIndex == d.from and now - lastClickTime <= DOUBLE_CLICK then
		lastClickIndex = nil
		useSlot(d.from)
		return
	end
	lastClickIndex, lastClickTime = d.from, now
	if d.from <= HOTBAR then
		-- щелчок по хотбару = как клавиша 1–0: взять в руки или убрать
		Panels.EquipSlot(d.from)
		setSelected(nil)
	else
		uiSound("ui_click")
		setSelected(d.from)
	end
end

local function beginPress(index, input)
	if drag then
		return
	end
	if not slotsTable()[index] then
		lastClickIndex = nil
		setSelected(nil)
		return
	end
	drag = {
		from = index,
		input = input,
		mouse = input.UserInputType == Enum.UserInputType.MouseButton1,
		touch = input.UserInputType == Enum.UserInputType.Touch,
		start = pointerPosition(input),
		t0 = os.clock(),
		started = false,
	}
	drag.lastPos = drag.start
end

-- Ввод по слоту (хотбар HUD и рюкзак): ЛКМ/касание — взять, ПКМ — быстрый перенос
function Panels.SlotInputBegan(index, input)
	if openName ~= "inventory" then
		return
	end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		beginPress(index, input)
	elseif t == Enum.UserInputType.MouseButton2 then
		cancelDrag()
		Panels.QuickTransfer(index)
	end
end

function Panels.SlotHover(index, on)
	if openName ~= "inventory" then
		if hoverIndex ~= nil then
			local old = hoverIndex
			hoverIndex = nil
			renderIndex(old)
		end
		return
	end
	if on then
		if hoverIndex == index then
			return
		end
		local old = hoverIndex
		hoverIndex = index
		renderIndex(old)
		renderIndex(index)
		if slotsTable()[index] and not (drag and drag.started) then
			local now = os.clock()
			if now - lastHoverSound >= HOVER_SOUND_GAP then
				lastHoverSound = now
				uiSound("ui_hover")
			end
		end
		refreshTooltip()
	elseif hoverIndex == index then
		hoverIndex = nil
		renderIndex(index)
		refreshTooltip()
	end
end

local function hookBagSlot(index, w)
	bagSlots[index] = w
	w.button.InputBegan:Connect(function(input)
		Panels.SlotInputBegan(index, input)
	end)
	w.button.MouseEnter:Connect(function()
		Panels.SlotHover(index, true)
	end)
	w.button.MouseLeave:Connect(function()
		Panels.SlotHover(index, false)
	end)
end

-- Персонаж и показатели ---------------------------------------------------------------------------

local function formatMoney(value)
	if value >= 1000000 then
		return string.format("%.1fM", value / 1000000)
	elseif value >= 100000 then
		return math.floor(value / 1000) .. "k"
	end
	return UI.Thousands(value)
end

local function refreshStats()
	local tiles = inv.tiles
	if not tiles then
		return
	end
	local V = UI.V5
	local hum = localHumanoid()
	local hp, maxHp = 0, 100
	if hum then
		hp, maxHp = math.max(0, hum.Health), math.max(1, hum.MaxHealth)
	end
	local hpFraction = math.clamp(hp / maxHp, 0, 1)
	tiles.hp.badge:Set(hpFraction, nil, hpFraction < 0.3 and rgb(238, 86, 86) or nil)
	tiles.hp.value.Text = tostring(math.ceil(hp))
	tiles.hp.value.TextColor3 = hpFraction < 0.3 and rgb(255, 130, 118) or V.text

	local hunger = player:GetAttribute("Hunger")
	hunger = type(hunger) == "number" and math.clamp(hunger, 0, 100) or 100
	tiles.hunger.badge:Set(hunger / 100, nil, hunger < 20 and rgb(255, 150, 64) or nil)
	tiles.hunger.value.Text = math.floor(hunger + 0.5) .. "%"
	tiles.hunger.value.TextColor3 = hunger < 20 and rgb(255, 178, 120) or V.text

	tiles.money.value.Text = "$" .. formatMoney(money())

	local slots = slotsTable()
	local pack = 0
	for i = HOTBAR + 1, TOTAL do
		if slots[i] then
			pack = pack + 1
		end
	end
	inv.counter.Text = pack .. "/" .. BACKPACK
	inv.counter.TextColor3 = pack >= BACKPACK and rgb(255, 150, 110) or V.text
	local classId = player:GetAttribute("ClassId")
	inv.className.Text = Classes.Get(type(classId) == "string" and classId or "survivor").name
end

local AVATAR_JUNK = { "LuaSourceContainer", "Tool", "Sound", "ParticleEmitter", "Light", "Trail", "Beam", "LayerCollector", "ProximityPrompt", "ClickDetector", "Fire", "Smoke", "Sparkles", "ForceField", "Constraint", "BodyMover" }
local avatarFor = nil

-- Поза «стоя» по суставам (C0/C1), независимо от текущей анимации
local function neutralPose(model, root)
	local joints = {}
	for _, j in ipairs(model:GetDescendants()) do
		if j:IsA("JointInstance") and j.Part0 and j.Part1 then
			table.insert(joints, j)
		end
	end
	local placed = { [root] = true }
	for _ = 1, 24 do
		local progress = false
		for _, j in ipairs(joints) do
			local p0, p1 = j.Part0, j.Part1
			if placed[p0] and not placed[p1] then
				p1.CFrame = p0.CFrame * j.C0 * j.C1:Inverse()
				placed[p1] = true
				progress = true
			elseif placed[p1] and not placed[p0] then
				p0.CFrame = p1.CFrame * j.C1 * j.C0:Inverse()
				placed[p0] = true
				progress = true
			end
		end
		if not progress then
			break
		end
	end
end

local function buildAvatar()
	local char = player.Character
	if not inv.avatarWorld then
		return
	end
	if char == avatarFor and inv.avatarWorld:FindFirstChildWhichIsA("Model") then
		return
	end
	avatarFor = char
	inv.avatarWorld:ClearAllChildren()
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		avatarFor = nil
		return
	end
	local archivable = char.Archivable
	char.Archivable = true
	local ok, clone = pcall(function()
		return char:Clone()
	end)
	char.Archivable = archivable
	if not ok or not clone then
		return
	end
	for _, d in ipairs(clone:GetDescendants()) do
		local junk = false
		for _, cls in ipairs(AVATAR_JUNK) do
			if d:IsA(cls) then
				junk = true
				break
			end
		end
		if junk then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CastShadow = false
			d.LocalTransparencyModifier = 0
		elseif d:IsA("Humanoid") then
			d.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local croot = clone:FindFirstChild("HumanoidRootPart")
	if not croot or not croot:IsA("BasePart") then
		clone:Destroy()
		return
	end
	neutralPose(clone, croot)
	clone.PrimaryPart = croot
	clone:PivotTo(CFrame.new())
	clone.Parent = inv.avatarWorld
	local cf, size = clone:GetBoundingBox()
	local fov = 28
	local tanHalf = math.tan(math.rad(fov / 2))
	local aspect = AVATAR_W / math.max(1, PANEL_H - PAD * 2)
	local distV = (size.Y * 0.5) / tanHalf
	local distH = (math.max(size.X, size.Z) * 0.5) / (tanHalf * math.max(0.2, aspect))
	local dist = math.max(distV, distH) * 1.06
	local center = cf.Position
	inv.avatarCamera.FieldOfView = fov
	inv.avatarCamera.CFrame = CFrame.lookAt(center + Vector3.new(dist * 0.16, size.Y * 0.03, -dist), center)
end

-- Панель инвентаря ---------------------------------------------------------------------------------

flashHint = function(text, isError)
	if isError then
		uiSound("ui_error")
	end
	if openName == "inventory" and inv.hint then
		inv.hintToken = (inv.hintToken or 0) + 1
		local token = inv.hintToken
		inv.hintLabel.Text = text
		inv.hintLabel.TextColor3 = isError and rgb(255, 130, 118) or UI.V5.text
		inv.hint.Visible = true
		task.delay(2.2, function()
			if inv.hintToken == token and inv.hint then
				inv.hint.Visible = false
			end
		end)
	else
		local hud = C.HUD
		if hud and hud.Notify then
			hud.Notify(text, isError and rgb(255, 130, 118) or nil)
		end
	end
end

local function buildTooltip()
	local V = UI.V5
	local frame = UI.Frame(gui, {
		Name = "ItemTooltip",
		Size = UDim2.fromOffset(238, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = rgb(11, 12, 14),
		BackgroundTransparency = 0.06,
		Visible = false,
		ZIndex = 60,
	})
	UI.AddScale(frame)
	UI.Corner(frame, V.corner)
	UI.Stroke(frame, V.line, 1, 0.72)
	UI.New("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		Parent = frame,
	})
	local layout = UI.List(frame, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	local name = UI.Label(frame, { Size = UDim2.new(1, 0, 0, 19), Text = "", TextSize = 16, Font = UI.Theme.font, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 1, LayoutOrder = 1, ZIndex = 61 })
	local sub = UI.Label(frame, { Size = UDim2.new(1, 0, 0, 14), Text = "", TextSize = 11, Font = UI.Theme.fontMedium, TextColor3 = V.muted, TextStrokeTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, ZIndex = 61 })
	local rows = {}
	for i = 1, 3 do
		local row = UI.Frame(frame, { Size = UDim2.new(1, 0, 0, 15), BackgroundTransparency = 1, LayoutOrder = 2 + i, Visible = false })
		local label = UI.Label(row, { Size = UDim2.new(0.62, 0, 1, 0), Text = "", TextSize = 12, Font = UI.Theme.fontMedium, TextColor3 = V.muted, TextStrokeTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 61 })
		local value = UI.Label(row, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.38, 0, 1, 0), Text = "", TextSize = 12, Font = UI.Theme.font, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 1, ZIndex = 61 })
		rows[i] = { frame = row, label = label, value = value }
	end
	local desc = UI.Label(frame, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = "", TextSize = 11, Font = UI.Theme.fontRegular, TextColor3 = V.muted, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextStrokeTransparency = 1, LayoutOrder = 6, Visible = false, ZIndex = 61 })
	local divider = UI.Frame(frame, { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = V.line, BackgroundTransparency = 0.86, LayoutOrder = 7, ZIndex = 61 })
	local hints = UI.Label(frame, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = "", TextSize = 11, Font = UI.Theme.fontMedium, TextColor3 = V.text, RichText = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextStrokeTransparency = 1, LayoutOrder = 8, ZIndex = 61 })
	inv.tooltip = { frame = frame, name = name, sub = sub, rows = rows, desc = desc, divider = divider, hints = hints, key = nil }
end

local function buildInventory()
	local V = UI.V5
	local H = UI.Hotbar

	-- держатель повторяет якорь нижней группы HUD: панель всегда ровно над хотбаром
	local holder = UI.Frame(gui, {
		Name = "InventoryHolder",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -H.bottom),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H + H.height + PANEL_LIFT),
		BackgroundTransparency = 1,
		Visible = false,
	})
	UI.AddScale(holder)
	inv.root = holder

	local panel = Instance.new("TextButton")
	panel.Name = "Inventory"
	panel.Text = ""
	panel.AutoButtonColor = false
	panel.BorderSizePixel = 0
	panel.BackgroundTransparency = 1
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -(H.height + PANEL_LIFT))
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.Selectable = false
	panel.Modal = true -- мышь свободна в первом лице, пока панель видна
	panel.Parent = holder
	inv.panel = panel
	inv.basePosition = panel.Position
	local anim = Instance.new("UIScale")
	anim.Parent = panel
	inv.anim = anim
	panel.Activated:Connect(function()
		if not drag then
			setSelected(nil)
		end
	end)

	-- Слева: плитки, персонаж, счётчик
	local left = UI.Frame(panel, { Name = "Survivor", Size = UDim2.fromOffset(LEFT_W, PANEL_H), BackgroundColor3 = V.panel, BackgroundTransparency = V.panelTransparency })
	UI.Corner(left, V.corner)
	UI.Stroke(left, V.line, 1, 0.75)
	inv.left = left

	inv.tiles = {}
	local tileDefs = { { key = "hp", title = "Здоровье" }, { key = "hunger", title = "Сытость" }, { key = "money", title = "Деньги" } }
	for i, t in ipairs(tileDefs) do
		local tile = UI.Frame(left, {
			Name = t.key,
			Position = UDim2.fromOffset(PAD, PAD + (i - 1) * (TILE_SIZE + TILE_GAP)),
			Size = UDim2.fromOffset(TILE_SIZE, TILE_SIZE),
			BackgroundColor3 = V.tile,
			BackgroundTransparency = V.tileTransparency,
		})
		UI.Corner(tile, V.corner)
		UI.Stroke(tile, V.line, 1, 0.82)
		local entry = { frame = tile }
		if t.key == "money" then
			UI.MoneyIcon(tile, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(TILE_SIZE / 2, 20) }, Vector2.new(34, 18))
		else
			entry.badge = UI.VitalBadge(tile, t.key == "hp" and "heart" or "food", {
				size = 32,
				showText = false,
				anchor = Vector2.new(0.5, 0),
				position = UDim2.new(0.5, 0, 0, 3),
			})
		end
		entry.value = UI.Label(tile, { Position = UDim2.fromOffset(0, 35), Size = UDim2.new(1, 0, 0, 15), Text = "", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.6 })
		UI.Label(tile, { Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 12), Text = t.title, TextSize = 9, Font = UI.Theme.fontMedium, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = V.muted, TextStrokeTransparency = 1 })
		inv.tiles[t.key] = entry
	end

	local stageX = PAD + TILE_SIZE + TILE_GAP
	local stage = UI.Frame(left, { Name = "Stage", Position = UDim2.fromOffset(stageX, PAD), Size = UDim2.fromOffset(AVATAR_W, PANEL_H - PAD * 2), BackgroundTransparency = 1 })
	local glow = UI.Frame(stage, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(1, 0.6), BackgroundColor3 = rgb(150, 160, 170), BackgroundTransparency = 0 })
	local glowGrad = Instance.new("UIGradient")
	glowGrad.Rotation = -90
	glowGrad.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.86), NumberSequenceKeypoint.new(1, 1) })
	glowGrad.Parent = glow
	local shadow = UI.Frame(stage, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.fromOffset(78, 9), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 0.5 })
	UI.Corner(shadow, 6)
	local avatar = Instance.new("ViewportFrame")
	avatar.Name = "Avatar"
	avatar.BackgroundTransparency = 1
	avatar.Size = UDim2.fromScale(1, 1)
	avatar.Ambient = rgb(130, 130, 134)
	avatar.LightColor = rgb(255, 235, 210)
	avatar.LightDirection = Vector3.new(-0.4, -0.7, 1)
	avatar.ZIndex = 2
	avatar.Parent = stage
	local world = Instance.new("WorldModel")
	world.Parent = avatar
	local avatarCamera = Instance.new("Camera")
	avatarCamera.Parent = avatar
	avatar.CurrentCamera = avatarCamera
	inv.avatarWorld = world
	inv.avatarCamera = avatarCamera

	inv.className = UI.Label(left, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0, stageX + AVATAR_W / 2, 1, -PAD), Size = UDim2.fromOffset(AVATAR_W, 16), Text = "", TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = V.muted, TextStrokeTransparency = 0.6, ZIndex = 3 })

	local counterPill = UI.Frame(left, { Name = "Counter", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -PAD, 0, PAD), Size = UDim2.fromOffset(62, 20), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 0.45, ZIndex = 3 })
	UI.Corner(counterPill, V.corner)
	UI.Stroke(counterPill, V.line, 1, 0.72)
	inv.counter = UI.Label(counterPill, { Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -24, 1, 0), Text = "0/" .. BACKPACK, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 1, ZIndex = 4 })
	local bagBody = UI.Frame(counterPill, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -5, 0.5, 2), Size = UDim2.fromOffset(9, 10), BackgroundColor3 = rgb(206, 208, 212), ZIndex = 4 })
	UI.Corner(bagBody, 2)
	UI.Frame(counterPill, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -7, 0.5, -3), Size = UDim2.fromOffset(5, 3), BackgroundColor3 = rgb(206, 208, 212), ZIndex = 4 })

	-- Справа: рюкзак 6×3
	local right = UI.Frame(panel, { Name = "Backpack", Position = UDim2.fromOffset(LEFT_W + BLOCK_GAP, 0), Size = UDim2.fromOffset(RIGHT_W, PANEL_H), BackgroundColor3 = V.panel, BackgroundTransparency = V.panelTransparency })
	UI.Corner(right, V.corner)
	UI.Stroke(right, V.line, 1, 0.75)
	inv.right = right
	for n = 0, BACKPACK - 1 do
		local index = HOTBAR + 1 + n
		local col, row = n % GRID_COLS, math.floor(n / GRID_COLS)
		local w = UI.ItemSlot(right, {
			size = SLOT_SIZE,
			cross = true,
			alwaysShowEmpty = true,
			transparency = 0.45,
			name = "Slot" .. index,
			position = UDim2.fromOffset(PAD + col * (SLOT_SIZE + SLOT_GAP), PAD + row * (SLOT_SIZE + SLOT_GAP)),
		})
		hookBagSlot(index, w)
	end

	-- Плашка подсказки над панелью («Рюкзак полон» и т. п.)
	local hint = UI.Frame(panel, { Name = "Hint", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -8), Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = rgb(11, 12, 14), BackgroundTransparency = 0.15, Visible = false, ZIndex = 5 })
	UI.Corner(hint, V.corner)
	UI.Stroke(hint, V.line, 1, 0.7)
	inv.hint = hint
	inv.hintLabel = UI.Label(hint, { Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Text = "", TextSize = 13, TextStrokeTransparency = 1, ZIndex = 6 })
	UI.New("UIPadding", { PaddingRight = UDim.new(0, 12), Parent = hint })

	buildTooltip()
	buildPicker(gui)
end

-- Показ окон ------------------------------------------------------------------------------------

local function onInventoryKey(_, state, input)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if openName ~= "inventory" or UserInputService:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end
	local index = hoverIndex or selectedIndex
	if index and slotsTable()[index] then
		local whole = shiftDown()
		if input.KeyCode == Enum.KeyCode.Q then
			dropSlot(index, whole)
		elseif input.KeyCode == Enum.KeyCode.T then
			giveSlot(index, whole)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function setInventoryVisible(open)
	local holder = inv.root
	if not holder then
		return
	end
	inv.token = (inv.token or 0) + 1
	local token = inv.token
	local base = inv.basePosition
	if open then
		holder.Visible = true
		inv.panel.Modal = true
		inv.anim.Scale = 0.96
		inv.panel.Position = base + UDim2.fromOffset(0, 10)
		UI.Tween(inv.anim, 0.14, { Scale = 1 })
		UI.Tween(inv.panel, 0.14, { Position = base })
		ContextActionService:BindActionAtPriority(KEYS_ACTION, onInventoryKey, false, INPUT_PRIORITY, Enum.KeyCode.Q, Enum.KeyCode.T)
	else
		inv.panel.Modal = false
		ContextActionService:UnbindAction(KEYS_ACTION)
		UI.Tween(inv.anim, 0.08, { Scale = 0.97 })
		UI.Tween(inv.panel, 0.08, { Position = base + UDim2.fromOffset(0, 8) })
		task.delay(0.09, function()
			if inv.token == token and openName ~= "inventory" then
				holder.Visible = false
			end
		end)
	end
end

local function show(name)
	local wasInventory = openName == "inventory"
	for key, p in pairs({ shop = shop, class = classes }) do
		if p.root then
			p.root.Visible = key == name
		end
	end
	if name ~= "inventory" then
		closePicker()
		cancelDrag()
		hoverIndex = nil
		selectedIndex = nil
		if inv.tooltip then
			inv.tooltip.frame.Visible = false
			inv.tooltip.key = nil
		end
		if inv.hint then
			inv.hint.Visible = false
		end
	end
	openName = name
	if wasInventory ~= (name == "inventory") then
		setInventoryVisible(name == "inventory")
		notifyOpen(name == "inventory")
		uiSound(name == "inventory" and "ui_open_bag" or "ui_close_bag")
		renderAll()
	end
	if name ~= nil then
		UserInputService.MouseIconEnabled = true
		if name ~= "inventory" then
			uiSound("ui_click")
		end
	end
end

function Panels.Close()
	if openName == nil then
		closePicker()
		return
	end
	show(nil)
end

local function refreshInventory()
	if not inv.root then
		return
	end
	renderAll()
	refreshStats()
	buildAvatar()
	refreshTooltip()
end

function Panels.ToggleInventory()
	local now = os.clock()
	if now - lastToggle < TOGGLE_GAP then
		return
	end
	lastToggle = now
	if openName == "inventory" then
		Panels.Close()
	elseif not Panels.IsOpen() then
		if inLobby() or player:GetAttribute("Sleeping") == true then
			return
		end
		local hum = localHumanoid()
		if not hum or hum.Health <= 0 then
			return
		end
		show("inventory")
		refreshInventory()
	else
		Panels.CloseAll()
	end
end

-- Магазин ----------------------------------------------------------------------------------

local function weaponStats(w)
	local ammoName = w.ammo and Items.List[w.ammo] and Items.List[w.ammo].name or ""
	if w.kind == "melee" then
		return string.format("Урон %d · удар раз в %.2f с%s", w.damage or 0, w.cooldown or 0, w.aoe and " · по площади" or "")
	elseif w.kind == "gun" then
		return string.format("Урон %d%s · раз в %.2f с · магазин %d · %s", w.damage or 0, w.pellets and (" x" .. w.pellets) or "", w.cooldown or 0, w.mag or 0, ammoName)
	elseif w.kind == "bow" then
		return string.format("Урон %d–%d · %s", w.damageMin or 0, w.damageMax or 0, ammoName)
	elseif w.kind == "crossbow" then
		return string.format("Урон %d · пробивает %d · %s", w.damage or 0, w.pierce or 1, ammoName)
	end
	return w.desc or ""
end

local function makeWindow(title, size)
	local win = UI.Window({ parent = gui, title = title, size = size, onClose = function()
		Panels.Close()
	end })
	Panels.AttachScale(win.frame)
	return win
end

local function rowIcon(parent, entry, color)
	local holder = UI.Frame(parent, { Position = UDim2.fromOffset(8, 6), Size = UDim2.fromOffset(44, 44), BackgroundColor3 = UI.V5.slot, BackgroundTransparency = 0.4 })
	UI.Corner(holder, UI.V5.corner)
	UI.Stroke(holder, color or UI.V5.line, 1, 0.7)
	local vp = UI.IconViewport(holder, { Position = UDim2.fromOffset(2, 2), Size = UDim2.new(1, -4, 1, -4) })
	UI.SetItemIcon(vp, entry)
end

-- Строка магазина: icon {kind, id}, title, subtitle, titleColor, price (текст), buttons
local function row(parent, order, opts)
	local r = UI.Frame(parent, { Size = UDim2.new(1, -4, 0, 56), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = opts.highlight and 0.9 or 0.95, LayoutOrder = order })
	UI.Corner(r, UI.V5.corner)
	local left = 12
	if opts.icon then
		rowIcon(r, opts.icon, opts.titleColor)
		left = 62
	end
	local buttons = opts.buttons or {}
	local buttonsWidth = 0
	for _, b in ipairs(buttons) do
		buttonsWidth = buttonsWidth + (b.width or 100) + 6
	end
	local textRight = buttonsWidth + (opts.price and 100 or 10) + left
	UI.Label(r, { Size = UDim2.new(1, -textRight, 0, 20), Position = UDim2.fromOffset(left, 8), Text = opts.title, TextSize = 15, TextColor3 = opts.titleColor or UI.V5.text, TextTruncate = Enum.TextTruncate.AtEnd })
	UI.Label(r, { Size = UDim2.new(1, -textRight, 0, 18), Position = UDim2.fromOffset(left, 29), Text = opts.subtitle or "", TextSize = 12, TextColor3 = UI.V5.muted, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 1, Font = UI.Theme.fontRegular })
	if opts.price then
		UI.Label(r, { Size = UDim2.fromOffset(90, 56), Position = UDim2.new(1, -buttonsWidth - 100, 0, 0), Text = opts.price, TextSize = 17, Font = UI.Theme.fontBlack, TextColor3 = opts.priceColor or UI.V5.money, TextXAlignment = Enum.TextXAlignment.Right })
	end
	local x = -8
	for i = #buttons, 1, -1 do
		local b = buttons[i]
		x = x - (b.width or 100)
		local btn = UI.ActionButton(r, { Size = UDim2.fromOffset(b.width or 100, 34), Position = UDim2.new(1, x, 0, 11), Text = b.text, TextSize = 14 }, b.style or "primary", function()
			if not b.disabled then
				b.onClick()
				uiSound("ui_click")
			end
		end)
		if b.disabled then
			UI.DisableButton(btn)
		end
		x = x - 6
	end
	return r
end

local function note(parent, order, text)
	UI.Label(parent, { Size = UDim2.new(1, -4, 0, 34), LayoutOrder = order, Text = text, TextSize = 13, TextWrapped = true, TextColor3 = UI.V5.muted, Font = UI.Theme.fontRegular, TextStrokeTransparency = 1 })
end

local function refreshShop()
	if not shop.root or openName ~= "shop" then
		return
	end
	local cash = money()
	shop.win:SetMoney(cash)
	shop.tabs:Set(shopTab)
	local list = shop.list
	UI.Clear(list)
	UI.List(list, 5)
	local inventory = C.State.Inventory or {}
	local order = 0
	local function nextOrder()
		order = order + 1
		return order
	end

	if shopTab == "sell" then
		local total = 0
		for id, count in pairs(inventory) do
			local item = Items.List[id]
			if item and item.cat == "valuable" and type(count) == "number" then
				total = total + (item.sell or 0) * count
			end
		end
		row(list, nextOrder(), {
			title = "Продать все ценности",
			subtitle = "Часы, слитки, идолы и прочее",
			titleColor = UI.Colors.yellow,
			price = "+$" .. total,
			highlight = true,
			buttons = { { text = "Продать всё", width = 130, style = "good", disabled = total == 0, onClick = function()
				Net.Get("SellAll"):FireServer()
			end } },
		})
		local entries = {}
		for id, count in pairs(inventory) do
			local item = Items.List[id]
			if item and (item.sell or 0) > 0 and type(count) == "number" and count > 0 then
				table.insert(entries, { id = id, item = item, count = count })
			end
		end
		table.sort(entries, function(a, b)
			if a.item.sell ~= b.item.sell then
				return a.item.sell > b.item.sell
			end
			return a.item.name < b.item.name
		end)
		for _, e in ipairs(entries) do
			local rarity = Items.Rarities[e.item.rarity] or Items.Rarities.common
			row(list, nextOrder(), {
				icon = { kind = "item", id = e.id },
				title = e.item.name .. "  ×" .. e.count,
				subtitle = rarity.name .. " · $" .. e.item.sell .. " за шт.",
				titleColor = rarityColor(e.item.rarity),
				price = "$" .. e.item.sell * e.count,
				buttons = {
					{ text = "Продать 1", style = "normal", onClick = function()
						Net.Get("ShopSell"):FireServer(e.id, 1)
					end },
					{ text = "Все", width = 64, style = "good", onClick = function()
						Net.Get("ShopSell"):FireServer(e.id, e.count)
					end },
				},
			})
		end
		if #entries == 0 then
			note(list, nextOrder(), "Продавать нечего: найденные ценности и лишние припасы появятся здесь.")
		end
	elseif shopTab == "supplies" or shopTab == "ammo" or shopTab == "materials" or shopTab == "parts" then
		if shopTab == "parts" then
			local state = Net.State()
			local hp = state:GetAttribute("BusHP") or 0
			local maxHp = state:GetAttribute("BusMaxHP") or 0
			local repair = Items.RepairService
			row(list, nextOrder(), {
				title = "Ремонт автобуса",
				subtitle = string.format("+%d прочности (сейчас %d / %d)", repair.hp, hp, maxHp),
				titleColor = UI.Colors.green,
				price = "$" .. repair.price,
				highlight = true,
				buttons = { { text = "Починить", style = "good", disabled = maxHp <= 0 or hp >= maxHp or cash < repair.price, onClick = function()
					Net.Get("ShopBuy"):FireServer("repair", "bus")
				end } },
			})
			note(list, nextOrder(), "Детали прикрепляются к автобусу: возьмите деталь и подойдите к пустому слоту на корпусе.")
		else
			note(list, nextOrder(), "Купленное кладётся в свободный слот. Если места нет — предмет упадёт рядом с вами.")
		end
		for _, entry in ipairs(Items.Shop[shopTab] or {}) do
			local item = Items.List[entry.id]
			if item then
				local pack = item.pack and (" (×" .. item.pack .. ")") or ""
				local subtitle = item.desc or ""
				local part = BusParts.List[entry.id]
				local slot = part and BusParts.Slots[part.slot]
				if slot then
					subtitle = "Слот: " .. slot.name .. " · " .. subtitle
				end
				row(list, nextOrder(), {
					icon = { kind = "item", id = entry.id },
					title = item.name .. pack,
					subtitle = subtitle .. " · у вас: " .. (inventory[entry.id] or 0),
					titleColor = rarityColor(item.rarity),
					price = "$" .. entry.price,
					priceColor = cash >= entry.price and UI.V5.money or rgb(255, 110, 90),
					buttons = { { text = "Купить", disabled = cash < entry.price, onClick = function()
						Net.Get("ShopBuy"):FireServer("item", entry.id)
					end } },
				})
			end
		end
	elseif shopTab == "weapons" then
		local owned = {}
		for _, w in ipairs(C.State.WeaponOrder or {}) do
			owned[w] = true
		end
		local levels = weaponLevels()
		for _, id in ipairs(Weapons.ShopOrder or {}) do
			local w = Weapons.List[id]
			if w then
				local level = levels[id] or 0
				local ownedText = level > 0 and ("Есть +" .. level) or "Есть"
				local price = w.price or 0
				row(list, nextOrder(), {
					icon = { kind = "weapon", id = id },
					title = w.name,
					subtitle = weaponStats(w) .. " · " .. (w.desc or ""),
					titleColor = rarityColor(w.rarity),
					price = "$" .. price,
					priceColor = (owned[id] or cash >= price) and UI.V5.money or rgb(255, 110, 90),
					buttons = { { text = owned[id] and ownedText or "Купить", width = 110, disabled = owned[id] or cash < price, onClick = function()
						Net.Get("ShopBuy"):FireServer("weapon", id)
					end } },
				})
			end
		end
	end
end

local SHOP_TABS = {
	{ "sell", "Продать" },
	{ "supplies", "Припасы" },
	{ "materials", "Материалы" },
	{ "parts", "Детали" },
	{ "ammo", "Патроны" },
	{ "weapons", "Оружие" },
}

local function buildShop()
	local win = makeWindow("МАГАЗИН", Vector2.new(880, 590))
	shop.win = win
	shop.root = win.frame
	shop.header = win.header
	shop.tabs = UI.Tabs(win.frame, SHOP_TABS, UDim2.fromOffset(20, 60), 118, function(key)
		shopTab = key
		uiSound("ui_click")
		refreshShop()
	end)
	shop.list = UI.Scroller(win.frame, { Size = UDim2.new(1, -40, 1, -124), Position = UDim2.fromOffset(20, 104) })
end

function Panels.OpenShop(info)
	if not shop.root then
		return
	end
	Panels.CloseAll()
	local name = type(info) == "table" and type(info.name) == "string" and info.name or "МАГАЗИН"
	shop.header.Text = string.upper(name)
	show("shop")
	refreshShop()
end

-- Выбор класса ---------------------------------------------------------------------------------

local function refreshClasses()
	if not classes.root then
		return
	end
	UI.Clear(classes.list)
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(238, 250)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = classes.list
	local current = player:GetAttribute("ClassId") or "survivor"
	for i, id in ipairs(Classes.Order) do
		local c = Classes.List[id]
		local selected = id == current
		local card = UI.Frame(classes.list, { BackgroundColor3 = selected and rgb(46, 34, 18) or rgb(255, 255, 255), BackgroundTransparency = selected and 0.15 or 0.95, LayoutOrder = i })
		UI.Corner(card, UI.V5.corner)
		UI.Stroke(card, selected and UI.V5.accent or UI.V5.line, 1, selected and 0 or 0.8)
		UI.Padding(card, 10)
		UI.Label(card, { Size = UDim2.new(1, 0, 0, 24), Text = c.name, TextSize = 18, Font = UI.Theme.fontBlack, TextColor3 = selected and UI.V5.accent or UI.V5.text, TextStrokeTransparency = 1 })
		UI.Label(card, { Size = UDim2.new(1, 0, 0, 32), Position = UDim2.fromOffset(0, 26), Text = c.desc, TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = UI.V5.muted, TextStrokeTransparency = 1, Font = UI.Theme.fontRegular })
		local kit = {}
		for _, w in ipairs(c.weapons or {}) do
			local wd = Weapons.List[w]
			table.insert(kit, wd and wd.name or w)
		end
		for itemId, n in pairs(c.items or {}) do
			local it = Items.List[itemId]
			table.insert(kit, (it and it.name or itemId) .. " ×" .. n)
		end
		UI.Label(card, { Size = UDim2.new(1, 0, 0, 70), Position = UDim2.fromOffset(0, 62), Text = "• " .. table.concat(c.perks or {}, "\n• "), TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
		UI.Label(card, { Size = UDim2.new(1, 0, 0, 48), Position = UDim2.fromOffset(0, 136), Text = "С собой: " .. table.concat(kit, ", "), TextSize = 11, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = UI.V5.muted, TextStrokeTransparency = 1, Font = UI.Theme.fontRegular })
		local btn = UI.ActionButton(card, { Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 1, -34), Text = selected and "Выбран" or "Выбрать" }, selected and "normal" or "primary", function()
			if id == (player:GetAttribute("ClassId") or "survivor") then
				return
			end
			Net.Get("SelectClass"):FireServer(id)
			uiSound("ui_click")
			task.delay(0.4, refreshClasses)
		end)
		if selected then
			UI.DisableButton(btn)
			btn.TextColor3 = UI.V5.accent
		end
	end
end

local function buildClasses()
	local win = UI.Window({ parent = gui, title = "ВЫБОР КЛАССА", size = Vector2.new(1040, 640), showMoney = false, onClose = function()
		Panels.Close()
	end })
	Panels.AttachScale(win.frame)
	classes.win = win
	classes.root = win.frame
	UI.Label(win.frame, { Size = UDim2.fromOffset(420, 46), Position = UDim2.new(1, -480, 0, 6), Text = "Класс можно сменить в лобби и в депо до отправления", TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = UI.V5.muted, TextStrokeTransparency = 1 })
	classes.list = UI.Scroller(win.frame, { Size = UDim2.new(1, -40, 1, -130), Position = UDim2.fromOffset(20, 66) })
	UI.ActionButton(win.frame, { Size = UDim2.fromOffset(200, 38), Position = UDim2.new(0.5, -100, 1, -50), Text = "Готово", TextSize = 16 }, "primary", function()
		Panels.Close()
	end)
end

-- Открывается из лобби (LobbyUI), в депо (сервер OpenClassSelect) — без проверки состояния заезда
function Panels.OpenClassSelect()
	if not classes.root then
		return
	end
	Panels.CloseAll()
	show("class")
	refreshClasses()
end

-- Итоги заезда -------------------------------------------------------------------------------------

local function statTile(parent, x, title)
	local tile = UI.Panel(parent, { Size = UDim2.fromOffset(240, 78), Position = UDim2.new(0.5, x, 0, 150), ZIndex = 21 })
	UI.Label(tile, { Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 10), Text = title, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = UI.V5.muted, ZIndex = 22 })
	return UI.Label(tile, { Size = UDim2.new(1, 0, 0, 36), Position = UDim2.fromOffset(0, 30), Text = "", TextSize = 30, Font = UI.Theme.fontBlack, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 22 })
end

local END_COLUMNS = {
	{ "Игрок", 0, 250, Enum.TextXAlignment.Left },
	{ "Убийства", 260, 110 },
	{ "Заработано", 380, 130 },
	{ "Поднял", 520, 100 },
	{ "Опыт", 630, 110 },
	{ "Билеты", 750, 110 },
}

local function endRow(parent, order, values, header)
	local r = UI.Frame(parent, { Size = UDim2.new(1, -4, 0, header and 24 or 34), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = header and 1 or 0.94, LayoutOrder = order, ZIndex = 21 })
	UI.Corner(r, UI.V5.corner)
	for i, col in ipairs(END_COLUMNS) do
		UI.Label(r, {
			Size = UDim2.fromOffset(col[3], header and 24 or 34),
			Position = UDim2.fromOffset(col[2] + 10, 0),
			Text = tostring(values[i] or ""),
			TextSize = header and 11 or 15,
			TextColor3 = header and UI.V5.muted or (i == 3 and UI.V5.money or UI.V5.text),
			TextXAlignment = col[4] or Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 22,
		})
	end
end

local function buildEnd()
	local frame = UI.Frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 0.3, Visible = false, ZIndex = 20 })
	ending.frame = frame
	local content = UI.Frame(frame, { Size = UDim2.fromOffset(900, 620), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, ZIndex = 20 })
	Panels.AttachScale(content)
	ending.title = UI.Label(content, { Size = UDim2.new(1, 0, 0, 64), Position = UDim2.fromOffset(0, 30), TextXAlignment = Enum.TextXAlignment.Center, Font = UI.Theme.fontBlack, TextSize = 48, TextStrokeTransparency = 0.4, ZIndex = 21 })
	ending.subtitle = UI.Label(content, { Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 98), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 18, TextColor3 = rgb(220, 220, 225), ZIndex = 21 })
	ending.km = statTile(content, -370, "ПРОЙДЕНО")
	ending.time = statTile(content, -120, "ВРЕМЯ В ПУТИ")
	ending.kills = statTile(content, 130, "ЗОМБИ УБИТО")
	ending.list = UI.Scroller(content, { Size = UDim2.new(1, 0, 0, 290), Position = UDim2.fromOffset(0, 250), ZIndex = 21 })
	ending.timer = UI.Label(content, { Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 1, -40), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 16, TextColor3 = UI.V5.muted, ZIndex = 21 })
end

function Panels.ShowEnd(kind, stats)
	Panels.CloseAll()
	stats = type(stats) == "table" and stats or {}
	local frame = ending.frame
	frame.Visible = true
	local victory = kind == "victory"
	ending.title.Text = victory and "ВЫ ДОЕХАЛИ ДО КОНЕЧНОЙ!" or "КОНЕЦ ПУТИ"
	ending.title.TextColor3 = victory and rgb(255, 210, 80) or rgb(255, 80, 70)
	local km = tonumber(stats.km) or 0
	local totalKm = tonumber(stats.totalKm) or 0
	ending.subtitle.Text = victory and "Автобус добрался до последней остановки" or "Автобус не доехал — попробуйте ещё раз"
	ending.km.Text = string.format("%.1f / %d км", km, totalKm)
	ending.time.Text = Util.FormatTime(tonumber(stats.time) or 0)
	ending.kills.Text = tostring(stats.kills or 0)
	UI.Clear(ending.list)
	UI.List(ending.list, 4)
	local header = {}
	for i, col in ipairs(END_COLUMNS) do
		header[i] = string.upper(col[1])
	end
	endRow(ending.list, 0, header, true)
	for i, p in ipairs(type(stats.players) == "table" and stats.players or {}) do
		if type(p) == "table" then
			endRow(ending.list, i, {
				tostring(p.name or "?"),
				p.kills or 0,
				"$" .. (p.earned or 0),
				p.revives or 0,
				p.xp and ("+" .. p.xp) or "—",
				p.tickets and ("+" .. p.tickets) or "—",
			})
		end
	end
	local seconds = tonumber(stats.returnIn) or (victory and 30 or 14)
	seconds = math.clamp(math.floor(seconds), 1, 120)
	local timerPrefix = "Продолжение через "
	if stats.nextMode == "lobby" then
		timerPrefix = "Возвращение в лобби через "
	elseif stats.nextMode == "run" then
		timerPrefix = "Новый заезд через "
	end
	ending.token = (ending.token or 0) + 1
	local token = ending.token
	task.spawn(function()
		for s = seconds, 1, -1 do
			if not frame.Visible or ending.token ~= token then
				return
			end
			ending.timer.Text = timerPrefix .. s .. " с"
			task.wait(1)
		end
		if ending.token == token then
			frame.Visible = false
		end
	end)
end

-- Инициализация ---------------------------------------------------------------------------------------

function Panels.Init(c)
	C = c
	UI = C.UI
	local st = C.State
	st.Slots = st.Slots or {}
	st.Active = st.Active or 0
	gui = UI.Screen("Panels", 10)
	buildInventory()
	buildShop()
	buildClasses()
	buildEnd()

	local cameraConn
	local function hookCamera()
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end
		local cam = workspace.CurrentCamera
		if cam then
			cameraConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScales)
		end
		updateScales()
	end
	hookCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)

	Net.Get("Inventory").OnClientEvent:Connect(applyInventory)
	Panels.OnInventory(function()
		if openName == "inventory" then
			renderAll()
			refreshStats()
			refreshTooltip()
			refreshPicker()
		elseif openName == "shop" then
			refreshShop()
		end
	end)
	Net.Get("OpenShop").OnClientEvent:Connect(Panels.OpenShop)
	Net.Get("OpenClassSelect").OnClientEvent:Connect(Panels.OpenClassSelect)
	Net.Get("EndScreen").OnClientEvent:Connect(Panels.ShowEnd)
	player:GetAttributeChangedSignal("Money"):Connect(function()
		if openName == "inventory" then
			refreshStats()
		elseif openName == "shop" then
			refreshShop()
		end
	end)
	player:GetAttributeChangedSignal("ClassId"):Connect(function()
		if openName == "class" then
			refreshClasses()
		elseif openName == "inventory" then
			refreshStats()
		end
	end)
	local state = Net.State()
	for _, attr in ipairs({ "BusHP", "BusMaxHP" }) do
		state:GetAttributeChangedSignal(attr):Connect(function()
			if openName == "shop" and shopTab == "parts" then
				refreshShop()
			end
		end)
	end
	state:GetAttributeChangedSignal("RunState"):Connect(function()
		-- после отправления из депо класс уже не сменить
		if openName == "class" and state:GetAttribute("RunState") == "Driving" then
			Panels.Close()
		end
	end)

	-- Tab: перехватываем с высоким приоритетом и Sink, чтобы не спорить со списком игроков Roblox
	-- и с запасной привязкой WeaponClient (иначе окно открывалось и сразу закрывалось)
	ContextActionService:BindActionAtPriority(TAB_ACTION, function(_, inputState)
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			Panels.ToggleInventory()
		end
		return Enum.ContextActionResult.Sink
	end, false, INPUT_PRIORITY, Enum.KeyCode.Tab, Enum.KeyCode.ButtonSelect)

	-- Esc и меню Roblox закрывают окно
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape and openName ~= nil then
			Panels.Close()
		end
	end)
	pcall(function()
		GuiService.MenuOpened:Connect(function()
			if openName ~= nil then
				Panels.Close()
			end
		end)
	end)

	-- Перетаскивание мышью и пальцем
	UserInputService.InputChanged:Connect(function(input)
		local d = drag
		if d and d.touch and input == d.input then
			d.lastPos = pointerPosition(input)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local d = drag
		if not d then
			return
		end
		if (d.mouse and input.UserInputType == Enum.UserInputType.MouseButton1) or input == d.input then
			finishPress()
		end
	end)

	RunService.RenderStepped:Connect(function()
		if drag then
			-- страховка: если отпускание мыши потерялось, завершаем перетаскивание сами
			if drag.mouse and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				finishPress()
			else
				local ok, err = pcall(updateDrag)
				if not ok and not dragWarned then
					dragWarned = true
					warn("[Panels] " .. tostring(err))
				end
			end
		end
		local tip = inv.tooltip
		if tip and tip.frame.Visible then
			positionTooltip()
		end
	end)

	-- 10 Гц: снятие устаревшего предсказания; 4 Гц при открытом окне: показатели и проверки
	local tickFast, tickSlow = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		tickFast = tickFast + dt
		if tickFast >= 0.1 then
			tickFast = 0
			local now = os.clock()
			local changed = false
			if predicted and now >= predicted.untilT then
				predicted = nil
				changed = true
			end
			if activeOverride and now >= activeOverride.untilT then
				activeOverride = nil
				changed = true
			end
			if changed then
				notifyInventory()
			end
		end
		if openName ~= "inventory" then
			return
		end
		tickSlow = tickSlow + dt
		if tickSlow >= 0.25 then
			tickSlow = 0
			if not UserInputService.MouseIconEnabled then
				UserInputService.MouseIconEnabled = true
			end
			local hum = localHumanoid()
			if inLobby() or player:GetAttribute("Sleeping") == true or not hum or hum.Health <= 0 then
				Panels.Close()
				return
			end
			refreshStats()
			buildAvatar()
		end
	end)
end

return Panels
