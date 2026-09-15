-- Перенос крупных объектов (v5, docs/SPEC_v5.md 2.7): колёса и стены лежат в мире физическими
-- объектами (тег LR_Grabbable, атрибуты GrabKind/GrabLabel/GrabCarrier) и переносятся мышью.
-- Порядок работы: клиент шлёт GrabAction("grab", объект) → сервер проверяет заезд, жизнь, тег,
-- расстояние до головы и занятость, отдаёт сетевое владение несущему и ставит на главную деталь
-- AlignPosition/AlignOrientation (режим OneAttachment). Цель констрейнтов каждый кадр задаёт
-- клиент-владелец (client/GrabClient) — сервер их только создаёт и убирает.
-- GrabAction("attach") передаёт объект автобусу (Bus.TryAttachGrabbed, если функция уже есть).
-- Отпускание: по запросу, при смерти, обмороке, сне, посадке в кресло, выходе игрока, удалении
-- объекта и при отходе дальше 20 studs. Упавший под карту объект возвращается на последнее
-- нормальное место; далеко брошенный «засыпает» (закрепляется), пока к нему не подойдут.
-- Столкновения: детали объектов — в группе LR_Grabbable, части персонажей — в LR_Players,
-- эти две группы не сталкиваются, поэтому объект в руках не толкает несущего.
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Grab = {}

local S
local PD

local TAG = "LR_Grabbable"
local OBJECT_GROUP = "LR_Grabbable"
local PLAYER_GROUP = "LR_Players"
local ATTACH_NAME = "GrabAttachment"
local ALIGN_POS_NAME = "GrabAlignPosition"
local ALIGN_ORI_NAME = "GrabAlignOrientation"
local WELD_NAME = "GrabWeld"

local GRAB_RANGE = 12 -- studs от головы до объекта
local RANGE_SLACK = 2 -- запас на задержку сети
local HOLD_RANGE = 20 -- дальше объект выпадает из рук
local ATTACH_RANGE = 14 -- на всякий случай: дальше слота автобуса «прикрепить» не сработает
local ACTION_GAP = 0.15
local BURST_WINDOW = 2
local BURST_MAX = 14
local CHECK_INTERVAL = 0.2
local REST_INTERVAL = 1
local FALL_Y = -40 -- земля в мире около нуля: ниже этого объект считается провалившимся
local FALL_DROP = 120
local FALL_RESET = 20
local FREEZE_DISTANCE = 250
local THAW_DISTANCE = 150
local ABANDON_DISTANCE = 400 -- дальше этого от всех игроков и от автобуса объект считается брошенным
local ABANDON_TIME = 300 -- и через столько секунд убирается (кроме сборки в депо)

local ORANGE = Color3.fromRGB(255, 170, 80)
local GREY = Color3.fromRGB(200, 200, 200)

-- Масса и трение по виду предмета (плотность считается от объёма главной детали)
local PHYSICS = {
	bus_wheel = { mass = 20, friction = 0.85, elasticity = 0.15 },
	plate_wood = { mass = 9, friction = 0.6, elasticity = 0.1 },
	plate_metal = { mass = 16, friction = 0.45, elasticity = 0.05 },
}
local DEFAULT_PHYSICS = { mass = 10, friction = 0.6, elasticity = 0.08 }

local objects = {} -- [inst] = entry
local carrying = {} -- [player] = inst
local rate = {} -- [player] = { last, windowStart, count }
local charConns = {} -- [player] = { RBXScriptConnection, ... }
local checkAcc, restAcc = 0, 0
local groupsReady = false

-- Общее ------------------------------------------------------------------------------------------

local function notify(player, text, color)
	if PD and PD.Notify and player and player.Parent then
		PD.Notify(player, text, color or GREY)
	end
end

local function runActive()
	local run = S and S.Run
	if not run or run.Mode == nil then
		return true
	end
	return run.Mode == "run"
end

