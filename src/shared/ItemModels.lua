-- Модели предметов из деталей (без загружаемых ассетов): инструмент в руке (Tool), вид от первого
-- лица (client/ViewModel), иконки (ViewportFrame) и добыча на земле.
-- Пространство модели как у оружия (WeaponModels): начало координат — точка хвата, -Z = вперёд, +Y = вверх.
-- Все детали: CanCollide/CanQuery/CanTouch = false, Massless; мелкие — без теней.
-- Стиль удержания (hold):
--   "hand"   — в ладони (начало координат — ладонь);
--   "handle" — за ручку сверху, предмет висит ниже (канистра, фонарь, аптечка, ящик);
--   "carry"  — двумя руками перед собой (начало координат — центр предмета);
--   "long"   — длинный предмет за один конец (доски, труба, стрелы);
--   "throw"  — метательное (бутылка с тряпкой).
local Shared = script.Parent
local Items = require(Shared.Items)

local ItemModels = {}

local rgb = Color3.fromRGB
local V = Vector3.new
local CF = CFrame.new
local rad = math.rad

local M = Enum.Material
local PLASTIC = M.SmoothPlastic
local METAL = M.Metal
local RUST = M.CorrodedMetal
local WOOD = M.Wood
local PLANKS = M.WoodPlanks
local FABRIC = M.Fabric
local GLASS = M.Glass
local NEON = M.Neon
local SLATE = M.Slate
local FOIL = M.Foil
local DPLATE = M.DiamondPlate
local RUBBER = M.Rubber

-- материалы новых версий движка — через pcall, чтобы старый клиент не падал
local function material(name, fallback)
	local ok, m = pcall(function()
		return Enum.Material[name]
	end)
	if ok and m then
		return m
	end
	return fallback
end
local CARDBOARD = material("Cardboard", PLASTIC)
local LEATHER = material("Leather", FABRIC)

-- Цвета
local STEEL = rgb(168, 170, 174)
local STEEL_LIGHT = rgb(215, 218, 222)
local STEEL_DARK = rgb(70, 72, 76)
local BLACK = rgb(28, 28, 30)
local RUSTC = rgb(128, 76, 40)
local BRASS = rgb(196, 156, 72)
local COPPER = rgb(184, 110, 60)
local ROPEC = rgb(170, 140, 90)
local WHITE = rgb(236, 234, 226)
local GOLD = rgb(236, 186, 60)

local ALIGN_Z = CFrame.Angles(0, rad(90), 0) -- ось цилиндра (X) -> Z
local ALIGN_Y = CFrame.Angles(0, 0, rad(90)) -- ось цилиндра (X) -> Y

local function rot(r)
	if not r then
		return CFrame.identity
	end
	return CFrame.Angles(rad(r.X), rad(r.Y), rad(r.Z))
end

local function spec(shape, size, cf, color, mat, tr)
	return { shape = shape, size = size, cf = cf, color = color, mat = mat or PLASTIC, tr = tr }
end

-- брусок
local function B(size, pos, color, mat, r, tr)
	return spec("Block", size, CF(pos) * rot(r), color, mat, tr)
end

-- брусок по готовому CFrame
local function BC(size, cf, color, mat, tr)
	return spec("Block", size, cf, color, mat, tr)
end

-- цилиндры вдоль Z / Y / X
local function CZ(len, d, pos, color, mat, r, tr)
	return spec("Cylinder", V(len, d, d), CF(pos) * rot(r) * ALIGN_Z, color, mat, tr)
end

local function CY(len, d, pos, color, mat, r, tr)
	return spec("Cylinder", V(len, d, d), CF(pos) * rot(r) * ALIGN_Y, color, mat, tr)
end

local function CX(len, d, pos, color, mat, r, tr)
	return spec("Cylinder", V(len, d, d), CF(pos) * rot(r), color, mat, tr)
end

local function BALL(d, pos, color, mat, tr)
	return spec("Ball", V(d, d, d), CF(pos), color, mat, tr)
end

local function WEDGE(size, pos, color, mat, r)
	return spec("Wedge", size, CF(pos) * rot(r), color, mat)
end

local function named(name, s)
	s.name = name
	return s
end

-- Кольцо из n брусков радиуса r вокруг оси axis ("X" | "Y" | "Z") с центром center
local function ring(list, n, r, thick, width, center, axis, color, mat, phase)
	local seg = 2 * r * math.tan(math.pi / n) * 1.08
	for i = 0, n - 1 do
		local a = (i + (phase or 0)) / n * math.pi * 2
		if axis == "Y" then
			table.insert(list, BC(V(seg, width, thick), CF(center) * CFrame.Angles(0, a, 0) * CF(0, 0, r), color, mat))
		elseif axis == "Z" then
			table.insert(list, BC(V(seg, thick, width), CF(center) * CFrame.Angles(0, 0, a) * CF(0, r, 0), color, mat))
		else
			table.insert(list, BC(V(width, thick, seg), CF(center) * CFrame.Angles(a, 0, 0) * CF(0, r, 0), color, mat))
		end
	end
end

local function append(list, more)
	for _, v in ipairs(more) do
		table.insert(list, v)
	end
	return list
end

-- Смещение модели относительно хвата руки персонажа (Tool.Grip) по стилю удержания.
-- Хват R15: -Z вдоль пальцев, +Y — от ладони вперёд.
local GRIP_BY_STYLE = {
	hand = CFrame.identity,
	throw = CFrame.identity,
	long = CFrame.identity,
	handle = CFrame.Angles(rad(90), 0, 0),
	carry = CF(-0.95, -0.1, -0.45) * CFrame.Angles(rad(12), 0, 0),
}

-- Поворот для показа на земле: плоские и круглые предметы кладутся плашмя
local FLAT_X = CFrame.Angles(rad(90), 0, 0)
local FLAT_Z = CFrame.Angles(0, 0, rad(90))

local SPECS = {}

------------------------------------------------------------------------------------------------
-- Топливо
------------------------------------------------------------------------------------------------

-- Кусок угля: неровные грани, редкие блестящие сколы
SPECS.coal = function()
	local c1, c2, c3 = rgb(30, 30, 33), rgb(44, 44, 48), rgb(22, 22, 24)
	return {
		hold = "hand",
		handle = B(V(0.55, 0.42, 0.5), V(0, 0, 0), c1, SLATE, V(12, 20, 8)),
		parts = {
			B(V(0.42, 0.34, 0.38), V(0.2, 0.12, -0.1), c2, SLATE, V(-20, 35, 15)),
			B(V(0.36, 0.3, 0.34), V(-0.18, -0.06, 0.12), c1, SLATE, V(30, -15, -20)),
			B(V(0.3, 0.26, 0.3), V(0.05, 0.2, 0.15), c3, SLATE, V(10, 50, 30)),
			B(V(0.26, 0.22, 0.28), V(-0.12, 0.16, -0.18), c2, SLATE, V(-35, 10, 25)),
			B(V(0.24, 0.2, 0.22), V(0.22, -0.14, 0.14), c3, SLATE, V(25, 60, -10)),
			B(V(0.1, 0.02, 0.08), V(0.14, 0.25, -0.02), rgb(96, 96, 108), METAL, V(-10, 30, 15)),
			B(V(0.08, 0.02, 0.07), V(-0.2, 0.08, -0.26), rgb(90, 90, 100), METAL, V(60, 10, 0)),
		},
	}
end

-- Канистра: широкие бока с рельефом-«крестом», тройная ручка, носик с крышкой, наклейка
SPECS.gas_can = function()
	local red, dark = rgb(172, 34, 28), rgb(120, 22, 18)
	local parts = {
		B(V(1.07, 0.08, 0.52), V(0, -0.26, 0), dark, METAL),
		B(V(1.07, 0.08, 0.52), V(0, -1.64, 0), dark, METAL),
		B(V(0.12, 1.2, 0.04), V(0, -0.95, 0.27), dark, METAL, V(0, 0, 36)),
		B(V(0.12, 1.2, 0.04), V(0, -0.95, 0.27), dark, METAL, V(0, 0, -36)),
		B(V(0.12, 1.2, 0.04), V(0, -0.95, -0.27), dark, METAL, V(0, 0, 36)),
		B(V(0.12, 1.2, 0.04), V(0, -0.95, -0.27), dark, METAL, V(0, 0, -36)),
		B(V(0.6, 0.12, 0.14), V(0.1, 0, 0), BLACK, PLASTIC),
		B(V(0.1, 0.22, 0.12), V(-0.16, -0.13, 0), red, METAL),
		B(V(0.1, 0.22, 0.12), V(0.1, -0.13, 0), red, METAL),
		B(V(0.1, 0.22, 0.12), V(0.36, -0.13, 0), red, METAL),
		CY(0.34, 0.18, V(-0.42, -0.14, 0), STEEL_DARK, METAL, V(0, 0, 38)),
		CY(0.12, 0.23, V(-0.53, -0.01, 0), rgb(40, 40, 42), PLASTIC, V(0, 0, 38)),
		B(V(0.5, 0.36, 0.02), V(0.12, -1.05, 0.265), rgb(232, 196, 58), PLASTIC),
		B(V(0.22, 0.22, 0.025), V(0.12, -1.05, 0.27), BLACK, PLASTIC, V(0, 0, 45)),
		B(V(0.3, 0.2, 0.02), V(-0.3, -1.4, -0.265), RUSTC, RUST),
	}
	return {
		hold = "handle",
		handle = B(V(1.05, 1.4, 0.5), V(0, -0.95, 0), red, METAL),
		parts = parts,
	}
end

