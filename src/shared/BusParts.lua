-- Детали автобуса (v5). Автобус собирают в депо и дорабатывают в пути: деталь — предмет в руках или
-- переносимый объект (колёса, стены — модуль GRAB), который крепится к слоту на автобусе.
-- У каждого слота на автобусе есть невидимая метка: тег LR_BusSlot, атрибуты SlotType, SlotIndex,
-- Accepts (id через запятую), Free; CFrame метки — CFrame установленной детали.
local BusParts = {}

-- Слоты на корпусе
BusParts.Slots = {
	wheel = { name = "Колесо", count = 4, required = true, accepts = { "bus_wheel" } },
	side = { name = "Стена", count = 8, accepts = { "plate_wood", "plate_metal" } }, -- по 4 секции на борт между стойками
	rear = { name = "Задняя стена", count = 1, accepts = { "plate_wood", "plate_metal" } },
	front = { name = "Решётка", count = 1, accepts = { "grill_spike", "grill_saw" } },
	roof = { name = "Крыша", count = 2, accepts = { "turret_auto" } },
	lamp = { name = "Прожектор", count = 2, accepts = { "bus_lamp" } },
	cabin = { name = "Салон", count = 3, accepts = { "bunk", "alarm_box" } },
}

-- Порядок слотов при сборке автобуса
BusParts.SlotOrder = { "wheel", "side", "rear", "front", "roof", "lamp", "cabin" }

-- Эффекты деталей. slot — основной слот (подпись в интерфейсе), slots — все слоты, куда деталь подходит
BusParts.List = {
	bus_wheel = { slot = "wheel" },
	plate_wood = { slot = "side", slots = { "side", "rear" }, armor = 150, blocksZombies = true },
	plate_metal = { slot = "side", slots = { "side", "rear" }, armor = 350, blocksZombies = true, crashMult = 0.95 },
	grill_spike = { slot = "front", ramMult = 2.5, selfDamageMult = 0.4 },
	grill_saw = { slot = "front", ramMult = 4, selfDamageMult = 0.25, sawDps = 24 },
	turret_auto = { slot = "roof", damage = 14, interval = 0.45, range = 90 },
	bus_lamp = { slot = "lamp", slow = 0.35 },
	bunk = { slot = "cabin", beds = 1, sleepMult = 1.15 },
	alarm_box = { slot = "cabin", hearMult = 1.6 },
}

for id, p in pairs(BusParts.List) do
	p.id = id
	p.slots = p.slots or { p.slot }
end

function BusParts.Get(id)
	return BusParts.List[id]
end

-- Все типы слотов, к которым подходит деталь (пустой список — это не деталь автобуса)
function BusParts.SlotsFor(id)
	local p = BusParts.List[id]
	return p and p.slots or {}
end

return BusParts
