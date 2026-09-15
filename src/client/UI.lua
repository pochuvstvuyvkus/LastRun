-- Помощники для построения интерфейса кодом и общая тема (v5, по видео оригинала):
-- тёмные полупрозрачные панели, почти прямые углы (2 px), тонкие светлые рамки, белый жирный текст,
-- оранжевый акцент, зелёные деньги; «текст + клавиша в рамке» для подсказок;
-- 3D-иконки предметов (ViewportFrame + WorldModel, шаблон на предмет, кэш);
-- слоты предметов (в пустом — едва заметный крестик, «в руках» — оранжевый уголок);
-- значки «сердце» и «окорочок» из фигур с заливкой снизу вверх (без загружаемых картинок).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Items)
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local Recipes = require(Shared.Recipes)

local UI = {}

local rgb = Color3.fromRGB
local SQRT2 = math.sqrt(2)

-- Ключи сохранены с v2 (ими пользуются LobbyUI, ProgressUI и др.)
UI.Colors = {
	bg = rgb(12, 12, 14),
	panel = rgb(18, 18, 21),
	panel2 = rgb(38, 38, 43),
	line = rgb(215, 215, 220),
	text = rgb(245, 245, 245),
	dim = rgb(165, 165, 172),
	accent = rgb(255, 170, 60),
	red = rgb(220, 70, 60),
	green = rgb(110, 215, 90),
	money = rgb(120, 225, 95),
	blue = rgb(90, 160, 255),
	yellow = rgb(255, 214, 90),
	purple = rgb(170, 110, 255),
	black = rgb(0, 0, 0),
}

UI.Theme = {
	panelTransparency = 0.45,
	windowTransparency = 0.12,
	corner = 2,
	strokeTransparency = 0.78,
	font = Enum.Font.GothamBold,
	fontBlack = Enum.Font.GothamBlack,
	fontRegular = Enum.Font.Gotham,
	fontMedium = Enum.Font.GothamMedium,
}

-- Токены v5: компактные панели поверх мира
UI.V5 = {
	panel = rgb(10, 11, 13),
	panelTransparency = 0.32,
	tile = rgb(255, 255, 255),
	tileTransparency = 0.94,
	slot = rgb(6, 7, 9),
	slotTransparency = 0.5,
	line = rgb(255, 255, 255),
	lineTransparency = 0.78,
	text = rgb(236, 235, 231),
	muted = rgb(160, 165, 172),
	dim = rgb(109, 115, 122),
	accent = rgb(255, 138, 43),
	ok = rgb(70, 167, 88),
	bad = rgb(229, 72, 77),
	money = rgb(123, 216, 143),
	badge = rgb(234, 232, 227),
	badgeEmpty = rgb(54, 57, 62),
	corner = 2,
}

-- Цвета редкости v5
UI.RarityColors = {
	common = rgb(161, 167, 173),
	uncommon = rgb(88, 196, 114),
	rare = rgb(76, 141, 255),
	epic = rgb(176, 104, 255),
	legendary = rgb(255, 181, 46),
}

-- Общая раскладка хотбара HUD (по ней панель Tab встаёт ровно над ним)
UI.Hotbar = {
	slot = 56,
	gap = 5,
	height = 60,
	bottom = 10,
	backpack = 44,
}

function UI.RarityColor(rarityId)
	local c = UI.RarityColors[rarityId]
	if c then
		return c
	end
	local r = Items.Rarities[rarityId]
	return r and r.color or UI.RarityColors.common
end

function UI.New(className, props, children)
	local inst = Instance.new(className)
	local parent = nil
	if props then
		for k, v in pairs(props) do
			if k == "Parent" then
				parent = v
			else
				inst[k] = v
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function UI.Corner(parent, radius)
	local existing = parent:FindFirstChildOfClass("UICorner")
	if existing then
		existing.CornerRadius = UDim.new(0, radius or UI.Theme.corner)
		return existing
	end
	return UI.New("UICorner", { CornerRadius = UDim.new(0, radius or UI.Theme.corner), Parent = parent })
end

-- Одна обводка на объект: повторный вызов меняет существующую
function UI.Stroke(parent, color, thickness, transparency)
	local stroke = parent:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = parent
	end
	stroke.Color = color or UI.Colors.line
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0
	return stroke
end

function UI.Padding(parent, px)
	return UI.New("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		Parent = parent,
	})
end

function UI.Screen(name, order)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = order or 0
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

function UI.Frame(parent, props)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = UI.Colors.panel
	f.BorderSizePixel = 0
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	f.Parent = parent
	return f
end

