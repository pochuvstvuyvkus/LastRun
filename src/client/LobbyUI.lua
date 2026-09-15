-- Лобби v3 (как схема оригинала, своя графика): слева сверху полоса уровня и крупные квадратные
-- кнопки (КЛАССЫ, НАГРАДЫ, ПРОФИЛЬ, ПРИСОЕДИНИТЬСЯ), слева снизу билеты, по центру снизу большая
-- зелёная «ИГРАТЬ», справа снизу «Пригласить друзей»; в зоне посадки автобуса — панель группы.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Difficulty = require(Shared.Difficulty)

local LobbyUI = {}

local C
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

-- Тема (как тёмное Tab-меню): тёмные панели, тонкая светлая обводка, жирный белый текст, оранжевый акцент.
-- Цвета берутся из C.UI.Colors, если они есть (loadTheme в Init)
local WHITE = rgb(245, 245, 245)
local DIM = rgb(165, 165, 172)
local ACCENT = rgb(255, 170, 60)
local LINE = rgb(215, 215, 220)
local PANEL = rgb(12, 12, 14)
local PANEL_T = 0.32
local STROKE_T = 0.78
local GREEN = rgb(62, 150, 72)
local GREEN_HI = rgb(78, 176, 88)
local BLUE = rgb(80, 150, 255)
local RED = rgb(220, 70, 60)
local YELLOW = rgb(255, 214, 90)
local DISABLED = rgb(46, 46, 50)

local function loadTheme()
	local ui = C and C.UI
	local colors = ui and type(ui.Colors) == "table" and ui.Colors or nil
	if colors then
		WHITE = colors.text or WHITE
		DIM = colors.dim or DIM
		ACCENT = colors.accent or ACCENT
		LINE = colors.line or LINE
		RED = colors.red or RED
		YELLOW = colors.yellow or YELLOW
		BLUE = colors.blue or BLUE
	end
	local theme = ui and type(ui.Theme) == "table" and ui.Theme or nil
	if theme and type(theme.strokeTransparency) == "number" then
		STROKE_T = theme.strokeTransparency
	end
end

local hudGui, winGui
local scales = {}
local hud = {}
local party = {}
local profileWin = {}
local joinWin = {}
local openName = nil -- "profile" | "join" | nil
local state = { myParty = nil, startPending = false }
local snapshot = nil -- последний ProfileSync
local startLockUntil = 0
local inviteMsgToken = 0
local lastJoinCode = nil

-- Помощники ---------------------------------------------------------------------------------------

local function new(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function frame(parent, props)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = rgb(0, 0, 0)
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	f.Parent = parent
	return f
end

local function corner(parent, px)
	return new("UICorner", { CornerRadius = UDim.new(0, px or 4) }, parent)
end

local function round(parent)
	return new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, parent)
end

local function stroke(parent, color, thickness, transparency)
	return new("UIStroke", {
		Color = color or LINE,
		Thickness = thickness or 1,
		Transparency = transparency or STROKE_T,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

-- Тонкая оранжевая линия сверху, гаснущая вправо (как у окон Tab-меню)
local function accentLine(parent, height)
	local line = frame(parent, { Size = UDim2.new(1, 0, 0, height or 2), BackgroundColor3 = ACCENT, ZIndex = 3 })
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, line)
	return line
end

-- Короткая оранжевая полоска слева (плашки HUD)
local function accentBar(parent)
	return frame(parent, { Size = UDim2.new(0, 3, 1, -12), Position = UDim2.fromOffset(0, 6), BackgroundColor3 = ACCENT, ZIndex = 3 })
end

local function label(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextColor3 = WHITE
	l.TextSize = 16
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextStrokeTransparency = 0.5
	l.TextStrokeColor3 = rgb(0, 0, 0)
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

local function playUi()
	if C and C.Effects and C.Effects.Play then
		pcall(C.Effects.Play, "ui")
	end
end

local function button(parent, props, onClick)
	local b = Instance.new("TextButton")
	b.BorderSizePixel = 0
	b.BackgroundColor3 = PANEL
	b.BackgroundTransparency = PANEL_T
	b.Font = Enum.Font.GothamBlack
	b.TextColor3 = WHITE
	b.TextSize = 16
	b.TextStrokeTransparency = 0.5
	b.AutoButtonColor = true
	for k, v in pairs(props or {}) do
		b[k] = v
	end
	corner(b, 4)
	b.Parent = parent
	if onClick then
		b.MouseButton1Click:Connect(function()
			playUi()
			onClick()
		end)
	end
	return b
end

local function addScale(target)
	local s = new("UIScale", {}, target)
	table.insert(scales, s)
	return s
end

local function updateScale()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	if vp.X < 2 or vp.Y < 2 then
		return
	end
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1)
	for _, sc in ipairs(scales) do
		sc.Scale = s
	end
end

local function isLobby()
	return Net.State():GetAttribute("Mode") == "lobby"
end

local function fire(action, data)
	Net.Get("PartyAction"):FireServer(action, data or {})
end

local function startLocked()
	if os.clock() < startLockUntil or state.startPending == true then
		return true
	end
	local my = state.myParty
	return type(my) == "table" and my.starting == true
end

local function numAttr(name, fallback)
	local v = player:GetAttribute(name)
	if type(v) == "number" then
		return v
	end
	return fallback
end

local function currentProfile()
	if type(snapshot) == "table" then
		return snapshot
	end
	if C and C.ProgressUI and C.ProgressUI.GetProfile then
		local ok, p = pcall(C.ProgressUI.GetProfile)
		if ok and type(p) == "table" then
			return p
		end
	end
	return nil
end

-- Иконки из Frame ---------------------------------------------------------------------------------

local function iconHolder(parent, x, y, size)
	return frame(parent, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(size or 52, size or 52), BackgroundTransparency = 1 })
