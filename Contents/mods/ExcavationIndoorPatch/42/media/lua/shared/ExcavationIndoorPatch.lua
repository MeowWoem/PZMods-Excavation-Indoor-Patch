local DigSquareAction = require("Excavation/timedActions/DigSquareAction");
local DigStairsAction = require("Excavation/timedActions/DigStairsAction");

local MOD_DATA_KEY = "ExcavationIndoorPatch";
local DEBUG_LOG_ENABLED = SandboxVars.ExcavationIndoorPatch.DebugInteriorRoom;

local pendingSquares = {};
local pendingPatchSquares = {};
local watchedSquares = {};
local isDirty = false;

local function isDebugAllowed()
    return isDebugEnabled() or DEBUG_LOG_ENABLED;
end

local function createCoordinateKey(square)
    return string.format("%d,%d,%d", square:getX(), square:getY(), square:getZ());
end

local function applyPatchServer(square)

    if(not isMultiplayer() or (isMultiplayer() and not isServer())) then return; end

    local metaGrid = IsoWorld.instance:getMetaGrid();
    local roomDef = metaGrid:getRoomAt(square:getX(), square:getY(), square:getZ());
    
    if(isDebugAllowed()) then
        print(string.format("[ExcavationIndoorPatch] applyPatchServer: square=%s roomDef=%s", createCoordinateKey(square), tostring(roomDef)));
    end

    local ok, err = pcall(function()
        square:setRoomID(roomDef:getID());
    end);

    if(isDebugAllowed()) then
        print(string.format("[ExcavationIndoorPatch] setRoomID ok=%s err=%s", tostring(ok), tostring(err)));
        print(string.format("[ExcavationIndoorPatch] after setRoomID -> getRoom(): %s", tostring(square:getRoom())));
        print(string.format("[ExcavationIndoorPatch] after setRoomID -> isInARoom(): %s", tostring(square:isInARoom())));
    end

end

local function patchSquare(square)
    local squareKey = createCoordinateKey(square);
    
    local room = square:getRoom();
    local bDef = room:getBuilding():getDef();

    local ok, err = pcall(function()
        bDef:setUserDefined(false);
    end);
    if not ok then
        print("[ExcavationIndoorPatch] setUserDefined(false) failed: " .. tostring(err));
    end

    for i = 0, bDef:getRooms():size()-1 do
        local r = bDef:getRooms():get(i);
        r:setExplored(true);
    end
    bDef:setHasBeenVisited(true);
    bDef:setAllExplored(true);

    watchedSquares[squareKey] = true;

    square:getModData()[MOD_DATA_KEY] = true;

    if(isDebugAllowed()) then
        print(string.format("[ExcavationIndoorPatch] room created at %s; isInARoom=%s", squareKey, tostring(square:isInARoom())));
    end

    if(isMultiplayer() and isServer()) then
        sendServerCommand("ExcavationIndoorPatch", "refreshRooms", {
            x = square:getX(),
            y = square:getY(),
            z = square:getZ(),
        });
    end
end


local function registerSquare(square)

    if not square or not (square:getZ() < 0 and square:hasFloor()) or square:isInARoom() then
        return false;
    end

    local squareKey = createCoordinateKey(square);
    if watchedSquares[squareKey] then return false; end

    local bre = BuildingRoomsEditor.getInstance();
    local breBuilding = bre:createBuilding();
    local breRoom = breBuilding:createRoom(square:getZ());
    breRoom:addRectangle(square:getX(), square:getY(), 1, 1);

    table.insert(pendingPatchSquares, square);
    isDirty = true;
    return true;

end


Events.LoadGridsquare.Add(function(square)
    if not square then return; end

    local modData = square:getModData();
    if modData[MOD_DATA_KEY] and not square:isInARoom() then
        table.insert(pendingSquares, square);
        if(isDebugAllowed()) then
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
                applyPatchServer(square);
                patchSquare(square);
            end

            pendingPatchSquares = {};

            if(isDebugAllowed()) then
                print("[ExcavationIndoorPatch] OnTick: applied pending rooms");
            end

        end

        return;

    end

    local square = table.remove(pendingSquares);
    registerSquare(square);

end);

Events.OnPlayerMove.Add(function(player)
    registerSquare(player:getSquare());
end);

Events.OnZombieCreate.Add(function(zombie)

    if(isMultiplayer() and not isServer()) then return; end

    local square = zombie:getCurrentSquare();
    if not square then return; end

    if watchedSquares[createCoordinateKey(square)] or square:getModData()[MOD_DATA_KEY] then
        zombie:removeFromWorld();
        zombie:removeFromSquare();
        if(isDebugAllowed()) then
            print(string.format("[ExcavationIndoorPatch] zeds spawned then removed at %s", createCoordinateKey(square)));
        end
    end
end);

Events.OnServerCommand.Add(function(module, command, args)
    if(module == "ExcavationIndoorPatch" and command == "refreshRooms") then
        registerSquare(getSquare(args.x, args.y, args.z));
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
            registerSquare(square);
        end
    end

    return result;
end

function DigSquareAction:complete()
    local result = old_DigSquareAction_complete(self);

    local square = getSquare(self.x, self.y, self.z);

    if(square) then
        registerSquare(square);
    end

    return result;
end