function UI.Label(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = UI.Theme.font
	l.TextColor3 = UI.Colors.text
	l.TextSize = 16
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextStrokeColor3 = UI.Colors.black
	l.TextStrokeTransparency = 0.55
	l.RichText = false
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

-- Кнопка в теме: тёмная, тонкая светлая рамка, почти прямые углы
function UI.Button(parent, props, onClick)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = rgb(24, 26, 30)
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.Font = UI.Theme.font
	b.TextColor3 = UI.V5.text
	b.TextSize = 15
	b.AutoButtonColor = true
	b.TextStrokeTransparency = 1
	for k, v in pairs(props or {}) do
		b[k] = v
	end
	UI.Corner(b, UI.Theme.corner)
	UI.Stroke(b, UI.V5.line, 1, 0.8)
	b.Parent = parent
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	return b
end

-- Стили кнопок: "primary" (оранжевая), "good" (зелёная), "danger" (красный текст), "normal", "ghost"
local BUTTON_STYLES = {
	primary = { bg = rgb(255, 138, 43), text = rgb(27, 15, 4), stroke = 1, transparency = 0 },
	good = { bg = rgb(52, 128, 66), text = rgb(240, 255, 240), stroke = 0.85 },
	danger = { bg = rgb(22, 23, 26), text = rgb(236, 88, 90), stroke = 0.7 },
	normal = { bg = rgb(24, 26, 30), text = rgb(236, 235, 231), stroke = 0.78 },
	ghost = { bg = rgb(255, 255, 255), text = rgb(236, 235, 231), stroke = 0.8, transparency = 0.95 },
}

function UI.StyleButton(btn, style)
	local s = BUTTON_STYLES[style or "normal"] or BUTTON_STYLES.normal
	btn.AutoButtonColor = true
	btn.BackgroundColor3 = s.bg
	btn.BackgroundTransparency = s.transparency or 0.08
	btn.TextColor3 = s.text
	UI.Stroke(btn, UI.V5.line, 1, s.stroke)
	return btn
end

function UI.ActionButton(parent, props, style, onClick)
	local b = UI.Button(parent, props, onClick)
	UI.StyleButton(b, style)
	for k, v in pairs(props or {}) do
		if k == "BackgroundColor3" or k == "TextColor3" or k == "BackgroundTransparency" then
			b[k] = v
		end
	end
	return b
end

function UI.DisableButton(btn)
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = rgb(26, 27, 30)
	btn.BackgroundTransparency = 0.25
	btn.TextColor3 = rgb(112, 116, 122)
	UI.Stroke(btn, UI.V5.line, 1, 0.9)
end

-- Тёмная полупрозрачная панель в теме
function UI.Panel(parent, props)
	local f = UI.Frame(parent, {
		BackgroundColor3 = UI.V5.panel,
		BackgroundTransparency = UI.Theme.panelTransparency,
	})
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	UI.Corner(f, UI.Theme.corner)
	UI.Stroke(f, UI.V5.line, 1, UI.Theme.strokeTransparency)
	return f
end

-- Горизонтальное затемнение под текстом (слева плотнее, справа исчезает)
function UI.Shade(parent, props, fromTransparency, rotation)
	local f = UI.Frame(parent, { BackgroundColor3 = UI.Colors.black, BackgroundTransparency = 0 })
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	local g = Instance.new("UIGradient")
	g.Rotation = rotation or 0
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, fromTransparency or 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = f
	return f
end

-- «Клавиша в рамке» ([Shift], [Q]): возвращает рамку, ширина по тексту
function UI.KeyCap(parent, text, props)
	local s = tostring(text)
	local len = utf8.len(s) or #s
	local width = math.max(18, 9 + len * 7)
	local f = UI.Frame(parent, {
		Size = UDim2.fromOffset(width, 18),
		BackgroundColor3 = rgb(14, 15, 17),
		BackgroundTransparency = 0.3,
	})
	UI.Corner(f, 2)
	UI.Stroke(f, rgb(255, 255, 255), 1, 0.55)
	UI.Label(f, {
		Name = "Text",
		Size = UDim2.fromScale(1, 1),
		Text = s,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = rgb(232, 232, 232),
		TextStrokeTransparency = 1,
	})
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	return f
end

-- Крестик из двух тонких линий (пустой слот, кнопка «закрыть»)
function UI.CrossIcon(parent, length, thickness, color, transparency)
	local holder = UI.Frame(parent, {
		Name = "Cross",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(length, length),
		BackgroundTransparency = 1,
	})
	for _, r in ipairs({ 45, -45 }) do
		UI.Frame(holder, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(math.floor(length * SQRT2 + 0.5), thickness or 1),
			Rotation = r,
			BackgroundColor3 = color or rgb(255, 255, 255),
			BackgroundTransparency = transparency or 0,
		})
	end
	return holder
end

-- Зелёная «купюра» из рамок (своя графика): size — Vector2 или nil (46×24)
function UI.MoneyIcon(parent, props, size)
	size = size or Vector2.new(46, 24)
	local bill = UI.Frame(parent, {
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = rgb(96, 196, 70),
		Rotation = -12,
	})
	UI.Corner(bill, 3)
	UI.Stroke(bill, rgb(30, 70, 25), 2, 0.1)
	local inner = UI.Frame(bill, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -8, 1, -8),
		BackgroundTransparency = 1,
	})
	UI.Corner(inner, 2)
	UI.Stroke(inner, rgb(200, 255, 170), 1, 0.45)
	local coin = UI.Frame(bill, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size.Y - 8, size.Y - 8),
		BackgroundColor3 = rgb(60, 150, 50),
	})
	UI.Corner(coin, size.Y)
	UI.Label(coin, {
		Size = UDim2.fromScale(1, 1),
		Text = "$",
		TextSize = math.max(9, size.Y - 11),
		Font = UI.Theme.fontBlack,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = rgb(225, 255, 210),
		TextStrokeTransparency = 1,
	})
	for k, v in pairs(props or {}) do
		bill[k] = v
	end
	return bill
end

-- Ромб (метки целей)
function UI.Diamond(parent, props)
	local d = UI.Frame(parent, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12),
		Rotation = 45,
		BackgroundColor3 = UI.Colors.yellow,
	})
	UI.Stroke(d, UI.Colors.black, 1.5, 0.3)
	for k, v in pairs(props or {}) do
		d[k] = v
	end
	return d
end

-- Прокручиваемый список в теме
function UI.Scroller(parent, props)
	local s = Instance.new("ScrollingFrame")
	s.BackgroundColor3 = UI.Colors.black
	s.BackgroundTransparency = 0.7
	s.BorderSizePixel = 0
	s.ScrollBarThickness = 3
	s.ScrollBarImageColor3 = rgb(200, 200, 205)
	s.ScrollBarImageTransparency = 0.4
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.CanvasSize = UDim2.new()
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	for k, v in pairs(props or {}) do
		s[k] = v
	end
	UI.Corner(s, UI.Theme.corner)
	UI.Padding(s, 8)
	s.Parent = parent
	return s
end