end

local function iconPerson(parent, x, y, s, color)
	local head = frame(parent, { Position = UDim2.fromOffset(x + 8 * s, y), Size = UDim2.fromOffset(14 * s, 14 * s), BackgroundColor3 = color })
	round(head)
	local body = frame(parent, { Position = UDim2.fromOffset(x + 1 * s, y + 16 * s), Size = UDim2.fromOffset(28 * s, 18 * s), BackgroundColor3 = color })
	corner(body, math.floor(8 * s))
end

local function iconClasses(parent)
	local h = iconHolder(parent, 26, 10)
	iconPerson(h, 11, 6, 1, WHITE)
	-- «каска» и нашивка класса
	frame(h, { Position = UDim2.fromOffset(17, 4), Size = UDim2.fromOffset(18, 5), BackgroundColor3 = ACCENT })
	frame(h, { Position = UDim2.fromOffset(22, 30), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = ACCENT, Rotation = 45 })
	return h
end

local function iconRewards(parent)
	local h = iconHolder(parent, 26, 10)
	frame(h, { Position = UDim2.fromOffset(8, 24), Size = UDim2.fromOffset(36, 24), BackgroundColor3 = WHITE })
	frame(h, { Position = UDim2.fromOffset(5, 16), Size = UDim2.fromOffset(42, 9), BackgroundColor3 = WHITE })
	frame(h, { Position = UDim2.fromOffset(23, 16), Size = UDim2.fromOffset(6, 32), BackgroundColor3 = ACCENT })
	frame(h, { Position = UDim2.fromOffset(14, 6), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = ACCENT, Rotation = 45 })
	frame(h, { Position = UDim2.fromOffset(28, 6), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = ACCENT, Rotation = 45 })
	return h
end

local function iconProfile(parent)
	local h = iconHolder(parent, 26, 10)
	local card = frame(h, { Position = UDim2.fromOffset(2, 10), Size = UDim2.fromOffset(48, 34), BackgroundTransparency = 1 })
	corner(card, 3)
	stroke(card, WHITE, 2.5, 0)
	local head = frame(card, { Position = UDim2.fromOffset(7, 6), Size = UDim2.fromOffset(11, 11), BackgroundColor3 = WHITE })
	round(head)
	local body = frame(card, { Position = UDim2.fromOffset(5, 19), Size = UDim2.fromOffset(15, 9), BackgroundColor3 = WHITE })
	corner(body, 3)
	for i = 0, 2 do
		frame(card, { Position = UDim2.fromOffset(24, 8 + i * 7), Size = UDim2.fromOffset(i == 2 and 12 or 18, 3), BackgroundColor3 = i == 0 and ACCENT or WHITE })
	end
	return h
end

local function iconJoin(parent)
	local h = iconHolder(parent, 26, 10)
	iconPerson(h, 2, 8, 1, WHITE)
	frame(h, { Position = UDim2.fromOffset(32, 22), Size = UDim2.fromOffset(18, 5), BackgroundColor3 = ACCENT })
	frame(h, { Position = UDim2.fromOffset(38.5, 15.5), Size = UDim2.fromOffset(5, 18), BackgroundColor3 = ACCENT })
	return h
end

local function iconTicket(parent, x, y, s)
	s = s or 1
	local t = frame(parent, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(34 * s, 22 * s), BackgroundColor3 = rgb(230, 165, 55) })
	corner(t, 3)
	for _, px in ipairs({ -5 * s, 29 * s }) do
		local hole = frame(t, { Position = UDim2.fromOffset(px, 6 * s), Size = UDim2.fromOffset(10 * s, 10 * s), BackgroundColor3 = rgb(12, 12, 14) })
		round(hole)
	end
	for i = 0, 2 do
		frame(t, { Position = UDim2.fromOffset(23 * s, (2 + i * 7) * s), Size = UDim2.fromOffset(2 * s, 4 * s), BackgroundColor3 = rgb(120, 80, 20) })
	end
	return t