local function partsOf(inst)
	local list = {}
	if inst:IsA("BasePart") then
		table.insert(list, inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

local function primaryOf(inst)
	if inst:IsA("BasePart") then
		return inst
	end
	if not inst:IsA("Model") then
		return nil
	end
	if inst.PrimaryPart and inst.PrimaryPart:IsDescendantOf(inst) then
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
	if best then
		inst.PrimaryPart = best
	end
	return best
end

-- Габариты объекта: размер по осям главной детали и радиус описанной сферы
local function extentsOf(inst)
	if inst:IsA("Model") then
		local ok, _, size = pcall(inst.GetBoundingBox, inst)
		if ok and typeof(size) == "Vector3" and size.Magnitude > 0 then
			return size, size.Magnitude / 2
		end
	end
	local primary = primaryOf(inst)
	local size = primary and primary.Size or Vector3.one
	return size, size.Magnitude / 2
end

-- Объём детали по её форме (для плотности)
local function partVolume(part)
	local s = part.Size
	if part:IsA("WedgePart") or part:IsA("CornerWedgePart") then
		return s.X * s.Y * s.Z * 0.5
	end
	if part:IsA("Part") then
		if part.Shape == Enum.PartType.Ball then
			local r = math.min(s.X, s.Y, s.Z) / 2
			return (4 / 3) * math.pi * r ^ 3
		elseif part.Shape == Enum.PartType.Cylinder then
			local r = math.min(s.Y, s.Z) / 2
			return math.pi * r * r * s.X
		end
	end
	return s.X * s.Y * s.Z
end

-- Группы столкновений ----------------------------------------------------------------------------

local function registerGroup(name)
	local okCheck, registered = pcall(PhysicsService.IsCollisionGroupRegistered, PhysicsService, name)
	if okCheck and registered then
		return true
	end
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, name)
	-- группа могла быть создана раньше: проверяем, что имя работает
	return (pcall(PhysicsService.CollisionGroupsAreCollidable, PhysicsService, name, "Default"))
end

local function setCollidable(a, b, want)
	local ok, current = pcall(PhysicsService.CollisionGroupsAreCollidable, PhysicsService, a, b)
	if ok and current == want then
		return
	end
	pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, a, b, want)
end

-- Свои группы ведут себя как Default со всеми чужими группами (Bus, World, Zombies, Debris и др.),
-- но объект в руках и персонажи друг друга не толкают
local function syncGroups()
	if not registerGroup(OBJECT_GROUP) or not registerGroup(PLAYER_GROUP) then
		return false
	end
	local ok, list = pcall(PhysicsService.GetRegisteredCollisionGroups, PhysicsService)
	if ok and type(list) == "table" then
		for _, group in ipairs(list) do
			local name = type(group) == "table" and group.name or nil
			if type(name) == "string" and name ~= OBJECT_GROUP and name ~= PLAYER_GROUP then
				local okDefault, collide = pcall(PhysicsService.CollisionGroupsAreCollidable, PhysicsService, "Default", name)
				if okDefault then
					setCollidable(OBJECT_GROUP, name, collide)
					setCollidable(PLAYER_GROUP, name, collide)
				end
			end
		end
	end
	setCollidable(OBJECT_GROUP, OBJECT_GROUP, true)
	setCollidable(PLAYER_GROUP, PLAYER_GROUP, true)
	setCollidable(OBJECT_GROUP, PLAYER_GROUP, false)
	groupsReady = true
	return true
end

local function setCharacterGroup(char)
	if not groupsReady then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and d.CollisionGroup ~= PLAYER_GROUP then
			d.CollisionGroup = PLAYER_GROUP
		end
	end
end

-- Физика объекта ---------------------------------------------------------------------------------

local function applyPhysics(entry)
	local inst, primary = entry.inst, entry.primary
	if not primary or not primary.Parent then
		return
	end
	local physics = PHYSICS[entry.kind] or DEFAULT_PHYSICS
	local volume = math.max(0.02, partVolume(primary))
	local density = math.clamp(physics.mass / volume, 0.05, 100)
	local props = PhysicalProperties.new(density, physics.friction, physics.elasticity, 1, 1)
	-- главная деталь несёт массу и столкновения; остальное приварено и невесомо
	local size, _ = extentsOf(inst)
	local big = { size.X, size.Y, size.Z }
	table.sort(big)
	local own = { primary.Size.X, primary.Size.Y, primary.Size.Z }
	table.sort(own)
	local primaryCovers = own[3] >= big[3] * 0.6 and own[2] >= big[2] * 0.6
	local connected = {}
	for _, p in ipairs(primary:GetConnectedParts(true)) do
		connected[p] = true
	end
	for _, p in ipairs(entry.parts) do
		if p.Parent then
			p.Anchored = entry.frozen == true and p == primary
			if p ~= primary and not connected[p] then
				local weld = Instance.new("WeldConstraint")
				weld.Name = WELD_NAME
				weld.Part0 = primary
				weld.Part1 = p
				weld.Parent = p
			end
			if groupsReady then
				p.CollisionGroup = OBJECT_GROUP
			end
			p.CanTouch = false
			p.CanQuery = true
			p.Massless = p ~= primary
			local collides = p == primary
			if not primaryCovers then
				local s = p.Size
				collides = collides or math.max(s.X, s.Y, s.Z) >= 0.5
			end
			p.CanCollide = collides
			if collides then
				p.CustomPhysicalProperties = props
			end
		end
	end
	if entry.frozen then
		primary.Anchored = true
	end