-- Бочка топлива: рёбра жёсткости, закраины, пробка, знак опасности, ржавчина
SPECS.fuel_barrel = function()
	local blue, dark = rgb(38, 84, 150), rgb(26, 58, 108)
	return {
		hold = "carry",
		handle = CY(2.3, 1.7, V(0, 0, 0), blue, METAL),
		parts = {
			CY(0.1, 1.76, V(0, 0.62, 0), dark, METAL),
			CY(0.1, 1.76, V(0, -0.62, 0), dark, METAL),
			CY(0.08, 1.74, V(0, 1.12, 0), STEEL_DARK, METAL),
			CY(0.08, 1.74, V(0, -1.12, 0), STEEL_DARK, METAL),
			CY(0.03, 1.5, V(0, 1.16, 0), rgb(52, 60, 70), METAL),
			CY(0.08, 0.28, V(0.45, 1.19, 0.2), STEEL, METAL),
			CY(0.06, 0.18, V(-0.5, 1.18, -0.15), STEEL, METAL),
			B(V(0.52, 0.52, 0.04), V(0, 0.15, 0.85), rgb(236, 196, 50), PLASTIC),
			B(V(0.3, 0.3, 0.05), V(0, 0.15, 0.86), BLACK, PLASTIC, V(0, 0, 45)),
			B(V(0.05, 0.5, 0.36), V(0.85, -0.35, 0.1), RUSTC, RUST),
			B(V(0.36, 0.3, 0.05), V(-0.3, -0.8, -0.84), RUSTC, RUST),
			B(V(0.05, 0.24, 0.3), V(-0.85, 0.4, -0.2), rgb(110, 70, 40), RUST),
		},
		rest = CFrame.identity,
	}
end

------------------------------------------------------------------------------------------------
-- Еда и напитки
------------------------------------------------------------------------------------------------

-- Консервы: жесть, этикетка с полосой, закраины, крышка с кольцом
SPECS.canned_food = function()
	return {
		hold = "hand",
		handle = CY(0.8, 0.62, V(0, 0, 0), STEEL, METAL),
		parts = {
			CY(0.52, 0.635, V(0, -0.02, 0), rgb(168, 58, 38), PLASTIC),
			CY(0.1, 0.64, V(0, 0.1, 0), rgb(234, 222, 190), PLASTIC),
			CY(0.05, 0.645, V(0, -0.2, 0), rgb(236, 180, 60), PLASTIC),
			CY(0.05, 0.64, V(0, 0.39, 0), STEEL_LIGHT, METAL),
			CY(0.05, 0.64, V(0, -0.39, 0), STEEL_LIGHT, METAL),
			CY(0.02, 0.5, V(0, 0.41, 0), rgb(190, 192, 196), METAL),
			B(V(0.16, 0.02, 0.1), V(0, 0.425, 0.13), STEEL_LIGHT, METAL),
			CY(0.03, 0.08, V(0, 0.43, 0.06), STEEL_DARK, METAL),
		},
	}
end

-- Чипсы: фольгированный пакет с запаянными краями, логотип и окошко
SPECS.chips = function()
	local yellow = rgb(236, 190, 40)
	return {
		hold = "hand",
		handle = B(V(0.9, 1.0, 0.26), V(0, 0, 0), yellow, FOIL),
		parts = {
			B(V(0.8, 0.8, 0.34), V(0, 0, 0), rgb(226, 178, 34), FOIL),
			B(V(0.92, 0.1, 0.1), V(0, 0.55, 0), rgb(200, 200, 205), FOIL),
			B(V(0.92, 0.1, 0.1), V(0, -0.55, 0), rgb(200, 200, 205), FOIL),
			B(V(0.5, 0.32, 0.02), V(0, 0.14, -0.175), rgb(200, 40, 34), PLASTIC),
			B(V(0.3, 0.1, 0.022), V(0, 0.14, -0.18), WHITE, PLASTIC),
			B(V(0.34, 0.16, 0.02), V(0, -0.24, -0.175), rgb(228, 210, 150), PLASTIC),
			BALL(0.09, V(-0.06, -0.24, -0.18), rgb(214, 170, 70), PLASTIC),
			BALL(0.08, V(0.08, -0.22, -0.18), rgb(206, 160, 60), PLASTIC),
		},
	}
end

-- Бутылка воды: прозрачный пластик, вода, ребристое дно, этикетка, крышка
SPECS.water = function()
	local clear = rgb(170, 210, 240)
	return {
		hold = "hand",
		handle = CY(0.82, 0.42, V(0, -0.06, 0), clear, GLASS, nil, 0.45),
		parts = {
			CY(0.62, 0.36, V(0, -0.14, 0), rgb(80, 140, 210), GLASS, nil, 0.35),
			CY(0.3, 0.43, V(0, -0.02, 0), rgb(50, 110, 196), PLASTIC),
			CY(0.06, 0.44, V(0, -0.02, 0), WHITE, PLASTIC),
			CY(0.04, 0.43, V(0, -0.38, 0), clear, GLASS, nil, 0.3),
			CY(0.14, 0.34, V(0, 0.42, 0), clear, GLASS, nil, 0.45),
			CY(0.12, 0.2, V(0, 0.55, 0), clear, GLASS, nil, 0.4),
			CY(0.12, 0.22, V(0, 0.66, 0), rgb(36, 90, 196), PLASTIC),
			CY(0.03, 0.26, V(0, 0.59, 0), rgb(36, 90, 196), PLASTIC),
		},
	}
end

-- Термос: стальная колба, кожаный пояс, крышка-чашка, откидная ручка
SPECS.coffee = function()
	return {
		hold = "hand",
		handle = CY(1.0, 0.46, V(0, -0.06, 0), rgb(122, 126, 132), METAL),
		parts = {
			CY(0.5, 0.475, V(0, -0.1, 0), rgb(96, 64, 40), LEATHER),
			CY(0.04, 0.48, V(0, 0.16, 0), STEEL_LIGHT, METAL),
			CY(0.04, 0.48, V(0, -0.36, 0), STEEL_LIGHT, METAL),
			CY(0.26, 0.5, V(0, 0.57, 0), rgb(46, 48, 52), PLASTIC),
			CY(0.04, 0.52, V(0, 0.45, 0), rgb(34, 34, 36), PLASTIC),
			CY(0.06, 0.2, V(0, 0.72, 0), rgb(34, 34, 36), PLASTIC),
			B(V(0.07, 0.46, 0.1), V(0.33, -0.08, 0), BLACK, PLASTIC),
			B(V(0.12, 0.06, 0.09), V(0.28, 0.14, 0), BLACK, PLASTIC),
			B(V(0.12, 0.06, 0.09), V(0.28, -0.3, 0), BLACK, PLASTIC),
			CY(0.03, 0.44, V(0, -0.57, 0), rgb(60, 62, 66), METAL),
		},
	}
end

-- Энергетик: тёмная банка, яркая полоса и молния, крышка с язычком
SPECS.energy_drink = function()
	local green = rgb(60, 222, 120)
	return {
		hold = "hand",
		handle = CY(0.88, 0.46, V(0, 0, 0), rgb(34, 36, 40), METAL),
		parts = {
			CY(0.24, 0.47, V(0, 0.06, 0), green, PLASTIC),
			CY(0.03, 0.472, V(0, -0.14, 0), green, PLASTIC),
			B(V(0.07, 0.28, 0.02), V(0.03, 0.06, -0.236), rgb(255, 226, 60), PLASTIC, V(0, 0, 28)),
			B(V(0.07, 0.2, 0.02), V(-0.04, -0.05, -0.236), rgb(255, 226, 60), PLASTIC, V(0, 0, -28)),
			CY(0.06, 0.4, V(0, 0.47, 0), STEEL_LIGHT, METAL),
			CY(0.02, 0.34, V(0, 0.5, 0), STEEL, METAL),
			B(V(0.12, 0.02, 0.07), V(0, 0.515, 0.08), STEEL_LIGHT, METAL),
			CY(0.05, 0.38, V(0, -0.46, 0), STEEL, METAL),
		},
	}
end

-- Травяной чай: эмалированная кружка с синим ободком, чай и листик, ручка
SPECS.herbal_tea = function()
	local enamel = rgb(232, 230, 218)
	return {
		hold = "hand",
		handle = CY(0.6, 0.56, V(0, 0, 0), enamel, PLASTIC),
		parts = {
			CY(0.04, 0.575, V(0, 0.29, 0), rgb(40, 56, 110), PLASTIC),
			CY(0.04, 0.575, V(0, -0.29, 0), rgb(40, 56, 110), PLASTIC),
			CY(0.02, 0.5, V(0, 0.25, 0), rgb(122, 80, 40), GLASS, nil, 0.1),
			B(V(0.14, 0.012, 0.07), V(0.08, 0.262, 0.05), rgb(80, 150, 60), PLASTIC, V(0, 30, 0)),
			B(V(0.1, 0.012, 0.05), V(-0.1, 0.262, -0.06), rgb(96, 170, 70), PLASTIC, V(0, -40, 0)),
			B(V(0.07, 0.34, 0.08), V(0.36, 0, 0), enamel, PLASTIC),
			B(V(0.12, 0.06, 0.08), V(0.31, 0.14, 0), enamel, PLASTIC),
			B(V(0.12, 0.06, 0.08), V(0.31, -0.14, 0), enamel, PLASTIC),
			B(V(0.14, 0.12, 0.02), V(-0.12, -0.05, -0.285), rgb(170, 60, 50), PLASTIC),
		},
	}
end

------------------------------------------------------------------------------------------------
-- Медицина
------------------------------------------------------------------------------------------------

-- Бинт: рулон с тёмной втулкой, свисающий конец и зажим
SPECS.bandage = function()
	return {
		hold = "hand",
		handle = CX(0.5, 0.56, V(0, 0, 0), WHITE, FABRIC),
		parts = {
			CX(0.52, 0.2, V(0, 0, 0), rgb(150, 142, 130), FABRIC),
			CX(0.53, 0.1, V(0, 0, 0), rgb(60, 58, 54), PLASTIC),
			CX(0.06, 0.575, V(0.12, 0, 0), rgb(222, 218, 206), FABRIC),
			B(V(0.42, 0.02, 0.36), V(0, -0.24, 0.26), rgb(240, 238, 230), FABRIC, V(-55, 0, 0)),
			B(V(0.42, 0.02, 0.24), V(0, -0.42, 0.42), rgb(236, 232, 222), FABRIC, V(-80, 0, 0)),
			B(V(0.08, 0.05, 0.12), V(0.14, 0.28, 0), STEEL, METAL),
			B(V(0.04, 0.03, 0.14), V(0.14, 0.3, -0.03), STEEL_LIGHT, METAL),
		},
	}
end

