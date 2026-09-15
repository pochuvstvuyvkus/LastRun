-- Дорога: плавная кривая, заданная длиной пути s.
-- s — расстояние вдоль дороги (studs), d — смещение вправо от центра.
local RoadPath = {}
RoadPath.__index = RoadPath

local STEP = 8

-- straightPoints: список значений s, около которых дорога прямая (станции, депо, конечная)
function RoadPath.new(seed, lengthStuds, straightPoints)
	local self = setmetatable({}, RoadPath)
	local rng = Random.new(seed)
	local p1 = rng:NextNumber(0, math.pi * 2)
	local p2 = rng:NextNumber(0, math.pi * 2)
	local p3 = rng:NextNumber(0, math.pi * 2)
	local a1 = rng:NextNumber(0.4, 0.65)
	local a2 = rng:NextNumber(0.25, 0.4)
	local a3 = rng:NextNumber(0.08, 0.15)

	self.length = lengthStuds
	self.n = math.ceil((lengthStuds + 2400) / STEP)
	self.xs = {}
	self.zs = {}
	self.hs = {}

	local function straightWeight(s)
		local w = 1
		if s < 420 then
			w = 0
		elseif s < 900 then
			w = math.min(w, (s - 420) / 480)
		end
		for _, sp in ipairs(straightPoints or {}) do
			local dist = math.abs(s - sp)
			local k = math.clamp((dist - 220) / 380, 0, 1)
			w = math.min(w, k)
		end
		return w * w * (3 - 2 * w)
	end

	local x, z = 0, 0
	for i = 0, self.n do
		local s = i * STEP
		local h = (a1 * math.sin(s / 950 + p1) + a2 * math.sin(s / 390 + p2) + a3 * math.sin(s / 170 + p3))
		-- в начале маршрута нулевой курс, дальше — извилистая дорога
		h = h * straightWeight(s)
		self.xs[i] = x
		self.zs[i] = z
		self.hs[i] = h
		x = x + math.sin(h) * STEP
		z = z + math.cos(h) * STEP
	end
	return self
end

-- Возвращает позицию центра дороги (y = 0) и курс (радианы)
function RoadPath:Sample(s)
	if s <= 0 then
		local h = self.hs[0]
		return Vector3.new(self.xs[0] + math.sin(h) * s, 0, self.zs[0] + math.cos(h) * s), h
	end
	local f = s / STEP
	local i = math.floor(f)
	if i >= self.n then
		local h = self.hs[self.n]
		local extra = s - self.n * STEP
		return Vector3.new(self.xs[self.n] + math.sin(h) * extra, 0, self.zs[self.n] + math.cos(h) * extra), h
	end
	local t = f - i
	local x = self.xs[i] + (self.xs[i + 1] - self.xs[i]) * t
	local z = self.zs[i] + (self.zs[i + 1] - self.zs[i]) * t
	local h = self.hs[i] + (self.hs[i + 1] - self.hs[i]) * t
	return Vector3.new(x, 0, z), h
end

-- позиция, направление вперёд, направление вправо, курс
function RoadPath:Frame(s)
	local pos, h = self:Sample(s)
	local tangent = Vector3.new(math.sin(h), 0, math.cos(h))
	local right = tangent:Cross(Vector3.yAxis)
	return pos, tangent, right, h
end

function RoadPath:ToWorld(s, d, y)
	local pos, _, right = self:Frame(s)
	return pos + right * d + Vector3.new(0, y or 0, 0)
end

-- CFrame на дороге, смотрит вдоль дороги (с поворотом headingOffset вправо)
function RoadPath:CFrameAt(s, d, y, headingOffset)
	local pos, _, right, h = self:Frame(s)
	local heading = h - (headingOffset or 0)
	local look = Vector3.new(math.sin(heading), 0, math.cos(heading))
	local p = pos + right * (d or 0) + Vector3.new(0, y or 0, 0)
	return CFrame.lookAt(p, p + look)
end

-- Проекция точки на дорогу рядом с подсказкой hintS. Возвращает s, d.
-- Без hintS — грубый поиск по всей дороге, затем уточнение.
-- До начала (s < 0) и после конца проекция продолжается по прямой.
function RoadPath:Project(position, hintS, window)
	local last = self.n - 1
	local i0, i1
	if type(hintS) ~= "number" or hintS ~= hintS then
		local coarse, bestC = 0, math.huge
		for i = 0, last, 16 do
			local dx = position.X - self.xs[i]
			local dz = position.Z - self.zs[i]
			local d2 = dx * dx + dz * dz
			if d2 < bestC then
				bestC = d2
				coarse = i
			end
		end
		i0 = coarse - 24
		i1 = coarse + 24
	else
		window = window or 400
		i0 = math.floor((hintS - window) / STEP)
		i1 = math.floor((hintS + window) / STEP)
	end
	i0 = math.clamp(i0, 0, last)
	i1 = math.clamp(i1, i0, last)
	local bestI, bestD2 = i0, math.huge
	for i = i0, i1 do
		local dx = position.X - self.xs[i]
		local dz = position.Z - self.zs[i]
		local d2 = dx * dx + dz * dz
		if d2 < bestD2 then
			bestD2 = d2
			bestI = i
		end
	end
	local ax, az = self.xs[bestI], self.zs[bestI]
	local bx, bz = self.xs[bestI + 1], self.zs[bestI + 1]
	local sx, sz = bx - ax, bz - az
	local len2 = sx * sx + sz * sz
	local t = 0
	if len2 > 0 then
		t = ((position.X - ax) * sx + (position.Z - az) * sz) / len2
		local tMin = bestI == 0 and -math.huge or 0
		local tMax = bestI == last and math.huge or 1
		t = math.clamp(t, tMin, tMax)
	end
	local s = (bestI + t) * STEP
	local pos, _, right = self:Frame(s)
	local rel = position - pos
	local d = rel.X * right.X + rel.Z * right.Z
	return s, d
end

return RoadPath
