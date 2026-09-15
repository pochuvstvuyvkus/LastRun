-- Цели и метки на клиенте (v3):
--  * метки объектов мира с тегом LR_Waypoint (атрибуты WaypointLabel / WaypointColor / WaypointMaxDistance):
--    белая подпись с обводкой + расстояние «46m» на маленьком ромбе;
--  * такие же метки активных целей биома;
--  * светящиеся шевроны на земле от персонажа к GuideTarget (атрибут игрока) или к ближайшей активной цели;
--  * компактный трекер целей текущего биома справа;
--  * GetMarkers() для карты, GetNearest() для панели задания HUD, анимация выживших.
-- Данные целей приходят событием ObjectivesSync:
-- { objectives = { {id, biomeId, biomeName, type, title, text, progress, goal, state, pos, required} },
--   biomes = { [biomeId] = {done, need, name} }, currentBiome = id }
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ObjectiveDefs = require(Shared.Objectives)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local ObjectivesUI = {}
local C, UI
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

local WAYPOINT_TAG = "LR_Waypoint"
local MARKER_RANGE = 1500
local GUIDE_OBJECTIVE_RANGE = 450
local ROW_H = 40
local MAX_ROWS = 5
local CHEVRON_COUNT = 25
local CHEVRON_STEP = 3
local CHEVRON_W = 1.8
local CHEVRON_L = 1.25
local CHEVRON_COLOR = rgb(255, 212, 80)

local TYPE_COLORS = {
	collect = rgb(255, 200, 70),
	clear = rgb(230, 80, 60),
	rescue = rgb(90, 200, 255),
	elite = rgb(190, 110, 255),
	defend = rgb(120, 220, 120),
	cache = rgb(255, 150, 40),
}
local DONE_COLOR = rgb(110, 220, 120)
local FAILED_COLOR = rgb(235, 90, 80)
local PENDING_COLOR = rgb(150, 150, 160)
local WAYPOINT_DEFAULT = rgb(255, 200, 70)

local data = { objectives = {}, biomes = {}, currentBiome = nil }
local gui, panel, titleLabel, reqLabel, listFrame
local rows = {}
local markers = {} -- [objectiveId] = label
local markerList = {}
local waypoints = {} -- [instance] = { inst, part, label, offset }
local survivors = {}
local survivorById = {}
local nearest = nil
local playerGui

local chevronFolder
local chevrons = {}
local chevronCount = 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local paramsAcc = 10

local function typeColor(t)
	return TYPE_COLORS[t] or rgb(255, 215, 90)
end

-- Расстояние в метках мира: как в оригинале, «46m»
local function formatDist(studs)
	if studs >= 1000 then
		return string.format("%.1fkm", studs / 1000)
	end
	return math.floor(studs + 0.5) .. "m"
end

local function isRunVisible()
	local state = Net.State()
	if state:GetAttribute("Mode") == "lobby" then
		return false
	end
	local rs = state:GetAttribute("RunState")
	return rs == "Depot" or rs == "Driving" or rs == "Boss"
end

local function myRoot()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function myPosition()
	local root = myRoot()
	if root then
		return root.Position
	end
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position or Vector3.zero
end

-- Приём данных ------------------------------------------------------------------------

local function onSync(state)
	if type(state) ~= "table" then
		return
	end
	local objectives = {}
	if type(state.objectives) == "table" then
		for _, o in ipairs(state.objectives) do
			if type(o) == "table" and type(o.id) == "string" then
				table.insert(objectives, o)
			end
		end
	end
	data.objectives = objectives
	data.biomes = type(state.biomes) == "table" and state.biomes or {}
	data.currentBiome = state.currentBiome
end

local function livePos(o)
	if o.type == "rescue" then
		local sv = survivorById[o.id]
		if sv and sv.root.Parent then
			return sv.root.Position
		end
	end
	return typeof(o.pos) == "Vector3" and o.pos or nil
end

-- Подпись в мире (общая для LR_Waypoint и целей) ---------------------------------------------

