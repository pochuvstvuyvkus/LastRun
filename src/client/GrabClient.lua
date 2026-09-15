-- Перенос крупных объектов мышью (v5, docs/SPEC_v5.md 2.7) — как в оригинале:
-- наведение лучом из центра камеры (≤ 12 studs, 20 раз/с) — белый контур (один Highlight на всё)
-- и тёмная плашка сверху «Взять [ЛКМ]»; ЛКМ — объект едет перед камерой (сервер отдаёт клиенту
-- сетевое владение и ставит AlignPosition/AlignOrientation, цель им задаёт этот модуль каждый кадр);
-- колесо мыши — расстояние 3…10, R — поворот на 45° вокруг текущей оси с доводкой, X — смена оси,
-- Z — прикрепить, ЛКМ или Q — отпустить. Рядом с подходящим свободным слотом автобуса (метки с тегом
-- LR_BusSlot, атрибуты SlotType/SlotIndex/Accepts/Free) показывается полупрозрачный призрак объекта
-- и плашка «Прикрепить [Z]», справа внизу — список подсказок в стиле оригинала.
-- Клавиши Z/R/X/Q перехватываются только на время переноса (ContextActionService, высокий приоритет),
-- поэтому перезарядка (R) и выброс предмета (Q) в WeaponClient работают как раньше.
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sounds = require(Shared.Sounds)
local Net = require(Shared.Net)

local GrabClient = {}
local C, UI
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

local TAG = "LR_Grabbable"
local SLOT_TAG = "LR_BusSlot"
local ALIGN_POS_NAME = "GrabAlignPosition"
local ALIGN_ORI_NAME = "GrabAlignOrientation"

local REACH = 12
local HOVER_INTERVAL = 0.05 -- 20 Гц
local SLOW_INTERVAL = 0.1
local SLOT_RANGE = 14
local DIST_MIN, DIST_MAX, DIST_STEP = 3, 10, 0.7
local ROTATE_STEP = math.rad(45)
local ROTATE_SPEED = 13
local CONFIRM_TIMEOUT = 1.5
local RELEASE_RETRY = 0.6
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50

local ACTION_ATTACH = "LastRunGrabAttach"
local ACTION_ROTATE = "LastRunGrabRotate"
local ACTION_AXIS = "LastRunGrabAxis"
local ACTION_DROP = "LastRunGrabDrop"

local AXES = { "Y", "X", "Z" }
local AXIS_VECTORS = { Y = Vector3.yAxis, X = Vector3.xAxis, Z = Vector3.zAxis }
local AXIS_HEX = { Y = "#78E18C", X = "#F0786E", Z = "#78AAFF" }

local GHOST_COLOR = rgb(206, 232, 214)
local PICKUP_FALLBACK = { bus_wheel = "pickup_metal", plate_wood = "pickup_wood", plate_metal = "pickup_metal" }

-- Состояние ---------------------------------------------------------------------------------------

local remote
local camera = workspace.CurrentCamera
local highlight
local hovered = nil
local carried, carriedPrimary = nil, nil
local carriedKind, carriedRadius = nil, 1
local alignPos, alignOri = nil, nil
local confirmed = false
local grabSentAt = 0
local distance = 6
local axisIndex = 1
local rotTarget, rotCurrent = CFrame.identity, CFrame.identity
local lastYaw = 0
local clickHeld = false
local clickAt = 0
local pendingRelease = nil
local actionsBound = false
local hoverAcc, slowAcc = 0, 0
local rotateFlash = 0

local markers = {} -- [BasePart] = { raw = "a,b", set = { [id] = true } }
local ghost, ghostPrimary, ghostIsModel = nil, nil, false
local ghostExtents, ghostRot, ghostScale = Vector3.one, nil, 1
local ghostCenterOffset, ghostPivotOffset = CFrame.identity, CFrame.identity
local ghostMarker = nil
local ghostShown = false

local gui, promptHolder, promptPlate, promptScale, promptText, promptCap, promptCapLetter, promptCapMouse, promptSub
local hintsFrame, hintRows = nil, {}
local promptState, promptSubText = "", ""
local hintsVisible = false
local warned = false