-- Аптечка: пластиковый кейс с крестами, защёлками и ручкой (широкие стороны смотрят на ±Z)
SPECS.medkit = function()
	local red, dark = rgb(204, 42, 40), rgb(150, 28, 26)
	return {
		hold = "handle",
		handle = B(V(0.5, 0.08, 0.1), V(0, 0, 0), BLACK, PLASTIC),
		parts = {
			B(V(1.2, 0.78, 0.5), V(0, -0.55, 0), red, PLASTIC),
			B(V(1.22, 0.04, 0.52), V(0, -0.34, 0), dark, PLASTIC),
			B(V(1.22, 0.06, 0.52), V(0, -0.93, 0), dark, PLASTIC),
			B(V(0.42, 0.13, 0.02), V(0, -0.58, 0.26), WHITE, PLASTIC),
			B(V(0.13, 0.42, 0.02), V(0, -0.58, 0.26), WHITE, PLASTIC),
			B(V(0.42, 0.13, 0.02), V(0, -0.58, -0.26), WHITE, PLASTIC),
			B(V(0.13, 0.42, 0.02), V(0, -0.58, -0.26), WHITE, PLASTIC),
			B(V(0.1, 0.14, 0.06), V(0.38, -0.34, 0.27), STEEL_DARK, METAL),
			B(V(0.1, 0.14, 0.06), V(-0.38, -0.34, 0.27), STEEL_DARK, METAL),
			B(V(0.06, 0.16, 0.08), V(0.22, -0.08, 0), BLACK, PLASTIC),
			B(V(0.06, 0.16, 0.08), V(-0.22, -0.08, 0), BLACK, PLASTIC),
			B(V(0.3, 0.16, 0.02), V(-0.36, -0.82, 0.26), rgb(230, 230, 224), PLASTIC),
		},
	}
end

-- Шприц с адреналином: прозрачный корпус, жёлтая жидкость, поршень, игла
SPECS.adrenaline = function()
	return {
		hold = "hand",
		handle = CY(0.8, 0.17, V(0, 0, 0), rgb(226, 232, 238), GLASS, nil, 0.35),
		parts = {
			CY(0.58, 0.13, V(0, -0.07, 0), rgb(255, 214, 50), NEON, nil, 0.25),
			CY(0.12, 0.175, V(0, -0.24, 0), rgb(230, 120, 40), PLASTIC),
			CY(0.34, 0.05, V(0, 0.56, 0), WHITE, PLASTIC),
			CY(0.03, 0.2, V(0, 0.74, 0), WHITE, PLASTIC),
			CY(0.06, 0.16, V(0, 0.28, 0), rgb(60, 60, 64), RUBBER),
			B(V(0.34, 0.03, 0.12), V(0, 0.4, 0), WHITE, PLASTIC),
			CY(0.08, 0.09, V(0, -0.44, 0), rgb(200, 200, 205), PLASTIC),
			named("Needle", CY(0.32, 0.022, V(0, -0.63, 0), STEEL_LIGHT, METAL)),
			B(V(0.01, 0.4, 0.03), V(0.085, 0.02, 0), rgb(70, 70, 76), PLASTIC),
		},
	}
end

------------------------------------------------------------------------------------------------
-- Патроны
------------------------------------------------------------------------------------------------

local function bulletsGrid(list, cols, rows, sx, sz, y, body, tip, len, d)
	for c = 1, cols do
		for r = 1, rows do
			local x = (c - (cols + 1) / 2) * sx
			local z = (r - (rows + 1) / 2) * sz
			table.insert(list, CY(len, d, V(x, y, z), body, METAL))
			table.insert(list, CY(len * 0.35, d * 0.8, V(x, y + len * 0.6, z), tip, METAL))
		end
	end
end

-- Лёгкие патроны: картонная коробка с открытой крышкой и рядами гильз
SPECS.ammo_light = function()
	local parts = {
		B(V(0.82, 0.14, 0.57), V(0, -0.02, 0), rgb(56, 48, 40), CARDBOARD),
		B(V(0.2, 0.08, 0.01), V(-0.2, -0.02, -0.29), rgb(230, 200, 80), PLASTIC),
		B(V(0.8, 0.02, 0.4), V(0, 0.38, 0.44), rgb(176, 136, 62), CARDBOARD, V(-62, 0, 0)),
	}
	bulletsGrid(parts, 3, 2, 0.24, 0.22, 0.24, BRASS, COPPER, 0.22, 0.1)
	return {
		hold = "hand",
		handle = B(V(0.8, 0.4, 0.55), V(0, 0, 0), rgb(186, 146, 70), CARDBOARD),
		parts = parts,
	}
end

-- Дробь: красная коробка с торчащими патронами (латунные донца)
SPECS.ammo_shell = function()
	local parts = {
		B(V(0.82, 0.12, 0.57), V(0, 0.02, 0), rgb(236, 220, 190), CARDBOARD),
		B(V(0.3, 0.06, 0.01), V(0.15, 0.02, -0.29), rgb(40, 40, 40), PLASTIC),
	}
	for c = 1, 2 do
		for r = 1, 2 do
			local x, z = (c - 1.5) * 0.36, (r - 1.5) * 0.26
			table.insert(parts, CY(0.36, 0.17, V(x, 0.3, z), rgb(186, 36, 30), PLASTIC))
			table.insert(parts, CY(0.08, 0.18, V(x, 0.14, z), BRASS, METAL))
			table.insert(parts, CY(0.02, 0.15, V(x, 0.485, z), rgb(150, 28, 24), PLASTIC))
		end
	end
	return {
		hold = "hand",
		handle = B(V(0.8, 0.4, 0.55), V(0, 0, 0), rgb(150, 30, 26), CARDBOARD),
		parts = parts,
	}
end

-- Винтовочные патроны: армейский металлический ящик с защёлкой и трафаретной полосой
SPECS.ammo_rifle = function()
	local olive, dark = rgb(72, 86, 52), rgb(52, 62, 38)
	return {
		hold = "hand",
		handle = B(V(0.9, 0.5, 0.45), V(0, 0, 0), olive, METAL),
		parts = {
			B(V(0.93, 0.07, 0.48), V(0, 0.28, 0), dark, METAL),
			B(V(0.1, 0.2, 0.07), V(0.47, 0.14, 0), STEEL_DARK, METAL),
			B(V(0.4, 0.05, 0.08), V(0, 0.34, 0), BLACK, PLASTIC),
			B(V(0.06, 0.06, 0.08), V(0.17, 0.33, 0), dark, METAL),
			B(V(0.06, 0.06, 0.08), V(-0.17, 0.33, 0), dark, METAL),
			B(V(0.52, 0.07, 0.01), V(0, 0.02, -0.23), rgb(230, 196, 70), PLASTIC),
			B(V(0.52, 0.07, 0.01), V(0, -0.1, -0.23), rgb(230, 196, 70), PLASTIC),
			B(V(0.93, 0.04, 0.47), V(0, -0.23, 0), dark, METAL),
		},
	}
end

-- Связка из трёх стрел: древки, стальные наконечники, оперение, обмотка
SPECS.arrow = function()
	local parts = {
		CZ(0.12, 0.26, V(0, 0, -0.35), ROPEC, FABRIC),
		CZ(0.1, 0.26, V(0, 0, 0.35), ROPEC, FABRIC),
	}
	local offs = { V(0, 0.07, 0), V(-0.07, -0.05, 0), V(0.07, -0.05, 0) }
	for i, o in ipairs(offs) do
		table.insert(parts, CZ(2.2, 0.06, V(o.X, o.Y, -0.3), rgb(150, 110, 70), WOOD))
		table.insert(parts, B(V(0.1, 0.03, 0.2), V(o.X, o.Y, -1.47), STEEL, METAL, V(0, 45, 0)))
		table.insert(parts, B(V(0.02, 0.14, 0.32), V(o.X, o.Y + 0.05, 0.62), i == 1 and rgb(190, 50, 45) or WHITE, FABRIC))
		table.insert(parts, B(V(0.14, 0.02, 0.32), V(o.X, o.Y, 0.62), WHITE, FABRIC))
	end
	return {
		hold = "long",
		handle = CZ(0.2, 0.2, V(0, 0, 0), ROPEC, FABRIC),
		parts = parts,
	}
end

-- Связка болтов: короткие толстые древки, четырёхгранные наконечники, чёрные лопасти
SPECS.bolt = function()
	local parts = {
		CZ(0.12, 0.28, V(0, 0, -0.2), ROPEC, FABRIC),
	}
	local offs = { V(0, 0.08, 0), V(-0.08, -0.05, 0), V(0.08, -0.05, 0) }
	for _, o in ipairs(offs) do
		table.insert(parts, CZ(1.5, 0.08, V(o.X, o.Y, -0.2), rgb(110, 90, 60), WOOD))
		table.insert(parts, B(V(0.12, 0.12, 0.22), V(o.X, o.Y, -1.02), STEEL_LIGHT, METAL, V(0, 0, 45)))
		table.insert(parts, B(V(0.02, 0.16, 0.26), V(o.X, o.Y, 0.44), BLACK, FABRIC))
		table.insert(parts, B(V(0.16, 0.02, 0.26), V(o.X, o.Y, 0.44), BLACK, FABRIC))
	end
	return {
		hold = "long",
		handle = CZ(0.16, 0.22, V(0, 0, 0.1), ROPEC, FABRIC),
		parts = parts,
	}
end

------------------------------------------------------------------------------------------------
-- Метательное
------------------------------------------------------------------------------------------------

-- Коктейль Молотова: бутылка с горючим, горлышко, заткнутая тряпка с обмоткой
SPECS.molotov = function()
	local glass = rgb(84, 124, 64)
	return {
		hold = "throw",
		handle = CY(0.72, 0.46, V(0, -0.12, 0), glass, GLASS, nil, 0.3),
		parts = {
			CY(0.5, 0.4, V(0, -0.22, 0), rgb(206, 124, 40), GLASS, nil, 0.15),
			CY(0.12, 0.38, V(0, 0.3, 0), glass, GLASS, nil, 0.3),
			CY(0.34, 0.18, V(0, 0.52, 0), glass, GLASS, nil, 0.25),
			CY(0.05, 0.21, V(0, 0.69, 0), glass, GLASS, nil, 0.2),
			CY(0.06, 0.2, V(0, 0.62, 0), ROPEC, FABRIC),
			named("Wick", B(V(0.2, 0.26, 0.18), V(0, 0.84, 0), rgb(216, 200, 164), FABRIC, V(0, 0, 14))),
			B(V(0.08, 0.36, 0.14), V(0.1, 0.62, 0.09), rgb(200, 184, 150), FABRIC, V(12, 0, 18)),
			B(V(0.22, 0.2, 0.02), V(0, -0.14, -0.235), rgb(228, 222, 196), PLASTIC),
		},
	}