end

local function iconInvite(parent, x, y)
	local h = frame(parent, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(40, 34), BackgroundTransparency = 1 })
	iconPerson(h, 12, 2, 0.8, DIM)
	iconPerson(h, 0, 6, 0.8, WHITE)
	return h
end

-- Экран лобби -------------------------------------------------------------------------------------

local function flashHint(text, color)
	if not hud.hintText then
		return
	end
	inviteMsgToken = inviteMsgToken + 1
	local token = inviteMsgToken
	hud.hint.Visible = true
	hud.hintText.Text = text
	hud.hintText.TextColor3 = color or YELLOW
	task.delay(3, function()
		if token == inviteMsgToken then
			hud.hintText.TextColor3 = WHITE
			LobbyUI.Refresh()
		end
	end)
end

local function menuButton(parent, x, y, caption, makeIcon, onClick)
	local b = button(parent, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(109, 109), Text = "", BackgroundTransparency = PANEL_T, AutoButtonColor = false }, onClick)
	local st = stroke(b)
	local line = accentLine(b)
	line.BackgroundTransparency = 0.6
	makeIcon(b)
	local cap = label(b, {
		Size = UDim2.new(1, -8, 0, 22),
		Position = UDim2.new(0, 4, 1, -30),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		Text = caption,
	})
	new("UITextSizeConstraint", { MaxTextSize = 15, MinTextSize = 8 }, cap)
	b.MouseEnter:Connect(function()
		b.BackgroundTransparency = 0.12
		st.Color = ACCENT
		st.Transparency = 0.35
		line.BackgroundTransparency = 0
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundTransparency = PANEL_T
		st.Color = LINE
		st.Transparency = STROKE_T
		line.BackgroundTransparency = 0.6
	end)
	return b
end

local function openClasses()
	LobbyUI.Close()
	if C.Panels and C.Panels.OpenClassSelect then
		pcall(C.Panels.OpenClassSelect)
		if C.Panels.IsOpen and not C.Panels.IsOpen() then
			flashHint("Выбор класса сейчас недоступен", RED)
		end
	end
end

local function openRewards()
	LobbyUI.Close()
	if C.ProgressUI and C.ProgressUI.OpenDaily then
		pcall(C.ProgressUI.OpenDaily)
	end
end

local function invite()
	if RunService:IsStudio() then
		flashHint("Приглашения друзей работают в опубликованной игре", YELLOW)
		return
	end
	task.spawn(function()
		local okCan, can = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
		if okCan and can == false then
			flashHint("Сейчас нельзя отправить приглашение", RED)
			return
		end
		local ok = pcall(SocialService.PromptGameInvite, SocialService, player)
		if not ok then
			flashHint("Не удалось открыть окно приглашения", RED)
		end
	end)
end

local function playSolo()
	if startLocked() then
		return
	end
	startLockUntil = os.clock() + 4
	fire("solo", {})
	LobbyUI.Refresh()
	task.delay(4.1, function()
		LobbyUI.Refresh()
	end)
end