local hoverParams = RaycastParams.new()
hoverParams.FilterType = Enum.RaycastFilterType.Exclude
hoverParams.IgnoreWater = true
local carryParams = RaycastParams.new()
carryParams.FilterType = Enum.RaycastFilterType.Exclude
carryParams.IgnoreWater = true
local hoverFilter = { nil, nil }
local carryFilter = { nil, nil, nil }

-- 24 поворота «по осям»: ими призрак разворачивается под форму слота
local ROTATIONS = {}
local IDENTITY_ROT = { cf = CFrame.identity, cx = Vector3.xAxis, cy = Vector3.yAxis, cz = Vector3.zAxis, trace = 3 }
do
	local axes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local perms = { { 1, 2 }, { 1, 3 }, { 2, 1 }, { 2, 3 }, { 3, 1 }, { 3, 2 } }
	for _, p in ipairs(perms) do
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				local cx = axes[p[1]] * sx
				local cy = axes[p[2]] * sy
				local cz = cx:Cross(cy)
				table.insert(ROTATIONS, {
					cf = CFrame.fromMatrix(Vector3.zero, cx, cy, cz),
					cx = cx,
					cy = cy,
					cz = cz,
					trace = cx.X + cy.Y + cz.Z,
				})
			end
		end
	end
end

-- Помощники ---------------------------------------------------------------------------------------

local function playSound(key, where)
	local fx = C and C.SoundFX
	if fx and fx.Play then
		pcall(fx.Play, key, where)
	end
end

local function pickupKey(kind)
	local byItem = Sounds["PickupKey"]
	if type(byItem) == "function" then
		local ok, key = pcall(byItem, kind)
		if ok and type(key) == "string" and key ~= "" then
			return key
		end
	end
	return PICKUP_FALLBACK[kind] or "pickup_generic"
end

local function gameState()
	return ReplicatedStorage:FindFirstChild("GameState")
end

local function inLobby()
	local st = gameState()
	return st ~= nil and st:GetAttribute("Mode") == "lobby"
end

-- Нельзя переносить: лобби, смерть, обморок, сон, открытое окно, кресло
local function isBlocked()
	if inLobby() then
		return true
	end
	if player:GetAttribute("Downed") == true or player:GetAttribute("Sleeping") == true then
		return true
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or hum.SeatPart then
		return true
	end
	local panels = C and C.Panels
	if panels and panels.IsOpen and panels.IsOpen() then
		return true
	end
	return false
end

-- В руках оружие (в том числе метательное): тогда ЛКМ — удар, а не перенос
local function holdingWeapon()
	local weapons = C and C.WeaponClient
	if not weapons or not weapons.Current then
		return false
	end
	local ok, tool, def = pcall(weapons.Current)
	if not ok then
		return false
	end
	if def then
		return true
	end
	return tool ~= nil and tool:GetAttribute("ItemKind") == "weapon"
end

local function primaryOf(inst)
	if inst:IsA("BasePart") then
		return inst
	end
	if inst.PrimaryPart then
		return inst.PrimaryPart
	end
	local best, bestVolume = nil, -1
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			local s = d.Size
			local volume = s.X * s.Y * s.Z
			if volume > bestVolume then
				best, bestVolume = d, volume
			end
		end
	end
	return best
end

local function extentsOf(inst)
	if inst:IsA("Model") then
		local ok, _, size = pcall(inst.GetBoundingBox, inst)
		if ok and typeof(size) == "Vector3" and size.Magnitude > 0 then
			return size
		end
	end
	local primary = primaryOf(inst)
	return primary and primary.Size or Vector3.one
end

local function grabbableFrom(part)
	local cur = part
	for _ = 1, 6 do
		if cur == nil or cur == workspace then
			return nil
		end
		if CollectionService:HasTag(cur, TAG) then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

-- Интерфейс ---------------------------------------------------------------------------------------