end

-- Разорвать связи с чужими деталями (например, если добычу приварили к полу автобуса):
-- иначе сетевое владение ушло бы вместе со всей сборкой
local function detachExternal(entry)
	local inside = {}
	for _, p in ipairs(entry.parts) do
		inside[p] = true
	end
	for _, p in ipairs(entry.parts) do
		if p.Parent then
			for _, joint in ipairs(p:GetJoints()) do
				local a, b = nil, nil
				if joint:IsA("WeldConstraint") then
					a, b = joint.Part0, joint.Part1
				elseif joint:IsA("JointInstance") then
					a, b = joint.Part0, joint.Part1
				end
				if a and b and (not inside[a] or not inside[b]) then
					joint:Destroy()
				end
			end
		end
	end
end

-- Реестр -----------------------------------------------------------------------------------------

local unregister, release

local function register(inst)
	local existing = objects[inst]
	if existing then
		return existing
	end
	if typeof(inst) ~= "Instance" or not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return nil
	end
	local primary = primaryOf(inst)
	if not primary then
		return nil
	end
	local _, radius = extentsOf(inst)
	local entry = {
		inst = inst,
		primary = primary,
		parts = partsOf(inst),
		kind = inst:GetAttribute("GrabKind") or inst:GetAttribute("ItemId") or inst.Name,
		radius = radius,
		lastValid = inst:GetPivot(),
		fallCount = 0,
		fallAt = 0,
		farChecks = 0,
		idleSince = os.clock(),
		frozen = false,
		conns = {},
	}
	objects[inst] = entry
	table.insert(entry.conns, inst.Destroying:Connect(function()
		unregister(inst)
	end))
	table.insert(entry.conns, primary.Destroying:Connect(function()
		unregister(inst)
	end))
	return entry
end

function unregister(inst)
	local entry = objects[inst]
	if not entry then
		return
	end
	objects[inst] = nil
	local player = entry.carrier
	if player then
		entry.carrier = nil
		if carrying[player] == inst then
			carrying[player] = nil
		end
	end
	for _, conn in ipairs(entry.conns) do
		conn:Disconnect()
	end
	entry.conns = {}
end

-- Найти объект по любой его детали
local function resolve(inst)
	if typeof(inst) ~= "Instance" then
		return nil
	end
	local cur = inst
	for _ = 1, 8 do
		if cur == nil or cur == workspace or cur == game then
			return nil
		end
		local entry = objects[cur]
		if entry then
			return entry
		end
		if CollectionService:HasTag(cur, TAG) then
			return register(cur)
		end
		cur = cur.Parent
	end
	return nil
end

-- Констрейнты ------------------------------------------------------------------------------------

local function removeConstraints(entry)
	local primary = entry.primary
	if primary and primary.Parent then
		for _, name in ipairs({ ALIGN_POS_NAME, ALIGN_ORI_NAME, ATTACH_NAME }) do
			local found = primary:FindFirstChild(name)
			if found then
				found:Destroy()
			end
		end
	end
	entry.alignPos, entry.alignOri = nil, nil
end

local function addConstraints(entry)
	local primary = entry.primary
	removeConstraints(entry)
	local mass = math.max(1, primary.AssemblyMass)
	local att = Instance.new("Attachment")
	att.Name = ATTACH_NAME
	att.Position = primary.CFrame:PointToObjectSpace(primary.AssemblyCenterOfMass)
	att.Parent = primary

	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = ALIGN_POS_NAME
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = att
	alignPos.ApplyAtCenterOfMass = true
	alignPos.RigidityEnabled = false
	alignPos.MaxForce = math.max(4000, mass * workspace.Gravity * 6)
	alignPos.MaxVelocity = 70
	alignPos.Responsiveness = 35
	alignPos.Position = att.WorldPosition
	alignPos.Parent = primary

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = ALIGN_ORI_NAME
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = att
	alignOri.RigidityEnabled = false
	alignOri.MaxTorque = math.max(8000, mass * 1500)
	alignOri.MaxAngularVelocity = 9
	alignOri.Responsiveness = 22
	alignOri.CFrame = primary.CFrame.Rotation
	alignOri.Parent = primary

	entry.alignPos, entry.alignOri = alignPos, alignOri