local function buildHud()
	hudGui = new("ScreenGui", { Name = "LobbyHUD", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 4, Enabled = false }, player:WaitForChild("PlayerGui"))

	-- слева сверху: уровень и меню
	local left = frame(hudGui, { Position = UDim2.fromOffset(16, 64), Size = UDim2.fromOffset(228, 290), BackgroundTransparency = 1 })
	addScale(left)
	local bar = frame(left, { Size = UDim2.fromOffset(228, 34), BackgroundColor3 = PANEL, BackgroundTransparency = PANEL_T })
	corner(bar, 4)
	stroke(bar)
	hud.xpFill = frame(bar, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = BLUE, BackgroundTransparency = 0.1 })
	corner(hud.xpFill, 4)
	hud.levelText = label(bar, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.6, -10, 1, 0), Font = Enum.Font.GothamBlack, TextSize = 17, Text = "Уровень 1", ZIndex = 2 })
	hud.xpText = label(bar, { Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, -10, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextSize = 14, Text = "0/100", ZIndex = 2 })

	menuButton(left, 0, 44, "КЛАССЫ", iconClasses, openClasses)
	local rewards = menuButton(left, 119, 44, "НАГРАДЫ", iconRewards, openRewards)
	hud.rewardsDot = frame(rewards, { Position = UDim2.new(1, -10, 0, -6), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = RED, Visible = false, ZIndex = 3 })
	round(hud.rewardsDot)
	stroke(hud.rewardsDot, WHITE, 1.5, 0.1)
	menuButton(left, 0, 163, "ПРОФИЛЬ", iconProfile, function()
		LobbyUI.Open("profile")
	end)
	menuButton(left, 119, 163, "ПРИСОЕДИНИТЬСЯ", iconJoin, function()
		LobbyUI.Open("join")
	end)

	-- слева снизу: билеты
	local tickets = frame(hudGui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -22), Size = UDim2.fromOffset(200, 56), BackgroundColor3 = PANEL, BackgroundTransparency = PANEL_T })
	addScale(tickets)
	corner(tickets, 4)
	stroke(tickets)
	accentBar(tickets)
	iconTicket(tickets, 14, 16, 1)
	hud.tickets = label(tickets, { Position = UDim2.fromOffset(60, 0), Size = UDim2.new(1, -70, 1, 0), Font = Enum.Font.GothamBlack, TextSize = 28, Text = "0" })

	-- снизу по центру: ИГРАТЬ
	local playHolder = frame(hudGui, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -22), Size = UDim2.fromOffset(320, 86), BackgroundTransparency = 1 })
	addScale(playHolder)
	hud.playSub = label(playHolder, { Position = UDim2.fromOffset(0, -24), Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 14, TextColor3 = DIM, Text = "Одиночный заезд — сразу" })
	local play = button(playHolder, { Size = UDim2.fromScale(1, 1), Text = "ИГРАТЬ", TextSize = 42, BackgroundColor3 = GREEN, BackgroundTransparency = 0, AutoButtonColor = false }, playSolo)
	stroke(play, WHITE, 1, 0.45)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(rgb(255, 255, 255), rgb(170, 170, 170)) }, play)
	play.MouseEnter:Connect(function()
		if not startLocked() then
			play.BackgroundColor3 = GREEN_HI
		end
	end)
	play.MouseLeave:Connect(function()
		LobbyUI.Refresh()
	end)
	hud.play = play

	-- справа снизу: пригласить друзей
	local inv = button(hudGui, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -22), Size = UDim2.fromOffset(250, 58), Text = "", BackgroundTransparency = 0.45 }, invite)
	addScale(inv)
	local invStroke = stroke(inv)
	inv.MouseEnter:Connect(function()
		invStroke.Color = ACCENT
		invStroke.Transparency = 0.35
	end)
	inv.MouseLeave:Connect(function()
		invStroke.Color = LINE
		invStroke.Transparency = STROKE_T
	end)
	iconInvite(inv, 14, 12)
	label(inv, { Position = UDim2.fromOffset(62, 0), Size = UDim2.new(1, -70, 1, 0), Font = Enum.Font.GothamBlack, TextSize = 17, Text = "Пригласить друзей" })

	-- сверху по центру: подсказка
	local hint = frame(hudGui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 64), Size = UDim2.fromOffset(640, 40), BackgroundColor3 = PANEL, BackgroundTransparency = PANEL_T })
	addScale(hint)
	corner(hint, 4)
	stroke(hint)
	accentBar(hint)
	hud.hint = hint
	hud.hintText = label(hint, { Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(10, 0), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 15, Text = "" })
end

-- Панель группы (внутри зоны посадки) -------------------------------------------------------------

