-- Мелкие помощники, общие для сервера и клиента
local Util = {}

function Util.New(className, props, children)
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

-- Деталь с разумными значениями по умолчанию (закреплена, гладкая)
function Util.Part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	local parent = nil
	for k, v in pairs(props) do
		if k == "Parent" then
			parent = v
		elseif k == "Shape" and type(v) == "string" then
			p.Shape = Enum.PartType[v]
		else
			p[k] = v
		end
	end
	if parent then
		p.Parent = parent
	end
	return p
end

function Util.Wedge(props)
	local p = Instance.new("WedgePart")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	local parent = nil
	for k, v in pairs(props) do
		if k == "Parent" then
			parent = v
		else
			p[k] = v
		end
	end
	if parent then
		p.Parent = parent
	end
	return p
end

function Util.Weld(a, b)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
	return w
end

function Util.Clamp(x, a, b)
	if x < a then
		return a
	elseif x > b then
		return b
	end
	return x
end

function Util.Lerp(a, b, t)
	return a + (b - a) * t
end

function Util.Smooth(t)
	t = Util.Clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function Util.Approach(current, target, maxDelta)
	if current < target then
		return math.min(current + maxDelta, target)
	else
		return math.max(current - maxDelta, target)
	end
end

function Util.LerpColor(a, b, t)
	return a:Lerp(b, Util.Clamp(t, 0, 1))
end

-- Взвешенный выбор: list = { {значение, вес}, ... }
function Util.Weighted(rng, list)
	local total = 0
	for _, e in ipairs(list) do
		total = total + e[2]
	end
	if total <= 0 then
		return nil
	end
	local r = rng:NextNumber() * total
	for _, e in ipairs(list) do
		r = r - e[2]
		if r <= 0 then
			return e[1]
		end
	end
	return list[#list][1]
end

function Util.Now()
	return workspace:GetServerTimeNow()
end

function Util.FlatDist(a, b)
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function Util.Flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

function Util.FormatTime(sec)
	sec = math.max(0, math.floor(sec))
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

function Util.Round(x, digits)
	local m = 10 ^ (digits or 0)
	return math.floor(x * m + 0.5) / m
end

-- Поиск модели-предка в папке (например, зомби в workspace.Zombies)
function Util.ModelIn(inst, folder)
	local cur = inst
	while cur and cur.Parent do
		if cur.Parent == folder then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

function Util.GetCharacterFromPart(part)
	local Players = game:GetService("Players")
	local cur = part
	while cur and cur ~= workspace do
		if cur:IsA("Model") then
			local plr = Players:GetPlayerFromCharacter(cur)
			if plr then
				return cur, plr
			end
		end
		cur = cur.Parent
	end
	return nil, nil
end

function Util.AliveHumanoid(character)
	if not character then
		return nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		return hum
	end
	return nil
end

-- Поворот сустава в осях родительской детали (работает и для R6, и для R15)
-- baseC0 — исходный C0 сустава; rot — CFrame-поворот в пространстве Part0
function Util.JointTransform(baseC0, rot)
	local baseRot = baseC0 - baseC0.Position
	return baseRot:Inverse() * rot * baseRot
end

return Util
