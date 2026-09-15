-- Модели оружия и снарядов из деталей (без загружаемых ассетов).
-- Пространство рукояти: начало координат — точка хвата (ладонь), -Z = вперёд (вдоль руки, от кулака),
-- +Y = верх оружия. У холодного оружия режущая/ударная кромка смотрит в -Y.
-- Attachments в Handle: Muzzle (дуло), TrailBase/TrailTip (след удара), Casing (выброс гильзы).
local WeaponModels = {}

local rgb = Color3.fromRGB
local V = Vector3.new
local rad = math.rad

local WOOD = Enum.Material.Wood
local METAL = Enum.Material.Metal
local RUST = Enum.Material.CorrodedMetal
local PLASTIC = Enum.Material.SmoothPlastic
local FABRIC = Enum.Material.Fabric
local GLASS = Enum.Material.Glass
local SLATE = Enum.Material.Slate

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
	return spec("Block", size, CFrame.new(pos) * rot(r), color, mat, tr)
end

-- брусок по готовому CFrame
local function BC(size, cf, color, mat, tr)
	return spec("Block", size, cf, color, mat, tr)
end

-- цилиндр вдоль Z / Y / X
local function CZ(len, d, pos, color, mat, r, tr)
	return spec("Cylinder", V(len, d, d), CFrame.new(pos) * rot(r) * ALIGN_Z, color, mat, tr)
end

local function CY(len, d, pos, color, mat, tr)
	return spec("Cylinder", V(len, d, d), CFrame.new(pos) * ALIGN_Y, color, mat, tr)
end

local function CX(len, d, pos, color, mat, r)
	return spec("Cylinder", V(len, d, d), CFrame.new(pos) * rot(r), color, mat)
end

local function BALL(d, pos, color, mat)
	return spec("Ball", V(d, d, d), CFrame.new(pos), color, mat)
end

-- ромб (квадрат, повёрнутый на 45°) в плоскости XZ — острие плоского клинка лопаты
local function DIAMOND_XZ(side, thick, pos, color, mat)
	return spec("Block", V(side, thick, side), CFrame.new(pos) * CFrame.Angles(0, rad(45), 0), color, mat)
end

-- ромб в плоскости YZ — острие ножа/катаны/пики
local function DIAMOND_YZ(side, thick, cf, color, mat)
	return spec("Block", V(thick, side, side), cf * CFrame.Angles(rad(45), 0, 0), color, mat)
end

-- тонкий цилиндр между двумя точками (тетива, струна)
local function LINE(a, b, d, color, mat)
	local mid = (a + b) / 2
	return spec("Cylinder", V((b - a).Magnitude, d, d), CFrame.lookAt(mid, b) * ALIGN_Z, color, mat)
end

-- именованная деталь (вид от первого лица находит её по имени, например тетиву лука)
local function named(name, s)
	s.name = name
	return s
end

-- деталь подвижной группы: имя для поиска, группа — чем двигается (атрибут Group), например гильзы
-- в стволах переломленного дробовика двигаются вместе со стволами
local function grouped(name, group, s)
	s.name = name
	s.group = group
	return s
end

-- деталь только для вида от первого лица (нет в инструменте и на земле), например опущенная тетива
local function vmOnly(s)
	s.vmOnly = true
	return s
end

-- Цвета
local STEEL = rgb(168, 170, 174)
local STEEL_LIGHT = rgb(222, 225, 230)
local STEEL_DARK = rgb(58, 60, 64)
local GUNMETAL = rgb(46, 48, 52)
local BLACK = rgb(30, 30, 32)
local WOOD_DARK = rgb(92, 66, 42)
local WOOD_MID = rgb(138, 102, 66)
local WOOD_WARM = rgb(110, 72, 44)
local RED_PAINT = rgb(178, 36, 28)
local BRASS = rgb(196, 156, 72)

-- Изогнутый клинок катаны из трёх сегментов (изгиб к обуху +Y)
local function katanaBlade()
	local parts = {}
	local cf = CFrame.new(0, 0.02, -0.65)
	local segs = { { 1.4, 0.24, 0 }, { 1.4, 0.23, 3 }, { 1.2, 0.21, 3 } }
	for _, s in ipairs(segs) do
		local len, width, bend = s[1], s[2], s[3]
		cf = cf * CFrame.Angles(rad(bend), 0, 0)
		local center = cf * CFrame.new(0, 0, -len / 2)
		table.insert(parts, BC(V(0.05, width, len), center, STEEL_LIGHT, METAL))
		-- светлая полоса закалки вдоль лезвия (-Y)
		table.insert(parts, BC(V(0.056, 0.05, len), center * CFrame.new(0, -width / 2 + 0.02, 0), rgb(240, 244, 250), METAL))
		-- обух (+Y)
		table.insert(parts, BC(V(0.07, 0.035, len), center * CFrame.new(0, width / 2 - 0.01, 0), rgb(150, 154, 160), METAL))
		cf = cf * CFrame.new(0, 0, -len)
	end
	table.insert(parts, DIAMOND_YZ(0.22, 0.05, cf * CFrame.new(0, -0.01, 0), STEEL_LIGHT, METAL))
	return parts
end

-- Гвозди биты: радиальные цилиндры, торчащие из утолщения
local function batNails()
	local list = {}
	local nails = {
		{ -2.25, 0 }, { -2.45, 60 }, { -2.65, 120 }, { -2.85, 30 }, { -3.05, 90 }, { -3.2, 150 }, { -2.35, 105 }, { -2.95, 165 },
	}
	for _, n in ipairs(nails) do
		table.insert(list, CX(0.74, 0.05, V(0, 0, n[1]), rgb(165, 165, 170), METAL, V(0, 0, n[2])))
	end
	return list
