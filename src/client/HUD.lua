-- HUD заезда (v5, по видео оригинала, своя графика):
--  верх-центр: «95 749 м до конечной» + время суток (солнце/луна, «07:40»), полоса босса, тосты
--  слева сверху: деньги (зелёная купюра + сумма на тёмной полосе); ниже значки-силуэты из фигур:
--             сердце (здоровье, число) и окорочок (сытость, %), заливка снизу вверх; сердце пульсирует
--             при < 30 %, окорочок трясётся при < 20 %; под ними — эффекты
--  слева снизу: уведомления
--  низ-центр: панель задания и хотбар из 10 слотов с 3D-иконками (рюкзак → Tab, клавиши 1–0, колесо мыши,
--             клик → InventoryAction equip, ПКМ при свободном курсоре → в рюкзак). Пока открыт Tab,
--             хотбар интерактивный: перетаскивание и ПКМ обрабатывает Panels, панель задания скрыта
--  низ-право: подсказки «текст + клавиша в рамке» (скрыты, пока GrabClient несёт объект), патроны
--  центр: прицел от первого лица (точка; у стрелкового — крестик), отметка попадания, оптика, полоса действия,
--         «при смерти» / «погиб»
-- В лобби заездный HUD скрыт.
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Classes = require(Shared.Classes)
local Items = require(Shared.Items)
local Weapons = require(Shared.Weapons)
local StatusEffects = require(Shared.StatusEffects)
local Recipes = require(Shared.Recipes)
local ObjectiveDefs = require(Shared.Objectives)
local Net = require(Shared.Net)

local HUD = {}
local C, UI
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

local HOTBAR = (Config.Inventory and Config.Inventory.HotbarSlots) or 10
local BADGE = 64
local GUIDE_YELLOW = rgb(255, 170, 60)
local HEART_LOW = rgb(238, 86, 86)
local FOOD_LOW = rgb(255, 150, 64)
local LOW_TEXT = rgb(255, 120, 100)
local SUN_DAY = rgb(255, 214, 90)
local SUN_DAWN = rgb(255, 150, 70)
local SUN_DUSK = rgb(255, 105, 60)
local MOON = rgb(205, 218, 255)

-- Подсказки справа внизу, пока открыт Tab
local INVENTORY_HINTS = {
	{ { "В руки / в рюкзак", "ПКМ" } },
	{ { "Использовать", "2×ЛКМ" } },
	{ { "Передать", "T" }, { "Выбросить", "Q" } },
	{ { "Половина стопки", "Shift" } },
}

local gui
local topGroup, distanceLabel, stationLabel, bossFrame, bossName, bossBar
local clockPill, clockLabel, sunIcon, moonIcon, sunParts
local leftGroup, moneyValue, moneyDelta, effectsFrame
local badges = {}
local warnRows = {}
local notifyList
local toastFrame, toastTitle, toastSub
local bottomGroup, guideFrame, guideTitle, guideText, hotbar
local slots = {}
local rightGroup, ammoFrame, ammoName, ammoValue, ammoSub, reloadBar, hintsFrame
local crosshair, crossDot, crossParts, hitMarker, scopeFrame
local turretFrame, heatBar, heatLabel
local downedFrame, downedText, deadFrame, deadText
local useFrame, useLabel, useBar
local helpFrame

local effectChips = {}
local toastQueue = {}
local toastBusy = false
local notifyOrder = 0
local deathTime = nil
local lastHitSound = 0
local useTotal = 3
local hintSignature = ""
local helpHintUntil = os.clock() + 120
local lastMoney = nil
local moneyToken = 0
local lastGuide = ""
local isLobby = false
local slowAcc = 0
local inventoryVersion = 0
local hotbarSignature = ""
local lastWheel = 0
local lastClockText = ""
local invOpen = false
local hpLow, hungerLow = false, false
local pulsing, shaking = false, false
local coreListMode = nil

local function effectSound(key, pitch)
	local effects = C and C.Effects
	if effects and effects.Play then
		pcall(effects.Play, key, nil, pitch)
	end
end

-- Уведомления и тосты -------------------------------------------------------------------------

