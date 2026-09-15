-- Верстак: рецепты крафта и улучшение оружия
local Recipes = {}

-- inputs/outputs: { itemId = количество }. Количество для патронов — в штуках.
Recipes.Order = {
	"bandage", "medkit", "herbal_tea", "molotov", "arrows", "bolts",
	"ammo_light", "ammo_shell", "ammo_rifle", "repair_kit", "barricade", "trap", "lantern",
	"bus_wheel", "plate_wood", "plate_metal", "grill_spike", "grill_saw", "turret_auto", "bus_lamp", "bunk", "alarm_box",
}

Recipes.List = {
	bandage = { name = "Бинт", inputs = { cloth = 2 }, outputs = { bandage = 1 } },
	medkit = { name = "Аптечка", inputs = { bandage = 2, herbs = 1 }, outputs = { medkit = 1 } },
	herbal_tea = { name = "Травяной чай", inputs = { herbs = 1, water = 1 }, outputs = { herbal_tea = 1 } },
	molotov = { name = "Коктейль Молотова x3", inputs = { bottle = 3, cloth = 1, gas_can = 1 }, outputs = { molotov = 3 } },
	arrows = { name = "Стрелы x10", inputs = { planks = 1, scrap = 1 }, outputs = { arrow = 10 } },
	bolts = { name = "Арбалетные болты x6", inputs = { pipe = 1, scrap = 1 }, outputs = { bolt = 6 } },
	ammo_light = { name = "Лёгкие патроны x18", inputs = { gunpowder = 1, scrap = 1 }, outputs = { ammo_light = 18 } },
	ammo_shell = { name = "Дробь x8", inputs = { gunpowder = 1, pipe = 1 }, outputs = { ammo_shell = 8 } },
	ammo_rifle = { name = "Винтовочные патроны x6", inputs = { gunpowder = 2, pipe = 1 }, outputs = { ammo_rifle = 6 } },
	repair_kit = { name = "Ремкомплект", inputs = { scrap = 3, tape = 2, spring = 1 }, outputs = { repair_kit = 1 } },
	barricade = { name = "Баррикада", inputs = { planks = 3, rope = 1 }, outputs = { barricade = 1 } },
	trap = { name = "Капкан", inputs = { spring = 2, scrap = 1 }, outputs = { trap = 1 } },
	lantern = { name = "Фонарь", inputs = { battery = 1, scrap = 1, bottle = 1 }, outputs = { lantern = 1 } },
	-- детали автобуса
	bus_wheel = { name = "Колесо", inputs = { scrap = 3, rope = 1 }, outputs = { bus_wheel = 1 } },
	plate_wood = { name = "Деревянная стена", inputs = { planks = 4 }, outputs = { plate_wood = 1 } },
	plate_metal = { name = "Металлическая стена", inputs = { scrap = 5, tape = 1 }, outputs = { plate_metal = 1 } },
	grill_spike = { name = "Шипастая решётка", inputs = { scrap = 4, pipe = 2 }, outputs = { grill_spike = 1 } },
	grill_saw = { name = "Решётка с пилами", inputs = { grill_spike = 1, spring = 3, circuit = 1 }, outputs = { grill_saw = 1 } },
	turret_auto = { name = "Автотурель", inputs = { pipe = 3, circuit = 1, gunpowder = 2 }, outputs = { turret_auto = 1 } },
	bus_lamp = { name = "Прожектор", inputs = { battery = 2, bottle = 1, scrap = 1 }, outputs = { bus_lamp = 1 } },
	bunk = { name = "Койка", inputs = { planks = 3, cloth = 2 }, outputs = { bunk = 1 } },
	alarm_box = { name = "Сигнализация", inputs = { battery = 2, circuit = 1 }, outputs = { alarm_box = 1 } },
}

for id, r in pairs(Recipes.List) do
	r.id = id
end

-- Улучшение оружия: уровни 1..MaxLevel, стоимость следующего уровня
Recipes.WeaponMaxLevel = 5
Recipes.WeaponUpgradeCost = {
	{ money = 40, materials = { scrap = 2, tape = 1 } },
	{ money = 80, materials = { scrap = 3, spring = 1 } },
	{ money = 140, materials = { pipe = 2, spring = 1 } },
	{ money = 220, materials = { pipe = 2, circuit = 1 } },
	{ money = 320, materials = { circuit = 2, gold_bar = 1 } },
}
Recipes.RarityPriceMult = { common = 0.8, uncommon = 1, rare = 1.3, epic = 1.7, legendary = 2.2 }

-- Бонусы уровня оружия (складываются с уровнем игрока и эффектами)
function Recipes.WeaponLevelMult(level)
	level = level or 0
	return 1 + 0.12 * level
end

function Recipes.WeaponCooldownMult(level)
	level = level or 0
	return 1 - 0.04 * level
end

function Recipes.WeaponMagBonus(baseMag, level)
	if not baseMag then
		return nil
	end
	level = level or 0
	return baseMag + math.floor(baseMag * 0.15 * level)
end

-- Стоимость улучшения до level+1 для оружия с данной редкостью
function Recipes.WeaponUpgradeFor(level, rarity)
	local nextLevel = (level or 0) + 1
	local cost = Recipes.WeaponUpgradeCost[nextLevel]
	if not cost then
		return nil
	end
	local mult = Recipes.RarityPriceMult[rarity or "common"] or 1
	return math.floor(cost.money * mult), cost.materials, nextLevel
end

return Recipes
