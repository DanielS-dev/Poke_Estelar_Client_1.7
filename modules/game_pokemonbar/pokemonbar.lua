local pokemonBarWindow
local pokemonList
local emptyLabel
local debugLoggedNoMatch = false
local pokemonInfoCache = {}
local pendingInfoRequests = {}
local pendingLookRequests = {}
local activeLookRequest = nil
local MAX_POKEMON_SLOTS = 6

local pokemonBallItemIds = {
    [59270] = true,
    [54270] = true,
    -- Add future pokeball item ids here:
    -- [60000] = true,
    -- [60001] = true,
}

local function safeItemNumber(item, methodName)
    if not item or type(item[methodName]) ~= 'function' then
        return nil
    end

    local ok, value = pcall(function()
        return item[methodName](item)
    end)

    if ok and type(value) == 'number' then
        return value
    end

    return nil
end

local function safeItemText(item, methodName)
    if not item or type(item[methodName]) ~= 'function' then
        return ''
    end

    local ok, value = pcall(function()
        return item[methodName](item)
    end)

    if ok and type(value) == 'string' then
        return value
    end

    return ''
end

local function normalizeText(value)
    if type(value) ~= 'string' then
        return ''
    end

    value = value:gsub('[\r\n]+', ' ')
    value = value:gsub('%s+', ' ')
    return value:trim()
end

local function getItemDebugIds(item)
    return {
        serverId = safeItemNumber(item, 'getServerId'),
        clientId = safeItemNumber(item, 'getClientId'),
        id = safeItemNumber(item, 'getId'),
    }
end

local function isPokemonBallItem(item)
    if not item then
        return false
    end

    local ids = getItemDebugIds(item)
    if pokemonBallItemIds[ids.serverId] == true
        or pokemonBallItemIds[ids.clientId] == true
        or pokemonBallItemIds[ids.id] == true then
        return true
    end

    local name = normalizeText(safeItemText(item, 'getName')):lower()
    local description = normalizeText(safeItemText(item, 'getDescription')):lower()
    local tooltip = normalizeText(safeItemText(item, 'getTooltip')):lower()
    local combined = table.concat({ name, description, tooltip }, ' ')

    return combined:find('pokemon:', 1, true) ~= nil
        or combined:find('pokeball', 1, true) ~= nil
        or combined:find('pokeball', 1, true) ~= nil
end

local function truncateText(text, maxLength)
    if #text <= maxLength then
        return text
    end

    return text:sub(1, math.max(1, maxLength - 3)) .. '...'
end