end

------------------------------------------------------------------------------------------------
-- Материалы
------------------------------------------------------------------------------------------------

-- поворот «лицом вверх» для предметов, собранных лицом к камере (+Z)
local FLAT_UP = CFrame.Angles(rad(-90), 0, 0)

-- Металлолом: гнутая пластина, шестерёнка, болт, пятна ржавчины
SPECS.scrap = function()
	local gear = rgb(92, 94, 98)
	local parts = {
		B(V(0.5, 0.08, 0.48), V(0.52, -0.12, 0.02), RUSTC, RUST, V(0, 0, 38)),
		B(V(0.14, 0.09, 0.3), V(-0.28, 0.06, 0.14), STEEL_DARK, METAL),
		CY(0.2, 0.08, V(-0.28, 0.14, 0.2), STEEL, METAL),
		CY(0.06, 0.16, V(-0.28, 0.1, 0.2), STEEL_DARK, METAL),
		CY(0.07, 0.4, V(0.08, 0.09, -0.1), gear, METAL),
		CY(0.08, 0.12, V(0.08, 0.1, -0.1), STEEL_DARK, METAL),
		B(V(0.3, 0.02, 0.22), V(-0.25, 0.05, -0.18), rgb(150, 90, 50), RUST, V(0, 25, 0)),
	}
	ring(parts, 8, 0.23, 0.08, 0.07, V(0.08, 0.09, -0.1), "Y", gear, METAL)
	return {
		hold = "hand",
		handle = B(V(0.9, 0.08, 0.5), V(0, 0, 0), rgb(120, 118, 116), METAL, V(0, 0, 8)),
		parts = parts,
	}
end

-- Изолента: рулон с картонной втулкой (смотрит на камеру), отклеенный край
SPECS.tape = function()
	return {
		hold = "hand",
		handle = CZ(0.34, 0.8, V(0, 0, 0), rgb(118, 120, 126), FABRIC),
		parts = {
			CZ(0.35, 0.56, V(0, 0, 0), rgb(98, 100, 106), FABRIC),
			CZ(0.36, 0.44, V(0, 0, 0), rgb(172, 142, 92), CARDBOARD),
			CZ(0.37, 0.34, V(0, 0, 0), rgb(24, 24, 26), PLASTIC),
			B(V(0.3, 0.02, 0.34), V(0.06, -0.41, 0), rgb(118, 120, 126), FABRIC, V(0, 0, -8)),
			B(V(0.24, 0.02, 0.3), V(0.24, -0.47, 0), rgb(110, 112, 118), FABRIC, V(0, 0, -32)),
		},
		rest = FLAT_X,
	}
end

-- Доски: три доски разной длины, стянутые верёвкой, шляпки гвоздей
SPECS.planks = function()
	return {
		hold = "long",
		handle = B(V(0.55, 0.12, 2.4), V(0, 0, -0.9), rgb(150, 110, 70), PLANKS),
		parts = {
			B(V(0.5, 0.12, 2.3), V(0.04, 0.12, -0.95), rgb(132, 96, 60), PLANKS, V(0, 3, 0)),
			B(V(0.52, 0.12, 2.2), V(-0.03, -0.12, -0.85), rgb(164, 124, 80), PLANKS, V(0, -3, 0)),
			CY(0.03, 0.06, V(0.12, 0.19, -0.2), STEEL, METAL),
			CY(0.03, 0.06, V(-0.1, 0.19, -1.7), STEEL, METAL),
			CY(0.03, 0.06, V(0.15, 0.07, -1.95), STEEL, METAL),
			B(V(0.6, 0.4, 0.08), V(0, 0, -0.35), ROPEC, FABRIC),
			B(V(0.6, 0.4, 0.08), V(0, 0, -1.55), ROPEC, FABRIC),
			B(V(0.2, 0.125, 0.4), V(-0.12, 0.005, -1.1), rgb(104, 76, 48), WOOD),
		},
	}
end

-- Ткань: сложенные отрезы трёх цветов, свисающий угол
SPECS.cloth = function()
	return {
		hold = "hand",
		handle = B(V(0.9, 0.1, 0.7), V(0, 0, 0), rgb(200, 190, 170), FABRIC),
		parts = {
			B(V(0.86, 0.1, 0.66), V(0.02, 0.1, -0.01), rgb(170, 62, 50), FABRIC, V(0, 3, 0)),
			B(V(0.84, 0.1, 0.64), V(-0.02, 0.2, 0.01), rgb(90, 110, 140), FABRIC, V(0, -4, 0)),
			B(V(0.4, 0.04, 0.3), V(0.3, -0.1, 0.35), rgb(200, 190, 170), FABRIC, V(-40, 0, 0)),
			B(V(0.06, 0.32, 0.72), V(0.45, 0.1, 0), rgb(186, 176, 156), FABRIC),
		},
	}
end

-- Верёвка: бухта из двух витков, обмотка сверху (за неё держат), свисающий конец
SPECS.rope = function()
	local parts = {}
	ring(parts, 12, 0.36, 0.1, 0.12, V(0, -0.45, 0), "Z", ROPEC, FABRIC)
	ring(parts, 12, 0.27, 0.09, 0.11, V(0, -0.42, 0.08), "Z", rgb(156, 126, 80), FABRIC, 0.5)
	append(parts, {
		B(V(0.2, 0.22, 0.26), V(0, -0.1, 0.04), rgb(140, 112, 70), FABRIC),
		B(V(0.06, 0.42, 0.06), V(0.14, -0.92, 0.05), ROPEC, FABRIC, V(0, 0, 20)),
	})
	return {
		hold = "handle",
		handle = B(V(0.16, 0.12, 0.2), V(0, 0, 0.04), ROPEC, FABRIC),
		parts = parts,
		rest = FLAT_X,
	}
end

-- Пустая бутылка: зелёное стекло, горлышко, облезлая этикетка
SPECS.bottle = function()
	local g = rgb(96, 150, 96)
	return {
		hold = "hand",
		handle = CY(0.6, 0.36, V(0, -0.14, 0), g, GLASS, nil, 0.3),
		parts = {
			CY(0.12, 0.3, V(0, 0.2, 0), g, GLASS, nil, 0.3),
			CY(0.34, 0.14, V(0, 0.42, 0), g, GLASS, nil, 0.25),
			CY(0.05, 0.18, V(0, 0.6, 0), g, GLASS, nil, 0.2),
			CY(0.02, 0.33, V(0, -0.44, 0), rgb(70, 110, 70), GLASS, nil, 0.2),
			B(V(0.2, 0.16, 0.02), V(0, -0.12, -0.18), rgb(210, 200, 160), PLASTIC, nil, 0.1),
		},
	}
end

-- Лечебные травы: пучок стеблей с листьями и цветками, перевязанный бечёвкой
SPECS.herbs = function()
	local parts = {}
	local stems = { V(0, 0, 0), V(0.06, 0, 0.05), V(-0.06, 0, 0.04), V(0.04, 0, -0.06), V(-0.05, 0, -0.05) }
	for i, o in ipairs(stems) do
		table.insert(parts, CY(0.9, 0.035, V(o.X, 0.1, o.Z), rgb(86, 130, 60), PLASTIC, V((i - 3) * 6, 0, (i % 2 == 0) and 8 or -8)))
		table.insert(parts, B(V(0.18, 0.02, 0.1), V(o.X * 3, 0.5 + i * 0.03, o.Z * 3), rgb(90, 170, 80), PLASTIC, V(20, i * 70, 10)))
		table.insert(parts, B(V(0.14, 0.02, 0.08), V(o.X * 2.5, 0.35 + i * 0.02, o.Z * 2.5), rgb(70, 150, 64), PLASTIC, V(-25, i * 50 + 90, -10)))
	end
	table.insert(parts, BALL(0.07, V(0.08, 0.57, 0.02), rgb(230, 230, 120), PLASTIC))
	table.insert(parts, BALL(0.06, V(-0.1, 0.53, -0.04), rgb(210, 140, 210), PLASTIC))
	return {
		hold = "hand",
		handle = CY(0.14, 0.2, V(0, -0.1, 0), ROPEC, FABRIC),
		parts = parts,
	}
end

-- Батарейки: две батарейки с медными торцами и полосой
SPECS.battery = function()
	local parts = {}
	for _, z in ipairs({ 0.11, -0.11 }) do
		table.insert(parts, CX(0.56, 0.2, V(0, 0, z), rgb(40, 40, 42), METAL))
		table.insert(parts, CX(0.14, 0.205, V(0.19, 0, z), COPPER, METAL))
		table.insert(parts, CX(0.12, 0.206, V(-0.06, 0, z), rgb(232, 190, 40), PLASTIC))
		table.insert(parts, CX(0.05, 0.08, V(0.3, 0, z), STEEL_LIGHT, METAL))
	end
	return {
		hold = "hand",
		handle = B(V(0.5, 0.18, 0.4), V(0, 0, 0), rgb(40, 40, 42), PLASTIC, nil, 1),
		parts = parts,
	}
end

-- Пружина: витая спираль
SPECS.spring = function()
	local parts = {}
	local n, turns, r, h = 28, 3.5, 0.2, 0.8
	local chord = 2 * r * math.sin(math.pi * turns / n) * 1.15
	for i = 0, n - 1 do
		local a = i / n * turns * math.pi * 2
		local y = -h / 2 + (i + 0.5) / n * h
		table.insert(parts, BC(V(chord, 0.05, 0.05), CF(0, y, 0) * CFrame.Angles(0, a, 0) * CF(0, 0, r) * CFrame.Angles(0, 0, rad(7)), rgb(176, 176, 184), METAL))
	end
	return {
		hold = "hand",
		handle = CY(0.8, 0.1, V(0, 0, 0), rgb(176, 176, 184), METAL, nil, 1),
		parts = parts,
	}
end

