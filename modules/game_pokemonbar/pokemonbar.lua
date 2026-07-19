local POKEMON_BAR_OPCODE = 81
local MAX_POKEMON_SLOTS = 6

local pokemonBarWindow
local pokemonList
local emptyLabel
local serverPokemonEntries = {}

local pokemonBallItemIds = {
    [59270] = true,
    [54270] = true,
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

    value = value:gsub('[\r\n\t]+', ' ')
    value = value:gsub('%s+', ' ')
    return value:trim()
end

local function isPokemonBallItem(item)
    if not item then
        return false
    end

    local serverId = safeItemNumber(item, 'getServerId')
    local clientId = safeItemNumber(item, 'getClientId')
    local runtimeId = safeItemNumber(item, 'getId')
    if pokemonBallItemIds[serverId] or pokemonBallItemIds[clientId] or pokemonBallItemIds[runtimeId] then
        return true
    end

    local combined = table.concat({
        normalizeText(safeItemText(item, 'getName')):lower(),
        normalizeText(safeItemText(item, 'getDescription')):lower(),
        normalizeText(safeItemText(item, 'getTooltip')):lower(),
    }, ' ')

    return combined:find('pokemon:', 1, true) ~= nil or combined:find('pokeball', 1, true) ~= nil
end

local function collectLocalPokemonBallItems()
    local entries = {}

    for _, container in pairs(g_game.getContainers()) do
        for slot = 0, container:getCapacity() - 1 do
            local item = container:getItem(slot)
            if isPokemonBallItem(item) then
                table.insert(entries, {
                    containerId = container:getId(),
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

    local items = {}
    for index, entry in ipairs(entries) do
        if index > MAX_POKEMON_SLOTS then
            break
        end
        items[index] = entry.item
    end

    return items
end

local function splitTabLine(line)
    local fields = {}
    for field in (line .. '\t'):gmatch('(.-)\t') do
        table.insert(fields, field)
    end
    return fields
end

local function parsePokemonBarPayload(buffer)
    local entries = {}
    if type(buffer) ~= 'string' or buffer == '' then
        return entries
    end

    for rawLine in buffer:gmatch('[^\r\n]+') do
        local line = normalizeText(rawLine)
        if line ~= '' then
            local fields = splitTabLine(rawLine)
            local order = tonumber(fields[1]) or (#entries + 1)
            local itemId = tonumber(fields[2]) or 59270
            local name = normalizeText(fields[3])
            local level = tonumber(fields[4]) or 1
            local hp = tonumber(fields[5]) or 0
            local maxHp = tonumber(fields[6]) or 0
            local isDead = tonumber(fields[7]) == 1

            table.insert(entries, {
                order = order,
                itemId = itemId,
                name = name ~= '' and name or 'Pokemon',
                level = level,
                hp = hp,
                maxHp = maxHp,
                isDead = isDead,
            })
        end
    end

    table.sort(entries, function(a, b)
        return a.order < b.order
    end)

    while #entries > MAX_POKEMON_SLOTS do
        table.remove(entries)
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

local function updateHealthBar(widget, currentHp, maxHp)
    local background = widget:getChildById('hpBarBackground')
    local fill = background:getChildById('hpBarFill')
    local hpLabel = background:getChildById('hpLabel')
    local percent = 0

    if maxHp and maxHp > 0 then
        percent = math.max(0, math.min(1, (currentHp or 0) / maxHp))
    end

    fill:setWidth(math.floor(background:getWidth() * percent))
    hpLabel:setText(string.format('%d / %d', currentHp or 0, maxHp or 0))
end

local function usePokemonBall(widget)
    if not widget or not widget.item then
        return
    end

    g_game.use(widget.item)
end

local function setPreviewItem(previewWidget, localItem, fallbackItemId)
    if localItem then
        previewWidget:setItem(localItem)
        return
    end

    local ok, fallbackItem = pcall(function()
        return Item.create(fallbackItemId, 1)
    end)

    if ok and fallbackItem then
        previewWidget:setItem(fallbackItem)
    end
end

local function refreshPokemonBar()
    if not pokemonBarWindow or not pokemonList or not emptyLabel then
        return
    end

    if not g_game.isOnline() then
        clearPokemonEntries()
        emptyLabel:setVisible(false)
        pokemonBarWindow:hide()
        return
    end

    clearPokemonEntries()

    if #serverPokemonEntries == 0 then
        emptyLabel:setVisible(true)
        pokemonList:setHeight(18)
        pokemonBarWindow:show()
        return
    end

    local localItems = collectLocalPokemonBallItems()
    emptyLabel:setVisible(false)

    for index, entry in ipairs(serverPokemonEntries) do
        local widget = g_ui.createWidget('PokemonBarEntry', pokemonList)
        local localItem = localItems[index]

        widget.item = localItem
        widget.onClick = usePokemonBall
        widget:setTooltip('')
        setPreviewItem(widget:recursiveGetChildById('itemPreview'), localItem, entry.itemId)
        widget:getChildById('nameLabel'):setText(entry.name)
        updateHealthBar(widget, entry.hp, entry.maxHp)
    end

    pokemonList:setHeight(#serverPokemonEntries * 48)
    pokemonBarWindow:show()
end

local function requestPokemonBar()
    local protocolGame = g_game.getProtocolGame()
    if protocolGame then
        protocolGame:sendExtendedOpcode(POKEMON_BAR_OPCODE, 'request')
    end
end

local function onPokemonBarOpcode(_, _, buffer)
    serverPokemonEntries = parsePokemonBarPayload(buffer)
    refreshPokemonBar()
end

local function onGameStart()
    scheduleEvent(function()
        if g_game.isOnline() then
            requestPokemonBar()
        end
    end, 800)

    refreshPokemonBar()
end

local function onGameEnd()
    serverPokemonEntries = {}
    refreshPokemonBar()
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
    })

    ProtocolGame.registerExtendedOpcode(POKEMON_BAR_OPCODE, onPokemonBarOpcode)
    refreshPokemonBar()
end

function terminate()
    ProtocolGame.unregisterExtendedOpcode(POKEMON_BAR_OPCODE)

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
    })

    serverPokemonEntries = {}

    if pokemonBarWindow then
        pokemonBarWindow:destroy()
        pokemonBarWindow = nil
        pokemonList = nil
        emptyLabel = nil
    end
end