end

-- Взять / отпустить ------------------------------------------------------------------------------

local function thaw(entry)
	if not entry.frozen then
		return
	end
	entry.frozen = false
	entry.fallCount = 0
	if entry.primary and entry.primary.Parent then
		entry.primary.Anchored = false
	end
end

function release(entry, reason)
	if not entry then
		return
	end
	local player = entry.carrier
	entry.carrier = nil
	if player and carrying[player] == entry.inst then
		carrying[player] = nil
	end
	removeConstraints(entry)
	local inst, primary = entry.inst, entry.primary
	if inst.Parent then
		inst:SetAttribute("GrabCarrier", nil)
	end
	if primary and primary.Parent and primary:IsDescendantOf(workspace) and not primary.Anchored then
		pcall(primary.SetNetworkOwnershipAuto, primary)
	end
	entry.releasedAt = os.clock()
	if reason == "distance" and player then
		notify(player, "Слишком далеко — предмет выпал из рук", GREY)
	end
end

local function releasePlayer(player)
	local inst = carrying[player]
	carrying[player] = nil
	local entry = inst and objects[inst]
	if entry then
		release(entry, "player")
	end
end

local function allowAction(player, isRelease)
	local now = os.clock()
	local r = rate[player]
	if not r then
		r = { last = 0, windowStart = now, count = 0 }
		rate[player] = r
	end
	if now - r.windowStart > BURST_WINDOW then
		r.windowStart = now
		r.count = 0
	end
	r.count = r.count + 1
	if r.count > BURST_MAX then
		return false
	end
	if not isRelease and now - r.last < ACTION_GAP then
		return false
	end
	r.last = now
	return true
end

local function headOf(player)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
	return head, hum
end

local function handleGrab(player, inst)
	if not runActive() then
		return
	end
	local entry = resolve(inst)
	if not entry or not CollectionService:HasTag(entry.inst, TAG) then
		return
	end
	if entry.carrier == player then
		return
	end
	if entry.carrier then
		notify(player, "Этот предмет уже несёт " .. entry.carrier.DisplayName, GREY)
		return
	end
	local current = carrying[player]
	if current and objects[current] then
		return
	end
	if not PD.IsActive(player) then
		return
	end
	local head, hum = headOf(player)
	if not head or not hum then
		return
	end
	if hum.SeatPart then
		return
	end
	local primary = entry.primary
	if not primary or not primary.Parent or not primary:IsDescendantOf(workspace) then
		return
	end
	local distance = (head.Position - primary.Position).Magnitude - entry.radius
	if distance > GRAB_RANGE + RANGE_SLACK then
		notify(player, "Слишком далеко — подойдите ближе", GREY)
		return
	end
	thaw(entry)
	detachExternal(entry)
	applyPhysics(entry)
	local root = primary.AssemblyRootPart
	if root and not (root == entry.inst or root:IsDescendantOf(entry.inst)) then
		warn("[Перенос] объект соединён с чужой сборкой: " .. entry.inst:GetFullName())
		return
	end
	local canOwn = primary:CanSetNetworkOwnership()
	if not canOwn then
		return
	end
	local ok = pcall(primary.SetNetworkOwner, primary, player)
	if not ok then
		return
	end
	addConstraints(entry)
	entry.carrier = player
	entry.farChecks = 0
	carrying[player] = entry.inst
	entry.inst:SetAttribute("GrabCarrier", player.UserId)
end

local function handleAttach(player, inst)
	local entry = resolve(inst) or (carrying[player] and objects[carrying[player]])
	if not entry or entry.carrier ~= player then
		return
	end
	if not PD.IsActive(player) then
		return
	end
	local bus = S.Bus
	-- функция появляется вместе с новым автобусом (агент BUS2); до тех пор — подсказка
	local tryAttach = bus and bus["TryAttachGrabbed"]
	if type(tryAttach) ~= "function" then
		notify(player, "Сюда пока нельзя прикрепить", ORANGE)
		return
	end
	local ok, result, message = pcall(tryAttach, player, entry.inst)
	if not ok then
		warn("[Перенос] Bus.TryAttachGrabbed: " .. tostring(result))
		return
	end
	if result then
		-- успех: автобус забирает объект себе; если он остался — просто отпустить
		if objects[entry.inst] then
			release(entry, "attached")
		end
	else
		notify(player, type(message) == "string" and message ~= "" and message
			or "Рядом нет свободного места на автобусе", ORANGE)
	end
