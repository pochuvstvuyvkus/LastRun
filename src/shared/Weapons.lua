-- Оружие: характеристики. Модели — в WeaponModels, анимации — в client/CharAnimator.
-- kind: melee (ближний бой), gun (пули), bow (лук с натяжением), crossbow (арбалет), throw (бросок)
local Weapons = {}

Weapons.List = {
	-- Ближний бой: combo — последовательность анимаций, последний удар серии умножается на comboBonus.
	-- hitDelay — момент попадания после начала замаха (анимация бьёт ровно в этот момент),
	-- breakMult — множитель урона по завалам, step — шаг вперёд при ударе, heavy — тяжёлый свист.
	-- vmScale — масштаб модели в руках от первого лица (лопата короче и ближе, как в оригинале)
	shovel = {
		name = "Лопата", kind = "melee", rarity = "common", price = 40,
		damage = 22, cooldown = 0.72, range = 7.5, arc = 80, knockback = 16,
		combo = { "shovel_side", "shovel_back", "shovel_overhead" }, comboBonus = 1.35, hitDelay = 0.2,
		breakMult = 1.3, step = 7, vmScale = 0.78,
		desc = "Надёжная. Боковой замах, обратный и удар сверху — третий сильнее",
	},
	bat = {
		name = "Бита с гвоздями", kind = "melee", rarity = "common", price = 60,
		damage = 28, cooldown = 0.68, range = 7.5, arc = 90, knockback = 32, stun = 0.25,
		combo = { "bat_swing", "bat_backswing" }, comboBonus = 1.25, hitDelay = 0.19,
		breakMult = 1, step = 6,
		desc = "Сильно отбрасывает",
	},
	machete = {
		name = "Мачете", kind = "melee", rarity = "uncommon", price = 110,
		damage = 19, cooldown = 0.36, range = 6.8, arc = 70, knockback = 5,
		combo = { "machete_slash_r", "machete_slash_l", "machete_rise", "machete_stab" }, comboBonus = 1.9, hitDelay = 0.1,
		breakMult = 0.6, step = 4,
		desc = "Очень быстрые удары, четвёртый — укол x1.9",
	},
	fire_axe = {
		name = "Пожарный топор", kind = "melee", rarity = "rare", price = 220,
		damage = 62, cooldown = 1.15, range = 8, arc = 60, knockback = 38, stun = 0.6,
		combo = { "axe_chop", "axe_sweep" }, comboBonus = 1.2, hitDelay = 0.32,
		breakMult = 2, step = 8, heavy = true,
		desc = "Медленный, но оглушает. Лучший против завалов",
	},
	katana = {
		name = "Катана", kind = "melee", rarity = "epic", price = 450,
		damage = 38, cooldown = 0.48, range = 9, arc = 100, knockback = 10, lunge = 20,
		combo = { "katana_slash_r", "katana_slash_l", "katana_spin" }, comboBonus = 1.8, hitDelay = 0.13,
		breakMult = 0.7, step = 0,
		desc = "Выпад вперёд, третий удар — круговой",
	},
	sledgehammer = {
		name = "Кувалда", kind = "melee", rarity = "epic", price = 380,
		damage = 85, cooldown = 1.7, range = 8.5, arc = 360, aoe = 11, knockback = 70, stun = 1.2,
		combo = { "sledge_slam" }, comboBonus = 1, hitDelay = 0.48,
		breakMult = 2.4, step = 5, heavy = true,
		desc = "Удар по земле бьёт всех вокруг",
	},

	-- Огнестрел. casing — выбрасывает гильзу; shotSound/drySound — ключи shared/Sounds (выстрел/пустой щелчок);
	-- reloadStyle — анимация перезарядки: magazine | cylinder | shells | rifle_magazine | bolt | string;
	-- boltCycle — затвор передёргивается после каждого выстрела (гильза вылетает в этот момент)
	pistol = {
		name = "Пистолет", kind = "gun", rarity = "common", price = 90,
		damage = 26, cooldown = 0.22, ammo = "ammo_light", mag = 12, reload = 1.6,
		spread = 1.6, aimSpread = 0.45, range = 280, headshot = 2, recoil = 5, breakMult = 0.25,
		casing = true, reloadStyle = "magazine", shotSound = "pistol_shot", drySound = "pistol_dry",
		desc = "Надёжный, магазин на 12 патронов. Выстрел в голову x2",
	},
	revolver = {
		name = "Револьвер", kind = "gun", rarity = "uncommon", price = 150,
		damage = 46, cooldown = 0.42, ammo = "ammo_light", mag = 6, reload = 2.0,
		spread = 1.2, aimSpread = 0.3, range = 320, headshot = 2, recoil = 8, breakMult = 0.25,
		reloadStyle = "cylinder", shotSound = "revolver_shot", drySound = "pistol_dry",
		desc = "Точный. Выстрел в голову x2",
	},
	shotgun = {
		name = "Дробовик", kind = "gun", rarity = "rare", price = 290,
		damage = 13, pellets = 8, cooldown = 0.95, ammo = "ammo_shell", mag = 2, reload = 2.3,
		spread = 6.5, aimSpread = 4.5, range = 95, headshot = 1.5, knockback = 22, recoil = 18, twoHanded = true,
		breakMult = 0.25, reloadStyle = "shells", shotSound = "shotgun_shot", drySound = "pistol_dry",
		desc = "8 дробин, отбрасывает",
	},
	rifle = {
		name = "Автомат", kind = "gun", rarity = "epic", price = 540,
		damage = 19, cooldown = 0.11, auto = true, ammo = "ammo_light", mag = 30, reload = 2.6,
		spread = 2.4, aimSpread = 0.9, range = 320, headshot = 1.8, recoil = 3, twoHanded = true,
		breakMult = 0.25, casing = true, reloadStyle = "rifle_magazine", shotSound = "rifle_shot", drySound = "pistol_dry",
		desc = "Автоматический огонь",
	},
	sniper = {
		name = "Снайперская винтовка", kind = "gun", rarity = "legendary", price = 720,
		damage = 160, cooldown = 1.35, ammo = "ammo_rifle", mag = 5, reload = 3.0,
		spread = 5, aimSpread = 0.05, range = 1000, headshot = 2.5, pierce = 3, recoil = 24,
		scope = true, zoomFov = 16, twoHanded = true, breakMult = 0.25, casing = true,
		reloadStyle = "bolt", boltCycle = true, shotSound = "sniper_shot", drySound = "pistol_dry",
		desc = "Оптика (ПКМ), пробивает до 3 зомби",
	},

	-- Стрелковое с летящими снарядами
	bow = {
		name = "Лук", kind = "bow", rarity = "uncommon", price = 160,
		damageMin = 16, damageMax = 90, drawTime = 0.85, cooldown = 0.3, ammo = "arrow",
		speedMin = 90, speedMax = 300, gravity = 45, headshot = 2, pierce = 1, knockback = 8, breakMult = 0.4,
		desc = "Зажмите, чтобы натянуть тетиву. Полное натяжение — x5 урона",
	},
	crossbow = {
		name = "Арбалет", kind = "crossbow", rarity = "rare", price = 420,
		damage = 115, cooldown = 0.25, reload = 1.5, mag = 1, ammo = "bolt",
		speed = 340, gravity = 14, pierce = 3, headshot = 2, knockback = 24,
		scope = true, zoomFov = 40, breakMult = 0.4, reloadStyle = "string", shotSound = "crossbow_shot",
		desc = "Болт пробивает 3 цели. Долгая перезарядка",
	},

	-- Бросок
	molotov = {
		name = "Коктейль Молотова", kind = "throw", rarity = "uncommon", price = 0, item = "molotov",
		cooldown = 0.9, speed = 80, gravity = 70, radius = 13, burnDps = 24, burnTime = 6,
		desc = "Огненная лужа на 6 секунд",
	},
}