-- Удаляет содержимое контейнера (элементы и раскладки), оставляя UIPadding/UICorner
function UI.Clear(container)
	for _, ch in ipairs(container:GetChildren()) do
		if ch:IsA("GuiObject") or ch:IsA("UIGridStyleLayout") then
			ch:Destroy()
		end
	end
end

function UI.List(parent, padding, horizontal)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding or 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	if horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
	end
	layout.Parent = parent
	return layout
end

-- «Грязная» отделка тёмной панели (v4; оставлено для совместимости)
function UI.Grime(frame, rustTransparency)
	local shade = Instance.new("UIGradient")
	shade.Rotation = 90
	shade.Color = ColorSequence.new(rgb(255, 255, 255), rgb(140, 140, 146))
	shade.Parent = frame
	local rust = UI.Frame(frame, { Name = "Rust", Size = UDim2.new(0.6, 0, 0.6, 0), BackgroundColor3 = rgb(140, 78, 32) })
	UI.Corner(rust, UI.Theme.corner)
	local rg = Instance.new("UIGradient")
	rg.Rotation = 40
	rg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, rustTransparency or 0.84),
		NumberSequenceKeypoint.new(0.55, 0.97),
		NumberSequenceKeypoint.new(1, 1),
	})
	rg.Parent = rust
	return rust
end

-- Заклёпки по углам панели (v4; оставлено для совместимости)
function UI.Rivets(frame, inset)
	inset = inset or 7
	for _, a in ipairs({ Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local r = UI.Frame(frame, {
			Name = "Rivet",
			AnchorPoint = a,
			Position = UDim2.new(a.X, a.X == 0 and inset or -inset, a.Y, a.Y == 0 and inset or -inset),
			Size = UDim2.fromOffset(5, 5),
			BackgroundColor3 = rgb(118, 112, 102),
		})
		UI.Corner(r, 3)
		UI.Stroke(r, rgb(0, 0, 0), 1, 0.3)
	end
end

-- Модальное окно в теме: { frame, header, money, moneyIcon, closeButton, divider, SetMoney }
-- opts: parent, title, size (Vector2), onClose, showMoney (bool)
function UI.Window(opts)
	local V = UI.V5
	local size = opts.size or Vector2.new(860, 560)
	local frame = UI.Frame(opts.parent, {
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = V.panel,
		BackgroundTransparency = 0.06,
		Visible = false,
	})
	UI.Corner(frame, V.corner)
	UI.Stroke(frame, V.line, 1, 0.8)
	local header = UI.Label(frame, {
		Size = UDim2.new(1, -330, 0, 46),
		Position = UDim2.fromOffset(20, 4),
		Text = opts.title or "",
		Font = UI.Theme.fontBlack,
		TextSize = 20,
		TextColor3 = V.text,
		TextStrokeTransparency = 1,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	UI.Frame(frame, { Name = "Marker", Position = UDim2.fromOffset(20, 44), Size = UDim2.fromOffset(28, 2), BackgroundColor3 = V.accent })
	local money, moneyIcon
	if opts.showMoney ~= false then
		money = UI.Label(frame, {
			Size = UDim2.fromOffset(150, 46),
			Position = UDim2.new(1, -206, 0, 6),
			TextXAlignment = Enum.TextXAlignment.Right,
			Font = UI.Theme.fontBlack,
			TextSize = 19,
			TextColor3 = V.money,
			TextStrokeTransparency = 1,
			Text = "",
		})
		moneyIcon = UI.MoneyIcon(frame, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -212, 0, 29) }, Vector2.new(34, 18))
		moneyIcon.Visible = false
	end
	local closeButton = UI.Button(frame, {
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(1, -44, 0, 14),
		Text = "",
		BackgroundColor3 = rgb(20, 21, 24),
		BackgroundTransparency = 0.2,
		Modal = true, -- пока окно видно, мышь свободна даже в первом лице
	}, function()
		if opts.onClose then
			opts.onClose()
		end
	end)
	UI.CrossIcon(closeButton, 11, 2, V.text, 0.1)
	local divider = UI.Frame(frame, { Size = UDim2.new(1, -40, 0, 1), Position = UDim2.fromOffset(20, 56), BackgroundColor3 = V.line, BackgroundTransparency = 0.88 })
	local win = { frame = frame, header = header, money = money, moneyIcon = moneyIcon, closeButton = closeButton, divider = divider }
	-- Обновить текст денег (иконка встаёт слева от суммы)
	function win.SetMoney(_, amount)
		if not money then
			return
		end
		money.Text = tostring(amount)
		moneyIcon.Visible = true
		local width = money.TextBounds.X
		if width <= 0 then
			width = #tostring(amount) * 12
		end
		moneyIcon.Position = UDim2.new(1, -56 - width - 10, 0, 29)
	end
	return win
end

-- Вкладки с подчёркиванием: tabs = { {key, title}, ... }; возвращает { Set(key), buttons }
function UI.Tabs(parent, tabs, position, width, onSelect)
	local V = UI.V5
	local row = UI.Frame(parent, {
		Size = UDim2.new(1, -40, 0, 36),
		Position = position or UDim2.fromOffset(20, 62),
		BackgroundTransparency = 1,
	})
	local buttons = {}
	local underlines = {}
	for i, t in ipairs(tabs) do
		local btn = Instance.new("TextButton")
		btn.Name = t[1]
		btn.AutoButtonColor = false
		btn.BackgroundTransparency = 1
		btn.Size = UDim2.fromOffset(width or 120, 36)
		btn.Position = UDim2.fromOffset((i - 1) * ((width or 120) + 4), 0)
		btn.Font = UI.Theme.font
		btn.TextSize = 14
		btn.Text = t[2]
		btn.TextColor3 = V.muted
		btn.TextStrokeTransparency = 1
		btn.Parent = row
		local line = UI.Frame(btn, { Size = UDim2.new(1, -16, 0, 2), Position = UDim2.new(0, 8, 1, -2), BackgroundColor3 = V.accent, Visible = false })
		buttons[t[1]] = btn
		underlines[t[1]] = line
		btn.MouseButton1Click:Connect(function()
			if onSelect then
				onSelect(t[1])
			end
		end)
	end
	local tabsObj = { row = row, buttons = buttons }
	function tabsObj.Set(_, key)
		for k, btn in pairs(buttons) do
			local on = k == key
			btn.TextColor3 = on and V.text or V.muted
			underlines[k].Visible = on
		end
	end
	return tabsObj
end

-- Полоска: возвращает объект с методом Set(доля, текст, цвет)
function UI.Bar(parent, props)
	local frame = UI.Frame(parent, {
		Size = props.Size,
		Position = props.Position or UDim2.new(),
		BackgroundColor3 = rgb(0, 0, 0),
		BackgroundTransparency = 0.45,
	})
	UI.Corner(frame, props.Radius or 2)
	UI.Stroke(frame, UI.Colors.line, 1, 0.85)
	local fill = UI.Frame(frame, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = props.Color or UI.Colors.green,
	})
	UI.Corner(fill, props.Radius or 2)
	local label = UI.Label(frame, {
		Size = UDim2.new(1, -12, 1, 0),
		Position = UDim2.fromOffset(6, 0),
		TextSize = props.TextSize or 13,
		Text = "",
		ZIndex = 3,
		TextStrokeTransparency = 0.35,
	})
	local bar = { Frame = frame, Fill = fill, Label = label }
	function bar.Set(_, fraction, text, color)
		fraction = math.clamp(fraction or 0, 0, 1)
		fill.Size = UDim2.fromScale(fraction, 1)
		fill.Visible = fraction > 0.003
		if text then
			label.Text = text
		end
		if color then
			fill.BackgroundColor3 = color
		end
	end
	return bar
end

-- Масштаб интерфейса по размеру экрана: clamp(min(vp.X/1280, vp.Y/720), 0.55, 1)
function UI.ViewportScale()
	local camera = workspace.CurrentCamera
	local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
	if vp.X <= 1 or vp.Y <= 1 then
		return 1
	end
	return math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1)