-- Значок мыши из рамок (левая кнопка или колесо) — без загружаемых картинок
local function mouseGlyph(parent, width, height, wheel)
	local body = UI.Frame(parent, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		BackgroundTransparency = 1,
	})
	UI.Corner(body, math.floor(width / 2))
	UI.Stroke(body, rgb(240, 240, 240), math.max(1, width / 10), 0)
	local line = math.max(1, math.floor(width / 9))
	if wheel then
		local w = UI.Frame(body, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0.16, 0),
			Size = UDim2.new(0, line * 2, 0.3, 0),
			BackgroundColor3 = rgb(240, 240, 240),
		})
		UI.Corner(w, line)
	else
		local fill = UI.Frame(body, {
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.new(0.5, 0, 0.42, 0),
			BackgroundColor3 = rgb(240, 240, 240),
		})
		UI.Corner(fill, math.floor(width / 2))
		-- прямые углы у внутренней стороны кнопки
		UI.Frame(fill, { Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromScale(0.5, 1), BackgroundColor3 = rgb(240, 240, 240) })
		UI.Frame(fill, { Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(1, 0.5), BackgroundColor3 = rgb(240, 240, 240) })
		UI.Frame(body, { Position = UDim2.new(0, 0, 0.42, 0), Size = UDim2.new(1, 0, 0, line), BackgroundColor3 = rgb(240, 240, 240) })
		UI.Frame(body, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.new(0, line, 0.42, 0),
			BackgroundColor3 = rgb(30, 30, 32),
		})
	end
	return body
end

-- Крупная клавиша на плашке («Z» или значок мыши)
local function buildPromptCap(parent)
	local cap = UI.Frame(parent, {
		Size = UDim2.fromOffset(50, 50),
		BackgroundColor3 = rgb(96, 96, 102),
		BackgroundTransparency = 0.05,
		LayoutOrder = 2,
	})
	UI.Corner(cap, 9)
	UI.Stroke(cap, rgb(16, 16, 18), 2, 0.15)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(rgb(128, 128, 134), rgb(62, 62, 68))
	grad.Parent = cap
	local face = UI.Frame(cap, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -10, 1, -10),
		BackgroundColor3 = rgb(74, 74, 80),
		BackgroundTransparency = 0.1,
	})
	UI.Corner(face, 6)
	local letter = UI.Label(face, {
		Size = UDim2.fromScale(1, 1),
		Text = "Z",
		Font = UI.Theme.fontBlack,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 1,
	})
	local glyph = mouseGlyph(face, 19, 27, false)
	glyph.Visible = false
	return cap, letter, glyph
end

-- Маленькая клавиша в подсказках справа внизу
local function buildHintKey(parent, text, glyph)
	local box = UI.Frame(parent, {
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = rgb(18, 18, 20),
		BackgroundTransparency = 0.25,
		LayoutOrder = 2,
	})
	UI.Corner(box, 3)
	UI.Stroke(box, rgb(235, 235, 240), 1, 0.55)
	if glyph then
		mouseGlyph(box, 11, 16, glyph == "wheel")
	else
		UI.Label(box, {
			Size = UDim2.fromScale(1, 1),
			Text = text,
			Font = UI.Theme.font,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeTransparency = 1,
		})
	end
	return box
end

local HINTS = {
	{ id = "attach", text = "Прикрепить", key = "Z" },
	{ id = "distance", text = "Расстояние", glyph = "wheel" },
	{ id = "axis", text = "Изменить ось", key = "X", rich = true },
	{ id = "rotate", text = "Повернуть", key = "R" },
	{ id = "drop", text = "Отпустить", glyph = "mouse" },
}

