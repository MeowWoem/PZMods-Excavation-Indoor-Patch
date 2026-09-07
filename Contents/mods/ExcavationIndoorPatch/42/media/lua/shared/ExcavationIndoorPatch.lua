local DigSquareAction = require("Excavation/timedActions/DigSquareAction");
local DigStairsAction = require("Excavation/timedActions/DigStairsAction");

local MOD_DATA_KEY = "ExcavationIndoorPatch";

local pendingSquares = {};      -- squares waiting for their turn in the OnTick queue (one per tick)
local pendingPatchSquares = {}; -- squares whose BuildingRoomsEditor room was created but not yet applyChanges()'d
local watchedSquares = {};      -- squareKey -> true, checked by OnZombieCreate
local isDirty = false;          -- true once at least one square is staged in pendingPatchSquares

local function createCoordinateKey(square)
    return string.format("%d,%d,%d", square:getX(), square:getY(), square:getZ());
end

local function patchSquare(square)
    local squareKey = createCoordinateKey(square);

    local room = square:getRoom();
    local bDef = room:getBuilding():getDef();

    -- If we dont do this, the game crashes when the room is unloaded (i think). Probably the proper creation of the
    -- room is incomplete but i dont know what else to do to fix it. This is a workaround.
    -- It works, but it also causes the room is not persistent and allow to spawn zombies, which is not what we want.
    -- So we have to watch the square and remove any zeds that spawn on it. See below in OnZombieCreate.
    -- And we have to recreate the room on LoadGridsquare after a game restart, which is done in the LoadGridsquare event below.
    local ok, err = pcall(function()
        bDef:setUserDefined(false);
    end)
    if not ok then
        print("[ExcavationIndoorPatch] setUserDefined(false) failed: " .. tostring(err));
    end

    -- An attempt to prevent zeds from spawning in the room, but it doesn't work. The zeds still spawn.
    -- So we have to watch the square and remove any zeds that spawn on it. See below in OnZombieCreate.
    for i = 0, bDef:getRooms():size()-1 do
        local r = bDef:getRooms():get(i);
        r:setExplored(true);
    end
    bDef:setHasBeenVisited(true);
    bDef:setAllExplored(true);

    -- Watch this square so OnZombieCreate removes any zombie roomSpotted()
    -- drops on it, right at the moment it spawns.
    watchedSquares[squareKey] = true;

    square:getModData()[MOD_DATA_KEY] = true;

    if(isDebugEnabled()) then
        print(string.format("[ExcavationIndoorPatch] room created at %s; isInARoom=%s", squareKey, tostring(square:isInARoom())));
    end
end

-- deferApply == true means: create the BuildingRoomsEditor room object and
-- stage it, but don't call applyChanges() or patchSquare() yet -- the caller
-- (the OnTick queue below) is responsible for calling applyChanges() once
-- for the whole batch and then patching every staged square in one pass.
-- This avoids one applyChanges() call per tile when many tiles stream in at
-- once (e.g. a whole basement loading via LoadGridsquare).
local function registerSquare(square, deferApply)
    if deferApply == nil then deferApply = false end

    if not square or not (square:getZ() < 0 and square:hasFloor()) or square:isInARoom() then
        return false;
    end

    local squareKey = createCoordinateKey(square);
    if watchedSquares[squareKey] then return false; end

    local bre = BuildingRoomsEditor.getInstance();
    local breBuilding = bre:createBuilding();
    local breRoom = breBuilding:createRoom(square:getZ());
    breRoom:addRectangle(square:getX(), square:getY(), 1, 1);

    if deferApply then
        table.insert(pendingPatchSquares, square);
        isDirty = true;
        return true; -- actually patched later, once the batched applyChanges() runs
    end

    bre:applyChanges(false);
    patchSquare(square);

    return square:isInARoom();
end


Events.LoadGridsquare.Add(function(square)
    if not square then return; end

    local modData = square:getModData();
    if modData[MOD_DATA_KEY] and not square:isInARoom() then
        table.insert(pendingSquares, square);
        if(isDebugEnabled()) then
            print(string.format("[ExcavationIndoorPatch] pending room at %s", createCoordinateKey(square)));
        end
    end
end);

Events.OnTick.Add(function()

    if #pendingSquares == 0 then
        if isDirty then
            isDirty = false;
            BuildingRoomsEditor.getInstance():applyChanges(false); -- one call for the whole batch
            for _, square in ipairs(pendingPatchSquares) do
                patchSquare(square);
            end
            pendingPatchSquares = {};
            if(isDebugEnabled()) then
                print("[ExcavationIndoorPatch] OnTick: applied pending rooms");
            end
        end
        return;
    end

    local square = table.remove(pendingSquares);
    registerSquare(square, true); -- defer: stage for the batched apply above

end);

Events.OnPlayerMove.Add(function(player)
    registerSquare(player:getSquare()); -- single tile, no batching needed
end);

Events.OnZombieCreate.Add(function(zombie)

    local square = zombie:getCurrentSquare();
    if not square then return; end

    if watchedSquares[createCoordinateKey(square)] then
        -- same removal pattern as vanilla's own ISSpawnHordeUI:onRemoveZombies()
        zombie:removeFromWorld();
        zombie:removeFromSquare();
        if(isDebugEnabled()) then
            print(string.format("[ExcavationIndoorPatch] zeds spawned then removed at %s", createCoordinateKey(square)));
        end
    end
end);

--------------------------------------------------------------------
-- Excavation Monkeypatches for DigSquareAction and DigStairsAction to register the
-- square after digging, so that the room is created immediately instead of waiting
-- for the player to move onto it.
--------------------------------------------------------------------

local old_DigStairsAction_complete = DigStairsAction.complete;
local old_DigSquareAction_complete = DigSquareAction.complete;

function DigStairsAction:complete()
    local result = old_DigStairsAction_complete(self);
    local x, y, z = self.square:getX(), self.square:getY(), self.square:getZ();
    for i = 1, 4 do
        local square = nil;
        if self.orientation == "south" then
            square = getSquare(x, y + i, z - 1);
        else
            square = getSquare(x + i, y, z - 1);
        end
        if(square) then
            registerSquare(square); -- single tile, no batching needed
        end
    end

    return result;
end

function DigSquareAction:complete()
    local result = old_DigSquareAction_complete(self);

    local square = getSquare(self.x, self.y, self.z);

    if(square) then
        registerSquare(square); -- single tile, no batching needed
    end

    return result;
end