end

-- Добавляет UIScale к панели и обновляет его при изменении размера окна.
-- scalePosition = true: смещение Position (Offset) тоже умножается на масштаб.
local scaled = {}
local scaleConn, cameraConn
local function refreshScales()
	local s = UI.ViewportScale()
	for scale, entry in pairs(scaled) do
		if scale.Parent then
			scale.Scale = s
			if entry.base and entry.object then
				local p = entry.base
				entry.object.Position = UDim2.new(p.X.Scale, p.X.Offset * s, p.Y.Scale, p.Y.Offset * s)
			end
		else
			scaled[scale] = nil
		end
	end
end
local function watchCamera()
	if scaleConn then
		scaleConn:Disconnect()
		scaleConn = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		scaleConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshScales)
	end
	refreshScales()
end

function UI.AddScale(guiObject, scalePosition)
	local scale = Instance.new("UIScale")
	scale.Scale = UI.ViewportScale()
	scale.Parent = guiObject
	scaled[scale] = { object = guiObject, base = scalePosition and guiObject.Position or nil }
	if not cameraConn then
		cameraConn = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
		watchCamera()
	else
		refreshScales()
	end
	return scale
end

-- Сменить базовую позицию панели, у которой масштабируется смещение
function UI.SetScaledPosition(guiObject, position)
	for scale, entry in pairs(scaled) do
		if entry.object == guiObject and scale.Parent then
			entry.base = position
			local s = scale.Scale
			guiObject.Position = UDim2.new(position.X.Scale, position.X.Offset * s, position.Y.Scale, position.Y.Offset * s)
			return
		end
	end
	guiObject.Position = position
end

function UI.Tween(inst, time, props, style, direction)
	local tween = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

