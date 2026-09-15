-- Смена дня и ночи по ключевым кадрам: синий час, тёплый рассвет, пасмурный день, красный закат,
-- фиолетовые сумерки, тёмно-синяя ночь со звёздами и холодным лунным светом.
-- Поверх — атмосфера биомов с плавным переходом, песчаная буря, кровавая луна и тёмные ночи «Кошмара».
-- Фонари и окна с тегом LR_NightLight включаются ночью (DayNight сам включает/выключает их).
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Biomes = require(Shared.Biomes)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local DN = {}
DN.LightTag = "LR_NightLight"

local S
local clock = Config.StartClock
local timeScale = 1
local atmosphere
local tint
local bloom
local sunRays
local clouds
local sky
local rng = Random.new()
local storm = nil
local nextStormRoll = 0
local lastNight = nil
local lastPhase = nil
local lightsOn = nil
local lightQueue = {}
local original = setmetatable({}, { __mode = "k" }) -- [лампа] = вид «включено»
local cur = nil
local blood = 0

local rgb = Color3.fromRGB

-- Палитры ключевых кадров ---------------------------------------------------------------
-- dens — добавка к плотности дымки биома; bio — насколько просвечивает оттенок биома
local NUMS = { "dens", "haze", "glare", "bright", "expo", "sat", "con", "cc", "bloom", "rays", "cover", "cdens", "bio" }
local COLORS = { "atmo", "decay", "amb", "out", "top", "bottom", "tint", "cloud" }

local function with(base, over)
	local t = {}
	for k, v in pairs(base) do
		t[k] = v
	end
	for k, v in pairs(over) do
		t[k] = v
	end
	return t
end

-- пасмурный серый день (стиль v3)
local DAY = {
	atmo = rgb(150, 160, 174), decay = rgb(92, 100, 114), dens = 0, haze = 2.4, glare = 0,
	amb = rgb(78, 82, 92), out = rgb(118, 124, 136), bright = 1.9, top = rgb(18, 18, 20), bottom = rgb(0, 0, 0), expo = 0,
	tint = rgb(226, 234, 255), sat = -0.24, con = 0.1, cc = 0, bloom = 0.6, rays = 0.04,
	cloud = rgb(170, 174, 182), cover = 0.78, cdens = 0.6, bio = 1,
}
local AFTERNOON = with(DAY, {
	atmo = rgb(172, 158, 148), decay = rgb(106, 92, 92), glare = 0.1, amb = rgb(88, 80, 80), out = rgb(134, 120, 112),
	bright = 1.8, top = rgb(150, 100, 62), tint = rgb(244, 228, 214), sat = -0.18, rays = 0.06,
	cloud = rgb(192, 166, 150), cover = 0.74, bio = 0.8,
})
-- красно-оранжевый закат
local SUNSET = with(DAY, {
	atmo = rgb(216, 110, 70), decay = rgb(124, 50, 46), dens = -0.02, haze = 1.8, glare = 0.55,
	amb = rgb(106, 64, 56), out = rgb(160, 94, 74), bright = 1.3, top = rgb(255, 108, 48), bottom = rgb(66, 28, 20), expo = 0.05,
	tint = rgb(255, 202, 174), sat = -0.02, con = 0.14, bloom = 0.82, rays = 0.14,
	cloud = rgb(230, 118, 82), cover = 0.68, cdens = 0.55, bio = 0.3,
})
-- фиолетовые сумерки
local DUSK = with(DAY, {
	atmo = rgb(98, 64, 104), decay = rgb(40, 26, 56), dens = 0.02, haze = 2, glare = 0.1,
	amb = rgb(58, 48, 74), out = rgb(84, 68, 106), bright = 0.85, top = rgb(150, 90, 150), expo = -0.04,
	tint = rgb(224, 200, 244), sat = -0.18, con = 0.13, bloom = 0.82, rays = 0.02,
	cloud = rgb(96, 68, 100), cover = 0.66, cdens = 0.55, bio = 0.35,
})
-- тёмно-синяя ночь: холодный лунный свет сверху, звёзды, но силуэты читаются
local NIGHT = with(DAY, {
	atmo = rgb(22, 28, 52), decay = rgb(8, 10, 24), dens = 0.04, haze = 2.2, glare = 0,
	amb = rgb(30, 38, 66), out = rgb(46, 58, 100), bright = 0.55, top = rgb(70, 100, 170), bottom = rgb(0, 0, 0), expo = -0.12,
	tint = rgb(186, 202, 255), sat = -0.32, con = 0.14, cc = -0.02, bloom = 0.9, rays = 0,
	cloud = rgb(34, 40, 62), cover = 0.6, cdens = 0.5, bio = 0.25,
})
-- синий час перед рассветом
local BLUE = with(DAY, {
	atmo = rgb(62, 62, 108), decay = rgb(30, 26, 58), dens = 0.02, haze = 2.2,
	amb = rgb(46, 48, 80), out = rgb(70, 72, 112), bright = 0.75, top = rgb(110, 110, 180), expo = -0.05,
	tint = rgb(206, 206, 255), sat = -0.24, con = 0.13, bloom = 0.8, rays = 0,
	cloud = rgb(84, 78, 114), cover = 0.66, cdens = 0.52, bio = 0.3,
})
-- тёплый оранжево-розовый рассвет
local DAWN = with(DAY, {
	atmo = rgb(226, 150, 134), decay = rgb(130, 78, 98), dens = -0.03, haze = 1.8, glare = 0.4,
	amb = rgb(100, 74, 82), out = rgb(156, 110, 108), bright = 1.35, top = rgb(255, 150, 96), bottom = rgb(56, 28, 40), expo = 0.06,
	tint = rgb(255, 220, 204), sat = -0.06, con = 0.12, bloom = 0.78, rays = 0.12,
	cloud = rgb(238, 166, 154), cover = 0.64, cdens = 0.5, bio = 0.3,
})
local MORNING = with(DAY, {
	atmo = rgb(190, 170, 164), decay = rgb(112, 98, 106), haze = 2.2, glare = 0.12,
	amb = rgb(88, 82, 88), out = rgb(134, 124, 128), bright = 1.7, top = rgb(170, 120, 90), expo = 0.03,
	tint = rgb(248, 234, 226), sat = -0.17, rays = 0.07, cloud = rgb(204, 182, 178), cover = 0.72, bio = 0.7,
})
-- лобби: неизменная туманная ночь на площади
local LOBBY = with(NIGHT, {
	atmo = rgb(56, 64, 84), decay = rgb(30, 34, 46), dens = 0.42, haze = 2.5,
	amb = rgb(46, 52, 70), out = rgb(62, 70, 96), bright = 0.6, top = rgb(80, 100, 150), expo = 0,
	tint = rgb(206, 216, 255), sat = -0.25, con = 0.1, bloom = 0.7,
	cloud = rgb(38, 42, 58), cover = 0.78, cdens = 0.7,
})