end

local function concat(a, b)
	local out = {}
	for _, v in ipairs(a) do
		table.insert(out, v)
	end
	for _, v in ipairs(b) do
		table.insert(out, v)
	end
	return out
end

WeaponModels.Specs = {
	-- Лопата (по виду оригинала): широкое плоское полотно со ступенчато скошенным концом, стальная
	-- конусная тулейка вдоль середины полотна (сторона +Y), деревянный черенок, Т-ручка сзади.
	-- Правая рука — у рукояти (начало координат), левая — на черенке у тулейки (z ≈ -2.15).
	shovel = {
		handle = CZ(0.8, 0.24, V(0, 0, 0), WOOD_DARK, WOOD),
		parts = {
			CX(0.7, 0.2, V(0, 0, 0.82), WOOD_DARK, WOOD),
			BALL(0.22, V(0.35, 0, 0.82), rgb(70, 50, 32), WOOD),
			BALL(0.22, V(-0.35, 0, 0.82), rgb(70, 50, 32), WOOD),
			CZ(0.45, 0.2, V(0, 0, 0.55), WOOD_DARK, WOOD),
			CZ(0.1, 0.25, V(0, 0, 0.42), STEEL_DARK, METAL),
			CZ(2.1, 0.2, V(0, 0, -1.45), WOOD_MID, WOOD),
			CZ(0.5, 0.27, V(0, 0, -2.68), rgb(150, 152, 156), METAL),
			CZ(0.5, 0.21, V(0, 0.03, -3.15), rgb(172, 174, 178), METAL),
			CZ(0.45, 0.15, V(0, 0.055, -3.6), rgb(186, 188, 192), METAL),
			CZ(0.3, 0.09, V(0, 0.065, -3.96), rgb(200, 202, 206), METAL),
			BALL(0.09, V(0, 0.065, -4.12), rgb(205, 207, 210), METAL),
			B(V(1.1, 0.07, 0.9), V(0, 0, -3.57), rgb(126, 126, 122), METAL),
			B(V(0.72, 0.07, 0.3), V(0, 0, -4.17), rgb(126, 126, 122), METAL),
			B(V(0.38, 0.07, 0.12), V(0, 0, -4.38), rgb(126, 126, 122), METAL),
			B(V(0.05, 0.1, 0.9), V(0.55, 0.02, -3.57), rgb(104, 104, 100), METAL),
			B(V(0.05, 0.1, 0.9), V(-0.55, 0.02, -3.57), rgb(104, 104, 100), METAL),
			B(V(0.36, 0.072, 0.34), V(-0.26, 0, -3.86), rgb(122, 78, 44), RUST),
			B(V(0.2, 0.072, 0.2), V(0.3, 0, -3.3), rgb(118, 74, 42), RUST),
		},
		trail = { base = V(0, 0, -3.2), tip = V(0, 0, -4.4) },
		trailColor = rgb(215, 220, 225),
	},
	-- Пистолет: полимерная рамка с рифлёной рукоятью, стальной затвор (детали «Slide»: прицелы, насечки,
	-- окно выброса), отдельный магазин (детали «Magazine»: корпус в рукояти, затыльник, верхний патрон).
	-- magAxis — направление извлечения магазина вдоль рукояти (вниз-назад).
	pistol = {
		handle = B(V(0.24, 0.8, 0.4), V(0, -0.2, 0.13), rgb(40, 40, 43), PLASTIC, V(-14, 0, 0)),
		parts = {
			B(V(0.25, 0.46, 0.3), V(0, -0.22, 0.14), rgb(30, 30, 32), FABRIC, V(-14, 0, 0)),
			B(V(0.22, 0.16, 1.02), V(0, 0.16, -0.36), rgb(40, 40, 43), PLASTIC),
			B(V(0.2, 0.05, 0.42), V(0, -0.05, -0.3), rgb(40, 40, 43), PLASTIC),
			B(V(0.2, 0.2, 0.05), V(0, 0.04, -0.49), rgb(40, 40, 43), PLASTIC),
			B(V(0.05, 0.16, 0.05), V(0, 0.05, -0.24), STEEL_DARK, METAL, V(12, 0, 0)),
			B(V(0.24, 0.1, 0.12), V(0, 0.19, 0.34), rgb(40, 40, 43), PLASTIC),
			B(V(0.03, 0.05, 0.22), V(0.125, 0.19, -0.2), STEEL_DARK, METAL),
			CZ(0.1, 0.13, V(0, 0.37, -1.2), rgb(26, 26, 28), METAL),
			named("Slide", B(V(0.25, 0.26, 1.58), V(0, 0.37, -0.42), rgb(58, 60, 64), METAL)),
			named("Slide", B(V(0.256, 0.16, 0.3), V(0, 0.38, 0.17), rgb(44, 46, 50), METAL)),
			named("Slide", B(V(0.05, 0.06, 0.08), V(0, 0.53, -1.1), BLACK, METAL)),
			named("Slide", B(V(0.2, 0.06, 0.07), V(0, 0.53, 0.3), BLACK, METAL)),
			named("Slide", B(V(0.02, 0.12, 0.34), V(0.127, 0.4, -0.3), rgb(24, 24, 26), METAL)),
			named("Magazine", B(V(0.18, 0.7, 0.3), V(0, -0.22, 0.13), rgb(46, 46, 50), METAL, V(-14, 0, 0))),
			named("Magazine", B(V(0.27, 0.07, 0.43), V(0, -0.62, 0.23), rgb(24, 24, 26), PLASTIC, V(-14, 0, 0))),
			named("Magazine", CZ(0.2, 0.09, V(0, 0.13, 0.05), BRASS, METAL, V(-14, 0, 0))),
		},
		muzzle = V(0, 0.37, -1.28),
		casing = V(0.16, 0.42, -0.3),
		magAxis = V(0, -0.970, 0.242),
		magPivot = V(0, -0.22, 0.13),
	},
	-- Бита: обмотка, навершие, утолщение с гвоздями и полосой скотча
	bat = {
		handle = CZ(1.0, 0.26, V(0, 0, 0.1), rgb(36, 36, 40), FABRIC),
		parts = concat({
			CZ(0.14, 0.4, V(0, 0, 0.66), WOOD_WARM, WOOD),
			CZ(0.9, 0.3, V(0, 0, -0.85), rgb(168, 128, 84), WOOD),
			CZ(0.9, 0.38, V(0, 0, -1.7), rgb(168, 128, 84), WOOD),
			CZ(1.2, 0.46, V(0, 0, -2.75), rgb(160, 120, 78), WOOD),
			BALL(0.46, V(0, 0, -3.35), rgb(160, 120, 78), WOOD),
			CZ(0.16, 0.48, V(0, 0, -2.05), rgb(96, 96, 100), FABRIC),
			B(V(0.1, 0.1, 0.5), V(0.2, 0.08, -2.9), rgb(120, 40, 36), WOOD),
		}, batNails()),
		trail = { base = V(0, 0, -1.9), tip = V(0, 0, -3.55) },
		trailColor = rgb(235, 215, 185),
	},
	-- Мачете: резиновая рукоять с упорами, заклёпки, расширяющийся к концу клинок
	machete = {
		handle = B(V(0.2, 0.3, 0.95), V(0, -0.02, 0.08), BLACK, PLASTIC),
		parts = {
			B(V(0.22, 0.06, 0.08), V(0, -0.18, -0.2), BLACK, PLASTIC),
			B(V(0.22, 0.06, 0.08), V(0, -0.18, 0.1), BLACK, PLASTIC),
			B(V(0.22, 0.06, 0.08), V(0, -0.18, 0.38), BLACK, PLASTIC),
			B(V(0.22, 0.36, 0.14), V(0, -0.02, 0.6), BLACK, PLASTIC),
			BALL(0.07, V(0.1, 0, -0.12), STEEL_LIGHT, METAL),
			BALL(0.07, V(0.1, 0, 0.28), STEEL_LIGHT, METAL),
			BALL(0.07, V(-0.1, 0, -0.12), STEEL_LIGHT, METAL),
			BALL(0.07, V(-0.1, 0, 0.28), STEEL_LIGHT, METAL),
			B(V(0.26, 0.4, 0.1), V(0, 0, -0.43), STEEL_DARK, METAL),
			B(V(0.05, 0.42, 1.4), V(0, 0.03, -1.18), STEEL, METAL),
			B(V(0.05, 0.56, 1.1), V(0, -0.04, -2.4), STEEL, METAL),
			DIAMOND_YZ(0.4, 0.05, CFrame.new(0, 0.02, -2.95), STEEL, METAL),
			B(V(0.055, 0.06, 1.4), V(0, -0.16, -1.18), STEEL_LIGHT, METAL),
			B(V(0.055, 0.06, 1.1), V(0, -0.3, -2.4), STEEL_LIGHT, METAL),
			B(V(0.07, 0.06, 2.4), V(0, 0.23, -1.6), rgb(110, 112, 116), METAL),
		},
		trail = { base = V(0, 0, -0.8), tip = V(0, -0.1, -3.2) },
		trailColor = rgb(220, 232, 245),
	},
	-- Пожарный топор: красный черенок с резиновой рукоятью, крашеный обух, стальная кромка, пика
	fire_axe = {
		handle = CZ(1.0, 0.28, V(0, 0, 0.1), BLACK, FABRIC),
		parts = {
			CZ(0.14, 0.32, V(0, 0, 0.66), BLACK, PLASTIC),
			CZ(2.6, 0.24, V(0, 0, -1.7), RED_PAINT, PLASTIC),
			CZ(0.15, 0.25, V(0, 0, -0.55), rgb(230, 190, 40), PLASTIC),
			B(V(0.28, 0.62, 0.62), V(0, 0, -3.15), RED_PAINT, METAL),
			B(V(0.2, 0.55, 0.55), V(0, -0.55, -3.15), RED_PAINT, METAL),
			B(V(0.14, 0.3, 0.95), V(0, -0.95, -3.15), STEEL, METAL),
			B(V(0.08, 0.08, 1.0), V(0, -1.12, -3.15), STEEL_LIGHT, METAL),
			B(V(0.18, 0.45, 0.3), V(0, 0.5, -3.15), RED_PAINT, METAL),
			B(V(0.14, 0.4, 0.2), V(0, 0.85, -3.15), STEEL_DARK, METAL),
			DIAMOND_YZ(0.2, 0.14, CFrame.new(0, 1.05, -3.15), STEEL_DARK, METAL),
			BALL(0.08, V(0.15, 0.1, -3.0), STEEL_LIGHT, METAL),
			BALL(0.08, V(-0.15, 0.1, -3.0), STEEL_LIGHT, METAL),
		},
		trail = { base = V(0, -0.2, -2.4), tip = V(0, -1.15, -3.15) },
		trailColor = rgb(255, 205, 190),
	},
	-- Катана: оплётка с ромбами, цуба, хабаки, изогнутый клинок с хамоном
	katana = {
		handle = B(V(0.2, 0.26, 1.15), V(0, 0, 0.2), rgb(26, 26, 40), FABRIC),
		parts = concat({
			B(V(0.21, 0.11, 0.11), V(0, 0, -0.2), rgb(185, 165, 115), FABRIC, V(45, 0, 0)),
			B(V(0.21, 0.11, 0.11), V(0, 0, 0.08), rgb(185, 165, 115), FABRIC, V(45, 0, 0)),
			B(V(0.21, 0.11, 0.11), V(0, 0, 0.36), rgb(185, 165, 115), FABRIC, V(45, 0, 0)),
			B(V(0.21, 0.11, 0.11), V(0, 0, 0.64), rgb(185, 165, 115), FABRIC, V(45, 0, 0)),
			B(V(0.22, 0.28, 0.1), V(0, 0, 0.82), rgb(60, 54, 40), METAL),
			CZ(0.07, 0.72, V(0, 0, -0.43), rgb(45, 42, 36), METAL),
			B(V(0.1, 0.28, 0.2), V(0, 0.01, -0.56), BRASS, METAL),
		}, katanaBlade()),
		trail = { base = V(0, 0, -1.0), tip = V(0, 0.2, -4.7) },
		trailColor = rgb(235, 242, 255),
	},
	-- Кувалда: тяжёлая головка с потёртыми бойками, стальная муфта, обмотка
	sledgehammer = {
		handle = CZ(1.1, 0.3, V(0, 0, 0.15), BLACK, FABRIC),
		parts = {
			CZ(0.12, 0.36, V(0, 0, 0.76), BLACK, PLASTIC),
			CZ(2.6, 0.24, V(0, 0, -1.6), rgb(150, 112, 72), WOOD),
			CZ(0.35, 0.3, V(0, 0, -2.75), STEEL_DARK, METAL),
			B(V(0.9, 1.5, 0.9), V(0, 0, -3.3), rgb(62, 64, 68), METAL),
			CY(0.12, 0.92, V(0, 0.8, -3.3), rgb(128, 130, 134), METAL),
			CY(0.12, 0.92, V(0, -0.8, -3.3), rgb(128, 130, 134), METAL),
			B(V(0.94, 0.1, 0.94), V(0, 0.6, -3.3), rgb(82, 84, 88), METAL),
			B(V(0.94, 0.1, 0.94), V(0, -0.6, -3.3), rgb(82, 84, 88), METAL),
			B(V(0.3, 0.3, 0.04), V(0, 0, -2.84), rgb(120, 90, 58), WOOD),
		},
		trail = { base = V(0, -0.2, -2.6), tip = V(0, -0.85, -3.3) },
		trailColor = rgb(205, 205, 210),
	},
	-- Револьвер
	revolver = {
		handle = B(V(0.28, 0.72, 0.36), V(0, -0.18, 0.12), rgb(95, 62, 38), WOOD, V(-15, 0, 0)),
		parts = {
			B(V(0.3, 0.08, 0.38), V(0, -0.55, 0.22), STEEL_DARK, METAL, V(-15, 0, 0)),
			B(V(0.26, 0.34, 0.95), V(0, 0.3, -0.2), rgb(52, 54, 58), METAL),
			B(V(0.1, 0.22, 0.14), V(0, 0.52, 0.24), rgb(40, 40, 44), METAL, V(-30, 0, 0)),
			named("Cylinder", CZ(0.55, 0.48, V(0, 0.3, -0.45), rgb(84, 86, 90), METAL)),
			named("Cylinder", CZ(0.57, 0.18, V(0, 0.3, -0.45), rgb(60, 62, 66), METAL)),
			CZ(1.35, 0.2, V(0, 0.4, -1.35), GUNMETAL, METAL),
			B(V(0.08, 0.06, 1.3), V(0, 0.52, -1.35), GUNMETAL, METAL),
			grouped("EjectorRod", "Cylinder", CZ(0.9, 0.09, V(0, 0.24, -1.15), rgb(70, 72, 76), METAL)),
			B(V(0.05, 0.12, 0.12), V(0, 0.56, -1.95), GUNMETAL, METAL),
			B(V(0.06, 0.06, 0.42), V(0, -0.02, -0.3), GUNMETAL, METAL),
			B(V(0.06, 0.24, 0.06), V(0, 0.08, -0.5), GUNMETAL, METAL),
			B(V(0.05, 0.18, 0.05), V(0, 0.06, -0.2), STEEL, METAL, V(15, 0, 0)),
		},
		muzzle = V(0, 0.4, -2.05),
		-- барабан откидывается влево вокруг оси вдоль ствола через эту точку
		cylinderPivot = V(0, 0.08, -0.45),
	},
	-- Двуствольный дробовик: стволы с цевьём («Barrels») переламываются вниз на шарнире hinge,
	-- в казённике видны донца патронов («Shell»)
	shotgun = {
		handle = B(V(0.26, 0.5, 0.45), V(0, -0.12, 0.05), WOOD_WARM, WOOD, V(-20, 0, 0)),
		parts = {
			B(V(0.3, 0.6, 1.3), V(0, -0.08, 0.95), WOOD_WARM, WOOD, V(8, 0, 0)),
			B(V(0.32, 0.66, 0.1), V(0, -0.18, 1.62), BLACK, PLASTIC, V(8, 0, 0)),
			B(V(0.4, 0.42, 0.75), V(0, 0.2, -0.35), rgb(60, 60, 64), METAL),
			B(V(0.41, 0.2, 0.4), V(0, 0.18, -0.35), rgb(150, 140, 110), METAL),
			named("Barrels", CZ(2.7, 0.19, V(0.095, 0.32, -2.05), rgb(42, 42, 46), METAL)),
			named("Barrels", CZ(2.7, 0.19, V(-0.095, 0.32, -2.05), rgb(42, 42, 46), METAL)),
			named("Barrels", B(V(0.07, 0.05, 2.7), V(0, 0.43, -2.05), rgb(42, 42, 46), METAL)),
			named("Barrels", B(V(0.36, 0.22, 1.0), V(0, 0.14, -1.25), WOOD_WARM, WOOD)),
			named("Barrels", BALL(0.07, V(0, 0.47, -3.35), BRASS, METAL)),
			grouped("Shell", "Barrels", CZ(0.05, 0.17, V(0.095, 0.32, -0.69), BRASS, METAL)),
			grouped("Shell", "Barrels", CZ(0.05, 0.17, V(-0.095, 0.32, -0.69), BRASS, METAL)),
			B(V(0.06, 0.06, 0.4), V(0, -0.04, -0.12), GUNMETAL, METAL),
			B(V(0.05, 0.16, 0.05), V(0, 0.06, -0.08), STEEL, METAL),
			CX(0.44, 0.12, V(0, 0.12, -0.72), STEEL_DARK, METAL),
		},
		muzzle = V(0, 0.32, -3.42),
		hinge = V(0, 0.12, -0.72),
	},
	-- Автомат
	rifle = {
		handle = B(V(0.24, 0.55, 0.32), V(0, -0.2, 0.05), rgb(38, 38, 40), PLASTIC, V(-18, 0, 0)),
		parts = {
			B(V(0.3, 0.3, 1.1), V(0, 0.12, -0.3), rgb(48, 50, 54), METAL),
			B(V(0.3, 0.26, 1.3), V(0, 0.4, -0.35), rgb(52, 54, 58), METAL),
			B(V(0.2, 0.06, 1.2), V(0, 0.56, -0.4), BLACK, METAL),
			CZ(0.75, 0.2, V(0, 0.36, 0.6), BLACK, METAL),
			B(V(0.26, 0.5, 0.7), V(0, 0.26, 1.1), rgb(40, 40, 42), PLASTIC),
			B(V(0.28, 0.56, 0.1), V(0, 0.24, 1.48), rgb(25, 25, 25), PLASTIC),
			named("Magazine", B(V(0.2, 0.5, 0.3), V(0, -0.2, -0.6), rgb(45, 45, 48), METAL, V(8, 0, 0))),
			named("Magazine", B(V(0.2, 0.45, 0.28), V(0, -0.6, -0.72), rgb(45, 45, 48), METAL, V(20, 0, 0))),
			B(V(0.36, 0.36, 1.15), V(0, 0.36, -1.6), rgb(72, 78, 62), PLASTIC),
			B(V(0.37, 0.05, 0.8), V(0, 0.3, -1.6), rgb(52, 56, 46), PLASTIC),
			B(V(0.16, 0.2, 0.14), V(0, 0.4, -2.35), BLACK, METAL),
			B(V(0.06, 0.3, 0.08), V(0, 0.6, -2.35), BLACK, METAL),
			CZ(1.0, 0.12, V(0, 0.36, -2.7), BLACK, METAL),
			CZ(0.3, 0.17, V(0, 0.36, -3.3), rgb(28, 28, 30), METAL),
			B(V(0.14, 0.14, 0.2), V(0, 0.66, 0.1), BLACK, METAL),
			B(V(0.2, 0.06, 0.1), V(0, 0.56, 0.25), GUNMETAL, METAL),
			B(V(0.06, 0.06, 0.35), V(0, -0.05, -0.1), GUNMETAL, METAL),
			B(V(0.02, 0.1, 0.3), V(0.16, 0.42, -0.3), rgb(20, 20, 20), METAL),
			named("Bolt", B(V(0.12, 0.06, 0.1), V(0.21, 0.44, -0.55), BLACK, METAL)),
		},
		muzzle = V(0, 0.36, -3.46),
		casing = V(0.18, 0.42, -0.3),
		magAxis = V(0, -0.97, -0.24),
		magPivot = V(0, -0.4, -0.66),
	},
	-- Снайперская винтовка со скользящим затвором («Bolt»: рукоять и стебель затвора) и оптикой
	sniper = {
		handle = B(V(0.24, 0.5, 0.32), V(0, -0.18, 0.05), rgb(76, 52, 34), WOOD, V(-22, 0, 0)),
		parts = {
			B(V(0.28, 0.5, 1.4), V(0, 0.1, 1.05), rgb(88, 60, 38), WOOD, V(4, 0, 0)),
			B(V(0.26, 0.18, 0.7), V(0, 0.4, 0.95), rgb(80, 55, 35), WOOD),
			B(V(0.3, 0.56, 0.1), V(0, 0.06, 1.78), rgb(25, 25, 25), PLASTIC, V(4, 0, 0)),
			B(V(0.32, 0.36, 1.3), V(0, 0.14, -0.55), rgb(88, 60, 38), WOOD),
			CZ(1.4, 0.3, V(0, 0.4, -0.4), rgb(50, 52, 56), METAL),
			named("Bolt", CZ(0.5, 0.2, V(0, 0.4, 0.1), STEEL, METAL)),
			named("Bolt", CX(0.34, 0.07, V(0.2, 0.42, 0.12), STEEL, METAL)),
			named("Bolt", BALL(0.14, V(0.38, 0.4, 0.12), STEEL_DARK, METAL)),
			B(V(0.3, 0.28, 1.4), V(0, 0.18, -1.85), rgb(88, 60, 38), WOOD),
			CZ(3.0, 0.15, V(0, 0.4, -2.6), rgb(40, 40, 44), METAL),
			B(V(0.22, 0.2, 0.35), V(0, 0.4, -4.25), rgb(35, 35, 38), METAL),
			CZ(1.5, 0.24, V(0, 0.82, -0.45), rgb(28, 28, 30), METAL),
			CZ(0.4, 0.36, V(0, 0.82, -1.35), rgb(28, 28, 30), METAL),
			CZ(0.3, 0.32, V(0, 0.82, 0.42), rgb(28, 28, 30), METAL),
			CZ(0.03, 0.3, V(0, 0.82, -1.56), rgb(60, 90, 130), GLASS),
			CY(0.16, 0.14, V(0, 0.99, -0.45), rgb(28, 28, 30), METAL),
			CX(0.16, 0.14, V(0.16, 0.82, -0.45), rgb(28, 28, 30), METAL),
			B(V(0.12, 0.24, 0.14), V(0, 0.62, -0.9), rgb(28, 28, 30), METAL),
			B(V(0.12, 0.24, 0.14), V(0, 0.62, 0.05), rgb(28, 28, 30), METAL),
			CZ(1.0, 0.06, V(0.1, 0.0, -2.2), BLACK, METAL),
			CZ(1.0, 0.06, V(-0.1, 0.0, -2.2), BLACK, METAL),
		},
		muzzle = V(0, 0.4, -4.45),
		casing = V(0.18, 0.44, -0.2),
	},
	-- Лук: рукоять, рукоятка-плечи (рекурв), тетива позади
	bow = {
		handle = B(V(0.2, 0.6, 0.28), V(0, 0, 0), rgb(70, 45, 28), FABRIC),
		parts = {
			B(V(0.18, 0.55, 0.24), V(0, 0.55, -0.02), rgb(95, 62, 38), WOOD),
			B(V(0.18, 0.55, 0.24), V(0, -0.55, -0.02), rgb(95, 62, 38), WOOD),
			B(V(0.08, 0.06, 0.18), V(0.1, 0.3, -0.05), BLACK, PLASTIC),
			B(V(0.14, 1.0, 0.18), V(0, 1.25, 0.08), rgb(120, 80, 45), WOOD, V(10, 0, 0)),
			B(V(0.12, 0.9, 0.15), V(0, 2.1, 0.32), rgb(120, 80, 45), WOOD, V(24, 0, 0)),
			B(V(0.1, 0.3, 0.12), V(0, 2.62, 0.45), rgb(60, 40, 25), WOOD, V(-18, 0, 0)),
			B(V(0.14, 1.0, 0.18), V(0, -1.25, 0.08), rgb(120, 80, 45), WOOD, V(-10, 0, 0)),
			B(V(0.12, 0.9, 0.15), V(0, -2.1, 0.32), rgb(120, 80, 45), WOOD, V(-24, 0, 0)),
			B(V(0.1, 0.3, 0.12), V(0, -2.62, 0.45), rgb(60, 40, 25), WOOD, V(18, 0, 0)),
			named("String", CY(5.0, 0.035, V(0, 0, 0.52), rgb(235, 232, 220), FABRIC)),
		},
		muzzle = V(0, 0.3, -0.3),
	},
	-- Арбалет: ложе, металлические плечи, взведённая тетива, болт, прицел, стремя
	crossbow = {
		handle = B(V(0.22, 0.5, 0.32), V(0, -0.2, 0.05), rgb(66, 48, 32), WOOD, V(-20, 0, 0)),
		parts = {
			B(V(0.28, 0.34, 2.3), V(0, 0.14, -0.6), rgb(92, 66, 44), WOOD),
			B(V(0.28, 0.55, 0.75), V(0, 0.02, 0.9), rgb(92, 66, 44), WOOD, V(8, 0, 0)),
			B(V(0.12, 0.05, 1.9), V(0, 0.33, -0.85), rgb(60, 60, 64), METAL),
			B(V(0.4, 0.16, 0.26), V(0, 0.26, -1.7), rgb(50, 50, 54), METAL),
			B(V(1.2, 0.12, 0.2), V(-0.767, 0.26, -1.555), rgb(45, 45, 50), METAL, V(0, 12, 0)),
			B(V(1.2, 0.12, 0.2), V(0.767, 0.26, -1.555), rgb(45, 45, 50), METAL, V(0, -12, 0)),
			BALL(0.1, V(-1.354, 0.26, -1.43), STEEL_DARK, METAL),
			BALL(0.1, V(1.354, 0.26, -1.43), STEEL_DARK, METAL),
			named("StringCocked", LINE(V(-1.354, 0.26, -1.43), V(0, 0.34, -0.7), 0.03, rgb(230, 228, 215), FABRIC)),
			named("StringCocked", LINE(V(1.354, 0.26, -1.43), V(0, 0.34, -0.7), 0.03, rgb(230, 228, 215), FABRIC)),
			vmOnly(named("StringRest", LINE(V(-1.354, 0.26, -1.43), V(1.354, 0.26, -1.43), 0.03, rgb(230, 228, 215), FABRIC))),
			B(V(0.18, 0.1, 0.1), V(0, 0.36, -0.68), rgb(40, 40, 42), METAL),
			named("Bolt", CZ(1.05, 0.06, V(0, 0.39, -1.2), rgb(120, 95, 60), WOOD)),
			named("Bolt", DIAMOND_YZ(0.12, 0.08, CFrame.new(0, 0.39, -1.76), STEEL, METAL)),
			B(V(0.36, 0.05, 0.05), V(0, 0.05, -2.05), STEEL_DARK, METAL),
			B(V(0.05, 0.3, 0.05), V(0.16, 0.18, -2.02), STEEL_DARK, METAL),
			B(V(0.05, 0.3, 0.05), V(-0.16, 0.18, -2.02), STEEL_DARK, METAL),
			CZ(0.7, 0.16, V(0, 0.62, -0.4), rgb(30, 30, 32), METAL),
			B(V(0.08, 0.2, 0.08), V(0, 0.47, -0.2), rgb(30, 30, 32), METAL),
			B(V(0.08, 0.2, 0.08), V(0, 0.47, -0.6), rgb(30, 30, 32), METAL),
			B(V(0.05, 0.08, 0.5), V(0, -0.02, -0.15), STEEL_DARK, METAL),
		},
		muzzle = V(0, 0.39, -1.9),
	},
	-- Коктейль Молотова: бутылка с жидкостью, горлышко, тряпка
	molotov = {
		handle = CZ(0.8, 0.5, V(0, 0, -0.05), rgb(80, 120, 60), GLASS, nil, 0.25),
		parts = {
			CZ(0.55, 0.42, V(0, -0.02, 0.08), rgb(200, 120, 40), PLASTIC),
			CZ(0.18, 0.38, V(0, 0, -0.52), rgb(80, 120, 60), GLASS, nil, 0.25),
			CZ(0.4, 0.18, V(0, 0, -0.8), rgb(80, 120, 60), GLASS, nil, 0.2),
			B(V(0.24, 0.3, 0.28), V(0, 0.02, -1.08), rgb(215, 200, 165), FABRIC, V(0, 0, 15)),
			B(V(0.08, 0.5, 0.14), V(0.06, -0.2, -1.12), rgb(200, 185, 150), FABRIC, V(12, 0, 0)),
		},
		muzzle = V(0, 0, -1.2),
	},
}