-- Короткое число с пробелами: 95749 -> "95 749"
function UI.Thousands(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local sign = ""
	if string.sub(s, 1, 1) == "-" then
		sign = "-"
		s = string.sub(s, 2)
	end
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1 ")))
	if string.sub(out, 1, 1) == " " then
		out = string.sub(out, 2)
	end
	return sign .. out
end

-- Значки «сердце» и «окорочок» ------------------------------------------------------------------
-- Силуэт из деталей: тень-обводка, пустой (тёмный) силуэт и светлая заливка снизу вверх.
-- Заливка — контейнер с ClipsDescendants (сам не повёрнут; повёрнутые детали внутри обрезаются по нему).
-- Сам значок не поворачивать: тряска — смещением, пульс — UIScale (badge.scale).

-- Деталь: { cx, cy, w, h, rotation, round } в долях квадрата; round 0.5 — капсула/круг
local function heartPieces()
	local W = 0.94
	local d = W / (1 + SQRT2) -- половина диагонали квадрата
	local r = d / SQRT2 -- радиус «ушек» (диаметр = стороне квадрата)
	local side = d * SQRT2
	local H = 1.5 * d + r
	local top = (1 - H) / 2
	local cx = 0.5
	return {
		{ cx - d / 2, top + r, 2 * r, 2 * r, 0, 0.5 },
		{ cx + d / 2, top + r, 2 * r, 2 * r, 0, 0.5 },
		{ cx, top + d / 2 + r, side, side, 45, 0 },
	}, cx, top + H * 0.43
end

local function foodPieces()
	local angle = 42
	local theta = math.rad(angle)
	local c, s = math.cos(theta), math.sin(theta)
	local function rot(x, y)
		local dx, dy = x - 0.5, y - 0.5
		return 0.5 + dx * c - dy * s, 0.5 + dx * s + dy * c
	end
	-- окорочок «лёжа» (мясо слева, кость вправо), затем поворот: кость смотрит вниз-вправо
	local raw = {
		{ 0.3, 0.5, 0.56, 0.48, 0, 0.5 }, -- мясо
		{ 0.52, 0.5, 0.24, 0.24, 45, 0.2 }, -- переход к кости
		{ 0.7, 0.5, 0.34, 0.12, 0, 0.5 }, -- кость
		{ 0.875, 0.4, 0.2, 0.2, 0, 0.5 }, -- головки кости
		{ 0.875, 0.6, 0.2, 0.2, 0, 0.5 },
	}
	local out = {}
	for i, p in ipairs(raw) do
		local x, y = rot(p[1], p[2])
		out[i] = { x, y, p[3], p[4], p[5] + angle, p[6] }
	end
	local tx, ty = rot(0.3, 0.5)
	return out, tx, ty
end

-- Вертикальная полувысота детали на экране (для доли заливки)
local function pieceExtentY(p)
	local w, h, rotRad = p[3], p[4], math.rad(p[5])
	if p[6] >= 0.5 then
		local long, short = math.max(w, h), math.min(w, h)
		local axis = (w >= h) and math.abs(math.sin(rotRad)) or math.abs(math.cos(rotRad))
		return (long - short) / 2 * axis + short / 2
	end
	return w / 2 * math.abs(math.sin(rotRad)) + h / 2 * math.abs(math.cos(rotRad))
end

-- UI.VitalBadge(parent, "heart" | "food", opts) -> badge
-- opts: size (px, по умолчанию 60), showText (true), name, position, anchor, layoutOrder, zIndex
-- badge:Set(доля 0..1, текст, цвет заливки или nil); badge.root, badge.scale (UIScale для пульса)
function UI.VitalBadge(parent, kind, opts)
	opts = opts or {}
	local V = UI.V5
	local size = opts.size or 60
	local outline = math.max(1, math.floor(size * 0.045 + 0.5))
	local pieces, textX, textY
	if kind == "heart" then
		pieces, textX, textY = heartPieces()
	else
		pieces, textX, textY = foodPieces()
	end
	local top, bottom = 1, 0
	for _, p in ipairs(pieces) do
		local e = pieceExtentY(p)
		top = math.min(top, p[2] - e)
		bottom = math.max(bottom, p[2] + e)
	end

	local root = UI.Frame(parent, { Name = opts.name or "VitalBadge", Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1 })
	if opts.position then
		root.Position = opts.position
	end
	if opts.anchor then
		root.AnchorPoint = opts.anchor
	end
	if opts.layoutOrder then
		root.LayoutOrder = opts.layoutOrder
	end
	if opts.zIndex then
		root.ZIndex = opts.zIndex
	end
	local scale = Instance.new("UIScale")
	scale.Parent = root

	local function layer(container, name, z, color, transparency, grow)
		local holder = UI.Frame(container, { Name = name, Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1, ZIndex = z })
		local parts = {}
		for _, p in ipairs(pieces) do
			local w, h = p[3] * size + grow * 2, p[4] * size + grow * 2
			local f = UI.Frame(holder, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(p[1] * size, p[2] * size),
				Size = UDim2.fromOffset(w, h),
				Rotation = p[5],
				BackgroundColor3 = color,
				BackgroundTransparency = transparency,
			})
			if p[6] > 0 then
				local corner = Instance.new("UICorner")
				corner.CornerRadius = p[6] >= 0.5 and UDim.new(0.5, 0) or UDim.new(0, math.floor(math.min(w, h) * p[6] + 0.5))
				corner.Parent = f
			end
			table.insert(parts, f)
		end
		return holder, parts
	end

	-- тёмный контур и серый «пустой» силуэт: значок читается и на светлом, и на тёмном фоне
	layer(root, "Shadow", 1, rgb(0, 0, 0), 0.35, outline)
	layer(root, "Empty", 2, V.badgeEmpty, 0.12, 0)
	local clip = UI.Frame(root, {
		Name = "Fill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 3,
	})
	local fillHolder, fillParts = layer(clip, "Shape", 3, V.badge, 0, 0)
	fillHolder.AnchorPoint = Vector2.new(0, 1)
	fillHolder.Position = UDim2.fromScale(0, 1)

	local label = nil
	if opts.showText ~= false then
		label = UI.Label(root, {
			Name = "Value",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(textX * size, textY * size),
			Size = UDim2.fromOffset(size, math.floor(size * 0.3)),
			Text = "",
			TextSize = math.max(10, math.floor(size * 0.19)),
			Font = UI.Theme.fontBlack,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 4,
		})
	end

	local badge = { root = root, scale = scale, label = label, fraction = -1, color = V.badge }
	function badge.Set(_, fraction, text, fillColor)
		fraction = math.clamp(tonumber(fraction) or 0, 0, 1)
		if math.abs(fraction - badge.fraction) > 0.0005 then
			badge.fraction = fraction
			local fillTop = top + (1 - fraction) * (bottom - top)
			clip.Size = UDim2.fromOffset(size, math.max(0, math.floor((1 - fillTop) * size + 0.5)))
			clip.Visible = fraction > 0.001
			if label then
				local covered = fillTop <= textY - 0.05
				label.TextColor3 = covered and rgb(26, 26, 28) or V.text
				label.TextStrokeTransparency = covered and 1 or 0.35
			end
		end
		if label and text ~= nil then
			label.Text = tostring(text)
		end
		local col = fillColor or V.badge
		if col ~= badge.color then
			badge.color = col
			for _, f in ipairs(fillParts) do
				f.BackgroundColor3 = col
			end
		end
	end
	badge:Set(1, "")
	return badge
end

-- 3D-иконки предметов --------------------------------------------------------------------------
-- Шаблон модели собирается один раз на предмет: ItemModels.Build (если модуль уже есть),
-- WeaponModels.MakeDisplay для оружия, иначе — простая деталь по Items.List.
-- Во ViewportFrame кладётся клон шаблона только при смене предмета (без перестройки каждый кадр).

