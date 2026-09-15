-- Окно верстака (v4): вкладки «Крафт», «Детали автобуса», «Улучшить оружие»; 3D-иконки результатов.
-- Наличие материалов — C.State.Inventory (сумма по слотам, разбирает Panels); изготовленное без места падает рядом.
-- Стоимость — деньги и материалы с подсветкой «есть/нужно». Открывается событием OpenWorkbench({kind, name, part}).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Items)
local Weapons = require(Shared.Weapons)
local Recipes = require(Shared.Recipes)
local BusParts = require(Shared.BusParts)
local Net = require(Shared.Net)

local WorkbenchUI = {}
local C, UI
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

local HAVE = rgb(120, 230, 120)
local NEED = rgb(255, 110, 100)
-- сервер пускает к верстаку в 14 studs от поверхности детали (BENCH_RANGE); чуть меньше — запас на задержку
local CLOSE_DISTANCE = 13

local gui, win, list, tabs
local isOpen = false
local tab = "craft"
local benchPart = nil
local monitorAcc = 0

local TABS = {
	{ "craft", "Крафт" },
	{ "parts", "Детали автобуса" },
	{ "weapons", "Улучшить оружие" },
}

-- Звуки интерфейса — через C.SoundFX ключами ui_* (см. docs/SPEC_v5.md 2.1)
local function sfx(key)
	local fx = C and C.SoundFX
	if fx and fx.Play then
		pcall(fx.Play, key)
	end
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