local function buildUI()
	gui = UI.Screen("GrabUI", 4)

	promptHolder = UI.Frame(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 104),
		Size = UDim2.fromOffset(620, 92),
		BackgroundTransparency = 1,
		Visible = false,
	})
	UI.AddScale(promptHolder, true)
	promptPlate = UI.Frame(promptHolder, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(0, 66),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = rgb(16, 16, 18),
		BackgroundTransparency = 0.18,
	})
	UI.Corner(promptPlate, 10)
	UI.Stroke(promptPlate, rgb(225, 225, 230), 1.5, 0.5)
	promptScale = Instance.new("UIScale")
	promptScale.Parent = promptPlate
	UI.New("UIPadding", {
		PaddingLeft = UDim.new(0, 22),
		PaddingRight = UDim.new(0, 9),
		Parent = promptPlate,
	})
	local plateLayout = UI.List(promptPlate, 14, true)
	plateLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	promptText = UI.Label(promptPlate, {
		Size = UDim2.fromOffset(0, 66),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = "Взять",
		Font = Enum.Font.GothamMedium,
		TextSize = 33,
		TextColor3 = rgb(243, 243, 243),
		TextStrokeTransparency = 1,
		LayoutOrder = 1,
	})
	promptCap, promptCapLetter, promptCapMouse = buildPromptCap(promptPlate)
	promptSub = UI.Label(promptHolder, {
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 20),
		Text = "",
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = rgb(214, 214, 220),
		TextStrokeTransparency = 0.5,
	})

	hintsFrame = UI.Frame(gui, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -14),
		Size = UDim2.fromOffset(320, 180),
		BackgroundTransparency = 1,
		Visible = false,
	})
	UI.AddScale(hintsFrame, true)
	local hintsLayout = UI.List(hintsFrame, 9)
	hintsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	hintsLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	for i, def in ipairs(HINTS) do
		local row = UI.Frame(hintsFrame, { Size = UDim2.fromOffset(320, 24), BackgroundTransparency = 1, LayoutOrder = i })
		local rowLayout = UI.List(row, 9, true)
		rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		local label = UI.Label(row, {
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			Text = def.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 17,
			TextStrokeTransparency = 0.55,
			RichText = def.rich == true,
			LayoutOrder = 1,
		})
		buildHintKey(row, def.key, def.glyph)
		hintRows[def.id] = { row = row, label = label }
	end

	highlight = Instance.new("Highlight")
	highlight.Name = "LR_GrabOutline"
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 0
	highlight.OutlineColor = rgb(255, 255, 255)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = camera
end

local function setOutline(target)
	if not highlight then
		return
	end
	if highlight.Parent ~= camera then
		highlight.Parent = camera
	end
	if highlight.Adornee ~= target then
		highlight.Adornee = target
	end
	if highlight.Enabled ~= (target ~= nil) then
		highlight.Enabled = target ~= nil
	end
end

local function setPrompt(state, sub)
	if state ~= promptState then
		promptState = state
		local show = state ~= ""
		promptHolder.Visible = show
		if show then
			local attach = state == "attach"
			local dim = state == "locked"
			promptText.Text = attach and "Прикрепить" or "Взять"
			promptText.TextTransparency = dim and 0.35 or 0
			promptCapLetter.Visible = attach
			promptCapMouse.Visible = not attach
			promptCap.BackgroundTransparency = dim and 0.45 or 0.05
			promptScale.Scale = 0.92
		end
	end
	sub = sub or ""
	if sub ~= promptSubText then
		promptSubText = sub
		promptSub.Text = sub
	end
end

local function setHints(show)
	if hintsVisible == show then
		return
	end
	hintsVisible = show
	hintsFrame.Visible = show
end

local function updateAxisHint()
	local row = hintRows.axis
	if row then
		local axis = AXES[axisIndex]
		row.label.Text = string.format('Изменить ось <font color="%s">%s</font>', AXIS_HEX[axis], axis)
	end
end

local function setAttachHint(ready)
	local row = hintRows.attach
	if row and row.label.TextTransparency ~= (ready and 0 or 0.5) then
		row.label.TextTransparency = ready and 0 or 0.5
	end
end

-- Призрак на слоте --------------------------------------------------------------------------------

local function destroyGhost()
	if ghost then
		ghost:Destroy()
	end
	ghost, ghostPrimary, ghostMarker = nil, nil, nil
	ghostShown = false
	ghostRot = nil
end