local ICON_FOV = 30
local ICON_JUNK = { "LuaSourceContainer", "Sound", "ParticleEmitter", "Light", "Trail", "Beam", "LayerCollector", "ProximityPrompt", "ClickDetector", "Fire", "Smoke", "Sparkles", "ForceField", "Constraint", "BodyMover" }
local DRINKS = { water = true, coffee = true, energy_drink = true, herbal_tea = true }

local iconTemplates = {} -- ["kind:id"] = шаблон | false
local itemModelsModule = nil -- nil — ещё нет (повторить позже), false — ошибка, table — модуль
local itemModelsRetryAt = 0

UI.IconEpoch = 0

local function itemModels()
	if itemModelsModule then
		return itemModelsModule
	end
	if itemModelsModule == false then
		return nil
	end
	local now = os.clock()
	if now < itemModelsRetryAt then
		return nil
	end
	itemModelsRetryAt = now + 4
	local module = Shared:FindFirstChild("ItemModels")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok or type(result) ~= "table" or type(result.Build) ~= "function" then
		itemModelsModule = false
		return nil
	end
	itemModelsModule = result
	-- запасные шаблоны, собранные до появления модуля, пересобрать
	for key, t in pairs(iconTemplates) do
		if t == false or t.fallback then
			if t then
				t.model:Destroy()
			end
			iconTemplates[key] = nil
		end
	end
	UI.IconEpoch = UI.IconEpoch + 1
	return result
end

-- Вид записи слота: "weapon" | "item" | nil
function UI.EntryKind(entry)
	if type(entry) ~= "table" or type(entry.id) ~= "string" then
		return nil
	end
	if entry.kind == "weapon" or entry.kind == "item" then
		return entry.kind
	end
	if Weapons.List[entry.id] and not Items.List[entry.id] then
		return "weapon"
	end
	return "item"
end

-- Описание записи слота: { kind, id, name, rarityId, rarity, rarityColor, count, level, stack, def | item }
function UI.EntryInfo(entry)
	local kind = UI.EntryKind(entry)
	if not kind then
		return nil
	end
	local info = { kind = kind, id = entry.id }
	if kind == "weapon" then
		local def = Weapons.List[entry.id]
		info.def = def
		info.name = def and def.name or entry.id
		info.rarityId = def and def.rarity or "common"
		info.level = math.max(0, math.floor(tonumber(entry.level) or 0))
		info.count = 1
		info.stack = 1
	else
		local item = Items.List[entry.id]
		info.item = item
		info.name = item and item.name or entry.id
		info.rarityId = item and item.rarity or "common"
		info.count = math.max(1, math.floor(tonumber(entry.count) or 1))
		info.level = 0
		local stack = item and tonumber(item.stack)
		info.stack = (stack and stack >= 1) and math.floor(stack) or 1
	end
	info.rarity = Items.Rarities[info.rarityId] or Items.Rarities.common
	info.rarityColor = UI.RarityColor(info.rarityId)
	return info
end

-- Глагол действия «использовать» для предмета (nil — нельзя использовать)
function UI.UseVerb(info)
	if not info or info.kind ~= "item" or not info.item then
		return nil
	end
	local cat = info.item.cat
	if cat == "food" then
		return DRINKS[info.id] and "Выпить" or "Съесть"
	elseif cat == "medical" then
		return info.id == "adrenaline" and "Вколоть" or "Лечиться"
	elseif cat == "fuel" then
		return "Закинуть в печь"
	elseif cat == "buspart" then
		return "Прикрепить"
	elseif cat == "placeable" then
		return "Поставить"
	elseif cat == "tool" then
		return "Использовать"
	elseif cat == "valuable" then
		return "Осмотреть"
	elseif cat == "throwable" then
		return "Бросить"
	end
	return nil
end

local function cleanIconModel(model)
	for _, d in ipairs(model:GetDescendants()) do
		local junk = false
		for _, cls in ipairs(ICON_JUNK) do
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
		end
	end
end

local function fallbackModel(item)
	local model = Instance.new("Model")
	model.Name = "Icon"
	local p = Instance.new("Part")
	local size = typeof(item.size) == "Vector3" and item.size or Vector3.new(1, 1, 1)
	if item.shape == "Cylinder" then
		p.Shape = Enum.PartType.Cylinder
	elseif item.shape == "Ball" then
		p.Shape = Enum.PartType.Ball
	end
	p.Size = Vector3.new(math.max(0.1, size.X), math.max(0.1, size.Y), math.max(0.1, size.Z))
	p.Color = typeof(item.color) == "Color3" and item.color or rgb(160, 160, 160)
	p.Material = typeof(item.material) == "EnumItem" and item.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = true
	p.CFrame = CFrame.new()
	p.Parent = model
	model.PrimaryPart = p
	return model
end

-- Ракурс: вытянутые предметы — по диагонали кадра (как иконка лопаты), компактные — три четверти сверху
local function iconView(model)
	local boxCf, size = model:GetBoundingBox()
	local axes = {
		{ dir = boxCf.RightVector, len = size.X },
		{ dir = boxCf.UpVector, len = size.Y },
		{ dir = boxCf.LookVector, len = size.Z },
	}
	table.sort(axes, function(a, b)
		return a.len > b.len
	end)
	local long, mid, short = axes[1], axes[2], axes[3]
	local tanHalf = math.tan(math.rad(ICON_FOV / 2))
	local dir, up, distance
	if long.len > mid.len * 1.7 then
		up = (long.dir + mid.dir).Unit
		dir = (short.dir + mid.dir * 0.22 - long.dir * 0.1).Unit
		distance = long.len * 0.5 / tanHalf / 1.32 + short.len * 0.5 + 0.2
	else
		up = boxCf.UpVector
		dir = (boxCf.LookVector + boxCf.RightVector * 0.7 + boxCf.UpVector * 0.55).Unit
		distance = size.Magnitude * 0.5 / tanHalf * 0.98
	end
	return boxCf.Position, dir, up, math.max(distance, 0.5)
