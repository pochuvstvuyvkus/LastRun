-- Логические препятствия для автобуса (деревья, дома, машины, ворота, стены границ, зоны топей).
-- Хранятся в сетке, чтобы автобус быстро проверял столкновения.
-- ob: shape ("circle"|"box"), x, z, r | fx, fz, rx, rz, hx, hz, bound, hard, model, gate, gateText,
--     zone (+slow) — зона замедления без столкновения, damageMult, kind, chunkId, removed
local Obstacles = {}

local CELL = 40
local grid = {} -- ["x:z"] = { [ob] = true }
local byChunk = {} -- [chunkId] = { ob, ... }

local function key(cx, cz)
	return cx .. ":" .. cz
end

local function cellsFor(ob)
	local r = ob.bound
	local x0 = math.floor((ob.x - r) / CELL)
	local x1 = math.floor((ob.x + r) / CELL)
	local z0 = math.floor((ob.z - r) / CELL)
	local z1 = math.floor((ob.z + r) / CELL)
	return x0, x1, z0, z1
end

local function insert(ob, chunkId)
	local x0, x1, z0, z1 = cellsFor(ob)
	for cx = x0, x1 do
		for cz = z0, z1 do
			local k = key(cx, cz)
			local cell = grid[k]
			if not cell then
				cell = {}
				grid[k] = cell
			end
			cell[ob] = true
		end
	end
	ob.chunkId = chunkId
	ob.removed = nil
	if chunkId ~= nil then
		local list = byChunk[chunkId]
		if not list then
			list = {}
			byChunk[chunkId] = list
		end
		table.insert(list, ob)
	end
	return ob
end

function Obstacles.Init() end

-- opts: hard (bool, по умолчанию true), model (Instance), damageMult, kind, gate, gateText, zone, slow
function Obstacles.AddCircle(chunkId, x, z, r, opts)
	local ob = opts or {}
	ob.shape = "circle"
	ob.x = x
	ob.z = z
	ob.r = math.max(0.1, r or 1)
	ob.bound = ob.r
	if ob.hard == nil then
		ob.hard = not ob.zone
	end
	return insert(ob, chunkId)
end

-- cf — CFrame центра (поворот по Y учитывается), halfX/halfZ — половины размеров
function Obstacles.AddBox(chunkId, cf, halfX, halfZ, opts)
	local ob = opts or {}
	ob.shape = "box"
	ob.x = cf.Position.X
	ob.z = cf.Position.Z
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	flat = flat.Unit
	ob.fx = flat.X -- "вперёд" коробки (-Z локально)
	ob.fz = flat.Z
	ob.rx = -flat.Z -- "вправо" коробки
	ob.rz = flat.X
	ob.hx = math.max(0.1, halfX or 1)
	ob.hz = math.max(0.1, halfZ or 1)
	ob.bound = math.sqrt(ob.hx * ob.hx + ob.hz * ob.hz)
	if ob.hard == nil then
		ob.hard = not ob.zone
	end
	return insert(ob, chunkId)
end

function Obstacles.Remove(ob)
	if not ob or ob.removed or not ob.bound then
		return
	end
	ob.removed = true
	local x0, x1, z0, z1 = cellsFor(ob)
	for cx = x0, x1 do
		for cz = z0, z1 do
			local k = key(cx, cz)
			local cell = grid[k]
			if cell then
				cell[ob] = nil
				if next(cell) == nil then
					grid[k] = nil
				end
			end
		end
	end
end

function Obstacles.ClearChunk(chunkId)
	if chunkId == nil then
		return
	end
	local list = byChunk[chunkId]
	if list then
		for _, ob in ipairs(list) do
			Obstacles.Remove(ob)
		end
		byChunk[chunkId] = nil
	end
end

function Obstacles.Clear()
	grid = {}
	byChunk = {}
end

function Obstacles.Query(x, z, radius)
	local out = {}
	local seen = {}
	radius = radius or 0
	local x0 = math.floor((x - radius) / CELL)
	local x1 = math.floor((x + radius) / CELL)
	local z0 = math.floor((z - radius) / CELL)
	local z1 = math.floor((z + radius) / CELL)
	for cx = x0, x1 do
		for cz = z0, z1 do
			local cell = grid[key(cx, cz)]
			if cell then
				for ob in pairs(cell) do
					if not seen[ob] and not ob.removed then
						seen[ob] = true
						table.insert(out, ob)
					end
				end
			end
		end
	end
	return out
end

-- Пересекает ли круг (x, z, pad) препятствие
function Obstacles.Hits(ob, x, z, pad)
	pad = pad or 0
	if ob.shape == "circle" then
		local dx = x - ob.x
		local dz = z - ob.z
		local rr = ob.r + pad
		return dx * dx + dz * dz < rr * rr
	else
		local dx = x - ob.x
		local dz = z - ob.z
		local lx = dx * ob.rx + dz * ob.rz
		local lz = dx * ob.fx + dz * ob.fz
		return math.abs(lx) < ob.hx + pad and math.abs(lz) < ob.hz + pad
	end
end

-- Есть ли твёрдое препятствие в круге (зоны замедления не считаются)
function Obstacles.IsBlocked(x, z, pad)
	for _, ob in ipairs(Obstacles.Query(x, z, (pad or 0) + 30)) do
		if ob.hard and not ob.zone and Obstacles.Hits(ob, x, z, pad) then
			return true
		end
	end
	return false
end

return Obstacles