local function buildGhost(inst)
	destroyGhost()
	local ok, clone = pcall(inst.Clone, inst)
	if not ok or not clone then
		return
	end
	for _, tag in ipairs(CollectionService:GetTags(clone)) do
		CollectionService:RemoveTag(clone, tag)
	end
	local function clean(d)
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Massless = true
			d.Material = Enum.Material.SmoothPlastic
			d.Color = d.Color:Lerp(GHOST_COLOR, 0.6)
			d.Transparency = math.max(0.5, math.min(0.85, d.Transparency))
			d.Reflectance = 0.05
		elseif d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = math.max(d.Transparency, 0.6)
		elseif not (d:IsA("DataModelMesh") or d:IsA("SurfaceAppearance")) then
			d:Destroy()
		end
	end
	if clone:IsA("BasePart") then
		clean(clone)
	end
	for _, d in ipairs(clone:GetDescendants()) do
		clean(d)
	end
	ghostIsModel = clone:IsA("Model")
	ghostPrimary = primaryOf(clone)
	if not ghostPrimary then
		clone:Destroy()
		return
	end
	if ghostIsModel and not clone.PrimaryPart then
		clone.PrimaryPart = ghostPrimary
	end
	ghost = clone
	ghostScale = 1
	ghostExtents = extentsOf(clone)
	ghostRot = nil
	ghostMarker = nil
	ghostShown = false
	ghost.Name = "LR_GrabGhost"
	ghost.Parent = nil
end

local function mapExtents(rot, ext)
	return Vector3.new(
		math.abs(rot.cx.X) * ext.X + math.abs(rot.cy.X) * ext.Y + math.abs(rot.cz.X) * ext.Z,
		math.abs(rot.cx.Y) * ext.X + math.abs(rot.cy.Y) * ext.Y + math.abs(rot.cz.Y) * ext.Z,
		math.abs(rot.cx.Z) * ext.X + math.abs(rot.cy.Z) * ext.Y + math.abs(rot.cz.Z) * ext.Z
	)
end

-- Разворот призрака под форму метки слота: самая тонкая сторона объекта к самой тонкой стороне слота
local function bestRotation(ext, size)
	local best, bestScore = IDENTITY_ROT, math.huge
	for _, rot in ipairs(ROTATIONS) do
		local along = mapExtents(rot, ext)
		local score = math.abs(math.log(math.max(along.X, 0.05) / math.max(size.X, 0.05)))
			+ math.abs(math.log(math.max(along.Y, 0.05) / math.max(size.Y, 0.05)))
			+ math.abs(math.log(math.max(along.Z, 0.05) / math.max(size.Z, 0.05)))
			+ (3 - rot.trace) * 0.001
		if score < bestScore then
			best, bestScore = rot, score
		end
	end
	return best
end

local function fitGhost(marker)
	if not ghost or not ghostPrimary then
		return
	end
	local size = marker.Size
	local rot = IDENTITY_ROT
	local scale = 1
	local maxSide = math.max(size.X, size.Y, size.Z)
	local minSide = math.min(size.X, size.Y, size.Z)
	local shaped = minSide > 0.05 and maxSide / minSide >= 1.3
	-- метка описывает объём места (а не просто точку) — можно разворачивать и подгонять размер
	if maxSide >= 0.8 and (shaped or maxSide >= 2) then
		if shaped then
			rot = bestRotation(ghostExtents, size)
		end
		local along = mapExtents(rot, ghostExtents)
		local ratios = {
			size.X / math.max(along.X, 0.05),
			size.Y / math.max(along.Y, 0.05),
			size.Z / math.max(along.Z, 0.05),
		}
		table.sort(ratios)
		scale = math.clamp(ratios[2], 0.5, 2.5)
	end
	ghostRot = rot.cf
	if ghostIsModel and math.abs(ghostScale - scale) > 0.02 then
		if pcall(ghost.ScaleTo, ghost, scale) then
			ghostScale = scale
		end
	end
	local primaryCF = ghostPrimary.CFrame
	local boxCF = primaryCF
	if ghostIsModel then
		local okBox, cf = pcall(ghost.GetBoundingBox, ghost)
		if okBox and typeof(cf) == "CFrame" then
			boxCF = cf
		end
	end
	ghostCenterOffset = primaryCF:ToObjectSpace(boxCF)
	ghostPivotOffset = primaryCF:ToObjectSpace(ghost:GetPivot())
end

local function acceptsKind(marker, kind)
	local raw = marker:GetAttribute("Accepts")
	if type(raw) ~= "string" then
		return false
	end
	local cached = markers[marker]
	if type(cached) ~= "table" or cached.raw ~= raw then
		local set = {}
		for id in string.gmatch(raw, "[^,%s]+") do
			set[id] = true
		end
		cached = { raw = raw, set = set }
		markers[marker] = cached
	end
	return cached.set[kind] == true