local function makeLabel(name)
	local bb = Instance.new("BillboardGui")
	bb.Name = name
	bb.Size = UDim2.fromOffset(220, 48)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.ResetOnSpawn = false
	bb.ClipsDescendants = false
	bb.Enabled = false
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = rgb(255, 255, 255)
	title.TextStrokeColor3 = rgb(0, 0, 0)
	title.TextStrokeTransparency = 0.35
	title.Text = ""
	title.ZIndex = 2
	title.Parent = bb
	local diamond = Instance.new("Frame")
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.new(0.5, 0, 0, 33)
	diamond.Size = UDim2.fromOffset(15, 15)
	diamond.Rotation = 45
	diamond.BorderSizePixel = 0
	diamond.BackgroundColor3 = WAYPOINT_DEFAULT
	diamond.BackgroundTransparency = 0.1
	diamond.ZIndex = 1
	diamond.Parent = bb
	local stroke = Instance.new("UIStroke")
	stroke.Color = rgb(255, 255, 255)
	stroke.Thickness = 1
	stroke.Transparency = 0.35
	stroke.Parent = diamond
	local dist = Instance.new("TextLabel")
	dist.BackgroundTransparency = 1
	dist.Position = UDim2.fromOffset(0, 25)
	dist.Size = UDim2.new(1, 0, 0, 16)
	dist.Font = Enum.Font.GothamBold
	dist.TextSize = 12
	dist.TextColor3 = rgb(255, 255, 255)
	dist.TextStrokeColor3 = rgb(0, 0, 0)
	dist.TextStrokeTransparency = 0.15
	dist.Text = ""
	dist.ZIndex = 3
	dist.Parent = bb
	bb.Parent = playerGui
	return { bb = bb, title = title, dist = dist, diamond = diamond }
end

local function destroyLabel(label)
	if label and label.bb then
		label.bb:Destroy()
	end
end

-- LR_Waypoint -----------------------------------------------------------------------------------

local function adorneeOf(inst)
	if inst:IsA("BasePart") or inst:IsA("Attachment") then
		return inst
	end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Высота подписи над объектом: верх детали/модели + запас
local function labelOffset(inst, part)
	local ok, offset = pcall(function()
		if inst:IsA("Model") and part:IsA("BasePart") then
			local cf, size = inst:GetBoundingBox()
			return (cf.Position.Y + size.Y / 2) - part.Position.Y + 1.4
		elseif part:IsA("BasePart") then
			return part.Size.Y / 2 + 1.4
		end
		return 1.5
	end)
	return ok and offset or 2
end

local function removeWaypoint(inst)
	local w = waypoints[inst]
	if w then
		destroyLabel(w.label)
		waypoints[inst] = nil
	end
end

local function addWaypoint(inst)
	if waypoints[inst] or not (inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Attachment")) then
		return
	end
	waypoints[inst] = { inst = inst, part = nil, label = nil, offset = 2 }
end

-- 5 Гц: подписи LR_Waypoint
local function refreshWaypoints(me)
	for inst, w in pairs(waypoints) do
		if not inst.Parent then
			removeWaypoint(inst)
		else
			local part = w.part
			if not part or not part.Parent or not part:IsDescendantOf(inst.Parent) then
				part = adorneeOf(inst)
				w.part = part
				if part then
					w.offset = labelOffset(inst, part)
					if w.label then
						w.label.bb.Adornee = part
						w.label.bb.StudsOffsetWorldSpace = Vector3.new(0, w.offset, 0)
					end
				end
			end
			local text = inst:GetAttribute("WaypointLabel")
			local show = false
			if part and type(text) == "string" and text ~= "" and part:IsDescendantOf(workspace) then
				local pos = part:IsA("Attachment") and part.WorldPosition or part.Position
				local distance = (pos - me).Magnitude
				local maxDistance = inst:GetAttribute("WaypointMaxDistance")
				if type(maxDistance) ~= "number" then
					maxDistance = 90
				end
				show = distance <= maxDistance and distance >= 3
				if show then
					local label = w.label
					if not label then
						label = makeLabel("Waypoint")
						label.bb.Adornee = part
						label.bb.StudsOffsetWorldSpace = Vector3.new(0, w.offset, 0)
						w.label = label
					end
					label.title.Text = text
					label.dist.Text = formatDist(distance)
					local color = inst:GetAttribute("WaypointColor")
					label.diamond.BackgroundColor3 = typeof(color) == "Color3" and color or WAYPOINT_DEFAULT
					label.bb.Enabled = true
				end
			end
			if not show and w.label then
				w.label.bb.Enabled = false
			end
		end
	end
end

local function watchWaypoints()
	CollectionService:GetInstanceAddedSignal(WAYPOINT_TAG):Connect(addWaypoint)
	CollectionService:GetInstanceRemovedSignal(WAYPOINT_TAG):Connect(removeWaypoint)
	for _, inst in ipairs(CollectionService:GetTagged(WAYPOINT_TAG)) do
		addWaypoint(inst)
	end
end

-- Трекер ------------------------------------------------------------------------------------------

local function stateColor(o)
	if o.state == "done" then
		return DONE_COLOR
	elseif o.state == "failed" then
		return FAILED_COLOR
	elseif o.state == "pending" then
		return PENDING_COLOR
	end
	return typeColor(o.type)
end

local function makeRow(index)
	local row = UI.Frame(listFrame, { Size = UDim2.new(1, 0, 0, ROW_H), BackgroundTransparency = 1, LayoutOrder = index })
	local diamond = UI.Diamond(row, { Position = UDim2.fromOffset(6, 10), Size = UDim2.fromOffset(8, 8) })
	local title = UI.Label(row, { Position = UDim2.fromOffset(18, 2), Size = UDim2.new(1, -70, 0, 16), TextSize = 13, Text = "", TextTruncate = Enum.TextTruncate.AtEnd })
	local dist = UI.Label(row, { Position = UDim2.new(1, -52, 0, 2), Size = UDim2.fromOffset(52, 16), TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = UI.Colors.dim, Text = "" })
	local text = UI.Label(row, { Position = UDim2.fromOffset(18, 18), Size = UDim2.new(1, -18, 0, 14), TextSize = 11, Font = UI.Theme.fontRegular, TextColor3 = rgb(210, 210, 215), TextTruncate = Enum.TextTruncate.AtEnd, Text = "" })
	local barBg = UI.Frame(row, { Position = UDim2.new(0, 18, 1, -5), Size = UDim2.new(1, -18, 0, 2), BackgroundColor3 = rgb(255, 255, 255), BackgroundTransparency = 0.85 })
	local fill = UI.Frame(barBg, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = PENDING_COLOR })
	local r = { frame = row, diamond = diamond, title = title, dist = dist, text = text, fill = fill }
	rows[index] = r
	return r