end

local function buildTemplate(kind, id)
	local model, fallback = nil, false
	if kind == "weapon" then
		if Weapons.List[id] then
			local ok, result = pcall(WeaponModels.MakeDisplay, id, CFrame.new())
			if ok and typeof(result) == "Instance" then
				model = result
			end
		end
	else
		local module = itemModels()
		if module then
			local ok, result = pcall(module.Build, id)
			if ok and typeof(result) == "Instance" then
				if result:IsA("Model") then
					model = result
				elseif result:IsA("BasePart") then
					model = Instance.new("Model")
					result.Parent = model
					model.PrimaryPart = result
				else
					result:Destroy()
				end
			end
		end
		local item = Items.List[id]
		if not model and item then
			model = fallbackModel(item)
			fallback = module == nil
		end
	end
	if not model then
		return nil
	end
	cleanIconModel(model)
	if not model:FindFirstChildWhichIsA("BasePart", true) then
		model:Destroy()
		return nil
	end
	local center, dir, up, distance = iconView(model)
	return { model = model, center = center, dir = dir, up = up, distance = distance, fallback = fallback }
end

-- Шаблон иконки (кэш на предмет): { model, center, dir, up, distance } или nil
function UI.GetIconTemplate(kind, id)
	if (kind ~= "weapon" and kind ~= "item") or type(id) ~= "string" then
		return nil
	end
	if kind == "item" then
		itemModels()
	end
	local key = kind .. ":" .. id
	local t = iconTemplates[key]
	if t == nil then
		t = buildTemplate(kind, id) or false
		iconTemplates[key] = t
	end
	return t or nil
end

-- CFrame камеры иконки; angle — поворот вокруг оси «вверх» кадра (для покачивания крупной иконки)
function UI.IconCFrame(template, angle)
	local dir = template.dir
	if angle and angle ~= 0 then
		dir = CFrame.fromAxisAngle(template.up, angle):VectorToWorldSpace(dir)
	end
	return CFrame.lookAt(template.center + dir * template.distance, template.center, template.up)
end

-- Показать 3D-иконку записи слота во ViewportFrame (nil — очистить). Возвращает шаблон или nil.
function UI.SetItemIcon(viewport, entry)
	local kind = UI.EntryKind(entry)
	local id = kind and entry.id or nil
	if kind == "item" then
		itemModels()
	end
	local key = kind and (kind .. ":" .. id .. ":" .. UI.IconEpoch) or ""
	if viewport:GetAttribute("IconKey") == key then
		return kind and iconTemplates[kind .. ":" .. id] or nil
	end
	viewport:SetAttribute("IconKey", key)
	local old = viewport:FindFirstChild("IconWorld")
	if old then
		old:Destroy()
	end
	local template = kind and UI.GetIconTemplate(kind, id) or nil
	if not template then
		return nil
	end
	local world = Instance.new("WorldModel")
	world.Name = "IconWorld"
	template.model:Clone().Parent = world
	local camera = viewport:FindFirstChild("IconCamera")
	if not camera then
		camera = Instance.new("Camera")
		camera.Name = "IconCamera"
		camera.Parent = viewport
	end
	camera.FieldOfView = ICON_FOV
	camera.CFrame = UI.IconCFrame(template, 0)
	viewport.CurrentCamera = camera
	world.Parent = viewport
	return template
end

-- Новый ViewportFrame для 3D-иконки (свет как у слотов)
function UI.IconViewport(parent, props)
	local vp = Instance.new("ViewportFrame")
	vp.Name = "Icon"
	vp.BackgroundTransparency = 1
	vp.Ambient = rgb(170, 170, 175)
	vp.LightColor = rgb(255, 246, 232)
	vp.LightDirection = Vector3.new(-0.5, -1, -0.7)
	for k, v in pairs(props or {}) do
		vp[k] = v
	end
	vp.Parent = parent
	return vp
end

