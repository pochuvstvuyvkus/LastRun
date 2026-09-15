-- Общие настройки игры. Баланс меняется здесь.
local Config = {}

Config.GameTitle = "Последний рейс"
Config.Seed = 0 -- 0 = новый случайный маршрут в каждом заезде

-- Маршрут и мир
Config.StudsPerKm = 200
Config.RouteKm = 100
Config.RoadHalfWidth = 14
Config.ChunkLength = 160
Config.ChunkAhead = 1100
Config.ChunkBehind = 520
Config.GroundWidth = 560
Config.DepotLength = 320

-- Станции (зачистка, торговец, ремонт, сон)
Config.Stations = {
	{ km = 15, name = "Станция «Ржавый кактус»" },
	{ km = 34, name = "Станция «Бетонный узел»" },
	{ km = 53, name = "Станция «Зелёный ад»" },
	{ km = 70, name = "Станция «Туманный причал»" },
	{ km = 87, name = "Станция «Ледяной перевал»" },
}
Config.StationTriggerDistance = 200
Config.FinalName = "КОНЕЧНАЯ"

-- Автобус
Config.Bus = {
	MaxHP = 1000,
	MaxSpeed = 48, -- studs/сек
	ReverseSpeed = 10,
	Accel = 8,
	Brake = 26,
	Coast = 5,
	MaxHeadingOffset = math.rad(30), -- насколько можно повернуть относительно дороги
	SteerRate = math.rad(42),
	AutoAlignRate = math.rad(16), -- автобус сам выравнивается по дороге, если не рулить
	MaxDeviation = 62, -- максимальное отклонение от центра дороги
	FuelMax = 100,
	FuelPerKm = 8.5,
	StartFuel = 70,
	RamDamage = 1.5, -- урон зомби = скорость * это
	RamSelfDamage = 4,
	CollisionDamage = 1.1, -- урон автобусу = скорость * это
	RideHeight = 3,
	SpeedDisplayMult = 1.7, -- studs/сек -> "км/ч" на спидометре
}

-- Игрок
Config.Player = {
	WalkSpeed = 16,
	SprintMult = 1.45,
	MaxHP = 100,
	-- Расход (v5): сытость 100 → 0 примерно за 25 минут; здоровье восстанавливается только сытым и тратит сытость
	HungerDrain = 100 / 1500, -- сытости в секунду
	SprintHungerMult = 1.8, -- на бегу голод идёт быстрее
	RegenMinHunger = 40, -- регенерация здоровья только при сытости не ниже
	RegenDelay = 8, -- секунд без урона до начала регенерации
	RegenRate = 0.8, -- HP в секунду
	RegenHungerCost = 0.4, -- сытости за 1 восстановленный HP
	StarveDamage = 0.5, -- HP в секунду при нулевой сытости
	DownedTime = 35,
	ReviveTime = 3.5,
	ReviveHealth = 35,
	RespawnDelay = 10,
	DeathMoneyLoss = 0.2,
	FallBehindDistance = 700,
	StartMoney = 40,
}

-- Сон
Config.Sleep = {
	NightOnly = true, -- лечь можно только ночью
	HearRadius = 60,
	AlarmHearRadius = 95,
	ThreatGain = 0.36,
	ThreatDecay = 0.2,
	WakeThreshold = 1,
	AlarmWakeThreshold = 0.72,
	AttackedDamageMult = 1.5,
	SleepyDuration = 9,
	WellRestedDuration = 240,
	AdrenalineDuration = 10,
	TimeScaleAllAsleep = 10,
	NightmareChance = 0.14,
	NightmareAlertRadius = 150,
	NoZombieRadius = 26,
}

-- Время суток
Config.DayLength = 960 -- секунд на сутки (16 минут)
Config.StartClock = 7 -- заезд начинается на рассвете
Config.NightStart = 20
Config.NightEnd = 5.5

-- Зомби
Config.Zombies = {
	MaxActive = 24,
	PerPlayerExtra = 5,
	SpawnMin = 110,
	SpawnMax = 175,
	DespawnDistance = 480,
	AggroRange = 130,
	NightAggroRange = 185,
	NightSpeedMult = 1.15,
	HPScalePerKm = 1 / 110,
	DamageScalePerKm = 1 / 170,
	UpdateRate = 8,
	POIActivateRadius = 115,
	-- Плавный рост: желаемое число бродячих зомби = (StartDesired + PerKm*км + PerKm2*км^2) * множители
	-- v5: пользователю зомби показалось слишком много — всё примерно вдвое реже
	StartDesired = 0.8,
	PerKm = 0.1,
	PerKm2 = 0.0012,
	GroupStart = { 1, 1 }, -- размер группы в начале
	GroupLate = { 2, 4 }, -- размер группы к концу маршрута
	POICountStart = { 1, 1 }, -- зомби в зданиях в начале
	POICountLate = { 1, 3 }, -- и к концу
	SpawnGraceKm = 2.0, -- первые км после депо без случайных зомби
	POIChanceStart = 0.35, -- шанс, что в здании вообще есть зомби, в начале маршрута
	POIChanceLate = 0.85, -- и к концу
	AliveCapStart = 12, -- здания не «просыпаются», если живых зомби уже столько (в начале)
	AliveCapLate = 38, -- и к концу маршрута
	SpawnInterval = 2.2,
}

-- Режим запуска сервера:
-- "auto"  — публичный сервер = лобби, зарезервированный (после телепорта группы) = заезд;
--           в Studio — лобби, а «Старт» запускает заезд на этом же сервере
-- "lobby" — всегда лобби;  "run" — сразу заезд (удобно для быстрых тестов в Studio)
-- Инвентарь: слоты 1..HotbarSlots — в руках (переключение 1-0), остальные — рюкзак (Tab)
Config.Inventory = {
	HotbarSlots = 10,
	BackpackSlots = 18,
}

-- Стартовый набор для проверки оружия (выключить перед публикацией: Enabled = false)
Config.TestKit = {
	Enabled = true,
	Weapons = { "bow", "pistol" },
	Items = { arrow = 20, ammo_light = 36 },
}

Config.StartMode = "auto"
Config.MaxPartySize = 4
Config.PartyStartTimeout = 25 -- сек ожидания участников на сервере заезда
Config.DataStoreName = "LastRun_Profiles_v1"
Config.AutosaveInterval = 120

-- Границы карты: коридор вокруг дороги, дальше не проехать и не пройти
Config.Bounds = {
	HalfWidth = 300, -- до стены от центра дороги
	WallThickness = 30,
	PlayerLimit = 335, -- дальше этого игрока/зомби возвращает внутрь
	BackS = -60, -- позади депо
	FrontExtra = 260, -- за конечной
}

-- Цели биомов
Config.Objectives = {
	PerBiome = 3,
	RequiredPerBiome = 2,
	MinOffset = 25, -- смещение места цели от дороги (дальше идти пешком)
	MaxOffset = 110,
}

-- Случайные события в пути
Config.Events = {
	MinGapKm = 3,
	MaxGapKm = 6,
	StartKm = 4,
}


return Config