local function buildPartyPanel()
	local p = frame(hudGui, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, -30), Size = UDim2.fromOffset(300, 350), BackgroundColor3 = rgb(10, 10, 12), BackgroundTransparency = 0.15, Visible = false })
	addScale(p)
	corner(p, 4)
	stroke(p, LINE, 1, 0.7)
	accentLine(p)
	party.frame = p
	party.title = label(p, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 26), Font = Enum.Font.GothamBlack, TextSize = 22, TextColor3 = ACCENT, Text = "" })
	party.diff = label(p, { Position = UDim2.fromOffset(14, 36), Size = UDim2.new(1, -28, 0, 20), TextSize = 14, TextColor3 = DIM, Text = "" })
	party.code = label(p, { Position = UDim2.fromOffset(14, 58), Size = UDim2.new(1, -28, 0, 22), TextSize = 16, TextColor3 = YELLOW, Text = "" })
	frame(p, { Position = UDim2.fromOffset(14, 86), Size = UDim2.new(1, -28, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.8 })
	party.countdown = label(p, { Position = UDim2.fromOffset(14, 94), Size = UDim2.new(1, -28, 0, 32), Font = Enum.Font.GothamBlack, TextSize = 22, Text = "" })
	party.rows = {}
	for i = 1, 4 do
		local row = frame(p, { Position = UDim2.fromOffset(14, 132 + (i - 1) * 30), Size = UDim2.new(1, -28, 0, 26), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = 0.95 })
		corner(row, 3)
		stroke(row, LINE, 1, 0.88)
		local name = label(row, { Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -90, 1, 0), TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Text = "" })
		local lvl = label(row, { Position = UDim2.new(1, -80, 0, 0), Size = UDim2.fromOffset(72, 26), TextXAlignment = Enum.TextXAlignment.Right, TextSize = 13, TextColor3 = DIM, Text = "" })
		party.rows[i] = { frame = row, name = name, level = lvl }
	end
	party.go = button(p, { Position = UDim2.fromOffset(14, 256), Size = UDim2.new(1, -28, 0, 44), Text = "ОТПРАВИТЬСЯ СЕЙЧАС", TextSize = 18, BackgroundColor3 = GREEN, BackgroundTransparency = 0 }, function()
		local my = state.myParty
		if type(my) == "table" and my.isLeader and not startLocked() then
			fire("go")
		end
	end)
	stroke(party.go, WHITE, 1, 0.5)
	party.wait = label(p, { Position = UDim2.fromOffset(14, 256), Size = UDim2.new(1, -28, 0, 44), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 15, TextColor3 = DIM, Text = "Ждём отправления…" })
	party.leave = button(p, { Position = UDim2.fromOffset(14, 308), Size = UDim2.new(1, -28, 0, 30), Text = "Выйти  ·  или отойдите от автобуса", TextSize = 13, BackgroundTransparency = 0.3 }, function()
		fire("leave")
	end)
	stroke(party.leave)
end

local function updateCountdown()
	local my = state.myParty
	if type(my) ~= "table" or not party.countdown then
		return
	end
	if my.starting or startLocked() then
		party.countdown.Text = "Отправление…"
		party.countdown.TextColor3 = YELLOW
		return
	end
	local startAt = tonumber(my.startAt)
	if not startAt then
		party.countdown.Text = ""
		return
	end
	local left = math.max(0, math.ceil(startAt - workspace:GetServerTimeNow()))
	party.countdown.Text = "Отправление через " .. left .. " с"
	party.countdown.TextColor3 = left <= 5 and YELLOW or WHITE
end

local function refreshPartyPanel()
	local my = state.myParty
	local visible = type(my) == "table" and isLobby()
	party.frame.Visible = visible
	if not visible then
		return
	end
	party.title.Text = tostring(my.busName or "АВТОБУС") .. "  " .. tostring(my.count or 0) .. "/" .. tostring(my.maxSize or 4)
	local diffName = type(my.difficultyName) == "string" and my.difficultyName or Difficulty.Get(my.difficulty).name
	party.diff.Text = "Сложность: " .. diffName
	party.code.Text = "Код для друзей: " .. tostring(my.code or "----")
	local members = type(my.members) == "table" and my.members or {}
	for i, row in ipairs(party.rows) do
		local m = members[i]
		if type(m) == "table" then
			row.frame.Visible = true
			row.name.Text = tostring(m.name or "?") .. (m.isLeader and "  · лидер" or "")
			row.name.TextColor3 = m.isLeader and YELLOW or WHITE
			row.level.Text = "Ур. " .. tostring(m.level or 1)
		else
			row.frame.Visible = false
		end
	end
	local locked = startLocked()
	party.go.Visible = my.isLeader == true and not locked
	party.wait.Visible = not party.go.Visible
	party.wait.Text = locked and "Отправление…" or "Ждём отправления…"
	party.leave.Visible = not locked
	updateCountdown()
end

-- Окна: профиль и вход по коду --------------------------------------------------------------------

local function makeWindow(title, w, h)
	local win = frame(winGui, {
		Name = title,
		Size = UDim2.fromOffset(w, h),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = rgb(10, 10, 12),
		BackgroundTransparency = 0.12,
		Visible = false,
	})
	addScale(win)
	corner(win, 4)
	stroke(win, LINE, 1, 0.7)
	accentLine(win)
	label(win, { Position = UDim2.fromOffset(20, 10), Size = UDim2.new(1, -80, 0, 40), Font = Enum.Font.GothamBlack, TextSize = 22, TextColor3 = ACCENT, Text = title })
	local close = button(win, { Size = UDim2.fromOffset(34, 34), Position = UDim2.new(1, -46, 0, 12), Text = "X", TextSize = 16, BackgroundColor3 = rgb(40, 40, 44), BackgroundTransparency = 0.1 }, function()
		LobbyUI.Close()
	end)
	stroke(close)
	frame(win, { Size = UDim2.new(1, -40, 0, 1), Position = UDim2.fromOffset(20, 56), BackgroundColor3 = WHITE, BackgroundTransparency = 0.8 })
	return win
end