local KEYS = {
	{ 0, NIGHT },
	{ 4.4, NIGHT },
	{ 5.3, BLUE },
	{ 6.3, DAWN },
	{ 7.6, MORNING },
	{ 9.2, DAY },
	{ 16.2, DAY },
	{ 17.4, AFTERNOON },
	{ 18.7, SUNSET },
	{ 19.8, DUSK },
	{ 21, NIGHT },
	{ 24, NIGHT },
}

local function lerpNum(a, b, k)
	return a + (b - a) * k
end

local function lerpPalette(a, b, k, out)
	out = out or {}
	for _, key in ipairs(NUMS) do
		out[key] = lerpNum(a[key], b[key], k)
	end
	for _, key in ipairs(COLORS) do
		out[key] = a[key]:Lerp(b[key], k)
	end
	return out
end

local function paletteAt(c)
	for i = 1, #KEYS - 1 do
		local a, b = KEYS[i], KEYS[i + 1]
		if c >= a[1] and c <= b[1] then
			local span = b[1] - a[1]
			local k = span > 0 and Util.Smooth((c - a[1]) / span) or 0
			return lerpPalette(a[2], b[2], k)
		end
	end
	return lerpPalette(NIGHT, NIGHT, 0)
end

-- оттенок цвета b при яркости цвета c (биом меняет оттенок, но не делает ночь светлее)
local function hueAt(b, c)
	local mb = math.max(b.R, b.G, b.B)
	local mc = math.max(c.R, c.G, c.B)
	if mb < 0.001 then
		return c
	end
	local f = mc / mb
	return Color3.new(math.min(1, b.R * f), math.min(1, b.G * f), math.min(1, b.B * f))
end

-- Фонари и окна (тег LR_NightLight) ----------------------------------------------------------
local function remember(inst)
	local o = original[inst]
	if not o and inst:IsA("BasePart") then
		o = { color = inst.Color, material = inst.Material, transparency = inst.Transparency }
		original[inst] = o
	end
	return o