function HUD.Notify(text, color)
	if not notifyList then
		return
	end
	local col = typeof(color) == "Color3" and color or UI.V5.text
	notifyOrder = notifyOrder + 1
	local item = UI.Shade(notifyList, { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = notifyOrder }, 0.35)
	local strip = UI.Frame(item, { Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = typeof(color) == "Color3" and color or UI.V5.accent })
	local label = UI.Label(item, {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		Text = tostring(text),
		TextColor3 = col,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextStrokeTransparency = 0.45,
	})
	local children = {}
	for _, ch in ipairs(notifyList:GetChildren()) do
		if ch:IsA("Frame") then
			table.insert(children, ch)
		end
	end
	if #children > 6 then
		table.sort(children, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		children[1]:Destroy()
	end
	task.delay(5, function()
		if item.Parent then
			UI.Tween(item, 0.5, { BackgroundTransparency = 1 })
			UI.Tween(strip, 0.5, { BackgroundTransparency = 1 })
			UI.Tween(label, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
			task.delay(0.55, function()
				item:Destroy()
			end)
		end
	end)
end

local function runToasts()
	if toastBusy then
		return
	end
	toastBusy = true
	task.spawn(function()
		while #toastQueue > 0 do
			local t = table.remove(toastQueue, 1)
			toastTitle.Text = tostring(t[1] or "")
			toastTitle.TextColor3 = typeof(t[3]) == "Color3" and t[3] or UI.Colors.accent
			toastSub.Text = tostring(t[2] or "")
			toastFrame.Visible = true
			toastTitle.TextTransparency = 1
			toastTitle.TextStrokeTransparency = 1
			toastSub.TextTransparency = 1
			toastSub.TextStrokeTransparency = 1
			toastTitle.Position = UDim2.fromOffset(0, 8)
			UI.Tween(toastTitle, 0.35, { TextTransparency = 0, TextStrokeTransparency = 0.4, Position = UDim2.fromOffset(0, 0) })
			UI.Tween(toastSub, 0.35, { TextTransparency = 0, TextStrokeTransparency = 0.5 })
			task.wait(3.2)
			UI.Tween(toastTitle, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
			UI.Tween(toastSub, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
			task.wait(0.45)
		end
		toastFrame.Visible = false
		toastBusy = false
	end)
end

function HUD.Toast(title, subtitle, color)
	if not toastFrame then
		return
	end
	table.insert(toastQueue, { title, subtitle, color })
	runToasts()
end

function HUD.HitMarker(killed, headshot)
	if not hitMarker then
		return
	end
	-- водитель не целится: попадания тарана не мигают прицелом и не пищат
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat and seat.Name == "DriverSeat" and not killed then
		return
	end
	hitMarker.Visible = true
	local color = killed and rgb(255, 60, 50) or (headshot and rgb(255, 220, 60) or rgb(255, 255, 255))
	for _, bar in ipairs(hitMarker:GetChildren()) do
		if bar:IsA("Frame") then
			bar.BackgroundColor3 = color
		end
	end
	local stamp = os.clock()
	hitMarker:SetAttribute("Stamp", stamp)
	task.delay(0.15, function()
		if hitMarker:GetAttribute("Stamp") == stamp then
			hitMarker.Visible = false
		end
	end)
	local now = os.clock()
	if killed or now - lastHitSound >= 0.1 then
		lastHitSound = now
		effectSound("hit", killed and 0.8 or 1.4)
	end
end

-- Построение ------------------------------------------------------------------------------------

-- Рюкзак из рамок (своя иконка)
local function drawBackpack(parent)
	local icon = UI.Frame(parent, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Size = UDim2.fromOffset(24, 26), BackgroundTransparency = 1 })
	local strapL = UI.Frame(icon, { Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(3, 8), BackgroundColor3 = rgb(210, 210, 214) })
	UI.Corner(strapL, 1)
	local strapR = UI.Frame(icon, { Position = UDim2.fromOffset(15, 0), Size = UDim2.fromOffset(3, 8), BackgroundColor3 = rgb(210, 210, 214) })
	UI.Corner(strapR, 1)
	local top = UI.Frame(icon, { Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(12, 3), BackgroundColor3 = rgb(210, 210, 214) })
	UI.Corner(top, 1)
	local body = UI.Frame(icon, { Position = UDim2.fromOffset(1, 5), Size = UDim2.fromOffset(22, 21), BackgroundColor3 = rgb(64, 64, 70) })
	UI.Corner(body, 6)
	UI.Stroke(body, rgb(225, 225, 230), 1.5, 0.1)
	local pocket = UI.Frame(body, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -3), Size = UDim2.fromOffset(12, 7), BackgroundColor3 = rgb(92, 92, 100) })
	UI.Corner(pocket, 2)
	UI.Stroke(pocket, rgb(225, 225, 230), 1, 0.35)
	return icon
end

-- Солнце (4 луча-полосы + диск) и луна (диск с мягкой тенью) из рамок
local function buildClock(parent)
	clockPill = UI.Frame(parent, { Size = UDim2.fromOffset(78, 20), BackgroundColor3 = UI.Colors.black, BackgroundTransparency = 0.55, LayoutOrder = 2 })
	UI.Corner(clockPill, 10)
	UI.Stroke(clockPill, UI.Colors.line, 1, 0.85)
	local holder = UI.Frame(clockPill, { Position = UDim2.fromOffset(5, 1), Size = UDim2.fromOffset(18, 18), BackgroundTransparency = 1 })
	sunIcon = UI.Frame(holder, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
	sunParts = {}
	for i = 0, 3 do
		table.insert(sunParts, UI.Frame(sunIcon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 2), Rotation = i * 45, BackgroundColor3 = SUN_DAY }))
	end
	local core = UI.Frame(sunIcon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = SUN_DAY })
	UI.Corner(core, 5)
	table.insert(sunParts, core)
	moonIcon = UI.Frame(holder, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(13, 13), BackgroundColor3 = MOON, Visible = false })
	UI.Corner(moonIcon, 7)
	local shadow = Instance.new("UIGradient")
	shadow.Rotation = -35
	shadow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.52, 0),
		NumberSequenceKeypoint.new(0.72, 0.92),
		NumberSequenceKeypoint.new(1, 1),
	})
	shadow.Parent = moonIcon
	clockLabel = UI.Label(clockPill, { Position = UDim2.fromOffset(26, 0), Size = UDim2.fromOffset(48, 20), Text = "", TextSize = 13, Font = UI.Theme.fontBlack, TextStrokeTransparency = 0.5 })
end

-- Строка значка: силуэт слева, подсказка «текст + клавиша» справа (видна при низком значении)
local function vitalRow(order, kind, warnText, key)
	local row = UI.Frame(leftGroup, { Size = UDim2.fromOffset(230, BADGE + 4), BackgroundTransparency = 1, LayoutOrder = order })
	local badge = UI.VitalBadge(row, kind, { size = BADGE, position = UDim2.fromOffset(0, 2), name = kind == "heart" and "Health" or "Hunger" })
	local warnHolder = UI.Frame(row, { Position = UDim2.fromOffset(BADGE + 8, 0), Size = UDim2.new(1, -(BADGE + 8), 1, 0), BackgroundTransparency = 1, Visible = false })
	local wl = UI.List(warnHolder, 6, true)
	wl.VerticalAlignment = Enum.VerticalAlignment.Center
	UI.Label(warnHolder, { Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, Text = warnText, TextSize = 14, TextColor3 = LOW_TEXT, TextStrokeTransparency = 0.4, LayoutOrder = 1 })
	UI.KeyCap(warnHolder, key, { LayoutOrder = 2 })
	return badge, warnHolder
end

