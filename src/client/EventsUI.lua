-- Компактный баннер случайного события (под расстоянием / полосой босса) и метки событий для карты
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventDefs = require(Shared.Events)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local EventsUI = {}
local C, UI
local rgb = Color3.fromRGB

local BASE_Y = 40 -- под строкой «… м до конечной»
local BOSS_Y = 82 -- ниже полосы босса
local gui, banner, strip, titleLabel, textLabel, timerLabel
local shownId = nil
local resultUntil = nil
local baseColor = rgb(255, 255, 255)
local currentY = nil

local function build()
	gui = UI.Screen("EventsUI", 2)
	banner = UI.Panel(gui, {
		Name = "EventBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(440, 58),
		Position = UDim2.new(0.5, 0, 0, BASE_Y),
		Visible = false,
	})
	UI.AddScale(banner, true)
	strip = UI.Frame(banner, { Size = UDim2.new(0, 3, 1, -10), Position = UDim2.fromOffset(6, 5), BackgroundColor3 = baseColor })
	titleLabel = UI.Label(banner, {
		Size = UDim2.new(1, -90, 0, 20),
		Position = UDim2.fromOffset(16, 5),
		Font = UI.Theme.fontBlack,
		TextSize = 15,
		Text = "",
		TextStrokeTransparency = 0.4,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	timerLabel = UI.Label(banner, {
		Size = UDim2.new(0, 70, 0, 20),
		Position = UDim2.new(1, -80, 0, 5),
		Font = UI.Theme.fontBlack,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
	})
	textLabel = UI.Label(banner, {
		Size = UDim2.new(1, -26, 0, 28),
		Position = UDim2.fromOffset(16, 25),
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = rgb(215, 215, 220),
		Text = "",
	})
end

local function show(id, title, text, color)
	shownId = id
	baseColor = typeof(color) == "Color3" and color or rgb(255, 220, 120)
	titleLabel.Text = tostring(title or "")
	titleLabel.TextColor3 = baseColor
	strip.BackgroundColor3 = baseColor
	textLabel.Text = tostring(text or "")
	banner.Visible = true
	titleLabel.TextTransparency = 1
	textLabel.TextTransparency = 1
	UI.Tween(titleLabel, 0.35, { TextTransparency = 0 })
	UI.Tween(textLabel, 0.35, { TextTransparency = 0 })
end

local function hide()
	shownId = nil
	resultUntil = nil
	banner.Visible = false
end

local function onBanner(info)
	if type(info) ~= "table" then
		return
	end
	if info.silent then
		hide()
		return
	end
	local def = type(info.id) == "string" and EventDefs.List[info.id] or nil
	local title = info.title or (def and def.title) or "СОБЫТИЕ"
	if info.ended then
		show(info.id, title, info.text or "", info.color or (info.success and rgb(120, 230, 140) or rgb(190, 190, 190)))
		timerLabel.Text = info.success and "ГОТОВО" or ""
		resultUntil = os.clock() + (tonumber(info.duration) or 6)
	else
		resultUntil = nil
		show(info.id, title, info.text or (def and def.text) or "", info.color or (def and def.color))
	end
	if C.Effects and C.Effects.Play then
		pcall(C.Effects.Play, "ui")
	end
end

local acc = 0
local function update(dt)
	acc = acc + dt
	if acc < 0.1 then
		return
	end
	acc = 0
	local st = Net.State()
	if st:GetAttribute("Mode") == "lobby" then
		banner.Visible = false
		return
	end
	local y = st:GetAttribute("BossActive") == true and BOSS_Y or BASE_Y
	if y ~= currentY then
		currentY = y
		UI.SetScaledPosition(banner, UDim2.new(0.5, 0, 0, y))
	end

	local id = st:GetAttribute("EventId") or ""
	if resultUntil then
		if os.clock() >= resultUntil then
			hide()
		end
		return
	end
	if id == "" then
		if shownId then
			hide()
		end
		return
	end
	if shownId ~= id then
		-- вошли в игру посреди события
		local def = EventDefs.List[id]
		show(id, st:GetAttribute("EventTitle") or (def and def.title) or "СОБЫТИЕ", def and def.text or "", def and def.color)
	end
	local left = (st:GetAttribute("EventEnd") or 0) - workspace:GetServerTimeNow()
	timerLabel.Text = left > 0 and Util.FormatTime(left) or ""
	if id == "blood_moon" then
		local pulse = (math.sin(os.clock() * 3) + 1) / 2
		titleLabel.TextColor3 = baseColor:Lerp(rgb(255, 200, 200), pulse * 0.4)
		strip.BackgroundColor3 = titleLabel.TextColor3
	end
end

function EventsUI.Init(c)
	C = c
	UI = C.UI
	build()
	Net.Get("EventBanner").OnClientEvent:Connect(onBanner)
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(update, dt)
		if not ok and not EventsUI.warned then
			EventsUI.warned = true
			warn("[EventsUI] " .. tostring(err))
		end
	end)
end

-- { {pos = Vector3, color = Color3, label = string, id = string}, ... } для карты
function EventsUI.GetMarkers()
	local st = Net.State()
	local id = st:GetAttribute("EventId")
	local pos = st:GetAttribute("EventPos")
	if type(id) == "string" and id ~= "" and typeof(pos) == "Vector3" then
		local def = EventDefs.List[id]
		return {
			{ pos = pos, color = def and def.color or rgb(255, 220, 120), label = def and def.marker or "Событие", id = id },
		}
	end
	return {}
end

return EventsUI