end

local function applyLight(inst, on)
	if not inst.Parent then
		return
	end
	if inst:IsA("BasePart") then
		local o = remember(inst)
		if on then
			inst.Color = o.color
			inst.Material = o.material
			inst.Transparency = o.transparency
		else
			local offColor = inst:GetAttribute("NightOffColor")
			inst.Color = typeof(offColor) == "Color3" and offColor or o.color:Lerp(rgb(46, 46, 50), 0.62)
			local offMat = inst:GetAttribute("NightOffMaterial")
			local mat = Enum.Material.Glass
			if type(offMat) == "string" then
				local ok, found = pcall(function()
					return Enum.Material[offMat]
				end)
				if ok and found then
					mat = found
				end
			end
			inst.Material = mat
			local offT = inst:GetAttribute("NightOffTransparency")
			inst.Transparency = type(offT) == "number" and offT or o.transparency
		end
		for _, child in ipairs(inst:GetChildren()) do
			if child:IsA("Light") or child:IsA("Fire") or child:IsA("ParticleEmitter") then
				child.Enabled = on
			end
		end
	elseif inst:IsA("LayerCollector") or inst:IsA("Light") or inst:IsA("Fire") or inst:IsA("ParticleEmitter") then
		inst.Enabled = on
	end
end

local function setLights(on, stagger)
	lightsOn = on
	lightQueue = {}
	local now = os.clock()
	for _, inst in ipairs(CollectionService:GetTagged(DN.LightTag)) do
		if stagger then
			-- фонари загораются не разом, а один за другим
			table.insert(lightQueue, { inst = inst, at = now + rng:NextNumber(0, 2.6) })
		else
			applyLight(inst, on)
		end
	end
end

local function processLightQueue()
	if #lightQueue == 0 then
		return
	end
	local now = os.clock()
	for i = #lightQueue, 1, -1 do
		local e = lightQueue[i]
		if now >= e.at then
			table.remove(lightQueue, i)
			applyLight(e.inst, lightsOn == true)
		end
	end
end

function DN.LightsOn()
	return lightsOn == true
end

-- Основное -----------------------------------------------------------------------------------
local function ensure(className, name, parent)
	local inst = parent:FindFirstChild(name)
	if not inst or not inst:IsA(className) then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = parent
	end
	return inst
end

function DN.Init(services)
	S = services
	atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	tint = ensure("ColorCorrectionEffect", "BiomeTint", Lighting)
	bloom = ensure("BloomEffect", "LR_Bloom", Lighting)
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 1.4
	sunRays = ensure("SunRaysEffect", "LR_SunRays", Lighting)
	sunRays.Intensity = 0.04
	sunRays.Spread = 0.6
	sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		sky = Instance.new("Sky")
		sky.StarCount = 3000
		sky.Parent = Lighting
	end
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local ok, result = pcall(function()
			local c = terrain:FindFirstChildOfClass("Clouds")
			if not c then
				c = Instance.new("Clouds")
				c.Parent = terrain
			end
			return c
		end)
		if ok then
			clouds = result
		end
	end
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.5
	Lighting.ClockTime = clock
	-- лампы, появившиеся позже (новые чанки, станции, лобби), сразу получают текущее состояние
	CollectionService:GetInstanceAddedSignal(DN.LightTag):Connect(function(inst)
		if lightsOn ~= nil then
			applyLight(inst, lightsOn)
		end
	end)
	DN.Reset()
end

function DN.Reset()
	clock = Config.StartClock
	timeScale = 1
	storm = nil
	nextStormRoll = os.clock() + 60
	lastNight = nil
	lastPhase = nil
	lightsOn = nil
	lightQueue = {}
	cur = nil
	blood = 0
end

function DN.SetTimeScale(s)
	if type(s) == "number" then
		timeScale = s
	end
end

function DN.Clock()
	return clock
end

function DN.IsNight()
	return clock >= Config.NightStart or clock < Config.NightEnd
end

-- 0 — день, 1 — глубокая ночь, плавные сумерки
function DN.NightFactor()
	local c = clock
	if c >= 21 or c < 4.5 then
		return 1
	elseif c >= 19 then
		return (c - 19) / 2
	elseif c < 6.5 then
		return 1 - (c - 4.5) / 2
	end
	return 0
end

-- "dawn" | "day" | "dusk" | "night"
function DN.Phase()
	local c = clock
	if DN.IsNight() then
		return "night"
	elseif c < 8 then
		return "dawn"
	elseif c < 17.5 then
		return "day"
	end
	return "dusk"