local function extractPokemonName(rawDescription)
    local text = normalizeText(rawDescription)
    if text == '' then
        return ''
    end

    local lowerText = text:lower()
    local pokemonIndex = lowerText:find('pokemon:', 1, true)
    if not pokemonIndex then
        return ''
    end

    local namePart = text:sub(pokemonIndex + #'pokemon:')
    namePart = namePart:match('^%s*(.-)%s+[Ll][Ee][Vv][Ee][Ll]%s*:') or
        namePart:match('^%s*(.-)%s+[Hh][Pp]%s*:') or
        namePart:match('^%s*([^:]*)')

    namePart = normalizeText(namePart or '')
    namePart = namePart:gsub('%s+[Ll][Ee][Vv][Ee][Ll].*$', '')

    return normalizeText(namePart)
end

local function getCachedPokemonName(item)
    local ids = getItemDebugIds(item)

    return pokemonInfoCache[ids.id]
        or pokemonInfoCache[ids.serverId]
        or pokemonInfoCache[ids.clientId]
        or ''
end

local function rememberPokemonName(item, description)
    local name = extractPokemonName(description)
    if name == '' or not item then
        return
    end

    local ids = getItemDebugIds(item)
    if ids.id then
        pokemonInfoCache[ids.id] = name
        pendingInfoRequests[ids.id] = nil
    end
    if ids.serverId then
        pokemonInfoCache[ids.serverId] = name
        pendingInfoRequests[ids.serverId] = nil
    end
    if ids.clientId then
        pokemonInfoCache[ids.clientId] = name
        pendingInfoRequests[ids.clientId] = nil
    end
end

local function getRequestKey(item)
    local ids = getItemDebugIds(item)
    return ids.id or ids.serverId or ids.clientId
end

local function clearPendingLookRequest(requestKey)
    if not requestKey then
        return
    end

    pendingLookRequests[requestKey] = nil
    if activeLookRequest and activeLookRequest.key == requestKey then
        activeLookRequest = nil
    end
end

local function processNextLookRequest()
    if activeLookRequest or not g_game.isOnline() then
        return
    end

    for requestKey, item in pairs(pendingLookRequests) do
        if item then
            activeLookRequest = {
                key = requestKey,
                item = item,
            }
            g_game.look(item)
            return
        end

        pendingLookRequests[requestKey] = nil
    end
end

local function requestPokemonInfo(item)
    if not item then
        return
    end

    local requestKey = getRequestKey(item)
    if not requestKey or pokemonInfoCache[requestKey] or pendingInfoRequests[requestKey] then
        return
    end

    pendingInfoRequests[requestKey] = true
    g_game.requestItemInfo(item, 0)
end

local function requestPokemonLook(item)
    if not item then
        return
    end

    local requestKey = getRequestKey(item)
    if not requestKey or pokemonInfoCache[requestKey] or pendingLookRequests[requestKey] then
        return
    end

    pendingLookRequests[requestKey] = item
    processNextLookRequest()
end

local function getDisplayName(item)
    local cachedName = getCachedPokemonName(item)
    if cachedName ~= '' then
        return truncateText(cachedName, 24)
    end

    local description = normalizeText(safeItemText(item, 'getDescription'))
    if description ~= '' then
        local extracted = extractPokemonName(description)
        if extracted ~= '' then
            return truncateText(extracted, 24)
        end
        return truncateText(description, 24)
    end

    local tooltip = normalizeText(safeItemText(item, 'getTooltip'))
    if tooltip ~= '' then
        local extracted = extractPokemonName(tooltip)
        if extracted ~= '' then
            return truncateText(extracted, 24)
        end
        return truncateText(tooltip, 24)
    end

    local name = normalizeText(safeItemText(item, 'getName'))
    if name ~= '' then
        return truncateText(name, 24)
    end

    requestPokemonInfo(item)
    requestPokemonLook(item)
    return 'Pokemon'
end

local function logVisibleContainerItems()
    if debugLoggedNoMatch then
        return
    end

    debugLoggedNoMatch = true
    pinfo('[PokemonBar] No matches found. Dumping visible container items...')

    for _, container in pairs(g_game.getContainers()) do
        local containerName = normalizeText(container:getName())
        pinfo(string.format('[PokemonBar] Container id=%s name="%s" capacity=%d',
            tostring(container:getId()), containerName, container:getCapacity()))

        for slot = 0, container:getCapacity() - 1 do
            local item = container:getItem(slot)
            if item then
                local ids = getItemDebugIds(item)
                local itemName = normalizeText(safeItemText(item, 'getName'))
                local description = normalizeText(safeItemText(item, 'getDescription'))
                local tooltip = normalizeText(safeItemText(item, 'getTooltip'))

                pinfo(string.format(
                    '[PokemonBar] slot=%d serverId=%s clientId=%s runtimeId=%s name="%s" desc="%s" tooltip="%s"',
                    slot + 1,
                    tostring(ids.serverId),
                    tostring(ids.clientId),
                    tostring(ids.id),
                    itemName,
                    description,
                    tooltip
                ))
            end
        end
    end
end

local function collectPokemonEntries()
    local entries = {}

    for _, container in pairs(g_game.getContainers()) do
        local containerName = container:getName()
        for slot = 0, container:getCapacity() - 1 do
            local item = container:getItem(slot)
            if isPokemonBallItem(item) then
                table.insert(entries, {
                    containerId = container:getId(),
                    containerName = containerName,
                    slot = slot,
                    item = item,
                })
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.containerId == b.containerId then
            return a.slot < b.slot
        end

        return a.containerId < b.containerId
    end)

    if #entries > MAX_POKEMON_SLOTS then
        while #entries > MAX_POKEMON_SLOTS do
            table.remove(entries)
        end
    end

    return entries