local PROFILE_ROWS = {
	{ key = "runs", name = "Заездов" },
	{ key = "wins", name = "Побед (до конечной)" },
	{ key = "bestKm", name = "Лучший результат", km = true },
	{ key = "kills", name = "Убито зомби" },
	{ key = "objectives", name = "Выполнено целей" },
	{ key = "difficulty", name = "Открытая сложность" },
	{ key = "tickets", name = "Билеты" },
}

local function buildProfileWindow()
	local win = makeWindow("ПРОФИЛЬ", 480, 430)
	profileWin.frame = win
	profileWin.name = label(win, { Position = UDim2.fromOffset(20, 66), Size = UDim2.new(1, -40, 0, 28), Font = Enum.Font.GothamBlack, TextSize = 22, Text = player.DisplayName })
	profileWin.user = label(win, { Position = UDim2.fromOffset(20, 92), Size = UDim2.new(1, -40, 0, 18), TextSize = 13, TextColor3 = DIM, Text = "@" .. player.Name })
	local bar = frame(win, { Position = UDim2.fromOffset(20, 120), Size = UDim2.new(1, -40, 0, 30), BackgroundTransparency = 0.4 })
	corner(bar, 4)
	stroke(bar)
	profileWin.fill = frame(bar, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = BLUE, BackgroundTransparency = 0.1 })
	corner(profileWin.fill, 4)
	profileWin.level = label(bar, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.6, -10, 1, 0), Font = Enum.Font.GothamBlack, TextSize = 16, Text = "", ZIndex = 2 })
	profileWin.xp = label(bar, { Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, -10, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextSize = 13, Text = "", ZIndex = 2 })
	profileWin.rows = {}
	for i, row in ipairs(PROFILE_ROWS) do
		local y = 164 + (i - 1) * 34
		local line = frame(win, { Position = UDim2.fromOffset(20, y), Size = UDim2.new(1, -40, 0, 30), BackgroundTransparency = i % 2 == 0 and 0.7 or 0.5 })
		corner(line, 3)
		label(line, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.6, 0, 1, 0), TextSize = 15, TextColor3 = DIM, Text = row.name })
		profileWin.rows[row.key] = label(line, { Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, -10, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBlack, TextSize = 16, Text = "—" })
	end
	profileWin.note = label(win, { Position = UDim2.fromOffset(20, 402), Size = UDim2.new(1, -40, 0, 18), TextSize = 12, TextColor3 = DIM, Text = "" })
end

local function refreshProfile()
	if not profileWin.frame then
		return
	end
	local p = currentProfile()
	local level = numAttr("Level", p and tonumber(p.level) or 1)
	local xp = numAttr("XP", p and tonumber(p.xp) or 0)
	local xpNext = numAttr("XPNext", p and tonumber(p.xpNext) or 100)
	profileWin.level.Text = "Уровень " .. level
	profileWin.xp.Text = xp .. "/" .. xpNext .. " опыта"
	profileWin.fill.Size = UDim2.fromScale(math.clamp(xp / math.max(1, xpNext), 0, 1), 1)
	local stats = p and type(p.stats) == "table" and p.stats or {}
	for _, row in ipairs(PROFILE_ROWS) do
		local text
		if row.key == "difficulty" then
			local id = p and p.unlockedDifficulty or "normal"
			text = Difficulty.Get(id).name
		elseif row.key == "tickets" then
			text = tostring(numAttr("Tickets", p and tonumber(p.tickets) or 0))
		elseif row.km then
			text = string.format("%.1f км", tonumber(stats[row.key]) or 0)
		else
			text = tostring(math.floor(tonumber(stats[row.key]) or 0))
		end
		profileWin.rows[row.key].Text = text
	end
	if not p then
		profileWin.note.Text = "Профиль загружается…"
	elseif p.saveEnabled == false then
		profileWin.note.Text = "Сохранение профиля недоступно на этом сервере"
	else
		profileWin.note.Text = ""
	end
end

local function setJoinStatus(text, color)
	if joinWin.status then
		joinWin.status.Text = text or ""
		joinWin.status.TextColor3 = color or DIM
	end
end

local function submitJoin()
	if startLocked() then
		setJoinStatus("Заезд уже запускается", RED)
		return
	end
	local code = joinWin.box and joinWin.box.Text or ""
	if not string.match(code, "^%u%u%u%u$") then
		setJoinStatus("Код группы — 4 латинские буквы", RED)
		return
	end
	lastJoinCode = code
	setJoinStatus("Ищем группу…", YELLOW)
	fire("join", { code = code })
end