end

local function handleAction(player, action, inst)
	if type(action) ~= "string" or typeof(player) ~= "Instance" then
		return
	end
	if typeof(inst) ~= "Instance" then
		inst = nil
	end
	if not allowAction(player, action == "release") then
		return
	end
	if action == "grab" then
		handleGrab(player, inst)
	elseif action == "release" then
		local entry = inst and resolve(inst)
		if entry and entry.carrier == player then
			release(entry, "player")
		elseif not entry then
			releasePlayer(player)
		end
	elseif action == "attach" then
		handleAttach(player, inst)
	end
end

-- Проверки в цикле -------------------------------------------------------------------------------

local function nearestPlayerDistance(position)
	local best = math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local d = (root.Position - position).Magnitude
			if d < best then
				best = d
			end
		end
	end
	return best
end

local function groundBelow(entry)
	local primary = entry.primary
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { entry.inst }
	for _, name in ipairs({ "Loot", "Zombies", "Effects" }) do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local reach = entry.radius + 8
	return workspace:Raycast(primary.Position, Vector3.new(0, -reach, 0), params) ~= nil
end

local function restore(entry)
	local now = os.clock()
	if now - entry.fallAt > FALL_RESET then
		entry.fallCount = 0
	end
	entry.fallAt = now
	entry.fallCount = entry.fallCount + 1
	if entry.carrier then
		release(entry, "fell")
	end
	local primary = entry.primary
	primary.AssemblyLinearVelocity = Vector3.zero
	primary.AssemblyAngularVelocity = Vector3.zero
	if entry.lastValid then
		entry.inst:PivotTo(entry.lastValid + Vector3.new(0, 1.5, 0))
	end
	-- вернули трижды подряд — под объектом больше нет мира: закрепить, пока кто-нибудь не подойдёт
	if entry.fallCount >= 3 or not entry.lastValid then
		entry.frozen = true
		primary.Anchored = true
	end
end

local function checkCarried(entry)
	local player = entry.carrier
	if not player or not player.Parent then
		release(entry, "left")
		return
	end
	if not runActive() or not PD.IsActive(player) then
		release(entry, "state")
		return
	end
	local head, hum = headOf(player)
	if not head or not hum or hum.SeatPart then
		release(entry, "state")
		return
	end
	local primary = entry.primary
	if not primary.Parent or not primary:IsDescendantOf(workspace) or primary.Anchored then
		release(entry, "gone")
		return
	end
	if (head.Position - primary.Position).Magnitude > HOLD_RANGE then
		entry.farChecks = entry.farChecks + 1
		if entry.farChecks >= 2 then
			release(entry, "distance")
		end
	else
		entry.farChecks = 0
	end
end

-- API --------------------------------------------------------------------------------------------

-- Сделать модель (или деталь) переносимым объектом: физика, тег, атрибуты. Возвращает inst.
function Grab.MakeGrabbable(inst, kind, label)
	if typeof(inst) ~= "Instance" or not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return inst
	end
	local entry = objects[inst] or register(inst)
	if not entry then
		return inst
	end
	entry.parts = partsOf(inst)
	if type(kind) == "string" and kind ~= "" then
		entry.kind = kind
	end
	inst:SetAttribute("GrabKind", entry.kind)
	inst:SetAttribute("GrabLabel", type(label) == "string" and label or (inst:GetAttribute("GrabLabel") or entry.kind))
	inst:SetAttribute("GrabCarrier", nil)
	entry.frozen = false
	applyPhysics(entry)
	entry.lastValid = inst:GetPivot()
	if not CollectionService:HasTag(inst, TAG) then
		CollectionService:AddTag(inst, TAG)
	end
	return inst
end

-- Кто несёт объект (принимается сам объект или любая его деталь)
function Grab.GetCarrier(inst)
	local entry = resolve(inst)
	return entry and entry.carrier or nil
end

-- Что несёт игрок
function Grab.IsCarrying(player)
	local inst = carrying[player]
	if inst and objects[inst] then
		return inst
	end
	return nil
end

-- Принудительно отпустить объект (например, перед тем как его израсходовать)
function Grab.ForceRelease(inst)
	local entry = resolve(inst)
	if entry then
		release(entry, "force")
	end
end

-- Слот автобуса для объекта ищет сам автобус; здесь только радиус для проверок
function Grab.AttachRange()
	return ATTACH_RANGE