local function build()
	gui = UI.Screen("HUD", 1)
	local V = UI.V5
	local H = UI.Hotbar

	-- Верх-центр --------------------------------------------------------------------------------
	topGroup = UI.Frame(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(560, 96), BackgroundTransparency = 1 })
	UI.AddScale(topGroup)
	local line = UI.Frame(topGroup, { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1 })
	local lineLayout = UI.List(line, 10, true)
	lineLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	lineLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	distanceLabel = UI.Label(line, { Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, TextSize = 15, Text = "", TextStrokeTransparency = 0.35, LayoutOrder = 1 })
	buildClock(line)
	stationLabel = UI.Label(topGroup, { Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 22), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 11, Text = "", TextColor3 = rgb(200, 200, 205), TextStrokeTransparency = 0.5 })
	bossFrame = UI.Frame(topGroup, { Size = UDim2.fromOffset(440, 34), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 40), BackgroundTransparency = 1, Visible = false })
	bossName = UI.Label(bossFrame, { Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Center, Font = UI.Theme.fontBlack, TextSize = 14, TextColor3 = rgb(255, 120, 90), Text = "КОНДУКТОР", TextStrokeTransparency = 0.3 })
	bossBar = UI.Bar(bossFrame, { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, 19), Color = rgb(200, 40, 40), TextSize = 10, Radius = 2 })

	toastFrame = UI.Frame(gui, { Size = UDim2.new(1, 0, 0, 90), Position = UDim2.new(0, 0, 0.19, 0), BackgroundTransparency = 1, Visible = false })
	toastTitle = UI.Label(toastFrame, { Size = UDim2.new(1, 0, 0, 50), TextXAlignment = Enum.TextXAlignment.Center, Font = UI.Theme.fontBlack, TextSize = 40, TextStrokeTransparency = 0.4 })
	toastSub = UI.Label(toastFrame, { Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 52), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 18, TextStrokeTransparency = 0.5 })

	-- Слева: деньги, сердце, окорочок, эффекты -----------------------------------------------------
	leftGroup = UI.Frame(gui, { Position = UDim2.new(0, 14, 0, 122), Size = UDim2.fromOffset(250, 340), BackgroundTransparency = 1 })
	UI.AddScale(leftGroup, true)
	local leftLayout = UI.List(leftGroup, 4)
	leftLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local moneyRow = UI.Frame(leftGroup, { Size = UDim2.fromOffset(230, 44), BackgroundTransparency = 1, LayoutOrder = 1 })
	UI.Shade(moneyRow, { Position = UDim2.fromOffset(18, 7), Size = UDim2.fromOffset(170, 30) }, 0.25)
	UI.MoneyIcon(moneyRow, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(27, 22) }, Vector2.new(52, 28))
	moneyValue = UI.Label(moneyRow, { Position = UDim2.fromOffset(62, 7), Size = UDim2.fromOffset(120, 30), Text = "0", Font = UI.Theme.fontBlack, TextSize = 20, TextStrokeTransparency = 0.35 })
	moneyDelta = UI.Label(moneyRow, { Position = UDim2.fromOffset(62, -9), Size = UDim2.fromOffset(120, 16), Text = "", TextSize = 13, Font = UI.Theme.fontBlack, TextColor3 = UI.Colors.money, TextTransparency = 1, TextStrokeTransparency = 1 })

	badges.hp, warnRows.hp = vitalRow(2, "heart", "Лечитесь", "H")
	badges.hunger, warnRows.hunger = vitalRow(3, "food", "Поешьте", "F")
	effectsFrame = UI.Frame(leftGroup, { Size = UDim2.fromOffset(200, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 5 })
	UI.List(effectsFrame, 3)

	-- Уведомления: слева снизу
	notifyList = UI.Frame(gui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -18), Size = UDim2.fromOffset(300, 196), BackgroundTransparency = 1 })
	UI.AddScale(notifyList, true)
	local nl = UI.List(notifyList, 3)
	nl.VerticalAlignment = Enum.VerticalAlignment.Bottom

	-- Низ-центр: задание и хотбар -------------------------------------------------------------------
	bottomGroup = UI.Frame(gui, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -H.bottom), Size = UDim2.fromOffset(760, 176), BackgroundTransparency = 1 })
	UI.AddScale(bottomGroup)

	guideFrame = UI.Frame(bottomGroup, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, -200, 1, -(H.height + 26)), Size = UDim2.fromOffset(560, 76), BackgroundTransparency = 1, Visible = false })
	UI.Shade(guideFrame, { Position = UDim2.fromOffset(-14, -4), Size = UDim2.new(1, 14, 1, 4) }, 0.6)
	guideTitle = UI.Label(guideFrame, { Size = UDim2.new(1, 0, 0, 20), Text = "", TextSize = 15, TextColor3 = GUIDE_YELLOW, TextStrokeTransparency = 0.45 })
	local guideLine = UI.Frame(guideFrame, { Position = UDim2.fromOffset(0, 21), Size = UDim2.fromOffset(250, 2), BackgroundColor3 = GUIDE_YELLOW })
	local lineGrad = Instance.new("UIGradient")
	lineGrad.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	lineGrad.Parent = guideLine
	guideText = UI.Label(guideFrame, { Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, 0, 0, 48), Text = "", TextSize = 19, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextStrokeTransparency = 0.4 })

	hotbar = UI.Frame(bottomGroup, { Name = "Hotbar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(760, H.height), BackgroundTransparency = 1 })
	local hl = UI.List(hotbar, H.gap, true)
	hl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	hl.VerticalAlignment = Enum.VerticalAlignment.Bottom

	local backpackButton = Instance.new("TextButton")
	backpackButton.Name = "Backpack"
	backpackButton.Text = ""
	backpackButton.AutoButtonColor = false
	backpackButton.BackgroundTransparency = 1
	backpackButton.Size = UDim2.fromOffset(H.backpack, H.slot)
	backpackButton.LayoutOrder = 0
	backpackButton.Parent = hotbar
	drawBackpack(backpackButton)
	UI.Label(backpackButton, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 40), Size = UDim2.fromOffset(H.backpack, 14), Text = "(Tab)", TextSize = 10, TextColor3 = rgb(190, 190, 195), TextXAlignment = Enum.TextXAlignment.Center })
	backpackButton.Activated:Connect(function()
		if C.Panels and C.Panels.ToggleInventory then
			C.Panels.ToggleInventory()
		end
	end)
	for i = 1, HOTBAR do
		local slot = UI.ItemSlot(hotbar, { size = H.slot, keyText = tostring(i % 10), showName = true, cross = true, hoverScale = false, transparency = 0.5, layoutOrder = i, name = "Slot" .. i })
		slot.button.InputBegan:Connect(function(input)
			local panels = C.Panels
			if panels.IsInventoryOpen() then
				panels.SlotInputBegan(i, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 and not isLobby then
				-- ПКМ по слоту при свободном курсоре (Alt): быстро в рюкзак
				panels.QuickTransfer(i)
			end
		end)
		slot.button.Activated:Connect(function()
			if not C.Panels.IsInventoryOpen() then
				HUD.EquipSlot(i)
			end
		end)
		slot.button.MouseEnter:Connect(function()
			C.Panels.SlotHover(i, true)
		end)
		slot.button.MouseLeave:Connect(function()
			C.Panels.SlotHover(i, false)
		end)
		slots[i] = slot
	end

	-- Низ-право: патроны и подсказки клавиш ----------------------------------------------------------
	rightGroup = UI.Frame(gui, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -12), Size = UDim2.fromOffset(340, 200), BackgroundTransparency = 1 })
	UI.AddScale(rightGroup)
	hintsFrame = UI.Frame(rightGroup, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(340, 120), BackgroundTransparency = 1 })

	ammoFrame = UI.Frame(rightGroup, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, -84), Size = UDim2.fromOffset(260, 90), BackgroundTransparency = 1, Visible = false })
	ammoName = UI.Label(ammoFrame, { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 8), Text = "", TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = V.accent, TextTruncate = Enum.TextTruncate.AtEnd })
	ammoValue = UI.Label(ammoFrame, { Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 26), Text = "", TextSize = 30, Font = UI.Theme.fontBlack, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 0.35 })
	ammoSub = UI.Label(ammoFrame, { Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 60), Text = "", TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = rgb(210, 210, 215) })
	reloadBar = UI.Bar(ammoFrame, { Size = UDim2.fromOffset(160, 5), Position = UDim2.new(1, -160, 0, 80), Color = rgb(255, 210, 80), TextSize = 1, Radius = 2 })
	reloadBar.Frame.Visible = false

	-- Подсказки управления (F1): компактный список справа
	helpFrame = UI.Panel(gui, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.45, 0), Size = UDim2.fromOffset(260, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false })
	UI.AddScale(helpFrame)
	UI.Padding(helpFrame, 10)
	UI.List(helpFrame, 4)
	UI.Label(helpFrame, { Size = UDim2.new(1, 0, 0, 18), Text = "УПРАВЛЕНИЕ", TextSize = 13, Font = UI.Theme.fontBlack, TextColor3 = V.accent, LayoutOrder = 0 })
	local HELP = {
		{ "ЛКМ", "удар / использовать предмет" }, { "ПКМ", "прицел" }, { "R", "перезарядка" }, { "E", "взаимодействие" },
		{ "Tab", "инвентарь" }, { "1–0", "предмет в руки" }, { "Колесо", "сменить предмет" }, { "Q", "выбросить из рук" },
		{ "F", "поесть" }, { "H", "лечиться" }, { "Shift", "спринт" }, { "Alt", "свободный курсор" }, { "G", "адреналин" },
		{ "F1", "скрыть список" },
	}
	for i, h in ipairs(HELP) do
		local r = UI.Frame(helpFrame, { Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = i })
		UI.KeyCap(r, h[1], { Position = UDim2.fromOffset(0, 0) })
		UI.Label(r, { Position = UDim2.fromOffset(62, 0), Size = UDim2.new(1, -62, 1, 0), Text = h[2], TextSize = 13 })
	end

	-- Прицел от первого лица: точка; у стрелкового оружия — крестик ------------------------------------
	crosshair = UI.Frame(gui, { Size = UDim2.fromOffset(0, 0), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1, Visible = false })
	crossParts = {}
	for i = 1, 4 do
		crossParts[i] = UI.Frame(crosshair, { BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Visible = false })
		UI.Stroke(crossParts[i], rgb(0, 0, 0), 1, 0.5)
	end
	crossDot = UI.Frame(crosshair, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(4, 4), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = 0.1 })
	UI.Corner(crossDot, 2)
	UI.Stroke(crossDot, rgb(0, 0, 0), 1, 0.45)
	hitMarker = UI.Frame(gui, { Size = UDim2.fromOffset(24, 24), Position = UDim2.new(0.5, -12, 0.5, -12), BackgroundTransparency = 1, Visible = false, ZIndex = 3 })
	for _, rot in ipairs({ 45, -45 }) do
		UI.Frame(hitMarker, { Size = UDim2.fromOffset(24, 2), Position = UDim2.fromOffset(0, 11), Rotation = rot, BackgroundColor3 = rgb(255, 255, 255), ZIndex = 3 })
	end

	-- Прицел башни (если у автобуса есть управляемая башня)
	turretFrame = UI.Frame(gui, { Size = UDim2.fromOffset(0, 0), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1, Visible = false })
	local ring = UI.Frame(turretFrame, { Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(-20, -20), BackgroundTransparency = 1 })
	UI.Corner(ring, 20)
	UI.Stroke(ring, rgb(255, 230, 120), 2, 0.1)
	heatBar = UI.Bar(turretFrame, { Size = UDim2.fromOffset(200, 6), Position = UDim2.fromOffset(-100, 46), Color = rgb(120, 220, 90), TextSize = 1, Radius = 2 })
	heatLabel = UI.Label(turretFrame, { Size = UDim2.fromOffset(220, 18), Position = UDim2.fromOffset(-110, 56), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 13, Text = "" })

	scopeFrame = UI.Frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 0 })
	local black = rgb(0, 0, 0)
	UI.Frame(scopeFrame, { Size = UDim2.new(0.5, -300, 1, 0), BackgroundColor3 = black })
	UI.Frame(scopeFrame, { Size = UDim2.new(0.5, -300, 1, 0), Position = UDim2.new(0.5, 300, 0, 0), BackgroundColor3 = black })
	UI.Frame(scopeFrame, { Size = UDim2.new(0, 600, 0.5, -300), Position = UDim2.new(0.5, -300, 0, 0), BackgroundColor3 = black })
	UI.Frame(scopeFrame, { Size = UDim2.new(0, 600, 0.5, -300), Position = UDim2.new(0.5, -300, 0.5, 300), BackgroundColor3 = black })
	UI.Frame(scopeFrame, { Size = UDim2.new(0, 600, 0, 1), Position = UDim2.new(0.5, -300, 0.5, 0), BackgroundColor3 = black })
	UI.Frame(scopeFrame, { Size = UDim2.new(0, 1, 0, 600), Position = UDim2.new(0.5, 0, 0.5, -300), BackgroundColor3 = black })
	local scopeRing = UI.Frame(scopeFrame, { Size = UDim2.fromOffset(600, 600), Position = UDim2.new(0.5, -300, 0.5, -300), BackgroundTransparency = 1 })
	UI.Corner(scopeRing, 300)
	-- углы квадрата за кругом (300·√2 − 300 ≈ 124 px) закрывает толстая обводка
	UI.Stroke(scopeRing, black, 130)

	-- При смерти / погиб -------------------------------------------------------------------------------
	local function vignette(parent, color)
		local specs = {
			{ UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.35), 90 },
			{ UDim2.fromScale(0, 0.65), UDim2.fromScale(1, 0.35), -90 },
			{ UDim2.fromScale(0, 0), UDim2.fromScale(0.3, 1), 0 },
			{ UDim2.fromScale(0.7, 0), UDim2.fromScale(0.3, 1), 180 },
		}
		for _, s in ipairs(specs) do
			UI.Shade(parent, { Position = s[1], Size = s[2], BackgroundColor3 = color, ZIndex = 5 }, 0.25, s[3])
		end
	end
	downedFrame = UI.Frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = rgb(60, 0, 0), BackgroundTransparency = 0.82, Visible = false, ZIndex = 5 })
	vignette(downedFrame, rgb(150, 10, 10))
	local downedBox = UI.Frame(downedFrame, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.3, 0), Size = UDim2.fromOffset(700, 140), BackgroundTransparency = 1, ZIndex = 6 })
	UI.AddScale(downedBox)
	UI.Label(downedBox, { Size = UDim2.new(1, 0, 0, 46), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 38, Font = UI.Theme.fontBlack, TextColor3 = rgb(255, 90, 75), Text = "ВЫ ПРИ СМЕРТИ", ZIndex = 6, TextStrokeTransparency = 0.3 })
	downedText = UI.Label(downedBox, { Size = UDim2.new(1, 0, 0, 80), Position = UDim2.fromOffset(0, 50), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, TextSize = 18, Text = "", TextWrapped = true, ZIndex = 6, TextStrokeTransparency = 0.35 })

	deadFrame = UI.Frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 0.6, Visible = false, ZIndex = 5 })
	local deadBox = UI.Frame(deadFrame, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.32, 0), Size = UDim2.fromOffset(700, 110), BackgroundTransparency = 1, ZIndex = 6 })
	UI.AddScale(deadBox)
	UI.Label(deadBox, { Size = UDim2.new(1, 0, 0, 50), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 42, Font = UI.Theme.fontBlack, TextColor3 = rgb(255, 80, 70), Text = "ВЫ ПОГИБЛИ", ZIndex = 6, TextStrokeTransparency = 0.3 })
	deadText = UI.Label(deadBox, { Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 56), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 18, Text = "", ZIndex = 6 })

	-- Полоса действия (есть, лечиться, чинить...)
	useFrame = UI.Frame(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.6, 0), Size = UDim2.fromOffset(240, 34), BackgroundTransparency = 1, Visible = false })
	UI.AddScale(useFrame)
	useLabel = UI.Label(useFrame, { Size = UDim2.new(1, 0, 0, 18), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 14, Text = "" })
	useBar = UI.Bar(useFrame, { Size = UDim2.new(1, 0, 0, 7), Position = UDim2.fromOffset(0, 22), Color = V.accent, TextSize = 1, Radius = 2 })
