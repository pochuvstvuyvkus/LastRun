-- Предметы, редкость, таблицы добычи и магазин
local Items = {}

local rgb = Color3.fromRGB
local V = Vector3.new

Items.Rarities = {
	common = { name = "Обычный", color = rgb(205, 205, 205), order = 1 },
	uncommon = { name = "Необычный", color = rgb(96, 206, 96), order = 2 },
	rare = { name = "Редкий", color = rgb(76, 146, 255), order = 3 },
	epic = { name = "Эпический", color = rgb(186, 96, 255), order = 4 },
	legendary = { name = "Легендарный", color = rgb(255, 176, 44), order = 5 },
}

Items.Categories = {
	fuel = "Топливо",
	food = "Еда и напитки",
	medical = "Медицина",
	ammo = "Патроны",
	throwable = "Метательное",
	material = "Материалы",
	tool = "Инструменты",
	placeable = "Ловушки и укрепления",
	quest = "Для заданий",
	buspart = "Детали автобуса",
	valuable = "Ценности",
}

-- sell — цена продажи за штуку; pack — сколько штук в найденной пачке;
-- stack — сколько штук помещается в один слот инвентаря (оружие — всегда 1 в слоте)
Items.List = {
	coal = { name = "Уголь", cat = "fuel", stack = 10, rarity = "common", sell = 3, fuel = 12, color = rgb(40, 40, 40), size = V(1.2, 0.9, 1.2), desc = "+12 топлива" },
	gas_can = { name = "Канистра бензина", cat = "fuel", stack = 1, rarity = "uncommon", sell = 9, fuel = 30, color = rgb(200, 40, 40), size = V(1.2, 1.6, 0.7), desc = "+30 топлива" },
	fuel_barrel = { name = "Бочка топлива", cat = "fuel", stack = 1, rarity = "rare", sell = 20, fuel = 60, color = rgb(40, 90, 160), size = V(1.8, 2.6, 1.8), shape = "Cylinder", desc = "+60 топлива" },

	-- hunger — сытость из 100 (v5: тратится ~4 в минуту, на бегу ~7). Консервы — полноценная еда,
	-- чипсы — перекус, напитки почти не насыщают
	canned_food = { name = "Консервы", cat = "food", stack = 5, rarity = "common", sell = 4, hunger = 45, color = rgb(170, 170, 180), size = V(0.7, 0.9, 0.7), desc = "+45 сытости — сытная еда" },
	chips = { name = "Чипсы", cat = "food", stack = 5, rarity = "common", sell = 2, hunger = 12, color = rgb(240, 200, 40), size = V(1, 1.2, 0.4), desc = "+12 сытости — лёгкий перекус" },
	water = { name = "Бутылка воды", cat = "food", stack = 5, rarity = "common", sell = 2, hunger = 5, drink = true, color = rgb(120, 190, 255), size = V(0.5, 1.2, 0.5), desc = "+5 сытости" },
	-- effect — эффект на effectTime секунд; crash — после него «Упадок сил» на crash секунд
	coffee = { name = "Термос с кофе", cat = "food", stack = 5, rarity = "uncommon", sell = 6, hunger = 2, drink = true, effect = "Caffeine", effectTime = 90, color = rgb(110, 70, 40), size = V(0.6, 1.3, 0.6), desc = "Кофеин: +10% скорости на 90 с, +2 сытости" },
	energy_drink = { name = "Энергетик", cat = "food", stack = 5, rarity = "uncommon", sell = 7, hunger = 4, drink = true, effect = "Adrenaline", effectTime = 8, crash = 25, color = rgb(60, 220, 120), size = V(0.5, 1, 0.5), desc = "+4 сытости. Адреналин на 8 с, потом упадок сил на 25 с" },
	herbal_tea = { name = "Травяной чай", cat = "food", stack = 5, rarity = "common", sell = 4, heal = 15, hunger = 5, drink = true, color = rgb(150, 110, 60), size = V(0.6, 1, 0.6), desc = "+15 здоровья, +5 сытости" },

	bandage = { name = "Бинт", cat = "medical", stack = 5, rarity = "common", sell = 4, heal = 25, useTime = 1.5, color = rgb(240, 240, 230), size = V(0.8, 0.5, 0.8), desc = "+25 здоровья" },
	medkit = { name = "Аптечка", cat = "medical", stack = 5, rarity = "rare", sell = 16, heal = 75, useTime = 3, color = rgb(220, 50, 50), size = V(1.4, 0.9, 1), desc = "+75 здоровья" },
	adrenaline = { name = "Адреналин", cat = "medical", stack = 5, rarity = "epic", sell = 35, revive = true, color = rgb(255, 220, 60), size = V(0.3, 1, 0.3), desc = "Поднимает на ноги без помощи. Можно использовать, лёжа при смерти" },

	ammo_light = { name = "Лёгкие патроны", cat = "ammo", stack = 120, rarity = "common", sell = 0, pack = 12, color = rgb(200, 170, 60), size = V(0.8, 0.5, 0.6), desc = "Пистолет, револьвер и автомат" },
	ammo_shell = { name = "Дробь", cat = "ammo", stack = 120, rarity = "uncommon", sell = 0, pack = 6, color = rgb(200, 50, 40), size = V(0.8, 0.5, 0.6), desc = "Дробовик" },
	ammo_rifle = { name = "Винтовочные патроны", cat = "ammo", stack = 120, rarity = "rare", sell = 0, pack = 5, color = rgb(90, 110, 60), size = V(0.9, 0.5, 0.6), desc = "Снайперская винтовка" },
	arrow = { name = "Стрелы", cat = "ammo", stack = 120, rarity = "common", sell = 0, pack = 8, color = rgb(150, 110, 70), size = V(0.4, 0.4, 2.2), desc = "Лук" },
	bolt = { name = "Арбалетные болты", cat = "ammo", stack = 120, rarity = "uncommon", sell = 0, pack = 5, color = rgb(90, 90, 100), size = V(0.4, 0.4, 1.6), desc = "Арбалет" },

	molotov = { name = "Коктейль Молотова", cat = "throwable", stack = 5, rarity = "uncommon", sell = 8, color = rgb(120, 200, 80), size = V(0.6, 1.2, 0.6), desc = "Поджигает землю и зомби" },

	-- Материалы (ремонт, верстак)
	scrap = { name = "Металлолом", cat = "material", stack = 20, rarity = "common", sell = 3, color = rgb(120, 120, 130), size = V(1.2, 0.6, 1), desc = "Ремонт автобуса, крафт" },
	tape = { name = "Изолента", cat = "material", stack = 20, rarity = "common", sell = 3, color = rgb(60, 60, 70), size = V(0.8, 0.4, 0.8), shape = "Cylinder", desc = "Ремонт автобуса, крафт" },
	planks = { name = "Доски", cat = "material", stack = 20, rarity = "common", sell = 2, color = rgb(150, 110, 70), size = V(0.6, 0.4, 2.4), desc = "Ремонт, баррикады, стрелы" },
	cloth = { name = "Ткань", cat = "material", stack = 20, rarity = "common", sell = 2, color = rgb(200, 190, 170), size = V(1, 0.3, 1), desc = "Бинты, коктейли, койки" },
	rope = { name = "Верёвка", cat = "material", stack = 20, rarity = "common", sell = 2, color = rgb(170, 140, 90), size = V(1, 0.4, 1), desc = "Баррикады, колёса" },
	bottle = { name = "Пустая бутылка", cat = "material", stack = 20, rarity = "common", sell = 1, color = rgb(120, 180, 120), size = V(0.4, 1, 0.4), desc = "Коктейли, фонари" },
	herbs = { name = "Лечебные травы", cat = "material", stack = 20, rarity = "common", sell = 3, color = rgb(90, 170, 80), size = V(0.8, 0.6, 0.8), desc = "Аптечки, чай" },
	battery = { name = "Батарейки", cat = "material", stack = 20, rarity = "uncommon", sell = 5, color = rgb(60, 60, 60), size = V(0.6, 0.4, 0.4), desc = "Фонари, электрика автобуса" },
	spring = { name = "Пружины", cat = "material", stack = 20, rarity = "uncommon", sell = 4, color = rgb(170, 170, 180), size = V(0.5, 0.8, 0.5), desc = "Капканы, улучшения" },
	pipe = { name = "Металлическая труба", cat = "material", stack = 20, rarity = "uncommon", sell = 4, color = rgb(120, 120, 130), size = V(0.4, 0.4, 2.4), desc = "Болты, патроны, улучшения" },
	gunpowder = { name = "Порох", cat = "material", stack = 20, rarity = "rare", sell = 8, color = rgb(50, 45, 40), size = V(0.8, 0.8, 0.8), desc = "Патроны, вооружение автобуса" },
	circuit = { name = "Микросхема", cat = "material", stack = 20, rarity = "rare", sell = 12, color = rgb(40, 120, 60), size = V(0.8, 0.12, 0.6), desc = "Улучшения высокого уровня" },

	-- Инструменты и укрепления (крафтятся на верстаке)
	repair_kit = { name = "Ремкомплект", cat = "tool", stack = 3, rarity = "rare", sell = 20, busRepair = 350, color = rgb(40, 90, 160), size = V(1.2, 0.8, 0.8), desc = "+350 прочности автобуса (используйте рядом с ним)" },
	lantern = { name = "Фонарь", cat = "tool", stack = 3, rarity = "uncommon", sell = 8, lightTime = 180, color = rgb(255, 220, 120), size = V(0.6, 1, 0.6), desc = "Светит вокруг вас 3 минуты" },
	barricade = { name = "Баррикада", cat = "placeable", stack = 3, rarity = "uncommon", sell = 6, placeHP = 300, color = rgb(140, 100, 60), size = V(1.6, 0.6, 1), desc = "Ставится перед вами и задерживает зомби" },
	trap = { name = "Капкан", cat = "placeable", stack = 3, rarity = "uncommon", sell = 6, trapDamage = 60, trapRoot = 3, color = rgb(140, 140, 150), size = V(1, 0.3, 1), desc = "Ловит зомби: урон и обездвиживание" },

	-- Детали автобуса (прикрепляются к слотам на автобусе, см. shared/BusParts.lua).
	-- grab = true — крупный объект (v5, SPEC 2.7): в инвентарь не кладётся, лежит в мире, его переносят мышью
	-- и прикрепляют к автобусу клавишей Z. wall = true — стена, которую игрок ставит в пустой проём автобуса
	bus_wheel = { name = "Колесо", cat = "buspart", stack = 1, rarity = "common", sell = 10, grab = true, color = rgb(30, 30, 30), size = V(1.2, 3.2, 3.2), shape = "Cylinder", desc = "Нужно 4 колеса, чтобы автобус поехал. Возьмите колесо (ЛКМ), поднесите к пустой ступице и прикрепите (Z)" },
	plate_wood = { name = "Деревянная стена", cat = "buspart", stack = 1, rarity = "common", sell = 8, grab = true, wall = true, color = rgb(140, 100, 60), size = V(3, 2, 0.4), desc = "Стена из досок. Возьмите (ЛКМ), поднесите к пустому проёму борта или задней стены автобуса и прикрепите (Z). Не пускает зомби внутрь, +150 прочности" },
	plate_metal = { name = "Металлическая стена", cat = "buspart", stack = 1, rarity = "uncommon", sell = 18, grab = true, wall = true, color = rgb(120, 124, 130), size = V(3, 2, 0.3), material = Enum.Material.DiamondPlate, desc = "Стена из стальных листов. Ставится так же — в пустой проём борта или сзади. Прочнее деревянной: не пускает зомби внутрь, +350 прочности" },
	grill_spike = { name = "Шипастая решётка", cat = "buspart", stack = 1, rarity = "uncommon", sell = 25, color = rgb(90, 90, 95), size = V(3, 1.2, 0.8), material = Enum.Material.Metal, desc = "Таран x2.5, автобус меньше страдает" },
	grill_saw = { name = "Решётка с пилами", cat = "buspart", stack = 1, rarity = "rare", sell = 60, color = rgb(170, 170, 175), size = V(3, 1.2, 1), material = Enum.Material.Metal, desc = "Таран x4, пилы режут всё впереди" },
	turret_auto = { name = "Автотурель", cat = "buspart", stack = 1, rarity = "epic", sell = 120, color = rgb(70, 76, 60), size = V(1.6, 1.2, 1.6), material = Enum.Material.Metal, desc = "Ставится на крышу, сама стреляет по зомби" },
	bus_lamp = { name = "Прожектор", cat = "buspart", stack = 1, rarity = "uncommon", sell = 15, color = rgb(255, 240, 190), size = V(1, 1, 1), material = Enum.Material.Neon, desc = "Ночью зомби в свете замедляются" },
	bunk = { name = "Койка", cat = "buspart", stack = 1, rarity = "common", sell = 10, color = rgb(110, 60, 50), size = V(1.6, 0.6, 3), material = Enum.Material.Fabric, desc = "Ещё одно спальное место в салоне" },
	alarm_box = { name = "Сигнализация", cat = "buspart", stack = 1, rarity = "rare", sell = 30, color = rgb(200, 40, 40), size = V(1, 1, 0.6), desc = "Будит спящих заранее, когда зомби рядом" },

	-- Для заданий
	cache_key = { name = "Ключ от тайника", cat = "quest", stack = 1, rarity = "epic", sell = 0, color = rgb(255, 210, 60), size = V(0.8, 0.2, 0.3), desc = "Открывает тайник из цели биома" },

	-- Ценности
	old_coin = { name = "Старинная монета", cat = "valuable", stack = 10, rarity = "uncommon", sell = 18, color = rgb(210, 170, 60), size = V(0.6, 0.15, 0.6), shape = "Cylinder" },
	watch = { name = "Карманные часы", cat = "valuable", stack = 10, rarity = "uncommon", sell = 26, color = rgb(220, 200, 120), size = V(0.6, 0.2, 0.6) },
	camera = { name = "Фотоаппарат", cat = "valuable", stack = 10, rarity = "uncommon", sell = 30, color = rgb(40, 40, 45), size = V(1, 0.7, 0.6) },
	silver_bar = { name = "Серебряный слиток", cat = "valuable", stack = 10, rarity = "rare", sell = 60, color = rgb(200, 205, 215), size = V(1.2, 0.4, 0.6), material = Enum.Material.Metal },
	orchid = { name = "Редкая орхидея", cat = "valuable", stack = 10, rarity = "rare", sell = 55, color = rgb(230, 120, 220), size = V(0.8, 1, 0.8) },
	wolf_pelt = { name = "Волчья шкура", cat = "valuable", stack = 10, rarity = "rare", sell = 70, color = rgb(130, 130, 130), size = V(2, 0.3, 1.4) },
	gold_bar = { name = "Золотой слиток", cat = "valuable", stack = 10, rarity = "epic", sell = 150, color = rgb(255, 200, 40), size = V(1.2, 0.4, 0.6), material = Enum.Material.Foil },
	amber = { name = "Янтарь с жуком", cat = "valuable", stack = 10, rarity = "epic", sell = 170, color = rgb(255, 150, 30), size = V(0.7, 0.7, 0.7), shape = "Ball", material = Enum.Material.Glass },
	skull_ring = { name = "Перстень с черепом", cat = "valuable", stack = 10, rarity = "epic", sell = 160, color = rgb(180, 180, 160), size = V(0.5, 0.5, 0.2) },
	jade_idol = { name = "Нефритовый идол", cat = "valuable", stack = 10, rarity = "legendary", sell = 420, color = rgb(60, 200, 120), size = V(0.9, 1.6, 0.9), material = Enum.Material.Glass },
	meteorite = { name = "Осколок метеорита", cat = "valuable", stack = 10, rarity = "legendary", sell = 450, color = rgb(90, 60, 160), size = V(1, 0.9, 1), shape = "Ball", material = Enum.Material.Neon },
}

