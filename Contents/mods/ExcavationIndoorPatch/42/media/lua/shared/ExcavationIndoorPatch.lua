local DigSquareAction = require("Excavation/timedActions/DigSquareAction");
local DigStairsAction = require("Excavation/timedActions/DigStairsAction");

local MOD_DATA_KEY = "ExcavationIndoorPatch";
local DEBUG_LOG_ENABLED = SandboxVars.ExcavationIndoorPatch.DebugInteriorRoom;

local SQUARES_PER_TICK = 32;
local NEIGHBORS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };

local pendingSquares = {};
local batch = {};
local batchCount = 0;
local watchedSquares = {};

local function isDebugAllowed()
    return isDebugEnabled() or DEBUG_LOG_ENABLED;
end

local function debugLog(fmt, ...)
    if isDebugAllowed() then
        print("[ExcavationIndoorPatch] " .. string.format(fmt, ...));
    end
end

local function coordKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z);
end

local function cellKey(x, y)
    return string.format("%d,%d", x, y);
end

local function squareKey(square)
    return coordKey(square:getX(), square:getY(), square:getZ());
end

local function splitIntoComponents(squares)
    local visited = {};
    local components = {};

    for startKey, startSquare in pairs(squares) do
        if not visited[startKey] then
            local comp = { z = startSquare:getZ(), squares = {}, cells = {} };
            local queue, head = { startSquare }, 1;
            visited[startKey] = true;

            while head <= #queue do
                local sq = queue[head];
                head = head + 1;

                local x, y, z = sq:getX(), sq:getY(), sq:getZ();
                comp.squares[#comp.squares + 1] = { x = x, y = y, square = sq };
                comp.cells[cellKey(x, y)] = true;

                for _, d in ipairs(NEIGHBORS) do
                    local nKey = coordKey(x + d[1], y + d[2], z);
                    local nSq = squares[nKey];
                    if nSq and not visited[nKey] then
                        visited[nKey] = true;
                        queue[#queue + 1] = nSq;
                    end
                end
            end

            components[#components + 1] = comp;
        end
    end

    return components;
end

local function computeRectangles(comp)
    local list = {};
    for i, c in ipairs(comp.squares) do list[i] = c; end
    table.sort(list, function(a, b)
        if a.y ~= b.y then return a.y < b.y; end
        return a.x < b.x;
    end);

    local cells = comp.cells;
    local covered = {};
    local rects = {};

    for _, c in ipairs(list) do
        if not covered[cellKey(c.x, c.y)] then
            local w = 1;
            while true do
                local k = cellKey(c.x + w, c.y);
                if cells[k] and not covered[k] then w = w + 1; else break end
            end

            local h = 1;
            while true do
                local rowOk = true;
                for dx = 0, w - 1 do
                    local k = cellKey(c.x + dx, c.y + h);
                    if not cells[k] or covered[k] then rowOk = false; break end
                end
                if rowOk then h = h + 1; else break end
            end

            for dy = 0, h - 1 do
                for dx = 0, w - 1 do
                    covered[cellKey(c.x + dx, c.y + dy)] = true;
                end
            end

            rects[#rects + 1] = { x = c.x, y = c.y, w = w, h = h };
        end
    end

    return rects;
end

local function touches(a, b)
    local overlapX = a.x < b.x + b.w and b.x < a.x + a.w;
    local overlapY = a.y < b.y + b.h and b.y < a.y + a.h;
    return (overlapX and (a.y + a.h == b.y or b.y + b.h == a.y))
        or (overlapY and (a.x + a.w == b.x or b.x + b.w == a.x));
end

local function orderRects(rects, anchor)
    local ordered, placed = {}, {};
    if anchor then
        placed[1] = { x = anchor.x, y = anchor.y, w = 1, h = 1 };
    end

    local remaining = {};
    for i, r in ipairs(rects) do remaining[i] = r; end

    while #remaining > 0 do
        local pick = nil;
        if #placed == 0 then
            pick = 1;
        else
            for i, r in ipairs(remaining) do
                for _, p in ipairs(placed) do
                    if touches(r, p) then pick = i; break end
                end
                if pick then break end
            end
        end
        pick = pick or 1; -- garde-fou

        local r = table.remove(remaining, pick);
        ordered[#ordered + 1] = r;
        placed[#placed + 1] = r;
    end

    return ordered;
end

local function findExistingRoom(comp)
    local defs, anchors, seen = {}, {}, {};

    for _, c in ipairs(comp.squares) do
        for _, d in ipairs(NEIGHBORS) do
            local nx, ny = c.x + d[1], c.y + d[2];
            if not comp.cells[cellKey(nx, ny)] then
                local n = getSquare(nx, ny, comp.z);
                if n and n:getModData()[MOD_DATA_KEY] and n:isInARoom() then
                    local room = n:getRoom();
                    local building = room and room:getBuilding();
                    local def = building and building:getDef();
                    if def and not seen[def] then
                        seen[def] = true;
                        defs[#defs + 1] = def;
                        anchors[def] = { x = nx, y = ny };
                    end
                end
            end
        end
    end

    return defs, anchors;
end

local function groupComponents(components)
    local defOwners = {};

    for _, comp in ipairs(components) do
        comp.defs, comp.anchors = findExistingRoom(comp);
        for _, def in ipairs(comp.defs) do
            defOwners[def] = defOwners[def] or {};
            table.insert(defOwners[def], comp);
        end
    end

    local groups = {};
    local visited = {};

    for _, comp in ipairs(components) do
        if not visited[comp] then
            local group = { z = comp.z, comps = {}, defs = {} };
            local seenDefs = {};
            local queue, head = { comp }, 1;
            visited[comp] = true;

            while head <= #queue do
                local c = queue[head];
                head = head + 1;
                group.comps[#group.comps + 1] = c;

                for _, def in ipairs(c.defs) do
                    if not seenDefs[def] then
                        seenDefs[def] = true;
                        group.defs[#group.defs + 1] = def;
                        for _, other in ipairs(defOwners[def]) do
                            if not visited[other] then
                                visited[other] = true;
                                queue[#queue + 1] = other;
                            end
                        end
                    end
                end
            end

            groups[#groups + 1] = group;
        end
    end

    return groups;
end

local function appendDefRects(breRoom, def, z)
    local rooms = def:getRooms();
    for i = 0, rooms:size() - 1 do
        local roomDef = rooms:get(i);
        if roomDef:getZ() == z then
            local rects = roomDef:getRects();
            for j = 0, rects:size() - 1 do
                local r = rects:get(j);
                breRoom:addRectangle(r:getX(), r:getY(), r:getW(), r:getH());
            end
        end
    end
end

local function buildRoomForGroup(bre, group)
    local primary = group.defs[1];
    local breBuilding, breRoom = nil, nil;

    if primary then
        local anchor = nil;
        for _, comp in ipairs(group.comps) do
            if comp.anchors[primary] then
                anchor = comp.anchors[primary];
                break
            end
        end

        breBuilding = bre:copyExistingBuilding(primary);
        local idx = anchor and breBuilding:getRoomIndexAt(anchor.x, anchor.y, group.z) or -1;
        if idx >= 0 then
            breRoom = breBuilding:getRoomByIndex(idx);
        else
            bre:removeBuilding(breBuilding);
        end
    end

    if not breRoom then
        breBuilding = bre:createBuilding();
        breRoom = breBuilding:createRoom(group.z);
        if primary then
            appendDefRects(breRoom, primary, group.z);
        end
    end

    for i = 2, #group.defs do
        appendDefRects(breRoom, group.defs[i], group.z);
    end

    local squareCount, rectCount = 0, 0;
    for _, comp in ipairs(group.comps) do
        local anchor = comp.defs[1] and comp.anchors[comp.defs[1]] or nil;
        local ordered = orderRects(computeRectangles(comp), anchor);
        for _, r in ipairs(ordered) do
            breRoom:addRectangle(r.x, r.y, r.w, r.h);
        end
        squareCount = squareCount + #comp.squares;
        rectCount = rectCount + #ordered;
    end
    breBuilding:setEdited(true);

    debugLog("group of %d component(s), %d square(s), %d new rectangle(s), merged with %d existing building(s)",
        #group.comps, squareCount, rectCount, #group.defs);
end

local function applyPatchServer(square)
    if not (isMultiplayer() and isServer()) then return; end

    local roomDef = IsoWorld.instance:getMetaGrid():getRoomAt(square:getX(), square:getY(), square:getZ());
    if not roomDef then
        debugLog("applyPatchServer: no roomDef at %s", squareKey(square));
        return;
    end

    local ok, err = pcall(function()
        square:setRoomID(roomDef:getID());
    end);
    debugLog("setRoomID at %s ok=%s err=%s isInARoom=%s",
        squareKey(square), tostring(ok), tostring(err), tostring(square:isInARoom()));
end

local function patchBuildingDef(bDef)
    local ok, err = pcall(function()
        bDef:setUserDefined(false);
    end);
    if not ok then
        print("[ExcavationIndoorPatch] setUserDefined(false) failed: " .. tostring(err));
    end

    local rooms = bDef:getRooms();
    for i = 0, rooms:size() - 1 do
        rooms:get(i):setExplored(true);
    end
    bDef:setHasBeenVisited(true);
    bDef:setAllExplored(true);
end

local function refreshGroupSquaresServer(group)
    if not (isMultiplayer() and isServer()) then return; end
    if #group.defs == 0 then return; end

    local first = group.comps[1].squares[1];
    local roomDef = IsoWorld.instance:getMetaGrid():getRoomAt(first.x, first.y, group.z);
    if not roomDef then
        debugLog("refreshGroupSquaresServer: no roomDef at %d,%d,%d", first.x, first.y, group.z);
        return;
    end
    local roomId = roomDef:getID();

    local count = 0;
    for _, def in ipairs(group.defs) do
        local rooms = def:getRooms();
        for i = 0, rooms:size() - 1 do
            local oldRoomDef = rooms:get(i);
            if oldRoomDef:getZ() == group.z then
                local rects = oldRoomDef:getRects();
                for j = 0, rects:size() - 1 do
                    local r = rects:get(j);
                    for x = r:getX(), r:getX() + r:getW() - 1 do
                        for y = r:getY(), r:getY() + r:getH() - 1 do
                            local sq = getSquare(x, y, group.z);
                            if sq then
                                local ok = pcall(function()
                                    sq:setRoomID(roomId);
                                end);
                                if ok then count = count + 1; end
                            end
                        end
                    end
                end
            end
        end
    end

    debugLog("refreshGroupSquaresServer: %d square(s) reassigned to room %s", count, tostring(roomId));
end

local function finalizeSquare(square, patchedDefs)
    applyPatchServer(square);

    local room = square:getRoom();
    local building = room and room:getBuilding();
    if not building then
        debugLog("no room after applyChanges at %s", squareKey(square));
        return false;
    end

    local bDef = building:getDef();
    if not patchedDefs[bDef] then
        patchedDefs[bDef] = true;
        patchBuildingDef(bDef);
    end

    watchedSquares[squareKey(square)] = true;
    square:getModData()[MOD_DATA_KEY] = true;
    return true;
end

local function registerSquare(square)
    if not square or square:getZ() >= 0 or not square:hasFloor() or square:isInARoom() then
        return false;
    end

    local key = squareKey(square);
    if watchedSquares[key] or batch[key] then return false; end

    batch[key] = square;
    batchCount = batchCount + 1;
    return true;
end

local function flushBatch()
    local squares = batch;
    batch = {};
    batchCount = 0;

    for key, sq in pairs(squares) do
        if sq:isInARoom() then squares[key] = nil; end
    end

    local components = splitIntoComponents(squares);
    if #components == 0 then return; end

    local bre = BuildingRoomsEditor.getInstance();

    local groups = groupComponents(components);
    for _, group in ipairs(groups) do
        buildRoomForGroup(bre, group);
    end

    bre:applyChanges(false);

    for _, group in ipairs(groups) do
        refreshGroupSquaresServer(group);
    end

    local patchedDefs = {};
    local refreshed = {};

    for _, comp in ipairs(components) do
        for _, c in ipairs(comp.squares) do
            if finalizeSquare(c.square, patchedDefs) then
                refreshed[#refreshed + 1] = { x = c.x, y = c.y, z = comp.z };
            end
        end
    end

    if isMultiplayer() and isServer() and #refreshed > 0 then
        sendServerCommand("ExcavationIndoorPatch", "refreshRooms", { squares = refreshed });
    end

    debugLog("flush: %d component(s), %d square(s) patched", #components, #refreshed);
end

--------------------------------------------------------------------
-- Events
--------------------------------------------------------------------

Events.LoadGridsquare.Add(function(square)
    if not square then return; end

    if square:getModData()[MOD_DATA_KEY] and not square:isInARoom() then
        pendingSquares[#pendingSquares + 1] = square;
        debugLog("pending room at %s", squareKey(square));
    end
end);

Events.OnTick.Add(function()
    if #pendingSquares > 0 then
        for _ = 1, SQUARES_PER_TICK do
            local square = table.remove(pendingSquares);
            if not square then break end
            registerSquare(square);
        end
        return;
    end

    if batchCount > 0 then
        flushBatch();
    end
end);

Events.OnPlayerMove.Add(function(player)
    registerSquare(player:getSquare());
end);

Events.OnZombieCreate.Add(function(zombie)
    if isMultiplayer() and not isServer() then return; end

    local square = zombie:getCurrentSquare();
    if not square then return; end

    if watchedSquares[squareKey(square)] or square:getModData()[MOD_DATA_KEY] then
        zombie:removeFromWorld();
        zombie:removeFromSquare();
        debugLog("zeds spawned then removed at %s", squareKey(square));
    end
end);

Events.OnServerCommand.Add(function(module, command, args)
    if module == "ExcavationIndoorPatch" and command == "refreshRooms" then
        for _, s in ipairs(args.squares or {}) do
            registerSquare(getSquare(s.x, s.y, s.z));
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
        local square;
        if self.orientation == "south" then
            square = getSquare(x, y + i, z - 1);
        else
            square = getSquare(x + i, y, z - 1);
        end
        if square then
            registerSquare(square);
        end
    end

    return result;
end

function DigSquareAction:complete()
    local result = old_DigSquareAction_complete(self);

    local square = getSquare(self.x, self.y, self.z);
    if square then
        registerSquare(square);
    end

    return result;
end