local function makePart(s, name)
	local p = Instance.new("Part")
	p.Name = s.name or name or "Part"
	p.CanQuery = false
	-- мелкие детали без теней
	p.CastShadow = (s.size.X + s.size.Y + s.size.Z) > 0.6
	if s.shape == "Cylinder" then
		p.Shape = Enum.PartType.Cylinder
	elseif s.shape == "Ball" then
		p.Shape = Enum.PartType.Ball
	end
	p.Size = s.size
	p.Color = s.color
	p.Material = s.mat
	p.Transparency = s.tr or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.Massless = true
	if s.group then
		p:SetAttribute("Group", s.group)
	end
	return p
end

local function addAttachment(handle, name, originCF, localPos)
	local att = Instance.new("Attachment")
	att.Name = name
	att.CFrame = handle.CFrame:ToObjectSpace(originCF * CFrame.new(localPos))
	att.Parent = handle
	return att
end

-- Собирает детали вокруг CFrame. Возвращает handle. full — вместе с деталями только для вида
-- от первого лица (vmOnly); в инструменте и на земле их нет.
local function assemble(id, container, originCF, anchored, full)
	local s = WeaponModels.Specs[id] or WeaponModels.Specs.shovel
	local handle = makePart(s.handle, "Handle")
	handle.Anchored = anchored
	handle.CFrame = originCF * s.handle.cf
	handle.Parent = container
	for i, pd in ipairs(s.parts) do
		if full or not pd.vmOnly then
			local p = makePart(pd, "Part" .. i)
			p.Anchored = anchored
			p.CFrame = originCF * pd.cf
			p.Parent = container
			if not anchored then
				local w = Instance.new("WeldConstraint")
				w.Part0 = handle
				w.Part1 = p
				w.Parent = p
			end
		end
	end
	addAttachment(handle, "Muzzle", originCF, s.muzzle or Vector3.new(0, 0, -1.5))
	if s.trail then
		addAttachment(handle, "TrailBase", originCF, s.trail.base)
		addAttachment(handle, "TrailTip", originCF, s.trail.tip)
	end
	if s.casing then
		addAttachment(handle, "Casing", originCF, s.casing)
	end
	return handle