end

-- 0..1 — насколько сейчас видна кровавая луна (плавно)
function DN.BloodFactor()
	return blood
end

local LOBBY_CLOCK = 22
local function isLobby(st)
	return st:GetAttribute("Mode") == "lobby" or (S.Run ~= nil and S.Run.Mode == "lobby")
end

local function applyLighting(p, clockTime)
	Lighting.ClockTime = clockTime
	atmosphere.Density = math.clamp(p.dens, 0, 1)
	atmosphere.Offset = 0.1
	atmosphere.Color = p.atmo
	atmosphere.Decay = p.decay
	atmosphere.Glare = math.clamp(p.glare, 0, 10)
	atmosphere.Haze = math.clamp(p.haze, 0, 10)
	Lighting.Ambient = p.amb
	Lighting.OutdoorAmbient = p.out
	Lighting.Brightness = math.max(0, p.bright)
	Lighting.ColorShift_Top = p.top
	Lighting.ColorShift_Bottom = p.bottom
	Lighting.ExposureCompensation = math.clamp(p.expo, -3, 3)
	tint.TintColor = p.tint
	tint.Saturation = math.clamp(p.sat, -1, 1)
	tint.Contrast = math.clamp(p.con, -1, 1)
	tint.Brightness = math.clamp(p.cc, -1, 1)
	if bloom then
		bloom.Intensity = math.max(0, p.bloom)
		bloom.Size = 24
		bloom.Threshold = 1.4
	end
	if sunRays then
		sunRays.Intensity = math.clamp(p.rays, 0, 1)
		sunRays.Spread = 0.6
	end
	if clouds and clouds.Parent then
		clouds.Cover = math.clamp(p.cover, 0, 1)
		clouds.Density = math.clamp(p.cdens, 0, 1)
		clouds.Color = p.cloud
	end
	if sky and sky.Parent then
		sky.MoonAngularSize = 11 + blood * 16
		sky.StarCount = blood > 0.5 and 800 or 3000
	end
end

local function smoothTo(target, step)
	if not cur then
		cur = lerpPalette(target, target, 0)
		return
	end
	lerpPalette(cur, target, math.min(1, step * 1.2), cur)
end

local function lobbyLighting(step)
	blood = 0
	smoothTo(LOBBY, step)
	applyLighting(cur, LOBBY_CLOCK)
	if lightsOn ~= true then
		setLights(true, false)
	end
end

local function updatePhase(st, lobby)
	local night = DN.IsNight()
	if night ~= lastNight then
		local first = lastNight == nil
		lastNight = night
		st:SetAttribute("IsNight", night)
		if not first and not lobby then
			if night then
				local sub = "Зомби быстрее и их больше. Держитесь у автобуса"
				if st:GetAttribute("Difficulty") == "nightmare" then
					sub = "Кошмарная ночь: почти ничего не видно. Держитесь у автобуса"
				end
				Net.Get("Toast"):FireAllClients("НАСТУПАЕТ НОЧЬ", sub, rgb(150, 160, 255))
			else
				Net.Get("Toast"):FireAllClients("РАССВЕТ", "Ночь позади — зомби успокаиваются", rgb(255, 196, 150))
			end
		end
	end
	local phase = DN.Phase()
	if phase ~= lastPhase then
		lastPhase = phase
		st:SetAttribute("DayPhase", phase)
	end
end

