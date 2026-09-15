-- Вооружение и улучшения автобуса с уровнями (уровни складываются: каждый следующий
-- усиливает предыдущий). Ставятся и прокачиваются на верстаке за деньги + материалы.
-- Значения по уровням: массивы, индекс = уровень (1..maxLevel).
local Upgrades = {}

Upgrades.Categories = {
	defense = "Защита",
	weapon = "Вооружение",
	mobility = "Ходовая",
	utility = "Удобства",
}

Upgrades.List = {
	-- Защита
	{
		id = "armor", cat = "defense", name = "Броня", maxLevel = 5,
		desc = "+400 к прочности за каждый уровень, меньше урона от столкновений",
		prices = { 200, 350, 550, 800, 1100 },
		materials = { { scrap = 3 }, { scrap = 5, tape = 2 }, { scrap = 6, pipe = 2 }, { pipe = 4, spring = 2 }, { pipe = 4, circuit = 1 } },
		hpBonus = { 400, 800, 1200, 1600, 2000 },
		crashMult = { 0.9, 0.8, 0.7, 0.6, 0.5 },
	},
	{
		id = "ram", cat = "defense", name = "Таран", maxLevel = 4,
		desc = "Шипы -> острые шипы -> циркулярные пилы -> дробилка",
		levelNames = { "Шипы", "Острые шипы", "Циркулярные пилы", "Дробилка" },
		prices = { 260, 420, 640, 900 },
		materials = { { scrap = 4 }, { scrap = 4, spring = 1 }, { pipe = 3, spring = 2 }, { pipe = 4, circuit = 1 } },
		ramMult = { 2, 2.8, 4, 5.5 },
		selfDamageMult = { 0.5, 0.4, 0.25, 0.15 },
		sawDps = { 0, 0, 24, 40 },
	},
	-- Ходовая
	{
		id = "engine", cat = "mobility", name = "Мотор", maxLevel = 3,
		desc = "Выше максимальная скорость и разгон",
		prices = { 300, 550, 850 },
		materials = { { scrap = 3, spring = 1 }, { pipe = 2, spring = 2 }, { pipe = 3, circuit = 1 } },
		speedMult = { 1.1, 1.2, 1.3 },
		accelMult = { 1.15, 1.3, 1.45 },
	},
	{
		id = "tank", cat = "mobility", name = "Топливный бак", maxLevel = 3,
		desc = "Больше бак и меньше расход",
		prices = { 180, 320, 500 },
		materials = { { scrap = 2 }, { scrap = 3, pipe = 1 }, { pipe = 2, tape = 2 } },
		fuelBonus = { 30, 60, 100 },
		fuelEff = { 0.95, 0.9, 0.85 },
	},
	{
		id = "wheels", cat = "mobility", name = "Колёса", maxLevel = 3,
		desc = "Шипованные -> внедорожные -> золотые: сцепление и скорость на бездорожье",
		levelNames = { "Шипованные", "Внедорожные", "Золотые" },
		prices = { 220, 420, 900 },
		materials = { { scrap = 2, spring = 1 }, { rope = 2, pipe = 2 }, { gold_bar = 1, circuit = 1 } },
		gripBonus = { 0.2, 0.35, 0.5 },
		offroadBonus = { 0.1, 0.2, 0.3 },
	},
	-- Вооружение
	{
		id = "autoturret", cat = "weapon", name = "Автотурель", maxLevel = 5,
		desc = "Сама стреляет по ближайшим зомби. С 3-го уровня — две турели",
		prices = { 500, 700, 950, 1250, 1600 },
		materials = { { scrap = 4, spring = 1 }, { pipe = 2, battery = 1 }, { pipe = 3, battery = 2 }, { circuit = 1, gunpowder = 2 }, { circuit = 2, gunpowder = 3 } },
		damage = { 12, 16, 20, 26, 34 },
		interval = { 0.5, 0.42, 0.36, 0.3, 0.25 },
		range = { 80, 90, 100, 110, 120 },
		count = { 1, 1, 2, 2, 2 },
	},
	{
		id = "mg_turret", cat = "weapon", name = "Пулемётная башня", maxLevel = 5,
		desc = "Управляемая: сядьте в башню на крыше и стреляйте мышью. Перегревается",
		prices = { 450, 650, 900, 1200, 1550 },
		materials = { { pipe = 2, spring = 1 }, { pipe = 3, gunpowder = 1 }, { pipe = 3, gunpowder = 2 }, { circuit = 1, gunpowder = 3 }, { circuit = 2, gunpowder = 4 } },
		damage = { 14, 18, 23, 29, 36 },
		interval = { 0.11, 0.1, 0.09, 0.08, 0.07 },
		heatPerShot = { 0.05, 0.045, 0.04, 0.035, 0.03 },
		coolRate = { 0.35, 0.4, 0.45, 0.5, 0.6 },
		range = 320,
		spread = 1.8,
	},
	{
		id = "flamethrower", cat = "weapon", name = "Огнемёт на капоте", maxLevel = 4,
		desc = "Сжигает зомби перед автобусом, поджигает их",
		prices = { 480, 700, 950, 1300 },
		materials = { { pipe = 2, gas_can = 1 }, { pipe = 2, gas_can = 2 }, { pipe = 3, spring = 2 }, { circuit = 1, fuel_barrel = 1 } },
		dps = { 20, 30, 42, 56 },
		range = { 14, 17, 20, 24 },
		angle = 50,
	},
	{
		id = "tesla", cat = "weapon", name = "Катушка Теслы", maxLevel = 3,
		desc = "Бьёт молнией по нескольким зомби вокруг автобуса",
		prices = { 900, 1300, 1800 },
		materials = { { battery = 3, circuit = 1 }, { battery = 4, circuit = 2 }, { battery = 5, circuit = 3 } },
		damage = { 30, 45, 65 },
		interval = { 3, 2.5, 2 },
		chains = { 3, 4, 6 },
		radius = { 30, 35, 40 },
	},
	{
		id = "mortar", cat = "weapon", name = "Миномёт", maxLevel = 3,
		desc = "Навесом бьёт по скоплениям зомби вдали",
		prices = { 850, 1200, 1700 },
		materials = { { pipe = 4, gunpowder = 3 }, { pipe = 4, gunpowder = 5 }, { circuit = 2, gunpowder = 6 } },
		damage = { 60, 90, 130 },
		interval = { 6, 5, 4 },
		radius = { 10, 12, 14 },
		minRange = 40,
		maxRange = 170,
	},
	-- Удобства
	{
		id = "alarm", cat = "utility", name = "Сигнализация сна", maxLevel = 2,
		desc = "Слышит зомби дальше и будит спящих заранее, без сонливости",
		prices = { 130, 260 },
		materials = { { battery = 1 }, { battery = 2, circuit = 1 } },
		hearMult = { 1.6, 2 },
	},
	{
		id = "lights", cat = "utility", name = "Прожекторы", maxLevel = 2,
		desc = "Ночью зомби в свете фар замедляются",
		prices = { 110, 240 },
		materials = { { battery = 1 }, { battery = 2 } },
		slow = { 0.35, 0.5 },
	},
	{
		id = "bunks", cat = "utility", name = "Удобные койки", maxLevel = 2,
		desc = "+2 койки за уровень, сон восстанавливает быстрее",
		prices = { 150, 300 },
		materials = { { planks = 3, cloth = 2 }, { planks = 4, cloth = 4 } },
		extraBeds = { 2, 4 },
		sleepMult = { 1.3, 1.5 },
	},
}

Upgrades.ById = {}
for _, u in ipairs(Upgrades.List) do
	Upgrades.ById[u.id] = u
	u.price = u.prices[1] -- совместимость со старым кодом
end

-- Значение параметра на уровне (0 = не установлено -> default)
function Upgrades.Value(id, key, level, default)
	local u = Upgrades.ById[id]
	if not u or not level or level <= 0 then
		return default
	end
	local v = u[key]
	if type(v) == "table" then
		return v[math.min(level, #v)]
	elseif v ~= nil then
		return v
	end
	return default
end

-- Стоимость следующего уровня: price, materials (или nil, если уже максимум)
function Upgrades.NextCost(id, currentLevel)
	local u = Upgrades.ById[id]
	if not u then
		return nil
	end
	local nextLevel = (currentLevel or 0) + 1
	if nextLevel > u.maxLevel then
		return nil
	end
	return u.prices[nextLevel], u.materials[nextLevel] or {}, nextLevel
end

return Upgrades