end

local function findSlot(kind, from)
	local best, bestDist = nil, SLOT_RANGE
	for marker in pairs(markers) do
		if typeof(marker) == "Instance" and marker:IsA("BasePart") and marker:IsDescendantOf(workspace) then
			if marker:GetAttribute("Free") ~= false and acceptsKind(marker, kind) then
				local d = (marker.Position - from).Magnitude
				if d <= bestDist then
					best, bestDist = marker, d
				end
			end
		end
	end
	return best
end

local function updateGhost(marker)
	if not ghost then
		return
	end
	if marker ~= ghostMarker then
		ghostMarker = marker
		if marker then
			fitGhost(marker)
		end
	end
	local show = marker ~= nil
	if show then
		ghost:PivotTo(marker.CFrame * (ghostRot or CFrame.identity) * ghostCenterOffset:Inverse() * ghostPivotOffset)
	end
	if show ~= ghostShown then
		ghostShown = show
		ghost.Parent = show and camera or nil
	end
end

-- Перенос ------------------------------------------------------------------------------------------

local function unbindActions()
	if not actionsBound then
		return
	end
	actionsBound = false
	ContextActionService:UnbindAction(ACTION_ATTACH)
	ContextActionService:UnbindAction(ACTION_ROTATE)
	ContextActionService:UnbindAction(ACTION_AXIS)
	ContextActionService:UnbindAction(ACTION_DROP)
end

local function endCarry()
	carried, carriedPrimary, carriedKind = nil, nil, nil
	alignPos, alignOri = nil, nil
	confirmed = false
	unbindActions()
	destroyGhost()
	setHints(false)
	setOutline(nil)
end

local function releaseCarried(quiet)
	local inst, primary = carried, carriedPrimary
	if not inst then
		return
	end
	if primary and primary.Parent then
		-- физику объекта считает этот клиент: гасим рывок, чтобы предмет не улетал
		if alignPos and alignPos.Parent then
			alignPos.Enabled = false
		end
		if alignOri and alignOri.Parent then
			alignOri.Enabled = false
		end
		primary.AssemblyLinearVelocity = primary.AssemblyLinearVelocity * 0.4
		primary.AssemblyAngularVelocity = primary.AssemblyAngularVelocity * 0.3
		if not quiet then
			playSound("drop_item", primary)
		end
	end
	endCarry()
	remote:FireServer("release", inst)
	pendingRelease = { inst = inst, at = os.clock(), tries = 0 }
end

local function startGrab(inst)
	local primary = primaryOf(inst)
	if not primary then
		return
	end
	carried, carriedPrimary = inst, primary
	carriedKind = inst:GetAttribute("GrabKind") or inst:GetAttribute("ItemId") or inst.Name
	carriedRadius = extentsOf(inst).Magnitude / 2
	confirmed = false
	grabSentAt = os.clock()
	alignPos, alignOri = nil, nil
	local cf = camera.CFrame
	distance = math.clamp((primary.Position - cf.Position).Magnitude, DIST_MIN, DIST_MAX)
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-3 then
		lastYaw = math.atan2(-flat.X, -flat.Z)
	end
	rotTarget = CFrame.Angles(0, lastYaw, 0):Inverse() * primary.CFrame.Rotation
	rotCurrent = rotTarget
	remote:FireServer("grab", inst)
	if not actionsBound then
		actionsBound = true
		local function bind(name, keys)
			ContextActionService:BindActionAtPriority(name, GrabClient.OnAction, false, ACTION_PRIORITY, table.unpack(keys))
		end
		bind(ACTION_ATTACH, { Enum.KeyCode.Z })
		bind(ACTION_ROTATE, { Enum.KeyCode.R })
		bind(ACTION_AXIS, { Enum.KeyCode.X })
		bind(ACTION_DROP, { Enum.KeyCode.Q })
	end
	buildGhost(inst)
	setHints(true)
	setAttachHint(false)
	updateAxisHint()
	setOutline(inst)
	playSound(pickupKey(carriedKind), primary)
end

local function sendAttach()
	if carried then
		remote:FireServer("attach", carried)
	end
end