for id, item in pairs(Items.List) do
	item.id = id
	item.stack = math.max(1, math.floor(item.stack or 1))
end

-- Размер стопки предмета (1 для неизвестных)
function Items.StackSize(id)
	local item = Items.List[id]
	return item and item.stack or 1
end

-- Таблицы добычи. "w:id" = оружие (если такого оружия нет в Weapons.List, на месте ничего не появится)
Items.LootTables = {
	gas_station = { rolls = { 4, 7 }, entries = { { "gas_can", 6 }, { "coal", 4 }, { "fuel_barrel", 1.5 }, { "chips", 5 }, { "water", 5 }, { "energy_drink", 3 }, { "coffee", 2 }, { "scrap", 4 }, { "tape", 3 }, { "bottle", 3 }, { "rope", 1 }, { "battery", 1 }, { "ammo_light", 3 }, { "watch", 1 }, { "molotov", 1 }, { "w:pistol", 0.5 }, { "w:bat", 0.6 } } },
	motel = { rolls = { 3, 6 }, entries = { { "canned_food", 4 }, { "water", 4 }, { "coffee", 3 }, { "bandage", 3 }, { "cloth", 3 }, { "herbs", 1 }, { "watch", 2 }, { "camera", 2 }, { "old_coin", 2 }, { "silver_bar", 0.6 }, { "ammo_light", 2 }, { "w:machete", 0.5 }, { "w:revolver", 0.35 }, { "w:pistol", 0.6 } } },
	ranch = { rolls = { 3, 6 }, entries = { { "coal", 4 }, { "planks", 5 }, { "rope", 3 }, { "spring", 1 }, { "canned_food", 4 }, { "ammo_shell", 3 }, { "old_coin", 2 }, { "silver_bar", 1 }, { "arrow", 3 }, { "w:shotgun", 0.4 }, { "w:fire_axe", 0.4 }, { "w:bow", 0.45 } } },
	store = { rolls = { 4, 7 }, entries = { { "canned_food", 5 }, { "chips", 6 }, { "water", 5 }, { "energy_drink", 3 }, { "coffee", 3 }, { "tape", 3 }, { "scrap", 2 }, { "battery", 2 }, { "bottle", 2 }, { "cloth", 2 }, { "watch", 1.5 }, { "camera", 1.5 }, { "molotov", 1 }, { "w:bat", 0.6 } } },
	pharmacy = { rolls = { 3, 6 }, entries = { { "bandage", 7 }, { "medkit", 3 }, { "adrenaline", 0.8 }, { "herbs", 3 }, { "cloth", 3 }, { "coffee", 3 }, { "energy_drink", 3 }, { "water", 3 } } },
	police = { rolls = { 4, 6 }, entries = { { "ammo_light", 6 }, { "ammo_shell", 4 }, { "ammo_rifle", 1.5 }, { "gunpowder", 1.2 }, { "spring", 1 }, { "bandage", 3 }, { "medkit", 1 }, { "coffee", 2 }, { "w:pistol", 1.4 }, { "w:revolver", 1 }, { "w:shotgun", 0.7 }, { "w:rifle", 0.25 } } },
	apartment = { rolls = { 3, 6 }, entries = { { "canned_food", 4 }, { "chips", 3 }, { "water", 3 }, { "cloth", 2 }, { "battery", 1.5 }, { "circuit", 0.3 }, { "watch", 2 }, { "camera", 2 }, { "silver_bar", 0.7 }, { "gold_bar", 0.25 }, { "bandage", 2 }, { "ammo_light", 1.5 }, { "w:pistol", 0.4 }, { "w:bat", 0.6 }, { "w:katana", 0.12 } } },
	camp = { rolls = { 3, 6 }, entries = { { "canned_food", 4 }, { "coffee", 3 }, { "medkit", 1 }, { "rope", 3 }, { "herbs", 3 }, { "cloth", 2 }, { "arrow", 4 }, { "bolt", 2 }, { "orchid", 2 }, { "w:machete", 1 }, { "w:bow", 0.8 }, { "w:crossbow", 0.3 } } },
	temple = { rolls = { 4, 6 }, entries = { { "old_coin", 5 }, { "jade_idol", 0.6 }, { "gold_bar", 1 }, { "amber", 1.5 }, { "orchid", 2 }, { "herbs", 2 }, { "arrow", 3 }, { "w:katana", 0.3 }, { "w:machete", 0.8 } } },
	stilt_hut = { rolls = { 3, 5 }, entries = { { "canned_food", 4 }, { "water", 4 }, { "planks", 3 }, { "rope", 2 }, { "herbs", 2 }, { "orchid", 2 }, { "amber", 0.6 }, { "bolt", 2 }, { "w:crossbow", 0.3 } } },
	crypt = { rolls = { 3, 6 }, entries = { { "skull_ring", 1.5 }, { "old_coin", 5 }, { "silver_bar", 2 }, { "gold_bar", 1 }, { "bottle", 2 }, { "bolt", 3 }, { "bandage", 2 }, { "w:crossbow", 0.5 }, { "w:sledgehammer", 0.3 } } },
	boathouse = { rolls = { 3, 6 }, entries = { { "coal", 4 }, { "gas_can", 3 }, { "canned_food", 4 }, { "scrap", 3 }, { "tape", 3 }, { "rope", 3 }, { "pipe", 2 }, { "spring", 1 }, { "ammo_shell", 3 }, { "w:fire_axe", 0.5 } } },
	cabin = { rolls = { 3, 6 }, entries = { { "canned_food", 5 }, { "coffee", 4 }, { "coal", 4 }, { "cloth", 2 }, { "rope", 2 }, { "wolf_pelt", 2 }, { "ammo_rifle", 2 }, { "ammo_light", 2 }, { "bandage", 2 }, { "w:sniper", 0.35 }, { "w:fire_axe", 0.6 } } },
	weather_station = { rolls = { 3, 6 }, entries = { { "scrap", 4 }, { "tape", 4 }, { "battery", 3 }, { "circuit", 1 }, { "spring", 2 }, { "gas_can", 3 }, { "energy_drink", 3 }, { "meteorite", 0.4 }, { "silver_bar", 1 }, { "ammo_rifle", 2 }, { "medkit", 1 } } },
	bunker = { rolls = { 4, 7 }, entries = { { "ammo_light", 5 }, { "ammo_rifle", 3 }, { "ammo_shell", 3 }, { "gunpowder", 2.5 }, { "pipe", 2 }, { "circuit", 1 }, { "medkit", 2 }, { "adrenaline", 1 }, { "molotov", 2 }, { "gold_bar", 1 }, { "meteorite", 0.5 }, { "w:rifle", 0.5 }, { "w:sniper", 0.4 }, { "w:sledgehammer", 0.4 }, { "w:katana", 0.3 } } },
	military_wreck = { rolls = { 2, 4 }, entries = { { "ammo_light", 5 }, { "ammo_shell", 3 }, { "scrap", 4 }, { "gunpowder", 2 }, { "pipe", 2 }, { "spring", 1.5 }, { "molotov", 2 }, { "fuel_barrel", 1 }, { "w:rifle", 0.3 } } },
	safe = { rolls = { 2, 3 }, entries = { { "gold_bar", 3 }, { "silver_bar", 4 }, { "watch", 3 }, { "skull_ring", 1 }, { "circuit", 1.5 }, { "meteorite", 0.4 }, { "jade_idol", 0.4 }, { "adrenaline", 1.2 } } },
	roadside = { rolls = { 1, 2 }, entries = { { "coal", 4 }, { "gas_can", 2 }, { "chips", 3 }, { "water", 3 }, { "scrap", 3 }, { "bottle", 2 }, { "cloth", 2 }, { "pipe", 1 }, { "ammo_light", 2 }, { "bandage", 2 } } },
	-- События и цели
	airdrop = { rolls = { 4, 6 }, entries = { { "medkit", 3 }, { "adrenaline", 1.5 }, { "ammo_rifle", 3 }, { "ammo_light", 4 }, { "gunpowder", 3 }, { "circuit", 2 }, { "gold_bar", 1.5 }, { "repair_kit", 2 }, { "molotov", 2 }, { "w:rifle", 0.6 }, { "w:sniper", 0.5 }, { "w:katana", 0.5 } } },
	cache = { rolls = { 3, 5 }, entries = { { "gold_bar", 3 }, { "jade_idol", 0.8 }, { "meteorite", 0.8 }, { "circuit", 3 }, { "adrenaline", 2 }, { "repair_kit", 2 }, { "w:sniper", 0.7 }, { "w:katana", 0.7 }, { "w:sledgehammer", 0.7 } } },
	elite = { rolls = { 2, 4 }, entries = { { "gold_bar", 2 }, { "silver_bar", 3 }, { "circuit", 2 }, { "gunpowder", 3 }, { "repair_kit", 1.5 }, { "adrenaline", 1 }, { "w:crossbow", 0.5 }, { "w:rifle", 0.4 } } },
	meteor = { rolls = { 1, 2 }, entries = { { "meteorite", 2 }, { "circuit", 1 }, { "battery", 2 } } },
}