for id, w in pairs(Weapons.List) do
	w.id = id
end

-- Порядок в магазине
Weapons.ShopOrder = { "bat", "machete", "fire_axe", "katana", "sledgehammer", "pistol", "revolver", "shotgun", "rifle", "sniper", "bow", "crossbow" }

-- Звук доставания оружия (ключ shared/Sounds)
local EQUIP_BY_KIND = { melee = "equip_melee", gun = "equip_gun", crossbow = "equip_gun", bow = "equip_bow" }
function Weapons.EquipSound(id)
	local w = Weapons.List[id]
	if not w then
		return nil
	end
	return w.equipSound or EQUIP_BY_KIND[w.kind]
end

-- Вид попадания по материалу поверхности: "wood" | "metal" | "stone" | "glass" | "dirt"
-- (плоть "flesh" определяется попаданием по зомби, промах — "air")
local KIND_BY_MATERIAL = {
	Wood = "wood", WoodPlanks = "wood", Cardboard = "wood", RoofShingles = "wood",
	Metal = "metal", CorrodedMetal = "metal", DiamondPlate = "metal", Foil = "metal",
	Glass = "glass", Ice = "glass", Glacier = "glass", ForceField = "glass", Neon = "glass",
	Grass = "dirt", LeafyGrass = "dirt", Sand = "dirt", Ground = "dirt", Mud = "dirt", Snow = "dirt",
	Salt = "dirt", Fabric = "dirt", Carpet = "dirt", Leather = "dirt", Rubber = "dirt", Water = "dirt",
}

Weapons.HitKinds = { "flesh", "wood", "metal", "stone", "glass", "dirt", "bus" }

function Weapons.MaterialKind(material)
	if typeof(material) == "EnumItem" then
		return KIND_BY_MATERIAL[material.Name] or "stone"
	end
	return "stone"
end

-- Вид попадания по детали и её материалу: металл автобуса звучит отдельно ("bus" — гулкий кузов)
function Weapons.SurfaceKind(instance, material)
	local kind = Weapons.MaterialKind(material)
	if kind == "metal" and typeof(instance) == "Instance" then
		local bus = workspace:FindFirstChild("Bus")
		if bus and instance:IsDescendantOf(bus) then
			return "bus"
		end
	end
	return kind
end

-- Допустимый вид попадания (от сервера/клиента); иначе nil
local VALID_KIND = { flesh = true, wood = true, metal = true, stone = true, glass = true, dirt = true, bus = true, air = true }
function Weapons.ValidKind(kind)
	if type(kind) == "string" and VALID_KIND[kind] then
		return kind
	end
	return nil
end

return Weapons