-- Обработчик клавиш переноса (Z, R, X, Q) — перебивает перезарядку и выброс, пока объект в руках
function GrabClient.OnAction(name, state, input)
	if state ~= Enum.UserInputState.Begin or UserInputService:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end
	if not carried then
		return Enum.ContextActionResult.Pass
	end
	if name == ACTION_ATTACH then
		sendAttach()
	elseif name == ACTION_ROTATE then
		local back = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local axis = AXIS_VECTORS[AXES[axisIndex]]
		rotTarget = CFrame.fromAxisAngle(axis, back and -ROTATE_STEP or ROTATE_STEP) * rotTarget
		rotateFlash = os.clock() + 0.18
	elseif name == ACTION_AXIS then
		axisIndex = axisIndex % #AXES + 1
		updateAxisHint()
	elseif name == ACTION_DROP then
		releaseCarried(false)
	end
	return Enum.ContextActionResult.Sink
end

local function carryStep(dt)
	local inst, primary = carried, carriedPrimary
	if not inst.Parent or not primary or not primary.Parent or not primary:IsDescendantOf(workspace) then
		endCarry()
		return
	end
	local carrier = inst:GetAttribute("GrabCarrier")
	if confirmed then
		if carrier ~= player.UserId then
			endCarry()
			return
		end
	elseif carrier == player.UserId then
		confirmed = true
	elseif os.clock() - grabSentAt > CONFIRM_TIMEOUT then
		endCarry()
		return
	end
	if isBlocked() then
		releaseCarried(false)
		return
	end
	if not alignPos or not alignPos.Parent then
		alignPos = primary:FindFirstChild(ALIGN_POS_NAME)
	end
	if not alignOri or not alignOri.Parent then
		alignOri = primary:FindFirstChild(ALIGN_ORI_NAME)
	end

	rotCurrent = rotCurrent:Lerp(rotTarget, math.min(1, dt * ROTATE_SPEED))
	local cf = camera.CFrame
	local origin, look = cf.Position, cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-3 then
		lastYaw = math.atan2(-flat.X, -flat.Z)
	end
	-- не заталкивать объект в стену: цель не дальше препятствия перед камерой
	local char = player.Character
	carryFilter[1] = char or camera
	carryFilter[2] = inst
	carryFilter[3] = camera
	carryParams.FilterDescendantsInstances = carryFilter
	local reach = distance + carriedRadius
	local hit = workspace:Raycast(origin, look * reach, carryParams)
	local wanted = distance
	if hit then
		wanted = math.clamp(hit.Distance - carriedRadius, 1.2, distance)
	end
	local target = origin + look * wanted
	if alignPos then
		alignPos.Position = target
		if not alignPos.Enabled then
			alignPos.Enabled = true
		end
	end
	if alignOri then
		alignOri.CFrame = CFrame.Angles(0, lastYaw, 0) * rotCurrent
		if not alignOri.Enabled then
			alignOri.Enabled = true
		end
	end

	local marker = findSlot(carriedKind, primary.Position)
	updateGhost(marker)
	setAttachHint(marker ~= nil)
	setPrompt(marker and "attach" or "", nil)
	setOutline(inst)
end

local function hoverStep()
	if carried or isBlocked() then
		if hovered then
			hovered = nil
		end
		if not carried then
			setOutline(nil)
			setPrompt("", nil)
		end
		return
	end
	local char = player.Character
	hoverFilter[1] = char or camera
	hoverFilter[2] = camera
	hoverParams.FilterDescendantsInstances = hoverFilter
	local cf = camera.CFrame
	local hit = workspace:Raycast(cf.Position, cf.LookVector * REACH, hoverParams)
	local target = nil
	if hit then
		local root = grabbableFrom(hit.Instance)
		if root then
			local carrier = root:GetAttribute("GrabCarrier")
			if carrier == nil or carrier == player.UserId then
				target = root
			end
		end
	end
	hovered = target
	setOutline(target)
	if target then
		local label = target:GetAttribute("GrabLabel")
		if holdingWeapon() then
			setPrompt("locked", "Уберите оружие из рук")
		else
			setPrompt("take", type(label) == "string" and label or "")
		end
	else
		setPrompt("", nil)
	end
end