-- Металлическая труба: тёмное нутро, муфта с резьбой, ржавчина
SPECS.pipe = function()
	return {
		hold = "long",
		handle = CZ(2.4, 0.34, V(0, 0, -0.8), rgb(120, 122, 128), METAL),
		parts = {
			CZ(2.42, 0.24, V(0, 0, -0.8), rgb(30, 30, 32), PLASTIC),
			CZ(0.22, 0.42, V(0, 0, -1.88), rgb(96, 98, 104), METAL),
			CZ(0.08, 0.38, V(0, 0, -1.72), rgb(80, 82, 86), METAL),
			CZ(0.16, 0.36, V(0, 0, 0.3), rgb(104, 106, 110), METAL),
			B(V(0.05, 0.2, 0.5), V(0.165, 0.02, -1.1), RUSTC, RUST),
			B(V(0.2, 0.05, 0.36), V(0, 0.165, -0.3), rgb(110, 70, 40), RUST),
		},
	}
end

-- Порох: жестяная банка с красной этикеткой, крышка и носик
SPECS.gunpowder = function()
	return {
		hold = "hand",
		handle = CY(0.76, 0.66, V(0, 0, 0), rgb(52, 50, 46), METAL),
		parts = {
			CY(0.36, 0.675, V(0, -0.04, 0), rgb(150, 30, 22), PLASTIC),
			CY(0.05, 0.68, V(0, 0.15, 0), rgb(20, 20, 20), PLASTIC),
			CY(0.08, 0.69, V(0, 0.4, 0), STEEL, METAL),
			CY(0.04, 0.69, V(0, -0.38, 0), STEEL, METAL),
			CY(0.12, 0.14, V(0.18, 0.49, 0), STEEL_DARK, METAL),
			B(V(0.18, 0.2, 0.02), V(0, -0.04, -0.34), rgb(250, 200, 50), PLASTIC),
			B(V(0.08, 0.08, 0.022), V(0, -0.04, -0.345), BLACK, PLASTIC, V(0, 0, 45)),
		},
	}
end

-- Микросхема: плата с чипами, конденсаторами, дорожками и контактами (лицом к камере)
SPECS.circuit = function()
	local gold = rgb(220, 180, 80)
	return {
		hold = "hand",
		handle = B(V(0.8, 0.6, 0.05), V(0, 0, 0), rgb(30, 110, 50), PLASTIC),
		parts = {
			B(V(0.26, 0.2, 0.06), V(-0.15, 0.06, 0.05), BLACK, PLASTIC),
			B(V(0.16, 0.14, 0.05), V(0.22, -0.12, 0.045), BLACK, PLASTIC),
			CZ(0.16, 0.09, V(0.25, 0.17, 0.1), rgb(40, 70, 170), PLASTIC),
			CZ(0.12, 0.07, V(0.1, 0.19, 0.08), rgb(170, 40, 40), PLASTIC),
			B(V(0.5, 0.02, 0.006), V(0, -0.2, 0.028), gold, FOIL),
			B(V(0.02, 0.3, 0.006), V(0.05, -0.05, 0.028), gold, FOIL),
			B(V(0.3, 0.02, 0.006), V(-0.2, -0.1, 0.028), gold, FOIL),
			B(V(0.62, 0.05, 0.04), V(0, -0.27, 0), gold, FOIL),
			B(V(0.06, 0.06, 0.03), V(-0.33, 0.24, 0.04), STEEL_LIGHT, METAL),
		},
		rest = FLAT_UP,
	}
end

------------------------------------------------------------------------------------------------
-- Инструменты и укрепления
------------------------------------------------------------------------------------------------

-- Ремкомплект: синий ящик с инструментами, крышка, защёлки, ключ на боку
SPECS.repair_kit = function()
	local blue, dark = rgb(40, 90, 160), rgb(28, 64, 118)
	return {
		hold = "handle",
		handle = B(V(0.56, 0.08, 0.1), V(0, 0, 0), BLACK, PLASTIC),
		parts = {
			B(V(1.2, 0.55, 0.55), V(0, -0.62, 0), blue, METAL),
			B(V(1.22, 0.14, 0.57), V(0, -0.28, 0), dark, METAL),
			B(V(0.06, 0.18, 0.08), V(0.25, -0.12, 0), STEEL_DARK, METAL),
			B(V(0.06, 0.18, 0.08), V(-0.25, -0.12, 0), STEEL_DARK, METAL),
			B(V(0.12, 0.16, 0.06), V(0.4, -0.38, 0.29), STEEL, METAL),
			B(V(0.12, 0.16, 0.06), V(-0.4, -0.38, 0.29), STEEL, METAL),
			B(V(0.5, 0.06, 0.02), V(0, -0.66, 0.285), STEEL_LIGHT, METAL),
			B(V(0.1, 0.14, 0.02), V(0.27, -0.66, 0.285), STEEL_LIGHT, METAL),
			B(V(0.1, 0.14, 0.02), V(-0.27, -0.66, 0.285), STEEL_LIGHT, METAL),
			B(V(0.3, 0.2, 0.02), V(0.3, -0.75, -0.285), rgb(220, 60, 40), PLASTIC),
			B(V(1.22, 0.04, 0.57), V(0, -0.89, 0), dark, METAL),
		},
	}
end

-- Фонарь: стеклянный колпак со светящейся лампой, решётка, крышка, дужка
SPECS.lantern = function()
	local frame = rgb(46, 48, 50)
	local parts = {
		CY(0.14, 0.56, V(0, -1.0, 0), frame, METAL),
		CY(0.55, 0.42, V(0, -0.64, 0), rgb(255, 232, 170), GLASS, nil, 0.45),
		named("Glow", BALL(0.2, V(0, -0.66, 0), rgb(255, 204, 100), NEON)),
		CY(0.16, 0.06, V(0, -0.84, 0), rgb(90, 90, 90), METAL),
		CY(0.14, 0.5, V(0, -0.3, 0), frame, METAL),
		CY(0.1, 0.26, V(0, -0.18, 0), frame, METAL),
		B(V(0.46, 0.04, 0.04), V(0, 0, 0), frame, METAL),
		B(V(0.04, 0.2, 0.04), V(0.23, -0.1, 0), frame, METAL),
		B(V(0.04, 0.2, 0.04), V(-0.23, -0.1, 0), frame, METAL),
	}
	for _, o in ipairs({ V(0.22, 0, 0), V(-0.22, 0, 0), V(0, 0, 0.22), V(0, 0, -0.22) }) do
		table.insert(parts, B(V(0.04, 0.56, 0.04), V(o.X, -0.64, o.Z), frame, METAL))
	end
	return {
		hold = "handle",
		handle = CY(0.06, 0.3, V(0, -0.02, 0), frame, METAL, nil, 1),
		parts = parts,
	}
end

-- Баррикада в свёртке: доски, ремни и моток колючей проволоки
SPECS.barricade = function()
	local parts = {
		B(V(1.6, 0.14, 0.34), V(0, 0.16, 0.05), rgb(150, 110, 70), PLANKS, V(0, 4, 0)),
		B(V(1.5, 0.14, 0.34), V(0.04, -0.16, -0.04), rgb(126, 92, 58), PLANKS, V(0, -5, 0)),
		B(V(0.1, 0.5, 0.46), V(0.52, 0, 0), ROPEC, FABRIC),
		B(V(0.1, 0.5, 0.46), V(-0.52, 0, 0), ROPEC, FABRIC),
		CX(1.7, 0.03, V(0, 0.26, 0.2), STEEL, METAL, V(0, 8, 0)),
		CX(1.7, 0.03, V(0, 0.26, -0.18), STEEL, METAL, V(0, -6, 0)),
	}
	for i = -3, 3 do
		table.insert(parts, B(V(0.02, 0.1, 0.02), V(i * 0.22, 0.28, 0.2), STEEL_LIGHT, METAL, V(45, 0, 45)))
	end
	return {
		hold = "carry",
		handle = B(V(1.55, 0.14, 0.36), V(0, 0, 0), rgb(138, 100, 64), PLANKS),
		parts = parts,
	}
end

-- Капкан: раскрытые дуги с зубьями, пружины, тарелка-спуск, цепь
SPECS.trap = function()
	local steel, dark = rgb(120, 120, 128), rgb(66, 66, 70)
	local parts = {
		CY(0.05, 0.3, V(0, 0.05, 0), rgb(130, 90, 60), RUST),
		B(V(1.1, 0.05, 0.1), V(0, 0.01, 0), dark, METAL),
		B(V(0.1, 0.05, 1.1), V(0, 0.01, 0), dark, METAL),
		CY(0.06, 0.16, V(0.55, 0.03, 0), steel, METAL),
		CY(0.06, 0.16, V(-0.55, 0.03, 0), steel, METAL),
	}
	ring(parts, 14, 0.46, 0.05, 0.06, V(0, 0.05, 0), "Y", steel, METAL)
	for i = 0, 13 do
		local a = i / 14 * math.pi * 2
		table.insert(parts, WEDGE(V(0.03, 0.12, 0.08), V(math.sin(a) * 0.44, 0.13, math.cos(a) * 0.44), rgb(160, 160, 168), METAL, V(0, math.deg(a), 0)))
	end
	for i = 1, 3 do
		table.insert(parts, CZ(0.03, 0.12, V(0.62 + i * 0.1, 0, 0), dark, METAL, V(0, 90 * (i % 2), 0)))
	end
	return {
		hold = "carry",
		handle = CY(0.04, 0.9, V(0, 0, 0), dark, METAL),
		parts = parts,
	}
end

------------------------------------------------------------------------------------------------
-- Детали автобуса
------------------------------------------------------------------------------------------------