end

-- Цвет следа удара (для Trail на клиенте)
function WeaponModels.TrailColor(id)
	local s = WeaponModels.Specs[id]
	return s and s.trailColor or Color3.fromRGB(220, 225, 235)
end

function WeaponModels.MakeTool(id, displayName)
	local tool = Instance.new("Tool")
	tool.Name = displayName or id
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.ToolTip = displayName or id
	tool:SetAttribute("WeaponId", id)
	local s = WeaponModels.Specs[id] or WeaponModels.Specs.shovel
	local handle = assemble(id, tool, CFrame.new(0, 500, 0), false)
	-- рукоять в ладони: точка (0,0,0) пространства модели совпадает с хватом руки
	tool.Grip = s.handle.cf:Inverse()
	handle.CanTouch = false
	return tool
end

function WeaponModels.MakeDisplay(id, cframe)
	local model = Instance.new("Model")
	model.Name = id
	local handle = assemble(id, model, cframe, true)
	model.PrimaryPart = handle
	return model
end

function WeaponModels.Has(id)
	return WeaponModels.Specs[id] ~= nil
end

-- Модель оружия в пространстве рукояти (точка хвата в начале координат), детали закреплены.
-- Для вида от первого лица и иконок (ViewportFrame). full = false — без деталей вида от первого лица.
function WeaponModels.Build(id, full)
	local model = Instance.new("Model")
	model.Name = tostring(id)
	local handle = assemble(id, model, CFrame.identity, true, full ~= false)
	model.PrimaryPart = handle
	model:SetAttribute("WeaponId", id)
	return model