end

local function clearPokemonEntries()
    if not pokemonList then
        return
    end

    pokemonList:destroyChildren()
    pokemonList:setHeight(1)
end

local function usePokemonBall(widget)
    if not widget or not widget.item then
        return
    end

    g_game.use(widget.item)
end

local function refreshPokemonBar()
    if not pokemonBarWindow or not pokemonList or not emptyLabel then
        return
    end

    if not g_game.isOnline() then
        clearPokemonEntries()
        emptyLabel:setVisible(false)
        pokemonBarWindow:hide()
        debugLoggedNoMatch = false
        return
    end

    local entries = collectPokemonEntries()
    clearPokemonEntries()

    if #entries == 0 then
        logVisibleContainerItems()
        emptyLabel:setVisible(true)
        pokemonList:setHeight(18)
        pokemonBarWindow:show()
        return
    end

    debugLoggedNoMatch = false
    emptyLabel:setVisible(false)

    for _, entry in ipairs(entries) do
        local widget = g_ui.createWidget('PokemonBarEntry', pokemonList)
        widget.item = entry.item
        widget.onClick = usePokemonBall
        widget:setTooltip('')
        widget:recursiveGetChildById('itemPreview'):setItem(entry.item)
        widget:getChildById('nameLabel'):setText(getDisplayName(entry.item))
    end

    pokemonList:setHeight(#entries * 38)
    pokemonBarWindow:show()
end

local function onGameStart()
    refreshPokemonBar()
end

local function onGameEnd()
    pendingInfoRequests = {}
    pendingLookRequests = {}
    activeLookRequest = nil
    refreshPokemonBar()
end

local function onItemInfo(itemList)
    for _, data in pairs(itemList or {}) do
        local item = data[1]
        local description = data[2]
        if item and description then
            rememberPokemonName(item, description)
        end
    end

    refreshPokemonBar()
end

local function onLookMessage(_, message)
    if not activeLookRequest or type(message) ~= 'string' then
        return
    end

    local requestItem = activeLookRequest.item
    local requestKey = activeLookRequest.key
    local extractedName = extractPokemonName(message)

    clearPendingLookRequest(requestKey)

    if extractedName ~= '' then
        rememberPokemonName(requestItem, message)
        refreshPokemonBar()
    end

    processNextLookRequest()
end

function init()
    g_ui.importStyle('pokemonbar')

    pokemonBarWindow = g_ui.loadUI('pokemonbar', modules.game_interface.getLeftPanel())
    pokemonList = pokemonBarWindow:recursiveGetChildById('pokemonList')
    emptyLabel = pokemonBarWindow:recursiveGetChildById('emptyLabel')

    connect(Container, {
        onOpen = refreshPokemonBar,
        onClose = refreshPokemonBar,
        onSizeChange = refreshPokemonBar,
        onUpdateItem = refreshPokemonBar,
        onAddItem = refreshPokemonBar,
        onRemoveItem = refreshPokemonBar,
    })

    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
        onItemInfo = onItemInfo,
    })
    registerMessageMode(MessageModes.Look, onLookMessage)

    refreshPokemonBar()
end

function terminate()
    disconnect(Container, {
        onOpen = refreshPokemonBar,
        onClose = refreshPokemonBar,
        onSizeChange = refreshPokemonBar,
        onUpdateItem = refreshPokemonBar,
        onAddItem = refreshPokemonBar,
        onRemoveItem = refreshPokemonBar,
    })

    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
        onItemInfo = onItemInfo,
    })
    unregisterMessageMode(MessageModes.Look, onLookMessage)

    if pokemonBarWindow then
        pokemonBarWindow:destroy()
        pokemonBarWindow = nil
        pokemonList = nil
        emptyLabel = nil
    end
end