-- Каждый кадр: перенос — каждый кадр, наведение — 20 раз/с
local function step(dt)
	camera = workspace.CurrentCamera or camera
	if carried then
		carryStep(dt)
	else
		hoverAcc = hoverAcc + dt
		if hoverAcc >= HOVER_INTERVAL then
			hoverAcc = 0
			hoverStep()
		end
	end
	if promptScale.Scale < 0.999 then
		promptScale.Scale = promptScale.Scale + (1 - promptScale.Scale) * math.min(1, dt * 16)
	end
	local rotateRow = hintRows.rotate
	if rotateRow then
		local hot = rotateFlash > os.clock()
		local color = hot and UI.Colors.accent or UI.Colors.text
		if rotateRow.label.TextColor3 ~= color then
			rotateRow.label.TextColor3 = color
		end
	end
	slowAcc = slowAcc + dt
	if slowAcc >= SLOW_INTERVAL then
		slowAcc = 0
		-- страховка: если отпускание кнопки потерялось (потеря фокуса окна), не держать ЛКМ занятой
		if clickHeld and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			clickHeld = false
			clickAt = os.clock()
		end
		-- сервер мог не получить «отпустить» (потеря пакета) — повторить, пока он считает объект нашим
		local p = pendingRelease
		if p then
			if not p.inst.Parent or p.inst:GetAttribute("GrabCarrier") ~= player.UserId or p.tries >= 3 then
				pendingRelease = nil
			elseif os.clock() - p.at > RELEASE_RETRY then
				p.at = os.clock()
				p.tries = p.tries + 1
				remote:FireServer("release", p.inst)
			end
		end
	end
end

-- API ------------------------------------------------------------------------------------------------

function GrabClient.IsGrabbing()
	return carried ~= nil
end

-- Истина, если ЛКМ сейчас занята переносом: объект уже в руках либо под прицелом есть объект и в
-- руках не оружие. WeaponClient по этому признаку не бьёт и не выбрасывает предмет.
function GrabClient.WantsClick()
	if carried ~= nil or clickHeld then
		return true
	end
	if os.clock() - clickAt < 0.15 then
		return true
	end
	if hovered == nil or not hovered.Parent then
		return false
	end
	return not holdingWeapon() and not isBlocked()
end

-- Объект в руках или под прицелом
function GrabClient.GetTarget()
	return carried or hovered
end

function GrabClient.Init(c)
	C = c
	UI = C.UI
	remote = Net.Get("GrabAction")
	camera = workspace.CurrentCamera
	buildUI()

	for _, marker in ipairs(CollectionService:GetTagged(SLOT_TAG)) do
		markers[marker] = true
	end
	CollectionService:GetInstanceAddedSignal(SLOT_TAG):Connect(function(marker)
		markers[marker] = true
	end)
	CollectionService:GetInstanceRemovedSignal(SLOT_TAG):Connect(function(marker)
		markers[marker] = nil
	end)

	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = workspace.CurrentCamera or camera
		if highlight then
			highlight.Parent = camera
		end
		if ghost and ghostShown then
			ghost.Parent = camera
		end
	end)

	player.CharacterAdded:Connect(function()
		endCarry()
		hovered = nil
		setPrompt("", nil)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		-- в первом лице курсор заблокирован по центру: клики по интерфейсу невозможны
		if processed and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			return
		end
		if carried then
			clickHeld = true
			releaseCarried(false)
		elseif hovered and hovered.Parent and not isBlocked() and not holdingWeapon() then
			clickHeld = true
			startGrab(hovered)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and clickHeld then
			clickHeld = false
			clickAt = os.clock()
		end
	end)
	-- колесо мыши: расстояние до объекта (HUD не переключает слоты, пока идёт перенос)
	UserInputService.InputChanged:Connect(function(input, processed)
		if processed or not carried or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		distance = math.clamp(distance + input.Position.Z * DIST_STEP, DIST_MIN, DIST_MAX)
	end)

	RunService:BindToRenderStep("LastRunGrab", Enum.RenderPriority.Camera.Value + 3, function(dt)
		local ok, err = pcall(step, dt)
		if not ok and not warned then
			warned = true
			warn("[Перенос] " .. tostring(err))
		end
	end)
end

return GrabClient