local function escape(text)
	return (string.gsub(tostring(text), "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

local function colored(text, color)
	return string.format('<font color="%s">%s</font>', hex(color), escape(text))
end

local function inventory()
	return C.State.Inventory or {}
end

local function money()
	return player:GetAttribute("Money") or 0
end

-- Текст стоимости с подсветкой и признак «хватает»
local function costText(price, materials)
	local parts = {}
	local enough = true
	if price and price > 0 then
		local ok = money() >= price
		enough = enough and ok
		table.insert(parts, colored("$" .. price, ok and HAVE or NEED))
	end
	local mats = {}
	for id, n in pairs(materials or {}) do
		if n > 0 then
			table.insert(mats, { id = id, n = n, item = Items.List[id] })
		end
	end
	table.sort(mats, function(a, b)
		local an = a.item and a.item.name or a.id
		local bn = b.item and b.item.name or b.id
		return an < bn
	end)
	local inv = inventory()
	for _, m in ipairs(mats) do
		local have = inv[m.id] or 0
		local ok = have >= m.n
		enough = enough and ok
		table.insert(parts, colored(string.format("%s %d/%d", m.item and m.item.name or m.id, have, m.n), ok and HAVE or NEED))
	end
	return table.concat(parts, "  "), enough
end

local function clearList(grid)
	UI.Clear(list)
	if grid then
		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.new(0.5, -4, 0, 96)
		layout.CellPadding = UDim2.fromOffset(6, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list
	else
		UI.List(list, 5)
	end
end

local function note(order, text)
	UI.Label(list, { Size = UDim2.new(1, -4, 0, 40), LayoutOrder = order, Text = text, TextSize = 14, TextWrapped = true, TextColor3 = UI.Colors.dim, TextStrokeTransparency = 1, Font = UI.Theme.fontRegular })
end

local function actionButton(parent, props, button)
	local btn = UI.ActionButton(parent, props, button.style or "primary", function()
		if not button.disabled then
			button.onClick()
			sfx("ui_click")
		end
	end)
	if button.disabled then
		UI.DisableButton(btn)
	end
	return btn
end

-- Карточка рецепта (сетка в 2 колонки)
local function recipeCard(order, opts)
	local card = UI.Frame(list, { BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = 0.95, LayoutOrder = order })
	UI.Corner(card, 4)
	local color = opts.color or rgb(160, 160, 160)
	local iconHolder = UI.Frame(card, { Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 0.5 })
	UI.Corner(iconHolder, 3)
	UI.Stroke(iconHolder, color, 1, 0.6)
	local vp = Instance.new("ViewportFrame")
	vp.BackgroundTransparency = 1
	vp.Size = UDim2.fromScale(1, 1)
	vp.Ambient = rgb(170, 170, 175)
	vp.LightColor = rgb(255, 246, 232)
	vp.LightDirection = Vector3.new(-0.5, -1, -0.7)
	vp.Parent = iconHolder
	if opts.icon then
		UI.SetItemIcon(vp, opts.icon)
	end
	UI.Label(card, { Size = UDim2.new(1, -130, 0, 18), Position = UDim2.fromOffset(44, 7), Text = opts.title, TextSize = 15, TextColor3 = color, TextTruncate = Enum.TextTruncate.AtEnd })
	UI.Label(card, { Size = UDim2.new(1, -130, 0, 14), Position = UDim2.fromOffset(44, 26), Text = opts.subtitle or "", TextSize = 11, TextColor3 = UI.Colors.dim, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 1 })
	UI.Label(card, { Size = UDim2.new(1, -20, 0, 30), Position = UDim2.fromOffset(10, 44), Text = opts.desc or "", TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = rgb(215, 215, 220), TextStrokeTransparency = 1, Font = UI.Theme.fontRegular })
	UI.Label(card, { Size = UDim2.new(1, -130, 0, 18), Position = UDim2.new(0, 10, 1, -22), Text = opts.cost or "", RichText = true, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 0.8 })
	actionButton(card, { Size = UDim2.fromOffset(104, 30), Position = UDim2.new(1, -112, 0, 8), Text = opts.button.text, TextSize = 14 }, opts.button)
	return card
end

local function isPartRecipe(recipe)
	local outId = next(recipe.outputs)
	local item = outId and Items.List[outId]
	return item ~= nil and item.cat == "buspart"
end

local function refreshRecipes(parts)
	clearList(true)
	local order = 0
	for _, id in ipairs(Recipes.Order) do
		local recipe = Recipes.List[id]
		if recipe and isPartRecipe(recipe) == parts then
			order = order + 1
			local outId, outCount = next(recipe.outputs)
			local outItem = outId and Items.List[outId]
			local cost, enough = costText(0, recipe.inputs)
			local have = outId and (inventory()[outId] or 0) or 0
			local rarity = outItem and Items.Rarities[outItem.rarity]
			local subtitle = (outItem and Items.Categories[outItem.cat] or "") .. " · у вас: " .. have
			if parts then
				local part = BusParts.List[outId]
				local slot = part and BusParts.Slots[part.slot]
				if slot then
					subtitle = "Слот: " .. slot.name .. " · у вас: " .. have
				end
			elseif (outCount or 1) > 1 then
				subtitle = subtitle .. " · получите x" .. outCount
			end
			recipeCard(order, {
				title = recipe.name,
				subtitle = subtitle,
				desc = outItem and outItem.desc or "",
				color = rarity and rarity.color or UI.Colors.text,
				icon = outId and { kind = "item", id = outId } or nil,
				cost = cost,
				button = {
					text = "Создать",
					disabled = not enough,
					onClick = function()
						Net.Get("Craft"):FireServer(id)
					end,
				},
			})
		end
	end
	if order == 0 then
		note(1, "Рецептов пока нет.")
	end
end

local function refreshWeapons()
	clearList(false)
	local st = C.State
	local levels = st.WeaponLevels or {}
	local order = 0
	for _, id in ipairs(C.State.WeaponOrder or {}) do
		local def = Weapons.List[id]
		if def and def.kind ~= "throw" then
			order = order + 1
			local level = levels[id] or 0
			local rarity = Items.Rarities[def.rarity]
			local stats = string.format("Уровень %d/%d · урон x%.2f · скорость x%.2f", level, Recipes.WeaponMaxLevel, Recipes.WeaponLevelMult(level), 1 / Recipes.WeaponCooldownMult(level))
			if def.mag then
				stats = stats .. " · магазин " .. Recipes.WeaponMagBonus(def.mag, level)
			end
			local price, materials, nextLevel = Recipes.WeaponUpgradeFor(level, def.rarity)
			local r = UI.Frame(list, { Size = UDim2.new(1, -4, 0, 66), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = 0.95, LayoutOrder = order })
			UI.Corner(r, 4)
			UI.Frame(r, { Size = UDim2.new(0, 3, 1, -14), Position = UDim2.fromOffset(7, 7), BackgroundColor3 = rarity and rarity.color or UI.Colors.text })
			UI.Label(r, { Size = UDim2.new(1, -170, 0, 20), Position = UDim2.fromOffset(18, 5), Text = def.name .. (level > 0 and (" +" .. level) or ""), TextSize = 16, TextColor3 = rarity and rarity.color or UI.Colors.text, TextTruncate = Enum.TextTruncate.AtEnd })
			UI.Label(r, { Size = UDim2.new(1, -170, 0, 16), Position = UDim2.fromOffset(18, 25), Text = stats, TextSize = 12, TextColor3 = UI.Colors.dim, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 1 })
			-- уровни 0..max точками
			for i = 1, Recipes.WeaponMaxLevel do
				local pip = UI.Frame(r, { Size = UDim2.fromOffset(14, 4), Position = UDim2.new(1, -160 - (Recipes.WeaponMaxLevel - i + 1) * 17, 0, 12), BackgroundColor3 = i <= level and UI.Colors.accent or rgb(255, 255, 255), BackgroundTransparency = i <= level and 0 or 0.8 })
				UI.Corner(pip, 2)
			end
			if price then
				local cost, enough = costText(price, materials)
				UI.Label(r, { Size = UDim2.new(1, -170, 0, 18), Position = UDim2.fromOffset(18, 43), Text = cost .. escape(string.format("  → ур. %d: урон x%.2f", nextLevel, Recipes.WeaponLevelMult(nextLevel))), RichText = true, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 0.8 })
				actionButton(r, { Size = UDim2.fromOffset(130, 36), Position = UDim2.new(1, -140, 0, 15), Text = "Улучшить" }, {
					disabled = not enough,
					onClick = function()
						Net.Get("UpgradeWeapon"):FireServer(id)
					end,
				})
			else
				UI.Label(r, { Size = UDim2.new(1, -170, 0, 18), Position = UDim2.fromOffset(18, 43), Text = colored("Максимальный уровень", HAVE), RichText = true, TextSize = 12 })
				actionButton(r, { Size = UDim2.fromOffset(130, 36), Position = UDim2.new(1, -140, 0, 15), Text = "Максимум" }, { disabled = true, onClick = function() end })
			end
		end
	end
	if order == 0 then
		note(1, "Нет оружия для улучшения. Найдите или купите его в магазине.")
	end
end

local function refresh()
	if not isOpen then
		return
	end
	win:SetMoney(money())
	tabs:Set(tab)
	if tab == "craft" then
		refreshRecipes(false)
	elseif tab == "parts" then
		refreshRecipes(true)
	else
		refreshWeapons()
	end
end

function WorkbenchUI.IsOpen()
	return isOpen
end

function WorkbenchUI.Close()
	if not isOpen then
		return
	end
	isOpen = false
	benchPart = nil
	win.frame.Visible = false
end

function WorkbenchUI.Open(info)
	if not win then
		return
	end
	if player:GetAttribute("Downed") or player:GetAttribute("Sleeping") then
		return
	end
	info = type(info) == "table" and info or {}
	C.Panels.CloseAll()
	benchPart = typeof(info.part) == "Instance" and info.part or nil
	win.header.Text = string.upper(type(info.name) == "string" and info.name or "Верстак")
	isOpen = true
	win.frame.Visible = true
	sfx("ui_click")
	refresh()
end

local function build()
	gui = UI.Screen("Workbench", 11)
	win = UI.Window({ parent = gui, title = "ВЕРСТАК", size = Vector2.new(900, 590), onClose = WorkbenchUI.Close })
	C.Panels.AttachScale(win.frame)
	tabs = UI.Tabs(win.frame, TABS, UDim2.fromOffset(20, 60), 170, function(key)
		tab = key
		sfx("ui_click")
		refresh()
	end)
	UI.Label(win.frame, { Size = UDim2.fromOffset(300, 36), Position = UDim2.new(1, -320, 0, 60), Text = "Зелёным — есть, красным — не хватает", TextSize = 12, TextColor3 = UI.Colors.dim, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 1 })
	list = UI.Scroller(win.frame, { Size = UDim2.new(1, -40, 1, -124), Position = UDim2.fromOffset(20, 104) })
end

-- Расстояние до поверхности детали, как distanceToPart в WorkbenchService
local function distanceToPart(part, position)
	local lp = part.CFrame:PointToObjectSpace(position)
	local half = part.Size * 0.5
	local dx = math.max(0, math.abs(lp.X) - half.X)
	local dy = math.max(0, math.abs(lp.Y) - half.Y)
	local dz = math.max(0, math.abs(lp.Z) - half.Z)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Закрыть окно, если игрок отошёл от верстака, упал или уснул (4 Гц)
local function monitor(dt)
	if not isOpen then
		return
	end
	monitorAcc = monitorAcc + dt
	if monitorAcc < 0.25 then
		return
	end
	monitorAcc = 0
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 or player:GetAttribute("Downed") or player:GetAttribute("Sleeping") then
		WorkbenchUI.Close()
		return
	end
	if benchPart then
		if not benchPart:IsDescendantOf(workspace) or (benchPart:IsA("BasePart") and distanceToPart(benchPart, root.Position) > CLOSE_DISTANCE) then
			WorkbenchUI.Close()
		end
	end
end

function WorkbenchUI.Init(c)
	C = c
	UI = C.UI
	build()
	C.Panels.RegisterWindow(function()
		return isOpen
	end, WorkbenchUI.Close)
	Net.Get("OpenWorkbench").OnClientEvent:Connect(WorkbenchUI.Open)
	-- данные инвентаря (счётчики, оружие, слоты) разбирает Panels; здесь только перерисовка
	C.Panels.OnInventory(refresh)
	player:GetAttributeChangedSignal("Money"):Connect(refresh)
	RunService.Heartbeat:Connect(monitor)
end

return WorkbenchUI