end

local function buildTracker()
	gui = UI.Screen("ObjectivesUI", 3)
	panel = UI.Panel(gui, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 118),
		Size = UDim2.fromOffset(260, 60),
		Visible = false,
	})
	UI.AddScale(panel, true)
	titleLabel = UI.Label(panel, { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 16), TextSize = 13, Font = UI.Theme.fontBlack, Text = "ЦЕЛИ", TextColor3 = UI.Colors.accent, TextTruncate = Enum.TextTruncate.AtEnd })
	reqLabel = UI.Label(panel, { Position = UDim2.fromOffset(10, 22), Size = UDim2.new(1, -20, 0, 14), TextSize = 11, TextColor3 = UI.Colors.dim, Text = "" })
	listFrame = UI.Frame(panel, { Position = UDim2.fromOffset(6, 42), Size = UDim2.new(1, -14, 1, -46), BackgroundTransparency = 1 })
	UI.List(listFrame, 2)
end

local function refreshTracker(visible, me)
	local current = {}
	local rs = Net.State():GetAttribute("RunState")
	if visible and (rs == "Driving" or rs == "Boss") then
		for _, o in ipairs(data.objectives) do
			if o.biomeId == data.currentBiome then
				table.insert(current, o)
			end
		end
	end
	if #current == 0 then
		panel.Visible = false
		return
	end
	panel.Visible = true
	local info = data.biomes[data.currentBiome]
	local biomeName = (type(info) == "table" and info.name) or current[1].biomeName or ""
	titleLabel.Text = "ЦЕЛИ · " .. tostring(biomeName)
	if type(info) == "table" and type(info.need) == "number" then
		local done = tonumber(info.done) or 0
		reqLabel.Text = "Обязательно " .. info.need .. " из " .. #current .. " · выполнено " .. done
		reqLabel.TextColor3 = done >= info.need and DONE_COLOR or UI.Colors.dim
	else
		reqLabel.Text = ""
	end
	local shown = math.min(#current, MAX_ROWS)
	for i = 1, shown do
		local o = current[i]
		local r = rows[i] or makeRow(i)
		r.frame.Visible = true
		local color = stateColor(o)
		r.diamond.BackgroundColor3 = color
		r.title.Text = tostring(o.title or "")
		r.title.TextColor3 = o.state == "done" and DONE_COLOR or UI.Colors.text
		local goal = math.max(1, tonumber(o.goal) or 1)
		local progressValue = tonumber(o.progress) or 0
		local text = tostring(o.text or "")
		if o.state == "pending" then
			text = "Подъедьте ближе, чтобы найти место"
		elseif goal > 1 and o.state == "active" then
			text = math.floor(progressValue) .. "/" .. goal .. " · " .. text
		end
		r.text.Text = (ObjectiveDefs.TypeNames[o.type] or "Цель") .. " · " .. text
		r.fill.Size = UDim2.fromScale(math.clamp(progressValue / goal, 0, 1), 1)
		r.fill.BackgroundColor3 = color
		if o.state == "done" then
			r.dist.Text = "ГОТОВО"
			r.dist.TextColor3 = DONE_COLOR
		elseif o.state == "failed" then
			r.dist.Text = "ПРОВАЛ"
			r.dist.TextColor3 = FAILED_COLOR
		else
			local pos = livePos(o)
			r.dist.Text = pos and formatDist(Util.FlatDist(pos, me)) or ""
			r.dist.TextColor3 = UI.Colors.dim
		end
	end
	for i = shown + 1, #rows do
		rows[i].frame.Visible = false
	end
	panel.Size = UDim2.fromOffset(260, 46 + shown * (ROW_H + 2) + 4)
end

-- Метки активных целей -----------------------------------------------------------------------------

local function refreshMarkers(visible, me)
	local seen = {}
	markerList = {}
	local best, bestDist = nil, math.huge
	for _, o in ipairs(data.objectives) do
		seen[o.id] = true
		local pos = livePos(o)
		local active = o.state == "active"
		local distance = pos and Util.FlatDist(pos, me) or math.huge
		if visible and pos and (active or o.state == "pending" or o.state == "failed") then
			table.insert(markerList, {
				pos = pos,
				color = active and typeColor(o.type) or (o.state == "failed" and FAILED_COLOR or PENDING_COLOR),
				label = tostring(o.title or ""),
			})
		end
		if visible and active and pos then
			-- ближайшая активная цель: сначала текущего биома
			local weight = distance + (o.biomeId == data.currentBiome and 0 or 100000)
			if weight < bestDist then
				best, bestDist = o, weight
			end
		end
		local m = markers[o.id]
		if visible and active and pos and distance <= MARKER_RANGE then
			m = m or makeLabel("ObjectiveMarker")
			markers[o.id] = m
			if not m.att then
				m.att = Instance.new("Attachment")
				m.att.Name = "ObjectiveMarker_" .. o.id
				m.att.Parent = workspace.Terrain
				m.bb.Adornee = m.att
			end
			m.att.Position = pos + Vector3.new(0, 9, 0)
			m.title.Text = tostring(o.title or "")
			m.dist.Text = formatDist(distance)
			m.diamond.BackgroundColor3 = typeColor(o.type)
			m.bb.Enabled = distance > 12
		elseif m then
			m.bb.Enabled = false
		end
	end
	for id, m in pairs(markers) do
		if not seen[id] then
			destroyLabel(m)
			if m.att then
				m.att:Destroy()
			end
			markers[id] = nil
		end
	end
	if best then
		local pos = livePos(best)
		nearest = { objective = best, pos = pos, dist = pos and Util.FlatDist(pos, me) or math.huge }
	else
		nearest = nil
	end
end

-- Для миникарты/карты: { {pos = Vector3, color = Color3, label = string}, ... }
function ObjectivesUI.GetMarkers()
	return markerList
end

-- Ближайшая активная цель (для панели задания HUD): objective, pos, dist
function ObjectivesUI.GetNearest()
	if nearest then
		return nearest.objective, nearest.pos, nearest.dist
	end
	return nil
end

-- Шевроны на земле --------------------------------------------------------------------------------

local function makeWedge(name)
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.CanCollide = false
	w.CanQuery = false
	w.CanTouch = false
	w.CastShadow = false
	w.Material = Enum.Material.Neon
	w.Color = CHEVRON_COLOR
	w.Size = Vector3.new(0.1, CHEVRON_W / 2, CHEVRON_L)
	w.Transparency = 1
	w.Parent = chevronFolder
	return w
end

local function buildChevrons()
	chevronFolder = Instance.new("Folder")
	chevronFolder.Name = "LR_GuidePath"
	chevronFolder.Parent = workspace
	for i = 1, CHEVRON_COUNT do
		chevrons[i] = { left = makeWedge("L" .. i), right = makeWedge("R" .. i), on = false, shown = false }
	end
end

local function hideChevrons()
	chevronCount = 0
	for _, ch in ipairs(chevrons) do
		ch.on = false
		if ch.shown then
			ch.shown = false
			ch.left.Transparency = 1
			ch.right.Transparency = 1
		end
	end
end

local function refreshRayParams()
	local exclude = { chevronFolder }
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	for _, name in ipairs({ "Zombies", "Loot", "Effects", "ClientFX", "EventsFX", "Placeables" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
end

-- Треугольник из двух клиньев, лежащий на земле остриём к цели
local function placeChevron(ch, pos, normal, dir)
	local up = normal.Y > 0.5 and normal or Vector3.yAxis
	local f = dir - up * dir:Dot(up)
	if f.Magnitude < 0.01 then
		f = dir
	end
	f = f.Unit
	local r = f:Cross(up).Unit
	local base = pos + up * 0.08
	ch.right.CFrame = CFrame.fromMatrix(base + r * (CHEVRON_W / 4), -up, r, -f)
	ch.left.CFrame = CFrame.fromMatrix(base - r * (CHEVRON_W / 4), up, -r, -f)
end

local function groundAt(x, y, z)
	local origin = Vector3.new(x, y, z)
	for _ = 1, 3 do
		local hit = workspace:Raycast(origin, Vector3.new(0, -30, 0), rayParams)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		if inst:IsA("BasePart") and inst.Transparency >= 0.9 then
			origin = hit.Position - Vector3.new(0, 0.05, 0)
		else
			return hit.Position, hit.Normal
		end
	end
	return nil
end

local function guideTarget()
	local attr = player:GetAttribute("GuideTarget")
	if typeof(attr) == "Vector3" then
		return attr
	end
	if nearest and nearest.pos and nearest.dist <= GUIDE_OBJECTIVE_RANGE then
		return nearest.pos
	end
	return nil
end

-- 10 Гц: позиции шевронов
local function refreshPath(dt)
	paramsAcc = paramsAcc + dt
	if paramsAcc >= 1 then
		paramsAcc = 0
		refreshRayParams()
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = myRoot()
	-- пока открыто окно (инвентарь, магазин, верстак) — шевроны прячутся
	local panels = C.Panels
	local menuOpen = panels ~= nil and panels.IsOpen ~= nil and panels.IsOpen()
	if menuOpen or not isRunVisible() or not hum or not root or hum.Health <= 0 or hum.SeatPart ~= nil or player:GetAttribute("Sleeping") then
		hideChevrons()
		return
	end
	local target = guideTarget()
	if not target then
		hideChevrons()
		return
	end
	local from = root.Position
	local flat = Vector3.new(target.X - from.X, 0, target.Z - from.Z)
	local dist = flat.Magnitude
	if dist < 6 then
		hideChevrons()
		return
	end
	local dir = flat.Unit
	local count = math.clamp(math.floor((dist - 3) / CHEVRON_STEP), 0, CHEVRON_COUNT)
	chevronCount = count
	for i = 1, CHEVRON_COUNT do
		local ch = chevrons[i]
		ch.on = false
		if i <= count then
			local d = 2.5 + (i - 1) * CHEVRON_STEP
			local p = from + dir * d
			local baseY = from.Y + (target.Y - from.Y) * math.clamp(d / dist, 0, 1)
			local hitPos, normal = groundAt(p.X, math.max(baseY, from.Y - 2) + 4, p.Z)
			if hitPos then
				placeChevron(ch, hitPos, normal, dir)
				ch.on = true
			end
		end
		if not ch.on and ch.shown then
			ch.shown = false
			ch.left.Transparency = 1
			ch.right.Transparency = 1
		end
	end
end

-- 30 Гц: бегущая волна яркости к цели
local function animatePath()
	local t = os.clock()
	for i, ch in ipairs(chevrons) do
		if ch.on then
			local wave = 0.5 + 0.5 * math.sin(t * 5 - i * 0.55)
			local fadeFar = math.clamp((chevronCount - i + 1) / 5, 0, 1)
			local fadeNear = math.clamp(i / 2, 0, 1)
			local tr = 1 - (0.35 + 0.6 * wave) * fadeFar * fadeNear
			ch.left.Transparency = tr
			ch.right.Transparency = tr
			ch.shown = true
		end
	end
end

-- Анимация выживших ---------------------------------------------------------------------------------

local JOINTS = {
	RightShoulder = { "Torso", "Right Shoulder" },
	LeftShoulder = { "Torso", "Left Shoulder" },
	RightHip = { "Torso", "Right Hip" },
	LeftHip = { "Torso", "Left Hip" },
}

local function registerSurvivor(model)
	if survivors[model] then
		return
	end
	local torso = model:WaitForChild("Torso", 5)
	local root = model:WaitForChild("HumanoidRootPart", 5)
	if not torso or not root or not model.Parent then
		return
	end
	local sv = { model = model, root = root, motors = {}, base = {}, phase = math.random() * 6 }
	for name, path in pairs(JOINTS) do
		local parent = model:FindFirstChild(path[1])
		local m = parent and parent:WaitForChild(path[2], 3)
		if m and m:IsA("Motor6D") then
			sv.motors[name] = m
			sv.base[name] = m.C0
		end
	end
	survivors[model] = sv
	local id = model:GetAttribute("ObjectiveId")
	if type(id) == "string" then
		survivorById[id] = sv
	end
end

local function setJoint(sv, name, pitch, yaw, roll)
	local m = sv.motors[name]
	if not m or not m.Parent then
		return
	end
	m.Transform = Util.JointTransform(sv.base[name], CFrame.fromOrientation(math.rad(pitch), math.rad(yaw), math.rad(roll)))
end

local function animateSurvivor(sv, dt, now)
	local vel = sv.root.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	sv.phase = sv.phase + dt * (speed * 0.5 + 1)
	local move = math.clamp(speed / 12, 0, 1)
	local s = math.sin(sv.phase)
	setJoint(sv, "LeftShoulder", -s * 50 * move, 0, 0)
	setJoint(sv, "RightHip", -s * 40 * move, 0, 0)
	setJoint(sv, "LeftHip", s * 40 * move, 0, 0)
	if move < 0.2 and sv.model:GetAttribute("Following") ~= true then
		-- машет рукой: «помогите!»
		setJoint(sv, "RightShoulder", 165, 0, math.sin(now * 7) * 25)
	else
		setJoint(sv, "RightShoulder", s * 50 * move, 0, 0)
	end
end

local function watchSurvivors()
	local folder = workspace:WaitForChild("Objectives", 60)
	if not folder then
		return
	end
	folder.DescendantAdded:Connect(function(inst)
		if inst:IsA("Model") and inst:GetAttribute("Survivor") then
			task.spawn(registerSurvivor, inst)
		end
	end)
	for _, inst in ipairs(folder:GetDescendants()) do
		if inst:IsA("Model") and inst:GetAttribute("Survivor") then
			task.spawn(registerSurvivor, inst)
		end
	end
end

-- Инициализация -----------------------------------------------------------------------------------

function ObjectivesUI.Init(c)
	C = c
	UI = C.UI
	playerGui = player:WaitForChild("PlayerGui")
	buildTracker()
	buildChevrons()
	refreshRayParams()
	Net.Get("ObjectivesSync").OnClientEvent:Connect(onSync)
	task.spawn(watchSurvivors)
	watchWaypoints()

	RunService.Stepped:Connect(function(_, dt)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local camPos = cam.CFrame.Position
		local now = os.clock()
		for model, sv in pairs(survivors) do
			if not model.Parent then
				survivors[model] = nil
				local id = model:GetAttribute("ObjectiveId")
				if type(id) == "string" and survivorById[id] == sv then
					survivorById[id] = nil
				end
			elseif sv.root.Parent and (sv.root.Position - camPos).Magnitude < 160 then
				animateSurvivor(sv, dt, now)
			end
		end
	end)

	local pathAcc, animAcc = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		pathAcc = pathAcc + dt
		animAcc = animAcc + dt
		if pathAcc >= 0.1 then
			local step = pathAcc
			pathAcc = 0
			local ok, err = pcall(refreshPath, step)
			if not ok and not ObjectivesUI.warnedPath then
				ObjectivesUI.warnedPath = true
				warn("[ObjectivesUI] " .. tostring(err))
			end
		end
		if animAcc >= 1 / 30 then
			animAcc = 0
			animatePath()
		end
	end)

	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				local visible = isRunVisible()
				local me = myPosition()
				refreshMarkers(visible, me)
				refreshTracker(visible, me)
				refreshWaypoints(me)
			end)
			if not ok and not ObjectivesUI.warned then
				ObjectivesUI.warned = true
				warn("[ObjectivesUI] " .. tostring(err))
			end
			task.wait(0.2)
		end
	end)
end

return ObjectivesUI