-- Колесо: шина с протектором, боковина, ржавый диск с отверстиями, ступица, гайки (ось — к камере).
-- Размер как у колеса на автобусе (диаметр ≈ 4.6, ширина 1.5): что несёшь, то и встанет на ступицу.
SPECS.bus_wheel = function()
	local parts = {
		CZ(1.56, 3.83, V(0, 0, 0), rgb(40, 40, 42), RUBBER),
		CZ(1.62, 2.76, V(0, 0, 0), rgb(104, 98, 90), RUST),
		CZ(1.65, 2.3, V(0, 0, 0), rgb(84, 80, 74), METAL),
		CZ(1.86, 1.1, V(0, 0, 0), rgb(58, 56, 52), METAL),
		CZ(1.95, 0.46, V(0, 0, 0), rgb(40, 38, 36), METAL),
	}
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		table.insert(parts, CZ(1.98, 0.18, V(math.cos(a) * 0.37, math.sin(a) * 0.37, 0), STEEL, METAL))
		table.insert(parts, CZ(1.68, 0.37, V(math.cos(a + 0.52) * 0.89, math.sin(a + 0.52) * 0.89, 0), rgb(22, 22, 22), PLASTIC))
	end
	ring(parts, 16, 2.28, 0.15, 1.35, V(0, 0, 0), "Z", rgb(34, 34, 36), RUBBER)
	table.insert(parts, B(V(0.46, 0.31, 0.03), V(0.77, -0.69, 0.84), RUSTC, RUST))
	return {
		hold = "carry",
		handle = CZ(1.5, 4.6, V(0, 0, 0), rgb(28, 28, 30), RUBBER),
		parts = parts,
		rest = FLAT_X,
	}
end

-- Деревянный щит: четыре доски, две поперечины на гвоздях
SPECS.plate_wood = function()
	local parts = {}
	local cols = { rgb(140, 100, 60), rgb(126, 90, 54), rgb(152, 110, 68), rgb(134, 96, 58) }
	for i = 1, 4 do
		table.insert(parts, B(V(0.72, 2, 0.12), V(-1.11 + (i - 1) * 0.74, 0, 0), cols[i], PLANKS))
	end
	for _, y in ipairs({ 0.6, -0.6 }) do
		table.insert(parts, B(V(2.9, 0.26, 0.1), V(0, y, 0.1), rgb(112, 80, 48), PLANKS))
		for i = 1, 4 do
			table.insert(parts, CZ(0.03, 0.06, V(-1.11 + (i - 1) * 0.74, y, 0.16), STEEL_DARK, METAL))
		end
	end
	table.insert(parts, B(V(0.3, 0.5, 0.02), V(0.8, -0.2, -0.065), rgb(80, 60, 40), WOOD))
	return {
		hold = "carry",
		handle = B(V(2.9, 1.9, 0.06), V(0, 0, 0), rgb(120, 86, 52), PLANKS, nil, 1),
		parts = parts,
		rest = FLAT_UP,
	}
end

-- Стальной лист: рифлёный металл, окантовка, болты по углам, ржавые подтёки
SPECS.plate_metal = function()
	local edge = rgb(86, 90, 96)
	local parts = {
		B(V(3.04, 0.12, 0.16), V(0, 0.98, 0), edge, METAL),
		B(V(3.04, 0.12, 0.16), V(0, -0.98, 0), edge, METAL),
		B(V(0.12, 2, 0.16), V(1.46, 0, 0), edge, METAL),
		B(V(0.12, 2, 0.16), V(-1.46, 0, 0), edge, METAL),
		B(V(0.06, 0.9, 0.02), V(-0.6, -0.3, 0.06), RUSTC, RUST),
		B(V(0.4, 0.3, 0.02), V(0.9, 0.5, 0.06), rgb(110, 76, 46), RUST),
	}
	for _, x in ipairs({ -1.3, 1.3 }) do
		for _, y in ipairs({ -0.82, 0.82 }) do
			table.insert(parts, CZ(0.2, 0.1, V(x, y, 0.02), STEEL_LIGHT, METAL))
		end
	end
	return {
		hold = "carry",
		handle = B(V(3, 2, 0.1), V(0, 0, 0), rgb(120, 124, 130), DPLATE),
		parts = parts,
		rest = FLAT_UP,
	}
end

-- Шипастая решётка: рама, прутья, два ряда шипов вперёд
SPECS.grill_spike = function()
	local frame = rgb(80, 80, 86)
	local parts = {
		B(V(3, 0.18, 0.2), V(0, 0.5, 0), frame, METAL),
		B(V(3, 0.18, 0.2), V(0, -0.5, 0), frame, METAL),
		B(V(0.6, 0.3, 0.04), V(0.6, 0.1, 0.08), RUSTC, RUST),
	}
	for i = 0, 6 do
		table.insert(parts, B(V(0.1, 1, 0.12), V(-1.35 + i * 0.45, 0, 0), frame, METAL))
	end
	for i = 0, 4 do
		local x = -1.2 + i * 0.6
		for _, y in ipairs({ 0.25, -0.25 }) do
			table.insert(parts, CZ(0.5, 0.12, V(x, y, -0.3), rgb(150, 150, 156), METAL))
			table.insert(parts, CZ(0.24, 0.05, V(x, y, -0.66), STEEL_LIGHT, METAL))
		end
	end
	return {
		hold = "carry",
		handle = B(V(2.9, 0.9, 0.08), V(0, 0, 0.05), frame, METAL, nil, 1),
		parts = parts,
	}
end

-- Решётка с пилами: рама, вал и три дисковые пилы
SPECS.grill_saw = function()
	local frame = rgb(96, 96, 100)
	local parts = {
		B(V(3, 0.18, 0.2), V(0, 0.55, 0.1), frame, METAL),
		B(V(3, 0.18, 0.2), V(0, -0.55, 0.1), frame, METAL),
		B(V(0.12, 1.2, 0.2), V(1.44, 0, 0.1), frame, METAL),
		B(V(0.12, 1.2, 0.2), V(-1.44, 0, 0.1), frame, METAL),
		CX(2.9, 0.1, V(0, 0, -0.1), STEEL_DARK, METAL),
	}
	for _, x in ipairs({ -0.9, 0, 0.9 }) do
		table.insert(parts, CX(0.05, 0.9, V(x, 0, -0.3), rgb(190, 192, 198), METAL))
		table.insert(parts, CX(0.12, 0.22, V(x, 0, -0.3), STEEL_DARK, METAL))
		ring(parts, 8, 0.46, 0.08, 0.04, V(x, 0, -0.3), "X", rgb(210, 212, 216), METAL, 0.25)
	end
	return {
		hold = "carry",
		handle = B(V(2.8, 1, 0.08), V(0, 0, 0.1), frame, METAL, nil, 1),
		parts = parts,
	}
end

-- Автотурель: опора, корпус, спаренные стволы, короб с лентой, датчик, антенна
SPECS.turret_auto = function()
	local olive, dark = rgb(70, 76, 60), rgb(46, 50, 40)
	return {
		hold = "carry",
		handle = CY(0.2, 1.5, V(0, -0.5, 0), dark, METAL),
		parts = {
			CY(0.3, 0.6, V(0, -0.3, 0), STEEL_DARK, METAL),
			B(V(1.0, 0.6, 1.0), V(0, 0, 0), olive, METAL),
			B(V(1.02, 0.1, 1.02), V(0, 0.3, 0), dark, METAL),
			CZ(1.2, 0.14, V(0.16, 0.02, -1.0), BLACK, METAL),
			CZ(1.2, 0.14, V(-0.16, 0.02, -1.0), BLACK, METAL),
			CZ(0.22, 0.2, V(0.16, 0.02, -1.62), rgb(40, 40, 42), METAL),
			CZ(0.22, 0.2, V(-0.16, 0.02, -1.62), rgb(40, 40, 42), METAL),
			B(V(0.4, 0.4, 0.5), V(0.7, -0.1, 0.1), dark, METAL),
			B(V(0.1, 0.06, 0.4), V(0.52, 0.02, 0.1), BRASS, METAL),
			named("Glow", CZ(0.04, 0.16, V(0, 0.16, -0.51), rgb(255, 60, 40), NEON)),
			B(V(0.03, 0.5, 0.03), V(-0.4, 0.55, 0.3), BLACK, METAL),
			BALL(0.06, V(-0.4, 0.8, 0.3), rgb(255, 60, 40), NEON),
		},
	}
end

-- Прожектор: корпус, светящееся стекло, отражатель, защитная решётка, скоба и основание
SPECS.bus_lamp = function()
	local body = rgb(50, 52, 56)
	return {
		hold = "carry",
		handle = CZ(0.6, 0.9, V(0, 0.1, 0), body, METAL),
		parts = {
			named("Glow", CZ(0.04, 0.74, V(0, 0.1, -0.31), rgb(255, 240, 190), NEON)),
			CZ(0.08, 0.86, V(0, 0.1, -0.29), rgb(200, 202, 206), METAL),
			CZ(0.2, 0.7, V(0, 0.1, 0.36), rgb(40, 40, 42), METAL),
			B(V(0.08, 0.6, 0.12), V(0.5, -0.12, 0), body, METAL),
			B(V(0.08, 0.6, 0.12), V(-0.5, -0.12, 0), body, METAL),
			B(V(1.1, 0.1, 0.4), V(0, -0.42, 0), body, METAL),
			B(V(0.8, 0.03, 0.03), V(0, 0.28, -0.35), STEEL_DARK, METAL),
			B(V(0.8, 0.03, 0.03), V(0, 0.1, -0.35), STEEL_DARK, METAL),
			B(V(0.8, 0.03, 0.03), V(0, -0.08, -0.35), STEEL_DARK, METAL),
			CX(0.14, 0.14, V(0.56, 0.1, 0), STEEL, METAL),
			CX(0.14, 0.14, V(-0.56, 0.1, 0), STEEL, METAL),
		},
	}
end

-- Койка: складная раскладушка — трубчатая рама, ткань, подушка, одеяло
SPECS.bunk = function()
	local tube = rgb(80, 82, 86)
	return {
		hold = "carry",
		handle = B(V(1.4, 0.08, 2.8), V(0, 0.04, -0.6), rgb(110, 60, 50), FABRIC),
		parts = {
			CZ(3, 0.1, V(0.72, 0, -0.6), tube, METAL),
			CZ(3, 0.1, V(-0.72, 0, -0.6), tube, METAL),
			CX(1.54, 0.1, V(0, 0, 0.9), tube, METAL),
			CX(1.54, 0.1, V(0, 0, -2.1), tube, METAL),
			B(V(1.0, 0.24, 0.5), V(0, 0.18, 0.55), rgb(210, 200, 180), FABRIC),
			B(V(1.3, 0.1, 1.2), V(0, 0.1, -1.4), rgb(80, 90, 70), FABRIC),
			B(V(0.08, 0.08, 0.6), V(0.6, -0.08, 0.5), tube, METAL),
			B(V(0.08, 0.08, 0.6), V(-0.6, -0.08, 0.5), tube, METAL),
			B(V(0.08, 0.08, 0.6), V(0.6, -0.08, -1.7), tube, METAL),
			B(V(0.08, 0.08, 0.6), V(-0.6, -0.08, -1.7), tube, METAL),
		},
	}