end

-- Отдельная подвижная группа деталей оружия (например "Magazine" пистолета) в пространстве рукояти.
-- Опора модели (WorldPivot) — pivot или середина группы: клиент роняет по ней магазин на землю.
function WeaponModels.BuildGroup(id, group, pivot)
	local s = WeaponModels.Specs[id]
	if not s or type(group) ~= "string" then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = tostring(id) .. "_" .. group
	local first, sum, n = nil, Vector3.zero, 0
	for i, pd in ipairs(s.parts) do
		if (pd.group or pd.name) == group then
			local p = makePart(pd, "Part" .. i)
			p.Anchored = true
			p.CFrame = pd.cf
			p.Parent = model
			first = first or p
			sum = sum + pd.cf.Position
			n = n + 1
		end
	end
	if not first then
		model:Destroy()
		return nil
	end
	model.PrimaryPart = first
	model.WorldPivot = CFrame.new(typeof(pivot) == "Vector3" and pivot or (sum / n))
	return model
end

-- Визуальные снаряды (клиент): стрелы, болты, бутылка, кислота, пули мародёров,
-- снаряды миномёта, валуны элиты, метеориты
function WeaponModels.MakeProjectile(kind)
	kind = kind or "acid"
	local model = Instance.new("Model")
	model.Name = "Projectile_" .. kind
	local function part(size, cf, color, mat, shape)
		local p = Instance.new("Part")
		p.Size = size
		p.Color = color
		p.Material = mat or PLASTIC
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		if shape then
			p.Shape = shape
		end
		p.CFrame = cf
		p.Parent = model
		return p
	end
	local CYL = Enum.PartType.Cylinder
	local root
	if kind == "arrow" then
		root = part(V(0.09, 0.09, 2.6), CFrame.new(), rgb(150, 110, 70), WOOD)
		part(V(0.18, 0.08, 0.36), CFrame.new(0, 0, -1.42), rgb(160, 160, 170), METAL)
		part(V(0.08, 0.18, 0.36), CFrame.new(0, 0, -1.42), rgb(160, 160, 170), METAL)
		part(V(0.02, 0.32, 0.5), CFrame.new(0, 0, 1.05), rgb(190, 50, 45), FABRIC)
		part(V(0.32, 0.02, 0.5), CFrame.new(0, 0, 1.05), rgb(235, 230, 220), FABRIC)
		part(V(0.12, 0.12, 0.08), CFrame.new(0, 0, 1.32), rgb(40, 40, 40), PLASTIC)
	elseif kind == "bolt" then
		root = part(V(0.11, 0.11, 1.8), CFrame.new(), rgb(110, 90, 60), WOOD)
		part(V(0.2, 0.2, 0.3), CFrame.new(0, 0, -1.0) * CFrame.Angles(0, 0, rad(45)), rgb(190, 190, 200), METAL)
		part(V(0.02, 0.28, 0.35), CFrame.new(0, 0, 0.72), rgb(40, 40, 40), FABRIC)
		part(V(0.28, 0.02, 0.35), CFrame.new(0, 0, 0.72), rgb(40, 40, 40), FABRIC)
	elseif kind == "molotov" then
		root = part(V(0.8, 0.5, 0.5), ALIGN_Z, rgb(80, 120, 60), GLASS, CYL)
		root.Transparency = 0.25
		part(V(0.4, 0.18, 0.18), CFrame.new(0, 0, -0.55) * ALIGN_Z, rgb(80, 120, 60), GLASS, CYL)
		part(V(0.24, 0.3, 0.28), CFrame.new(0, 0, -0.85), rgb(215, 200, 165), FABRIC)
		local fire = Instance.new("Fire")
		fire.Size = 2
		fire.Heat = 4
		fire.Parent = root
	elseif kind == "bullet" then
		-- маленький жёлтый светящийся трассер, вытянут вдоль полёта (-Z)
		root = part(V(0.18, 0.18, 1.4), CFrame.new(), rgb(255, 220, 70), Enum.Material.Neon)
	elseif kind == "shell" then
		-- тёмный шар снаряда миномёта
		root = part(V(1.3, 1.3, 1.3), CFrame.new(), rgb(40, 42, 46), METAL, Enum.PartType.Ball)
		part(V(0.5, 0.5, 0.5), CFrame.new(0, 0, 0.55), rgb(255, 150, 60), Enum.Material.Neon, Enum.PartType.Ball)
	elseif kind == "boulder" then
		root = part(V(3.2, 3.2, 3.2), CFrame.new(), rgb(150, 124, 90), SLATE, Enum.PartType.Ball)
		part(V(1.8, 1.4, 1.6), CFrame.new(0.9, 0.7, 0.3), rgb(130, 108, 80), SLATE)
	elseif kind == "meteor" then
		root = part(V(3, 3, 3), CFrame.new(), rgb(255, 120, 30), Enum.Material.Neon, Enum.PartType.Ball)
		part(V(2.2, 2.2, 2.2), CFrame.new(0, 0, 1.6), rgb(255, 200, 80), Enum.Material.Neon, Enum.PartType.Ball).Transparency = 0.4
		local fire = Instance.new("Fire")
		fire.Size = 8
		fire.Heat = 12
		fire.Color = rgb(255, 120, 30)
		fire.SecondaryColor = rgb(255, 220, 90)
		fire.Parent = root
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 140, 50)
		light.Range = 24
		light.Brightness = 4
		light.Parent = root
	else
		root = part(V(0.9, 0.9, 0.9), CFrame.new(), rgb(120, 230, 60), Enum.Material.Neon, Enum.PartType.Ball)
	end
	model.PrimaryPart = root
	return model
end

return WeaponModels