end

-- Хотбар ------------------------------------------------------------------------------------------

-- Перерисовка слотов только при изменении инвентаря/активного слота/режима Tab (иконки кэшируются в UI)
local function refreshHotbar(force)
	local panels = C.Panels
	local data = panels.GetSlots()
	local active = panels.GetActive()
	local sig = inventoryVersion .. ":" .. active .. ":" .. UI.IconEpoch .. ":" .. (invOpen and "1" or "0")
	if not force and sig == hotbarSignature then
		return
	end
	hotbarSignature = sig
	for i = 1, HOTBAR do
		slots[i]:Set(data[i], panels.SlotVisualState(i))
	end
end

-- Перерисовать хотбар (Panels вызывает при наведении/перетаскивании в режиме Tab)
function HUD.RefreshHotbar(force)
	if slots[1] and C then
		refreshHotbar(force ~= false)
	end
end

-- Слот хотбара для Panels (попадание курсора при перетаскивании, призрак предмета)
function HUD.GetHotbarSlot(index)
	return slots[index]
end

function HUD.EquipSlot(index)
	if isLobby then
		return
	end
	-- звук доставания/убирания играет WeaponClient (ARMS), здесь только перерисовка
	if C.Panels.EquipSlot(index) then
		refreshHotbar(true)
	end