end

-- Сигнализация: красный короб, звонок с молоточком, мигалка, решётка динамика, провода
SPECS.alarm_box = function()
	return {
		hold = "carry",
		handle = B(V(1, 0.9, 0.5), V(0, 0, 0), rgb(196, 40, 36), METAL),
		parts = {
			CZ(0.16, 0.62, V(0, 0.02, -0.32), rgb(170, 30, 28), METAL),
			CZ(0.08, 0.5, V(0, 0.02, -0.42), rgb(210, 60, 50), METAL),
			BALL(0.12, V(0, 0.02, -0.48), STEEL, METAL),
			named("Glow", CY(0.2, 0.26, V(0, 0.55, 0), rgb(255, 70, 50), NEON)),
			CY(0.06, 0.32, V(0, 0.46, 0), STEEL_DARK, METAL),
			B(V(0.6, 0.04, 0.02), V(0, -0.3, -0.26), BLACK, PLASTIC),
			B(V(0.6, 0.04, 0.02), V(0, -0.38, -0.26), BLACK, PLASTIC),
			B(V(0.05, 0.3, 0.05), V(0.35, -0.55, 0.15), rgb(40, 40, 40), RUBBER),
			B(V(0.05, 0.3, 0.05), V(0.42, -0.55, 0.15), rgb(200, 180, 40), RUBBER),
			B(V(0.12, 0.12, 0.04), V(-0.36, 0.34, -0.26), STEEL_LIGHT, METAL),
			B(V(0.12, 0.12, 0.04), V(0.36, 0.34, -0.26), STEEL_LIGHT, METAL),
		},
	}
end

------------------------------------------------------------------------------------------------
-- Для заданий и ценности
------------------------------------------------------------------------------------------------

-- Ключ от тайника: кольцо с рубином, стержень, бородка
SPECS.cache_key = function()
	local gold = rgb(236, 196, 70)
	local parts = {
		B(V(0.06, 0.18, 0.12), V(0, -0.1, -0.56), gold, METAL),
		B(V(0.06, 0.1, 0.06), V(0, -0.07, -0.43), gold, METAL),
		B(V(0.07, 0.07, 0.06), V(0, 0, -0.18), rgb(200, 160, 50), METAL),
		BALL(0.11, V(0, 0, 0.14), rgb(200, 30, 40), GLASS),
	}
	ring(parts, 8, 0.15, 0.05, 0.06, V(0, 0, 0.14), "X", gold, METAL)
	return {
		hold = "hand",
		handle = B(V(0.06, 0.06, 0.5), V(0, 0, -0.38), gold, METAL),
		parts = parts,
		rest = FLAT_Z,
	}
end

-- Старинная монета с квадратным отверстием
SPECS.old_coin = function()
	local gold = rgb(210, 170, 60)
	return {
		hold = "hand",
		handle = CZ(0.07, 0.5, V(0, 0, 0), gold, METAL),
		parts = {
			CZ(0.08, 0.42, V(0, 0, 0), rgb(186, 146, 48), METAL),
			CZ(0.09, 0.26, V(0, 0, 0), gold, METAL),
			B(V(0.1, 0.1, 0.1), V(0, 0, 0), rgb(40, 34, 20), PLASTIC),
		},
		rest = FLAT_X,
	}
end

-- Карманные часы: корпус, циферблат, стрелки, заводная головка, цепочка
SPECS.watch = function()
	local gold = rgb(222, 196, 110)
	local parts = {
		CZ(0.15, 0.42, V(0, 0, 0), rgb(242, 238, 224), PLASTIC),
		CZ(0.16, 0.06, V(0, 0, 0), BLACK, METAL),
		B(V(0.02, 0.16, 0.02), V(0, 0.07, 0.08), BLACK, PLASTIC),
		B(V(0.11, 0.02, 0.02), V(0.05, 0, 0.08), BLACK, PLASTIC, V(0, 0, 30)),
		CY(0.1, 0.1, V(0, 0.29, 0), gold, METAL),
		CY(0.04, 0.06, V(0, 0.36, 0), gold, METAL),
		B(V(0.03, 0.12, 0.03), V(0.02, 0.44, 0), gold, METAL, V(0, 0, 20)),
		B(V(0.03, 0.12, 0.03), V(0.06, 0.55, 0), gold, METAL, V(0, 0, -20)),
	}
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2
		table.insert(parts, B(V(0.03, 0.05, 0.02), V(math.sin(a) * 0.16, math.cos(a) * 0.16, 0.077), BLACK, PLASTIC, V(0, 0, -math.deg(a))))
	end
	return {
		hold = "hand",
		handle = CZ(0.14, 0.5, V(0, 0, 0), gold, METAL),
		parts = parts,
		rest = FLAT_X,
	}
end

-- Фотоаппарат: корпус с кожей, объектив, рукоятка, вспышка, спуск, видоискатель
SPECS.camera = function()
	return {
		hold = "hand",
		handle = B(V(1, 0.6, 0.4), V(0, 0, 0), rgb(40, 40, 45), PLASTIC),
		parts = {
			B(V(1.02, 0.34, 0.42), V(0, -0.06, 0), rgb(60, 48, 40), LEATHER),
			CZ(0.3, 0.42, V(0.15, -0.02, -0.34), rgb(30, 30, 32), METAL),
			CZ(0.1, 0.46, V(0.15, -0.02, -0.46), rgb(70, 72, 76), METAL),
			CZ(0.02, 0.32, V(0.15, -0.02, -0.51), rgb(70, 100, 150), GLASS, nil, 0.1),
			B(V(0.2, 0.52, 0.16), V(-0.38, -0.02, -0.2), rgb(34, 34, 36), RUBBER),
			B(V(0.24, 0.12, 0.03), V(-0.18, 0.2, -0.21), rgb(240, 240, 236), PLASTIC),
			CY(0.06, 0.12, V(-0.34, 0.33, 0.02), STEEL_LIGHT, METAL),
			B(V(0.22, 0.16, 0.12), V(0.3, 0.36, 0.08), rgb(34, 34, 36), PLASTIC),
			B(V(0.06, 0.1, 0.06), V(0.52, 0.2, 0), STEEL, METAL),
			B(V(0.06, 0.1, 0.06), V(-0.52, 0.2, 0), STEEL, METAL),
		},
	}
end

-- Слиток: трапеция со скошенными гранями и клеймом
local function ingot(color, mark)
	return function()
		return {
			hold = "hand",
			handle = B(V(1.1, 0.26, 0.54), V(0, -0.04, 0), color, METAL),
			parts = {
				B(V(0.96, 0.1, 0.42), V(0, 0.13, 0), color, METAL),
				WEDGE(V(0.42, 0.1, 0.07), V(0.515, 0.13, 0), color, METAL, V(0, -90, 0)),
				WEDGE(V(0.42, 0.1, 0.07), V(-0.515, 0.13, 0), color, METAL, V(0, 90, 0)),
				WEDGE(V(0.96, 0.1, 0.06), V(0, 0.13, 0.24), color, METAL, V(0, 180, 0)),
				WEDGE(V(0.96, 0.1, 0.06), V(0, 0.13, -0.24), color, METAL),
				B(V(0.36, 0.01, 0.16), V(0, 0.185, 0), mark, METAL),
			},
		}
	end
end
SPECS.silver_bar = ingot(rgb(200, 205, 215), rgb(160, 164, 172))
SPECS.gold_bar = ingot(GOLD, rgb(200, 150, 40))

-- Редкая орхидея в горшке: земля, стебель, листья, три цветка
SPECS.orchid = function()
	local parts = {
		CY(0.04, 0.4, V(0, -0.12, 0), rgb(60, 40, 30), SLATE),
		CY(0.62, 0.035, V(0, 0.2, 0), rgb(70, 120, 50), PLASTIC),
		B(V(0.1, 0.02, 0.36), V(0.1, -0.08, 0.08), rgb(60, 130, 60), PLASTIC, V(15, 35, 0)),
		B(V(0.1, 0.02, 0.32), V(-0.1, -0.06, -0.06), rgb(70, 140, 64), PLASTIC, V(-12, -40, 0)),
	}
	local petals = rgb(230, 120, 220)
	for k, c in ipairs({ V(0, 0.52, 0), V(0.12, 0.4, -0.04), V(-0.1, 0.32, 0.03) }) do
		for i = 0, 4 do
			local a = rad(i / 5 * 360 + k * 20)
			table.insert(parts, BC(V(0.05, 0.02, 0.14), CF(c) * CFrame.Angles(0, a, 0) * CFrame.Angles(rad(-20), 0, 0) * CF(0, 0, -0.07), petals, PLASTIC))
		end
		table.insert(parts, BALL(0.06, c, rgb(255, 230, 120), PLASTIC))
	end
	return {
		hold = "hand",
		handle = CY(0.36, 0.4, V(0, -0.32, 0), rgb(170, 90, 60), SLATE),
		parts = parts,
	}
end

-- Волчья шкура: сложенный мех, хвост, лапа
SPECS.wolf_pelt = function()
	local fur, light = rgb(128, 126, 122), rgb(170, 166, 158)
	return {
		hold = "carry",
		handle = B(V(1.2, 0.26, 0.9), V(0, 0, 0), fur, FABRIC),
		parts = {
			B(V(1.1, 0.12, 0.8), V(0.02, 0.17, 0.02), light, FABRIC, V(0, 4, 0)),
			B(V(1.0, 0.1, 0.7), V(-0.03, 0.27, -0.02), rgb(110, 108, 104), FABRIC, V(0, -6, 0)),
			B(V(0.18, 0.12, 0.6), V(0.55, -0.02, 0.62), fur, FABRIC, V(0, 25, 0)),
			BALL(0.16, V(0.68, -0.02, 0.9), rgb(60, 58, 56), FABRIC),
			B(V(0.26, 0.08, 0.24), V(-0.62, 0.05, -0.5), light, FABRIC, V(0, 30, 10)),
			B(V(0.1, 0.12, 0.1), V(-0.7, 0.1, -0.62), rgb(40, 40, 40), FABRIC),
		},
	}