local function buildJoinWindow()
	local win = makeWindow("ПРИСОЕДИНИТЬСЯ", 460, 270)
	joinWin.frame = win
	label(win, { Position = UDim2.fromOffset(20, 66), Size = UDim2.new(1, -40, 0, 40), TextSize = 15, TextWrapped = true, TextColor3 = DIM, Text = "Введите 4-буквенный код группы друга — вас перенесут к его автобусу." })
	local box = new("TextBox", {
		Position = UDim2.fromOffset(20, 118),
		Size = UDim2.fromOffset(240, 58),
		BackgroundColor3 = rgb(0, 0, 0),
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBlack,
		TextSize = 32,
		TextColor3 = YELLOW,
		PlaceholderText = "КОД",
		PlaceholderColor3 = rgb(110, 110, 110),
		Text = "",
		ClearTextOnFocus = false,
	}, win)
	corner(box, 4)
	stroke(box, LINE, 1, 0.6)
	joinWin.box = box
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local cleaned = string.sub((string.gsub(string.upper(box.Text), "[^A-Z]", "")), 1, 4)
		if cleaned ~= box.Text then
			box.Text = cleaned
		end
	end)
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submitJoin()
		end
	end)
	local go = button(win, { Position = UDim2.fromOffset(272, 118), Size = UDim2.fromOffset(168, 58), Text = "ВОЙТИ", TextSize = 22, BackgroundColor3 = GREEN, BackgroundTransparency = 0 }, submitJoin)
	stroke(go, WHITE, 1, 0.5)
	joinWin.status = label(win, { Position = UDim2.fromOffset(20, 190), Size = UDim2.new(1, -40, 0, 50), TextSize = 14, TextWrapped = true, TextColor3 = DIM, Text = "" })
end

-- Мерцание неоновых вывесок лобби (тег ставит LobbyService): только локальные свойства, без новых объектов
local FLICKER_TAG = "LR_LobbyFlicker"

local function startNeonFlicker()
	local signs = {}
	local rng = Random.new()
	local function track(model)
		if signs[model] or not model:IsA("Model") or not model.Parent then
			return
		end
		local entry = { parts = {}, lights = {}, labels = {}, on = true, toggles = 0, nextToggle = 0, nextBurst = os.clock() + rng:NextNumber(2, 7) }
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
				table.insert(entry.parts, d)
			elseif d:IsA("PointLight") then
				table.insert(entry.lights, d)
			elseif d:IsA("TextLabel") then
				table.insert(entry.labels, d)
			end
		end
		signs[model] = entry
	end
	local function apply(entry)
		for _, p in ipairs(entry.parts) do
			p.Transparency = entry.on and 0 or 0.75
		end
		for _, l in ipairs(entry.lights) do
			l.Enabled = entry.on
		end
		for _, t in ipairs(entry.labels) do
			t.TextTransparency = entry.on and 0 or 0.7
		end
	end
	CollectionService:GetInstanceAddedSignal(FLICKER_TAG):Connect(function(inst)
		task.defer(track, inst)
	end)
	CollectionService:GetInstanceRemovedSignal(FLICKER_TAG):Connect(function(inst)
		signs[inst] = nil
	end)
	for _, inst in ipairs(CollectionService:GetTagged(FLICKER_TAG)) do
		track(inst)
	end
	task.spawn(function()
		while true do
			task.wait(0.05)
			if next(signs) ~= nil and isLobby() then
				local now = os.clock()
				for model, entry in pairs(signs) do
					if not model.Parent then
						signs[model] = nil
					elseif entry.toggles > 0 then
						if now >= entry.nextToggle then
							entry.toggles = entry.toggles - 1
							entry.on = entry.toggles == 0 or not entry.on
							entry.nextToggle = now + rng:NextNumber(0.04, 0.14)
							apply(entry)
							if entry.toggles == 0 then
								entry.nextBurst = now + rng:NextNumber(3, 9)
							end
						end
					elseif now >= entry.nextBurst then
						entry.toggles = rng:NextInteger(3, 7)
						entry.nextToggle = now
					end
				end
			end
		end
	end)
end

-- API ---------------------------------------------------------------------------------------------