-- Слот предмета (хотбар HUD, рюкзак Tab): квадрат с 3D-иконкой, количеством, уровнем, патронами и цветом редкости.
-- opts: size, keyText, showName, transparency, position, layoutOrder, name, cross (крестик в пустом)
-- Возвращает { button, viewport, stroke, scale, entry, info, template, Set(entry, state) };
-- state = { active (в руках), selected, hover, target ("ok" | "bad"), dim (тащат из слота), open (режим Tab) }
function UI.ItemSlot(parent, opts)
	opts = opts or {}
	local V = UI.V5
	local size = opts.size or 64
	local baseTransparency = opts.transparency or V.slotTransparency
	local button = Instance.new("TextButton")
	button.Name = opts.name or "Slot"
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = V.slot
	button.BackgroundTransparency = baseTransparency
	button.Size = UDim2.fromOffset(size, size)
	if opts.position then
		button.Position = opts.position
	end
	if opts.layoutOrder then
		button.LayoutOrder = opts.layoutOrder
	end
	UI.Corner(button, V.corner)
	local stroke = UI.Stroke(button, V.line, 1, V.lineTransparency)
	local scale = Instance.new("UIScale")
	scale.Parent = button

	local cross = nil
	if opts.cross then
		cross = UI.CrossIcon(button, math.floor(size * 0.34), 1, V.line, 0.86)
	end
	local rarityBar = UI.Frame(button, { Name = "RarityBar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2), Size = UDim2.new(1, -8, 0, 2), BackgroundColor3 = rgb(255, 255, 255), Visible = false })

	local nameH = opts.showName and math.max(11, math.floor(size * 0.2)) or 0
	local pad = math.max(4, math.floor(size * 0.09))
	local viewport = UI.IconViewport(button, {
		Position = UDim2.fromOffset(pad, pad - 1),
		Size = UDim2.new(1, -pad * 2, 1, -pad * 2 - nameH + 2),
	})

	local small = math.clamp(math.floor(size * 0.17), 9, 12)
	local fallback = UI.Label(button, { Name = "Fallback", Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6 - nameH), Text = "", TextSize = small, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = V.muted, Visible = false })
	local key = UI.Label(button, { Name = "Key", Position = UDim2.fromOffset(4, 2), Size = UDim2.fromOffset(16, small + 2), Text = opts.keyText or "", TextSize = small - 1, TextColor3 = rgb(150, 155, 162), TextStrokeTransparency = 0.5 })
	local levelChip = UI.Frame(button, { Name = "Level", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -3, 0, 3), Size = UDim2.fromOffset(22, 13), BackgroundColor3 = rgb(42, 47, 54), BackgroundTransparency = 0.05, Visible = false })
	UI.Corner(levelChip, 2)
	local levelLabel = UI.Label(levelChip, { Size = UDim2.fromScale(1, 1), Text = "", TextSize = 10, Font = UI.Theme.fontBlack, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = V.accent, TextStrokeTransparency = 1 })
	local countSize = math.clamp(math.floor(size * 0.22), 11, 14)
	local count = UI.Label(button, { Name = "Count", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -4, 1, -2 - nameH), Size = UDim2.fromOffset(50, countSize + 2), Text = "", TextSize = countSize, Font = UI.Theme.font, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 0.15 })
	local ammo = UI.Label(button, { Name = "Ammo", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 4, 1, -2 - nameH), Size = UDim2.fromOffset(44, 12), Text = "", TextSize = 9, Font = UI.Theme.font, TextColor3 = rgb(190, 194, 200), TextStrokeTransparency = 0.4 })
	local name = nil
	if opts.showName then
		name = UI.Label(button, { Name = "ItemName", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -3), Size = UDim2.new(1, -6, 0, nameH - 1), Text = "", TextScaled = true, TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.4 })
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = math.clamp(math.floor(size * 0.19), 9, 12)
		limit.MinTextSize = 7
		limit.Parent = name
	end
	-- «в руках»: оранжевый уголок (половина квадрата через ступенчатый градиент)
	local cornerSize = math.clamp(math.floor(size * 0.2), 8, 13)
	local handsCorner = UI.Frame(button, { Name = "Hands", Size = UDim2.fromOffset(cornerSize, cornerSize), BackgroundColor3 = V.accent, Visible = false })
	UI.Corner(handsCorner, 2)
	local handsGrad = Instance.new("UIGradient")
	handsGrad.Rotation = 45
	handsGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.499, 0),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	handsGrad.Parent = handsCorner
	button.Parent = parent

	local slot = { button = button, viewport = viewport, stroke = stroke, scale = scale, entry = nil, info = nil, template = nil }
	function slot.Set(_, entry, state)
		state = state or {}
		local info = UI.EntryInfo(entry)
		slot.entry = info and entry or nil
		slot.info = info
		slot.template = UI.SetItemIcon(viewport, slot.entry)
		local showEmpty = state.open == true or opts.alwaysShowEmpty == true
		if info then
			fallback.Visible = slot.template == nil
			fallback.Text = info.name
			if name then
				name.Text = info.name
				name.TextColor3 = state.active and rgb(255, 255, 255) or rgb(222, 222, 222)
			end
			count.Text = info.count > 1 and tostring(info.count) or ""
			levelChip.Visible = info.level > 0
			levelLabel.Text = info.level > 0 and ("+" .. info.level) or ""
			local ammoText = ""
			local def = info.def
			if def and def.mag and def.kind ~= "melee" then
				local mag = tonumber(entry.mag)
				if mag then
					ammoText = math.floor(mag) .. "/" .. Recipes.WeaponMagBonus(def.mag, info.level)
				end
			end
			ammo.Text = ammoText
			local rare = info.rarityId ~= "common"
			rarityBar.Visible = rare
			if rare then
				rarityBar.BackgroundColor3 = info.rarityColor
			end
		else
			fallback.Visible = false
			if name then
				name.Text = ""
			end
			count.Text = ""
			levelChip.Visible = false
			ammo.Text = ""
			rarityBar.Visible = false
		end
		if cross then
			cross.Visible = info == nil and showEmpty
		end
		key.Visible = key.Text ~= "" and (info ~= nil or showEmpty)
		local color, transparency, thickness = V.line, V.lineTransparency, 1
		if not info then
			transparency = showEmpty and 0.82 or 0.94
		elseif info.rarityId ~= "common" then
			color, transparency = info.rarityColor, 0.45
		end
		if state.active then
			color, transparency, thickness = rgb(255, 255, 255), 0.15, 1.5
		end
		if state.selected then
			color, transparency, thickness = V.accent, 0, 2
		end
		if state.hover then
			color, transparency = V.accent, 0.4
		end
		if state.target == "ok" then
			color, transparency, thickness = V.ok, 0, 2
		elseif state.target == "bad" then
			color, transparency, thickness = V.bad, 0, 2
		end
		stroke.Color = color
		stroke.Transparency = transparency
		stroke.Thickness = thickness
		handsCorner.Visible = state.active == true and info ~= nil
		local bg = baseTransparency
		if not info then
			bg = showEmpty and math.min(0.92, baseTransparency + 0.1) or 0.9
		elseif state.active then
			bg = math.max(0, baseTransparency - 0.15)
		end
		button.BackgroundTransparency = bg
		viewport.ImageTransparency = state.dim and 0.65 or 0
		-- в раскладке (хотбар) увеличение сдвигало бы соседей — там hoverScale = false
		if opts.hoverScale ~= false then
			scale.Scale = (state.hover and info) and 1.03 or 1
		end
	end
	return slot
end

return UI