end

-- Открыт/закрыт Tab: хотбар показывает пустые слоты с номерами, панель задания прячется
function HUD.SetInventoryOpen(open)
	invOpen = open == true
	hintSignature = ""
	if guideFrame and invOpen then
		guideFrame.Visible = false
	end
	if slots[1] and C then
		refreshHotbar(true)
	end
end

-- Подсказки клавиш (низ-право) --------------------------------------------------------------------

local function isTouchOnly()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function isGrabbing()
	local grab = C.GrabClient
	if not grab or type(grab.IsGrabbing) ~= "function" then
		return false
	end
	local ok, result = pcall(grab.IsGrabbing)
	return ok and result == true
end

-- rows = { { {text, key, highlight, keyFirst}, ... }, ... } — одна строка на элемент
local function setHints(rows)
	local parts = {}
	for _, r in ipairs(rows) do
		for _, e in ipairs(r) do
			table.insert(parts, tostring(e[1]) .. "/" .. tostring(e[2]) .. "/" .. tostring(e[3]))
		end
		table.insert(parts, "|")
	end
	local sig = table.concat(parts)
	if sig == hintSignature then
		return
	end
	hintSignature = sig
	UI.Clear(hintsFrame)
	local layout = UI.List(hintsFrame, 3)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	for ri, r in ipairs(rows) do
		local rowFrame = UI.Frame(hintsFrame, { Size = UDim2.fromOffset(340, 25), BackgroundTransparency = 1, LayoutOrder = ri })
		-- тонкая черта под строкой (как в оригинале), гаснет влево; вне раскладки строки
		local underline = UI.Frame(rowFrame, { Name = "Underline", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(190, 1), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = 0.55 })
		local ug = Instance.new("UIGradient")
		ug.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
		ug.Parent = underline
		local content = UI.Frame(rowFrame, { Name = "Content", Size = UDim2.new(1, 0, 1, -2), BackgroundTransparency = 1 })
		local rl = UI.List(content, 6, true)
		rl.HorizontalAlignment = Enum.HorizontalAlignment.Right
		rl.VerticalAlignment = Enum.VerticalAlignment.Center
		local order = 0
		for _, e in ipairs(r) do
			local label = UI.Label(content, {
				Size = UDim2.fromOffset(0, 22),
				AutomaticSize = Enum.AutomaticSize.X,
				Text = e[1],
				TextSize = 15,
				TextColor3 = e[3] and UI.V5.accent or UI.V5.text,
				TextStrokeTransparency = 0.45,
			})
			local cap = UI.KeyCap(content, e[2])
			if e[4] then
				cap.LayoutOrder = order + 1
				label.LayoutOrder = order + 2
			else
				label.LayoutOrder = order + 1
				cap.LayoutOrder = order + 2
			end
			order = order + 3
			local gap = UI.Frame(content, { Name = "Gap", Size = UDim2.fromOffset(8, 1), BackgroundTransparency = 1, LayoutOrder = order })
			gap.Visible = e ~= r[#r]
			order = order + 1
		end
	end
end

-- Обновление -----------------------------------------------------------------------------------------

local function getHumanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid"), char
end

local function heldTool(char)
	return char and char:FindFirstChildOfClass("Tool") or nil
end

local function toolWeapon(tool)
	if not tool then
		return nil
	end
	local id = tool:GetAttribute("WeaponId")
	return type(id) == "string" and Weapons.List[id] or nil
end

local function updateEffects(now)
	local active = {}
	for i, id in ipairs(StatusEffects.Order) do
		local e = StatusEffects.List[id]
		local untilT = player:GetAttribute("Eff_" .. id)
		if e and type(untilT) == "number" and untilT > now then
			active[id] = true
			local chip = effectChips[id]
			if not chip then
				chip = UI.Shade(effectsFrame, { Size = UDim2.fromOffset(176, 20), LayoutOrder = i }, 0.3)
				UI.Frame(chip, { Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = e.color })
				UI.Label(chip, { Name = "Text", Size = UDim2.new(1, -12, 1, 0), Position = UDim2.fromOffset(9, 0), TextSize = 12, TextColor3 = e.good and rgb(220, 240, 255) or rgb(255, 205, 195), TextTruncate = Enum.TextTruncate.AtEnd })
				effectChips[id] = chip
			end
			chip.Text.Text = e.name .. "  " .. math.ceil(untilT - now) .. " с"
		end
	end
	for id, chip in pairs(effectChips) do
		if not active[id] then
			chip:Destroy()
			effectChips[id] = nil
		end
	end
end

local function guideInfo(state)
	local title = player:GetAttribute("GuideTitle")
	local text = player:GetAttribute("GuideText")
	if type(text) == "string" and text ~= "" then
		return (type(title) == "string" and title ~= "") and title or "Цель", text
	end
	local objective = state:GetAttribute("Objective")
	if type(objective) == "string" and objective ~= "" then
		local count = state:GetAttribute("ObjectiveCount") or 0
		return "Задание", objective .. ((type(count) == "number" and count > 0) and (": осталось " .. count) or "")
	end
	local objectivesUI = C.ObjectivesUI
	if objectivesUI and objectivesUI.GetNearest then
		local o = objectivesUI.GetNearest()
		if type(o) == "table" then
			local typeName = ObjectiveDefs.TypeNames[o.type] or "Цель"
			local body = tostring(o.title or "")
			if type(o.text) == "string" and o.text ~= "" then
				body = body .. " — " .. o.text
			end
			return "Цель · " .. typeName, body
		end
	end
	return nil, nil
end

local function onMoneyChanged()
	local money = player:GetAttribute("Money") or 0
	if type(money) ~= "number" then
		return
	end
	if lastMoney ~= nil and money ~= lastMoney then
		local delta = money - lastMoney
		moneyToken = moneyToken + 1
		local token = moneyToken
		moneyDelta.Text = (delta > 0 and "+" or "") .. delta
		moneyDelta.TextColor3 = delta > 0 and UI.Colors.money or rgb(255, 110, 90)
		moneyDelta.TextTransparency = 0
		moneyDelta.TextStrokeTransparency = 0.4
		task.delay(1.4, function()
			if token == moneyToken then
				UI.Tween(moneyDelta, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
			end
		end)
	end
	lastMoney = money
	moneyValue.Text = UI.Thousands(money)
end

-- Время суток: солнце (рассвет — оранжевое, закат — красное) или луна + «07:40»
local function updateClock()
	local clock = Lighting.ClockTime % 24
	local h = math.floor(clock)
	local m = math.floor((clock - h) * 60)
	local text = string.format("%02d:%02d", h, m)
	if text == lastClockText then
		return
	end
	lastClockText = text
	clockLabel.Text = text
	local nightStart, nightEnd = Config.NightStart or 20, Config.NightEnd or 5.5
	local night = clock >= nightStart or clock < nightEnd
	sunIcon.Visible = not night
	moonIcon.Visible = night
	local color = SUN_DAY
	if clock >= nightEnd and clock < nightEnd + 2 then
		color = SUN_DAWN
	elseif clock >= nightStart - 2 and clock < nightStart then
		color = SUN_DUSK
	end
	for _, p in ipairs(sunParts) do
		p.BackgroundColor3 = color
	end
	clockLabel.TextColor3 = night and rgb(190, 205, 255) or rgb(250, 246, 235)
end

-- Список игроков Roblox перехватывает Tab: в заезде он выключен (страховка к Main.client)
local function enforceCoreGui(mode)
	if mode == coreListMode then
		return
	end
	coreListMode = mode
	if mode == "run" then
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
	end
end

-- Сердце и окорочок: заливка, число, подсказка при низком значении
local function updateVitals(hum)
	local health, maxHealth = 100, 100
	if hum then
		maxHealth = math.max(1, hum.MaxHealth)
		health = math.clamp(hum.Health, 0, maxHealth)
	end
	local hpFraction = health / maxHealth
	hpLow = hum ~= nil and health > 0 and hpFraction < 0.3
	badges.hp:Set(hpFraction, tostring(math.ceil(health)), hpLow and HEART_LOW or nil)
	warnRows.hp.Visible = hpLow

	local hunger = player:GetAttribute("Hunger")
	hunger = type(hunger) == "number" and math.clamp(hunger, 0, 100) or 100
	hungerLow = hunger < 20
	badges.hunger:Set(hunger / 100, math.floor(hunger + 0.5) .. "%", hungerLow and FOOD_LOW or nil)
	warnRows.hunger.Visible = hungerLow
end

-- Пульс сердца («тук-тук») и дрожь окорочка — только пока значение низкое
local function animateVitals()
	local now = os.clock()
	if hpLow and not isLobby then
		local phase = (now % 0.95) / 0.95
		local beat = math.exp(-((phase - 0.1) / 0.045) ^ 2) + 0.65 * math.exp(-((phase - 0.3) / 0.045) ^ 2)
		badges.hp.scale.Scale = 1 + 0.13 * beat
		pulsing = true
	elseif pulsing then
		pulsing = false
		badges.hp.scale.Scale = 1
	end
	if hungerLow and not isLobby then
		local cycle = now % 1.5
		local burst = cycle < 0.45 and math.sin(cycle / 0.45 * math.pi) or 0
		badges.hunger.root.Position = UDim2.fromOffset(math.sin(now * 47) * 2.2 * burst, 2 + math.cos(now * 39) * 1.1 * burst)
		shaking = true
	elseif shaking then
		shaking = false
		badges.hunger.root.Position = UDim2.fromOffset(0, 2)
	end
end

-- 10 Гц: тексты, значки, хотбар, задание, подсказки
local function slowUpdate()
	local now = workspace:GetServerTimeNow()
	local state = Net.State()
	local mode = state:GetAttribute("Mode")
	isLobby = mode == "lobby"
	enforceCoreGui(mode)
	local runState = state:GetAttribute("RunState")
	local hum, char = getHumanoid()

	topGroup.Visible = not isLobby
	leftGroup.Visible = not isLobby
	bottomGroup.Visible = not isLobby
	rightGroup.Visible = not isLobby
	if isLobby then
		helpFrame.Visible = false
		return
	end

	-- Верх
	local km = state:GetAttribute("Km") or 0
	km = type(km) == "number" and km or 0
	local meters = math.max(0, (Config.RouteKm - km) * 1000)
	if runState == "Boss" or meters < 1 then
		distanceLabel.Text = "Конечная"
	else
		distanceLabel.Text = UI.Thousands(meters) .. " м до конечной"
	end
	updateClock()
	local nextKm = state:GetAttribute("NextStationKm")
	local nextName = state:GetAttribute("NextStationName")
	if runState == "Driving" and type(nextKm) == "number" and type(nextName) == "string" and nextName ~= "" then
		stationLabel.Text = string.format("%s через %.1f км", nextName, math.max(0, nextKm - km))
	else
		stationLabel.Text = ""
	end
	bossFrame.Visible = state:GetAttribute("BossActive") == true
	if bossFrame.Visible then
		local hp = state:GetAttribute("BossHP") or 0
		local maxHp = math.max(1, state:GetAttribute("BossMaxHP") or 1)
		bossName.Text = tostring(state:GetAttribute("BossName") or "КОНДУКТОР")
		bossBar:Set(hp / maxHp, "")
	end

	-- Слева
	updateVitals(hum)
	updateEffects(now)

	-- Хотбар
	refreshHotbar(false)

	-- Задание (пока открыт Tab, на его месте панель инвентаря)
	local title, text = guideInfo(state)
	local showGuide = title ~= nil and runState ~= "Victory" and runState ~= "Failed"
	guideFrame.Visible = showGuide and not invOpen
	if showGuide then
		local key = title .. "\n" .. text
		if key ~= lastGuide then
			local changedText = guideText.Text ~= text
			lastGuide = key
			guideTitle.Text = title
			guideText.Text = text
			if changedText then
				guideText.TextTransparency = 1
				UI.Tween(guideText, 0.35, { TextTransparency = 0 })
			end
		end
	else
		lastGuide = ""
	end

	-- Подсказки клавиш (GrabClient показывает свои, пока несёт объект)
	local seat = hum and hum.SeatPart
	local busClient = C.BusClient
	local gunning = busClient and busClient.IsGunner and busClient.IsGunner() or false
	local tool = heldTool(char)
	local grabbing = isGrabbing()
	hintsFrame.Visible = not grabbing
	local rows = {}
	if not isTouchOnly() and not grabbing then
		if invOpen then
			rows = INVENTORY_HINTS
		elseif seat and seat.Name == "DriverSeat" then
			table.insert(rows, { { "газ", "W", false, true }, { "тормоз", "S", false, true }, { "встать", "Пробел", false, true } })
		elseif gunning then
			table.insert(rows, { { "огонь", "ЛКМ", false, true }, { "выйти", "Пробел", false, true } })
		elseif hum and hum.Health > 0 and not seat then
			if os.clock() < helpHintUntil then
				table.insert(rows, { { "Управление", "F1" } })
			end
			if tool and tool:GetAttribute("ItemKind") == "item" then
				local itemId = tool:GetAttribute("ItemId")
				local verb = type(itemId) == "string" and UI.UseVerb(UI.EntryInfo({ kind = "item", id = itemId })) or nil
				local row = {}
				if verb then
					table.insert(row, { verb, "ЛКМ" })
				end
				table.insert(row, { "Выбросить", "Q" })
				table.insert(rows, row)
			end
			local sprinting = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			table.insert(rows, { { "Спринт", "Shift", sprinting } })
		end
	end
	setHints(rows)

	-- Патроны оружия в руках (пока открыт Tab — на их месте подсказки инвентаря)
	local def = toolWeapon(tool)
	ammoFrame.Visible = def ~= nil and def.kind ~= "melee" and not invOpen
	reloadBar.Frame.Visible = false
	if ammoFrame.Visible then
		local levelAttr = tool:GetAttribute("Level") or 0
		ammoName.Text = def.name .. ((type(levelAttr) == "number" and levelAttr > 0) and (" +" .. levelAttr) or "")
		ammoValue.TextColor3 = UI.Colors.text
		local inv = C.State.Inventory or {}
		if def.kind == "throw" then
			ammoValue.Text = "×" .. (inv[def.item or "molotov"] or 0)
			ammoSub.Text = def.desc or ""
		elseif def.kind == "bow" then
			ammoValue.Text = tostring(inv[def.ammo] or 0)
			ammoSub.Text = (Items.List[def.ammo] and Items.List[def.ammo].name or "") .. " · зажмите ЛКМ"
			local weaponClient = C.WeaponClient
			local charge = weaponClient and weaponClient.DrawCharge and weaponClient.DrawCharge()
			if type(charge) == "number" then
				reloadBar.Frame.Visible = true
				reloadBar:Set(charge, nil, charge >= 1 and UI.Colors.accent or rgb(120, 220, 255))
			end
		else
			local mag = tool:GetAttribute("Mag") or 0
			local maxMag = tool:GetAttribute("MaxMag") or def.mag
			ammoValue.Text = tostring(mag) .. (maxMag and (" / " .. maxMag) or "")
			if mag == 0 then
				ammoValue.TextColor3 = rgb(255, 90, 80)
			end
			ammoSub.Text = (Items.List[def.ammo] and Items.List[def.ammo].name or "") .. ": " .. (inv[def.ammo] or 0)
			if tool:GetAttribute("Reloading") then
				local endT = tool:GetAttribute("ReloadEnd") or now
				local lvl = type(levelAttr) == "number" and levelAttr or 0
				local duration = (def.reload or 1) * Classes.Perk(player:GetAttribute("ClassId") or "survivor", "reloadMult", 1) * Recipes.WeaponCooldownMult(lvl)
				reloadBar.Frame.Visible = true
				reloadBar:Set(1 - math.clamp((endT - now) / math.max(0.05, duration), 0, 1))
				ammoSub.Text = "Перезарядка..."
			end
		end
	end

	-- При смерти / погиб
	local downed = player:GetAttribute("Downed") == true
	downedFrame.Visible = downed
	if downed then
		local left = math.max(0, math.ceil((player:GetAttribute("DownedUntil") or now) - now))
		local adrenaline = (C.State.Inventory or {}).adrenaline or 0
		downedText.Text = "Осталось " .. left .. " с · друзья могут поднять вас (зажать E рядом)" .. (adrenaline > 0 and ("\n[G] — вколоть адреналин (есть " .. adrenaline .. ")") or "")
	end
	local dead = (hum ~= nil and hum.Health <= 0) or (hum == nil and char == nil and deathTime ~= nil)
	if dead then
		deathTime = deathTime or os.clock()
		if runState == "Driving" or runState == "Boss" or runState == "Depot" then
			deadText.Text = "Возрождение в автобусе через " .. math.max(0, math.ceil(Config.Player.RespawnDelay + 1 - (os.clock() - deathTime))) .. " с"
			deadFrame.Visible = true
		else
			deadFrame.Visible = false
		end
	else
		if hum ~= nil then
			deathTime = nil
		end
		deadFrame.Visible = false
	end
end

local function isFirstPerson(char)
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return true
	end
	local head = char and char:FindFirstChild("Head")
	local cam = workspace.CurrentCamera
	return head ~= nil and cam ~= nil and (cam.CFrame.Position - head.Position).Magnitude < 1.6
end

-- Каждый кадр: прицел, оптика, башня, полоса действия, пульс значков
local function fastUpdate()
	local now = workspace:GetServerTimeNow()
	local hum, char = getHumanoid()
	local weaponClient = C.WeaponClient
	local busClient = C.BusClient
	local gunning = busClient and busClient.IsGunner and busClient.IsGunner() or false
	local def = toolWeapon(heldTool(char))
	local scoped = weaponClient and weaponClient.IsScoped and weaponClient.IsScoped() or false
	local combat = weaponClient and weaponClient.IsCombatCamera and weaponClient.IsCombatCamera() or false
	scopeFrame.Visible = not isLobby and scoped and def ~= nil and def.scope == true and def.kind ~= "crossbow" and not gunning
	local seat = hum and hum.SeatPart
	local panels = C.Panels
	local blocked = isLobby or hum == nil or hum.Health <= 0 or gunning or scopeFrame.Visible
		or (seat ~= nil and seat.Name == "DriverSeat")
		or player:GetAttribute("Downed") == true or player:GetAttribute("Sleeping") == true
		or (panels ~= nil and panels.IsOpen())
	crosshair.Visible = not blocked and (combat or isFirstPerson(char))
	if crosshair.Visible then
		local ranged = def ~= nil and (def.kind == "gun" or def.kind == "bow" or def.kind == "crossbow")
		for i = 1, 4 do
			crossParts[i].Visible = ranged
		end
		if ranged then
			local spread = 5
			if def.spread then
				spread = 3 + (scoped and (def.aimSpread or def.spread) or def.spread) * 2.5
			end
			local len = 6
			crossParts[1].Size = UDim2.fromOffset(2, len)
			crossParts[1].Position = UDim2.fromOffset(-1, -spread - len)
			crossParts[2].Size = UDim2.fromOffset(2, len)
			crossParts[2].Position = UDim2.fromOffset(-1, spread)
			crossParts[3].Size = UDim2.fromOffset(len, 2)
			crossParts[3].Position = UDim2.fromOffset(-spread - len, -1)
			crossParts[4].Size = UDim2.fromOffset(len, 2)
			crossParts[4].Position = UDim2.fromOffset(spread, -1)
		end
	end

	turretFrame.Visible = gunning and not isLobby
	if turretFrame.Visible and busClient.GetTurretState then
		local ts = busClient.GetTurretState() or {}
		local heat = ts.heat or 0
		local color = rgb(120, 220, 90):Lerp(rgb(255, 170, 40), math.clamp(heat * 1.6, 0, 1)):Lerp(rgb(255, 60, 40), math.clamp((heat - 0.6) * 2.5, 0, 1))
		if ts.overheated then
			heatLabel.Text = "ПЕРЕГРЕВ! Отпустите огонь"
			heatLabel.TextColor3 = rgb(255, 90, 70)
		else
			heatLabel.Text = "Нагрев " .. math.floor(heat * 100 + 0.5) .. "%"
			heatLabel.TextColor3 = UI.Colors.text
		end
		heatBar:Set(heat, nil, color)
	end

	local useEnd = player:GetAttribute("UseEnd")
	if type(useEnd) == "number" and useEnd > now then
		useFrame.Visible = true
		useLabel.Text = tostring(player:GetAttribute("UseName") or "") .. "..."
		useBar:Set(1 - math.clamp((useEnd - now) / useTotal, 0, 1))
	else
		useFrame.Visible = false
	end

	if hpLow or hungerLow or pulsing or shaking then
		animateVitals()
	end
end

local function disableCoreBackpack()
	for _ = 1, 5 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)
		if ok then
			return
		end
		task.wait(1)
	end
end

local KEY_SLOTS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 10,
}