end

-- Янтарь с жуком: неровные прозрачные грани и тёмный жук внутри
SPECS.amber = function()
	local amber = rgb(255, 150, 30)
	local bug = rgb(40, 24, 10)
	return {
		hold = "hand",
		handle = BALL(0.62, V(0, 0, 0), amber, GLASS, 0.25),
		parts = {
			B(V(0.4, 0.36, 0.4), V(0.08, 0.06, 0), amber, GLASS, V(30, 45, 20), 0.3),
			B(V(0.36, 0.3, 0.34), V(-0.1, -0.08, 0.04), rgb(230, 120, 20), GLASS, V(-25, 20, 40), 0.3),
			B(V(0.08, 0.05, 0.16), V(0, 0, 0), bug, PLASTIC),
			B(V(0.14, 0.01, 0.02), V(0, -0.02, 0.03), bug, PLASTIC, V(0, 30, 0)),
			B(V(0.14, 0.01, 0.02), V(0, -0.02, -0.03), bug, PLASTIC, V(0, -30, 0)),
			BALL(0.05, V(0, 0.01, -0.09), rgb(30, 20, 8), PLASTIC),
		},
	}
end

-- Перстень с черепом
SPECS.skull_ring = function()
	local silver = rgb(186, 186, 170)
	local bone = rgb(222, 216, 192)
	local parts = {
		BALL(0.24, V(0, 0.24, 0), bone, PLASTIC),
		B(V(0.14, 0.07, 0.12), V(0, 0.13, -0.04), bone, PLASTIC),
		BALL(0.06, V(0.05, 0.26, -0.1), BLACK, PLASTIC),
		BALL(0.06, V(-0.05, 0.26, -0.1), BLACK, PLASTIC),
		B(V(0.02, 0.03, 0.02), V(0, 0.19, -0.11), BLACK, PLASTIC),
	}
	ring(parts, 10, 0.16, 0.04, 0.08, V(0, -0.02, 0), "Z", silver, METAL)
	return {
		hold = "hand",
		handle = B(V(0.1, 0.06, 0.08), V(0, 0.12, 0), silver, METAL),
		parts = parts,
		rest = FLAT_X,
	}
end

-- Нефритовый идол: постамент, тело, голова с короной, светящиеся глаза
SPECS.jade_idol = function()
	local jade, dark = rgb(60, 200, 120), rgb(40, 150, 90)
	return {
		hold = "hand",
		handle = B(V(0.7, 0.2, 0.6), V(0, -0.7, 0), dark, GLASS, nil, 0.05),
		parts = {
			B(V(0.5, 0.66, 0.4), V(0, -0.26, 0), jade, GLASS, nil, 0.08),
			B(V(0.46, 0.42, 0.42), V(0, 0.28, 0), jade, GLASS, nil, 0.08),
			WEDGE(V(0.46, 0.18, 0.2), V(0, 0.58, 0.1), dark, GLASS, V(0, 180, 0)),
			WEDGE(V(0.46, 0.18, 0.2), V(0, 0.58, -0.1), dark, GLASS),
			B(V(0.12, 0.44, 0.14), V(0.3, -0.24, -0.02), jade, GLASS, V(0, 0, 8), 0.08),
			B(V(0.12, 0.44, 0.14), V(-0.3, -0.24, -0.02), jade, GLASS, V(0, 0, -8), 0.08),
			B(V(0.08, 0.05, 0.02), V(0.1, 0.32, -0.215), rgb(120, 255, 170), NEON),
			B(V(0.08, 0.05, 0.02), V(-0.1, 0.32, -0.215), rgb(120, 255, 170), NEON),
			B(V(0.2, 0.04, 0.02), V(0, 0.16, -0.215), dark, GLASS),
			B(V(0.4, 0.06, 0.02), V(0, -0.62, -0.305), rgb(220, 190, 80), METAL),
		},
	}
end

-- Осколок метеорита: тёмные сколы со светящимися прожилками
SPECS.meteorite = function()
	local rock, rock2 = rgb(52, 40, 70), rgb(36, 28, 50)
	local glow = rgb(150, 90, 255)
	return {
		hold = "hand",
		handle = B(V(0.7, 0.6, 0.66), V(0, 0, 0), rock, SLATE, V(15, 25, 10)),
		parts = {
			B(V(0.5, 0.46, 0.5), V(0.22, 0.14, -0.1), rock2, SLATE, V(-30, 40, 15)),
			B(V(0.46, 0.4, 0.42), V(-0.2, -0.1, 0.14), rock, SLATE, V(35, -20, -25)),
			B(V(0.36, 0.32, 0.36), V(0.05, 0.28, 0.16), rock2, SLATE, V(10, 60, 35)),
			named("Glow", B(V(0.04, 0.5, 0.05), V(0.16, 0.02, -0.34), glow, NEON, V(0, 0, 25))),
			B(V(0.04, 0.3, 0.05), V(-0.3, 0.06, -0.24), glow, NEON, V(10, 0, -40)),
			B(V(0.36, 0.04, 0.05), V(0.02, -0.28, 0.3), glow, NEON, V(0, 20, 10)),
		},
	}
end

-- @@SPECS_END@@

------------------------------------------------------------------------------------------------
-- Сборка
------------------------------------------------------------------------------------------------

local cache = {}
local warned = {}

local function genericSpec(id)
	local item = Items.List[id]
	local size = item and item.size or V(0.8, 0.8, 0.8)
	local color = item and item.color or rgb(160, 160, 160)
	local mat = item and item.material or PLASTIC
	local handle
	if item and item.shape == "Cylinder" then
		handle = CY(size.Y, math.max(size.X, size.Z), V(0, 0, 0), color, mat)
	elseif item and item.shape == "Ball" then
		handle = BALL(math.max(size.X, size.Y, size.Z), V(0, 0, 0), color, mat)
	else
		handle = B(size, V(0, 0, 0), color, mat)
	end
	local big = math.max(size.X, size.Y, size.Z) > 1.7
	return { hold = big and "carry" or "hand", handle = handle, parts = {} }
end

local function getSpec(id)
	local s = cache[id]
	if s == nil then
		local maker = SPECS[id]
		s = false
		if maker then
			local ok, result = pcall(maker)
			if ok and type(result) == "table" and result.handle then
				s = result
				s.parts = s.parts or {}
			elseif not warned[id] then
				warned[id] = true
				warn("[ItemModels] " .. tostring(id) .. ": " .. tostring(result))
			end
		end
		cache[id] = s
	end
	return s or genericSpec(id)
end

local function makePart(s)
	local p
	if s.shape == "Wedge" then
		p = Instance.new("WedgePart")
	else
		p = Instance.new("Part")
		if s.shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		elseif s.shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		end
	end
	p.Name = s.name or "Part"
	p.Size = s.size
	p.Color = s.color
	p.Material = s.mat
	p.Transparency = s.tr or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = (s.size.X + s.size.Y + s.size.Z) > 0.6
	return p
end

local function assemble(s, container, origin, anchored)
	local handle = makePart(s.handle)
	handle.Name = "Handle"
	handle.Anchored = anchored
	handle.CFrame = origin * s.handle.cf
	handle.Parent = container
	for i, pd in ipairs(s.parts) do
		local p = makePart(pd)
		if not pd.name then
			p.Name = "Part" .. i
		end
		p.Anchored = anchored
		p.CFrame = origin * pd.cf
		p.Parent = container
		if not anchored then
			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = p
			w.Parent = p
		end
	end
	return handle
end

function ItemModels.Has(id)
	return SPECS[id] ~= nil
end

-- Стиль удержания предмета ("hand" | "handle" | "carry" | "long" | "throw")
function ItemModels.HoldStyle(id)
	return getSpec(id).hold or "hand"
end

-- Модель в пространстве хвата (начало координат — точка хвата), детали закреплены
function ItemModels.Build(id)
	local s = getSpec(id)
	local model = Instance.new("Model")
	model.Name = tostring(id)
	model.PrimaryPart = assemble(s, model, CFrame.identity, true)
	model:SetAttribute("ItemId", id)
	model:SetAttribute("HoldStyle", s.hold or "hand")
	return model
end

-- Инструмент для хотбара: Handle + приваренные детали, хват по стилю удержания
function ItemModels.MakeTool(id, count)
	local s = getSpec(id)
	local item = Items.List[id]
	local name = item and item.name or tostring(id)
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.ToolTip = name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("ItemKind", "item")
	tool:SetAttribute("ItemId", id)
	tool:SetAttribute("Count", math.max(1, math.floor(tonumber(count) or 1)))
	tool:SetAttribute("HoldStyle", s.hold or "hand")
	local handle = assemble(s, tool, CF(0, 500, 0), false)
	handle.CanTouch = false
	local offset = s.toolGrip or GRIP_BY_STYLE[s.hold or "hand"] or CFrame.identity
	tool.Grip = (offset * s.handle.cf):Inverse()
	return tool
end

-- Модель для земли: закреплена, низ предмета — на уровне cframe (плоские предметы лежат плашмя)
function ItemModels.MakeDisplay(id, cframe)
	local s = getSpec(id)
	local rest = s.rest or CFrame.identity
	local minY = math.huge
	local function consider(pd)
		local cf = rest * pd.cf
		local h = pd.size / 2
		local ext = math.abs(cf.RightVector.Y) * h.X + math.abs(cf.UpVector.Y) * h.Y + math.abs(cf.LookVector.Y) * h.Z
		minY = math.min(minY, cf.Position.Y - ext)
	end
	consider(s.handle)
	for _, pd in ipairs(s.parts) do
		consider(pd)
	end
	if minY == math.huge then
		minY = 0
	end
	local base = typeof(cframe) == "CFrame" and cframe or CFrame.identity
	local model = Instance.new("Model")
	model.Name = tostring(id)
	model.PrimaryPart = assemble(s, model, base * CF(0, 0.02 - minY, 0) * rest, true)
	model:SetAttribute("ItemId", id)
	return model
end

return ItemModels