local lightAcc = 0
function DN.Update(dt)
	local st = Net.State()
	local lobby = isLobby(st)
	if not lobby then
		clock = (clock + dt * 24 / Config.DayLength * timeScale) % 24
	end
	lightAcc = lightAcc + dt
	if lightAcc < 0.2 then
		return
	end
	local step = lightAcc
	lightAcc = 0
	processLightQueue()
	if lobby then
		-- при возврате в заезд уведомление о ночи не должно всплыть сразу
		lastNight = nil
		lastPhase = nil
		lobbyLighting(step)
		return
	end
	updatePhase(st, lobby)

	local busS = (S.Bus and S.Bus.S) or 0
	local km = busS / Config.StudsPerKm
	local biome = S.World.BiomeAtS(busS)
	local nextBiome = Biomes.Next(biome)
	local blend = 0
	if nextBiome then
		blend = Util.Smooth(math.clamp(1 - (nextBiome.startKm - km) / 1.2, 0, 1))
	end
	-- у депо стиль почти полностью общий, дальше биом просвечивает сильнее
	local grade = lerpNum(0.9, 0.55, math.clamp((km - 1.5) / 2, 0, 1))
	local function biomeColor(key)
		local c = biome[key]
		if nextBiome and blend > 0 then
			c = c:Lerp(nextBiome[key], blend)
		end
		return c
	end
	local function biomeNum(key)
		if nextBiome and blend > 0 then
			return lerpNum(biome[key], nextBiome[key], blend)
		end
		return biome[key]
	end

	-- песчаная буря в пустыне
	local now = os.clock()
	if storm and now >= storm then
		storm = nil
		st:SetAttribute("Weather", "")
	end
	if not storm and biome.id == "desert" and km > 3 and now >= nextStormRoll then
		nextStormRoll = now + 90
		if rng:NextNumber() < 0.3 then
			storm = now + 40
			st:SetAttribute("Weather", "sandstorm")
			Net.Get("Toast"):FireAllClients("ПЕСЧАНАЯ БУРЯ", "Ничего не видно. Зомби подходят вплотную", rgb(255, 190, 110))
		end
	end

	local target = paletteAt(clock)
	-- оттенок биома: сильнее днём, слабее на рассвете, закате и ночью
	local w = (1 - grade) * target.bio
	target.atmo = target.atmo:Lerp(hueAt(biomeColor("atmoColor"), target.atmo), w)
	target.amb = target.amb:Lerp(hueAt(biomeColor("ambient"), target.amb), w)
	target.out = target.out:Lerp(hueAt(biomeColor("outdoor"), target.out), w)
	target.tint = target.tint:Lerp(hueAt(biomeColor("tint"), target.tint), w * 0.8)
	-- плотность дымки днём 0.35–0.45 (плотнее в болоте/джунглях) + добавка времени суток
	target.dens = math.clamp(lerpNum(0.4, biomeNum("atmoDensity"), 1 - grade), 0.35, 0.5) + target.dens

	local nf = DN.NightFactor()
	-- на «Кошмаре» ночь заметно темнее
	local dark = st:GetAttribute("Difficulty") == "nightmare" and nf or 0
	if dark > 0 then
		target.dens = target.dens + dark * 0.14
		target.atmo = target.atmo:Lerp(rgb(6, 6, 12), dark * 0.6)
		target.amb = target.amb:Lerp(rgb(10, 10, 16), dark * 0.7)
		target.out = target.out:Lerp(rgb(12, 12, 20), dark * 0.7)
		target.bright = target.bright * (1 - dark * 0.6)
		target.expo = target.expo - dark * 0.5
		target.top = target.top:Lerp(rgb(20, 24, 40), dark * 0.6)
	end
	if storm then
		target.dens = 0.8
		target.atmo = rgb(190, 150, 104)
		target.decay = rgb(120, 90, 60)
		target.haze = 3
		target.glare = 0
		target.rays = 0
		target.cover = 0.9
	end

	-- кровавая луна: красная атмосфера, плавное появление
	local bloodOn = S.Events and S.Events.IsBloodMoon and S.Events.IsBloodMoon() == true
	blood = lerpNum(blood, bloodOn and 1 or 0, math.min(1, step * 0.6))
	local bf = blood
	if bf > 0.01 then
		target.dens = lerpNum(target.dens, math.max(target.dens, 0.45), bf)
		target.atmo = target.atmo:Lerp(rgb(120, 18, 18), bf * 0.85)
		target.decay = target.decay:Lerp(rgb(60, 8, 8), bf * 0.7)
		target.amb = target.amb:Lerp(rgb(96, 28, 28), bf * 0.8)
		target.out = target.out:Lerp(rgb(120, 36, 36), bf * 0.8)
		target.top = target.top:Lerp(rgb(200, 40, 30), bf * 0.7)
		target.bright = lerpNum(target.bright, math.max(target.bright, 0.6), bf)
		target.tint = target.tint:Lerp(rgb(255, 140, 130), bf * 0.8)
		target.sat = lerpNum(target.sat, 0.05, bf)
		target.con = target.con + bf * 0.06
		target.haze = target.haze + bf * 0.4
		target.cloud = target.cloud:Lerp(rgb(110, 30, 30), bf * 0.6)
	end

	smoothTo(target, step)
	applyLighting(cur, clock)

	-- фонари: ночью, в бурю и при кровавой луне
	local want = DN.IsNight() or storm ~= nil or bf > 0.5
	if want ~= lightsOn then
		setLights(want, lightsOn ~= nil)
	end
end

return DN
