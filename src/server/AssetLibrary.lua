-- Библиотека моделей из Toolbox: ServerStorage.LR_Assets.<Категория> (Folder с моделями).
-- Если в категории есть модели, Props ставит их вместо процедурных объектов.
-- Категории: Trees, Rocks, Buildings, Props, Vehicles, Fences, Lamps
local ServerStorage = game:GetService("ServerStorage")

local AssetLibrary = {}

AssetLibrary.Categories = { "Trees", "Rocks", "Buildings", "Props", "Vehicles", "Fences", "Lamps" }

local CACHE_TIME = 8
local cache = {} -- [category] = { at = os.clock(), list = { Instance } }

-- variant — подпапка внутри категории (LR_Assets.Trees.pine_snow) или отдельная папка LR_Assets.Trees_pine_snow
local function scan(category, variant)
	local list = {}
	local root = ServerStorage:FindFirstChild("LR_Assets")
	local folder = root and root:FindFirstChild(category)
	if variant then
		folder = (folder and folder:FindFirstChild(variant)) or (root and root:FindFirstChild(category .. "_" .. variant))
	end
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") or child:IsA("BasePart") then
				table.insert(list, child)
			end
		end
	end
	return list
end

local function listFor(category, variant)
	if type(category) ~= "string" then
		return {}
	end
	local key = variant and (category .. "/" .. variant) or category
	local now = os.clock()
	local entry = cache[key]
	if not entry or now - entry.at > CACHE_TIME then
		entry = { at = now, list = scan(category, variant) }
		cache[key] = entry
	end
	return entry.list
end

function AssetLibrary.Has(category)
	return #listFor(category) > 0
end

-- Есть ли модели именно этого вида (например, Trees/pine_snow)
function AssetLibrary.HasVariant(category, variant)
	return type(variant) == "string" and #listFor(category, variant) > 0
end

-- Клон случайной модели категории: низ ограничивающего бокса на высоте cframe.Y,
-- центр по XZ — в точке cframe, поворот — как у cframe. Все детали закреплены, группа World.
-- Возвращает model, radius (половина большего горизонтального размера) или nil.
function AssetLibrary.Spawn(category, cframe, rng, parent, variant)
	local list = listFor(category, variant)
	if #list == 0 or typeof(cframe) ~= "CFrame" then
		return nil
	end
	local index = rng and rng:NextInteger(1, #list) or math.random(1, #list)
	local source = list[index]
	local ok, clone = pcall(function()
		return source:Clone()
	end)
	if not ok or not clone then
		return nil
	end
	local model = clone
	if clone:IsA("BasePart") then
		model = Instance.new("Model")
		model.Name = source.Name
		clone.Parent = model
	end
	local parts = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CollisionGroup = "World"
			parts = parts + 1
		end
	end
	if parts == 0 then
		model:Destroy()
		return nil
	end
	-- сначала поворот и позиция опорной точки, затем выравнивание по боксу
	model:PivotTo(cframe)
	local boxCF, size = model:GetBoundingBox()
	local bottomY = boxCF.Position.Y - size.Y / 2
	local delta = Vector3.new(cframe.X - boxCF.Position.X, cframe.Y - bottomY, cframe.Z - boxCF.Position.Z)
	model:PivotTo(model:GetPivot() + delta)
	model:SetAttribute("FromAssetLibrary", category)
	model.Parent = parent
	return model, math.max(size.X, size.Z) / 2
end

return AssetLibrary