function HUD.Init(c)
	C = c
	UI = C.UI
	build()
	updateVitals(nil)
	task.spawn(disableCoreBackpack)

	Net.Get("Notify").OnClientEvent:Connect(HUD.Notify)
	Net.Get("Toast").OnClientEvent:Connect(HUD.Toast)
	Net.Get("HitConfirm").OnClientEvent:Connect(HUD.HitMarker)
	-- данные инвентаря (слоты, активный слот) разбирает Panels; хотбар перерисуется на ближайшем такте
	C.Panels.OnInventory(function()
		inventoryVersion = inventoryVersion + 1
	end)
	C.Panels.OnOpenChanged(function(open)
		HUD.SetInventoryOpen(open)
	end)
	player:GetAttributeChangedSignal("UseEnd"):Connect(function()
		local e = player:GetAttribute("UseEnd")
		if type(e) == "number" then
			useTotal = math.max(0.1, e - workspace:GetServerTimeNow())
		end
	end)
	player:GetAttributeChangedSignal("Money"):Connect(onMoneyChanged)
	onMoneyChanged()

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		local key = input.KeyCode
		local index = KEY_SLOTS[key]
		local panels = C.Panels
		if index then
			if index <= HOTBAR and not isLobby then
				-- в открытом инвентаре цифра переносит предмет под курсором в этот слот хотбара
				if panels.HandleNumberKey(index) then
					return
				end
				if not panels.IsOpen() or panels.IsInventoryOpen() then
					HUD.EquipSlot(index)
				end
			end
		elseif key == Enum.KeyCode.ButtonR1 or key == Enum.KeyCode.ButtonL1 then
			if not isLobby and not panels.IsOpen() and not isGrabbing() then
				panels.CycleSlot(key == Enum.KeyCode.ButtonR1 and 1 or -1)
			end
		elseif key == Enum.KeyCode.F1 then
			helpFrame.Visible = not helpFrame.Visible and not isLobby
			helpHintUntil = 0
		end
	end)
	-- Колесо мыши: следующий/предыдущий предмет (не во время переноса объекта — там колесо меняет расстояние)
	UserInputService.InputChanged:Connect(function(input, processed)
		if processed or isLobby or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		local panels = C.Panels
		if panels.IsOpen() or isGrabbing() then
			return
		end
		local now = os.clock()
		if now - lastWheel < 0.05 then
			return
		end
		lastWheel = now
		panels.CycleSlot(input.Position.Z > 0 and -1 or 1)
	end)

	local iconAcc = 0
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(fastUpdate)
		if not ok and not HUD.warned then
			HUD.warned = true
			warn("[HUD] " .. tostring(err))
		end
		slowAcc = slowAcc + dt
		iconAcc = iconAcc + dt
		if slowAcc >= 0.1 then
			slowAcc = 0
			if iconAcc >= 3 then
				-- раз в 3 с: подхватить модели предметов, если модуль ItemModels появился позже
				iconAcc = 0
				hotbarSignature = ""
			end
			local ok2, err2 = pcall(slowUpdate)
			if not ok2 and not HUD.warnedSlow then
				HUD.warnedSlow = true
				warn("[HUD] " .. tostring(err2))
			end
		end
	end)
end

return HUD