end

function Grab.Update(dt)
	if not groupsReady and syncGroups() then
		-- группы удалось создать не с первого раза: расставить их задним числом
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character then
				setCharacterGroup(plr.Character)
			end
		end
		for _, entry in pairs(objects) do
			applyPhysics(entry)
		end
	end
	checkAcc = checkAcc + dt
	restAcc = restAcc + dt
	local doCheck = checkAcc >= CHECK_INTERVAL
	local doRest = restAcc >= REST_INTERVAL
	if not doCheck and not doRest then
		return
	end
	if doCheck then
		checkAcc = 0
	end
	if doRest then
		restAcc = 0
	end
	for inst, entry in pairs(objects) do
		local primary = entry.primary
		if not inst.Parent or not primary or not primary.Parent or not inst:IsDescendantOf(workspace) then
			if not inst.Parent or not primary or not primary.Parent then
				unregister(inst)
			end
		elseif not CollectionService:HasTag(inst, TAG) then
			-- тег сняли (объект израсходован автобусом) — больше не наш
			release(entry, "untagged")
			unregister(inst)
		else
			if doCheck then
				if entry.carrier then
					checkCarried(entry)
				end
				local position = primary.Position
				if position.Y < FALL_Y or (entry.lastValid and position.Y < entry.lastValid.Y - FALL_DROP) then
					restore(entry)
				end
			end
			if doRest then
				local position = primary.Position
				local near = entry.carrier and 0 or nearestPlayerDistance(position)
				local busPos = S.Bus.Position
				local busDist = typeof(busPos) == "Vector3" and (busPos - position).Magnitude or math.huge
				local now = os.clock()
				-- в депо идёт сборка автобуса: лежащие колёса не трогаем, пока заезд не начался
				if entry.carrier or S.Run.State == "Depot" or near < ABANDON_DISTANCE or busDist < ABANDON_DISTANCE then
					entry.idleSince = now
				elseif now - entry.idleSince > ABANDON_TIME then
					inst:Destroy()
				end
			end
			if doRest and not entry.carrier and inst.Parent and primary.Parent then
				local position = primary.Position
				local near = nearestPlayerDistance(position)
				if entry.frozen then
					if near < THAW_DISTANCE and groundBelow(entry) then
						thaw(entry)
					end
				elseif near > FREEZE_DISTANCE then
					-- далеко от всех: закрепить, чтобы объект не провалился вместе с выгруженным чанком
					entry.frozen = true
					primary.Anchored = true
				elseif primary.AssemblyLinearVelocity.Magnitude < 1.5 and position.Y > FALL_Y and groundBelow(entry) then
					entry.lastValid = inst:GetPivot()
					entry.fallCount = 0
				end
			end
		end
	end
end

function Grab.Init(services)
	S = services
	PD = S.PlayerData
	syncGroups()

	local function onCharacter(player, char)
		releasePlayer(player)
		setCharacterGroup(char)
		local conns = charConns[player]
		if conns then
			for _, conn in ipairs(conns) do
				conn:Disconnect()
			end
		end
		conns = {}
		charConns[player] = conns
		table.insert(conns, char.DescendantAdded:Connect(function(d)
			if groupsReady and d:IsA("BasePart") and d.CollisionGroup ~= PLAYER_GROUP then
				d.CollisionGroup = PLAYER_GROUP
			end
		end))
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			table.insert(conns, hum.Died:Connect(function()
				releasePlayer(player)
			end))
		end
	end

	local function onPlayer(player)
		player.CharacterAdded:Connect(function(char)
			onCharacter(player, char)
		end)
		player.CharacterRemoving:Connect(function()
			releasePlayer(player)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		releasePlayer(player)
		rate[player] = nil
		local conns = charConns[player]
		if conns then
			for _, conn in ipairs(conns) do
				conn:Disconnect()
			end
		end
		charConns[player] = nil
	end)

	-- объекты, помеченные тегом мимо MakeGrabbable, тоже попадают в реестр
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
		register(inst)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
		local entry = objects[inst]
		if entry then
			release(entry, "untagged")
			unregister(inst)
		end
	end)
	for _, inst in ipairs(CollectionService:GetTagged(TAG)) do
		register(inst)
	end

	Net.Get("GrabAction").OnServerEvent:Connect(function(player, action, inst)
		local ok, err = pcall(handleAction, player, action, inst)
		if not ok then
			warn("[Перенос] " .. tostring(err))
		end
	end)
end

return Grab