-- Магазин на станциях: цена покупки
Items.Shop = {
	supplies = {
		{ id = "canned_food", price = 10 },
		{ id = "chips", price = 4 },
		{ id = "water", price = 4 },
		{ id = "coffee", price = 12 },
		{ id = "herbal_tea", price = 10 },
		{ id = "energy_drink", price = 16 },
		{ id = "bandage", price = 10 },
		{ id = "medkit", price = 40 },
		{ id = "adrenaline", price = 90 },
		{ id = "coal", price = 9 },
		{ id = "gas_can", price = 24 },
		{ id = "fuel_barrel", price = 52 },
		{ id = "molotov", price = 28 },
		{ id = "repair_kit", price = 90 },
		{ id = "lantern", price = 25 },
		{ id = "barricade", price = 30 },
		{ id = "trap", price = 28 },
	},
	materials = {
		{ id = "scrap", price = 8 },
		{ id = "tape", price = 8 },
		{ id = "planks", price = 6 },
		{ id = "cloth", price = 6 },
		{ id = "rope", price = 5 },
		{ id = "bottle", price = 3 },
		{ id = "herbs", price = 6 },
		{ id = "battery", price = 10 },
		{ id = "spring", price = 12 },
		{ id = "pipe", price = 12 },
		{ id = "gunpowder", price = 20 },
	},
	parts = {
		{ id = "bus_wheel", price = 35 },
		{ id = "plate_wood", price = 30 },
		{ id = "plate_metal", price = 70 },
		{ id = "grill_spike", price = 110 },
		{ id = "bus_lamp", price = 45 },
		{ id = "bunk", price = 40 },
		{ id = "alarm_box", price = 90 },
	},
	ammo = {
		{ id = "ammo_light", price = 12 },
		{ id = "ammo_shell", price = 14 },
		{ id = "ammo_rifle", price = 22 },
		{ id = "arrow", price = 8 },
		{ id = "bolt", price = 12 },
	},
}

Items.RepairService = { hp = 300, price = 70 }

return Items