function LobbyUI.Refresh()
	if not hudGui then
		return
	end
	local lobby = isLobby()
	hudGui.Enabled = lobby
	if not lobby then
		return
	end
	local p = currentProfile()
	local level = numAttr("Level", p and tonumber(p.level) or 1)
	local xp = numAttr("XP", p and tonumber(p.xp) or 0)
	local xpNext = numAttr("XPNext", p and tonumber(p.xpNext) or 100)
	hud.levelText.Text = "Уровень " .. level
	hud.xpText.Text = xp .. "/" .. xpNext
	hud.xpFill.Size = UDim2.fromScale(math.clamp(xp / math.max(1, xpNext), 0, 1), 1)
	hud.xpFill.Visible = xp > 0
	hud.tickets.Text = tostring(numAttr("Tickets", p and tonumber(p.tickets) or 0))

	local claimable = false
	if C.ProgressUI and C.ProgressUI.HasClaimable then
		local ok, result = pcall(C.ProgressUI.HasClaimable)
		claimable = ok and result == true
	end
	hud.rewardsDot.Visible = claimable

	local locked = startLocked()
	hud.play.Text = locked and "ЗАПУСК…" or "ИГРАТЬ"
	hud.play.BackgroundColor3 = locked and DISABLED or GREEN
	hud.play.TextColor3 = locked and DIM or WHITE
	hud.playSub.Text = locked and "Готовим заезд…" or "Одиночный заезд — сразу"

	local my = state.myParty
	local inParty = type(my) == "table"
	if hud.hintText.TextColor3 == WHITE then
		hud.hint.Visible = not inParty
		hud.hintText.Text = "Встаньте на площадку «ПОСАДКА» у автобуса, чтобы собрать группу, или нажмите «ИГРАТЬ»"
	end
	refreshPartyPanel()

	if openName == "profile" then
		refreshProfile()
	elseif openName == "join" and inParty and lastJoinCode and my.code == lastJoinCode then
		lastJoinCode = nil
		LobbyUI.Close()
	end
end

function LobbyUI.Open(name)
	if not hudGui or not isLobby() then
		return
	end
	if name ~= "profile" and name ~= "join" then
		return
	end
	if C.Panels and C.Panels.CloseAll then
		pcall(C.Panels.CloseAll)
	end
	openName = name
	profileWin.frame.Visible = name == "profile"
	joinWin.frame.Visible = name == "join"
	if name == "join" then
		setJoinStatus("")
		lastJoinCode = nil
	end
	LobbyUI.Refresh()
end

function LobbyUI.Close()
	openName = nil
	if profileWin.frame then
		profileWin.frame.Visible = false
	end
	if joinWin.frame then
		joinWin.frame.Visible = false
	end
end

function LobbyUI.IsOpen()
	return openName ~= nil
end

function LobbyUI.Init(c)
	C = c
	loadTheme()
	buildHud()
	buildPartyPanel()
	winGui = new("ScreenGui", { Name = "LobbyWindows", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 12 }, player:WaitForChild("PlayerGui"))
	buildProfileWindow()
	buildJoinWindow()

	C.Panels.RegisterWindow(function()
		return openName == "profile"
	end, function()
		if openName == "profile" then
			LobbyUI.Close()
		end
	end)
	C.Panels.RegisterWindow(function()
		return openName == "join"
	end, function()
		if openName == "join" then
			LobbyUI.Close()
		end
	end)

	Net.Get("PartyState").OnClientEvent:Connect(function(newState)
		if type(newState) ~= "table" then
			return
		end
		if type(newState.myParty) ~= "table" then
			newState.myParty = nil
		end
		local hadParty = state.myParty ~= nil
		state = newState
		if openName == "join" and lastJoinCode and not newState.myParty then
			-- ответ сервера (ошибка) приходит уведомлением; здесь только снимаем «Ищем…»
			setJoinStatus("")
		end
		if not hadParty and newState.myParty then
			playUi()
		end
		LobbyUI.Refresh()
	end)
	Net.Get("ProfileSync").OnClientEvent:Connect(function(snap)
		if type(snap) == "table" then
			snapshot = snap
			LobbyUI.Refresh()
		end
	end)
	if C.ProgressUI and C.ProgressUI.OnChanged then
		C.ProgressUI.OnChanged(LobbyUI.Refresh)
	end
	for _, attr in ipairs({ "Level", "XP", "XPNext", "Tickets" }) do
		player:GetAttributeChangedSignal(attr):Connect(LobbyUI.Refresh)
	end
	Net.State():GetAttributeChangedSignal("Mode"):Connect(function()
		if not isLobby() then
			LobbyUI.Close()
			state = { myParty = nil, startPending = false }
			startLockUntil = 0
		end
		LobbyUI.Refresh()
	end)

	-- отсчёт в панели группы и снятие локальной блокировки «ИГРАТЬ»
	task.spawn(function()
		local wasLocked = false
		while true do
			task.wait(0.25)
			if hudGui.Enabled then
				updateCountdown()
				local locked = startLocked()
				if locked ~= wasLocked then
					wasLocked = locked
					LobbyUI.Refresh()
				end
			end
		end
	end)

	startNeonFlicker()

	local camConn
	local function bindCamera()
		if camConn then
			camConn:Disconnect()
			camConn = nil
		end
		local cam = workspace.CurrentCamera
		if cam then
			camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		end
		updateScale()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
	bindCamera()
	LobbyUI.Refresh()
end

return LobbyUI
