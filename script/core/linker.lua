local util  = require 'utility'
local guide = require 'parser.guide'

local Linkers, GetLink
local LastIDCache = {}
local SPLIT_CHAR = '\x1F'
local SPLIT_REGEX = SPLIT_CHAR .. '[^' .. SPLIT_CHAR .. ']+$'
local RETURN_INDEX_CHAR = '#'
local PARAM_INDEX_CHAR = '@'

---是否是全局变量（包括 _G.XXX 形式）
---@param source parser.guide.object
---@return boolean
local function isGlobal(source)
    if source.type == 'setglobal'
    or source.type == 'getglobal' then
        if source.node and source.node.tag == '_ENV' then
            return true
        end
    end
    if source.type == 'field' then
        source = source.parent
    end
    if source.special == '_G' then
        return true
    end
    return false
end

---获取语法树单元的key
---@param source parser.guide.object
---@return string? key
---@return parser.guide.object? node
local function getKey(source)
    if     source.type == 'local' then
        return tostring(source.start), nil
    elseif source.type == 'setlocal'
    or     source.type == 'getlocal' then
        return tostring(source.node.start), nil
    elseif source.type == 'setglobal'
    or     source.type == 'getglobal' then
        return ('%q'):format(source[1] or ''), nil
    elseif source.type == 'getfield'
    or     source.type == 'setfield' then
        return ('%q'):format(source.field and source.field[1] or ''), source.node
    elseif source.type == 'tablefield' then
        return ('%q'):format(source.field and source.field[1] or ''), source.parent
    elseif source.type == 'getmethod'
    or     source.type == 'setmethod' then
        return ('%q'):format(source.method and source.method[1] or ''), source.node
    elseif source.type == 'setindex'
    or     source.type == 'getindex' then
        local index = source.index
        if not index then
            return '', source.node
        end
        if index.type == 'string' then
            return ('%q'):format(index[1] or ''), source.node
        else
            return '', source.node
        end
    elseif source.type == 'tableindex' then
        local index = source.index
        if not index then
            return '', source.parent
        end
        if index.type == 'string' then
            return ('%q'):format(index[1] or ''), source.parent
        else
            return '', source.parent
        end
    elseif source.type == 'table' then
        return source.start, nil
    elseif source.type == 'label' then
        return source.start, nil
    elseif source.type == 'goto' then
        if source.node then
            return source.node.start, nil
        end
        return nil, nil
    elseif source.type == 'function' then
        return source.start, nil
    elseif source.type == '...' then
        return source.start, nil
    elseif source.type == 'select' then
        return ('%d%s%s%d'):format(source.start, SPLIT_CHAR, RETURN_INDEX_CHAR, source.index)
    elseif source.type == 'call' then
        local node = source.node
        if node.special == 'rawget'
        or node.special == 'rawset' then
            if not source.args then
                return nil, nil
            end
            local tbl, key = source.args[1], source.args[2]
            if not tbl or not key then
                return nil, nil
            end
            if key.type == 'string' then
                return ('%q'):format(key[1] or ''), tbl
            else
                return '', tbl
            end
        end
        return source.start, nil
    elseif source.type == 'doc.class.name'
    or     source.type == 'doc.type.name'
    or     source.type == 'doc.alias.name'
    or     source.type == 'doc.extends.name'
    or     source.type == 'doc.see.name' then
        return source[1], nil
    elseif source.type == 'doc.class'
    or     source.type == 'doc.type'
    or     source.type == 'doc.alias'
    or     source.type == 'doc.param'
    or     source.type == 'doc.vararg'
    or     source.type == 'doc.field.name'
    or     source.type == 'doc.type.function' then
        return source.start, nil
    elseif source.type == 'doc.see.field' then
        return ('%q'):format(source[1]), source.parent.name
    end
    return nil, nil
end

local function checkMode(source)
    if source.type == 'table' then
        return 't:'
    end
    if source.type == 'select' then
        return 's:'
    end
    if source.type == 'function' then
        return 'f:'
    end
    if source.type == 'call' then
        return 'c:'
    end
    if source.type == 'doc.class.name'
    or source.type == 'doc.type.name'
    or source.type == 'doc.alias.name'
    or source.type == 'doc.extends.name' then
        return 'dn:'
    end
    if source.type == 'doc.field.name' then
        return 'dfn:'
    end
    if source.type == 'doc.see.name' then
        return 'dsn:'
    end
    if source.type == 'doc.class' then
        return 'dc:'
    end
    if source.type == 'doc.type' then
        return 'dt:'
    end
    if source.type == 'doc.param' then
        return 'dp:'
    end
    if source.type == 'doc.alias' then
        return 'da:'
    end
    if source.type == 'doc.type.function' then
        return 'df:'
    end
    if source.type == 'doc.vararg' then
        return 'dv:'
    end
    if isGlobal(source) then
        return 'g:'
    end
    return 'l:'
end

local IDList = {}
---获取语法树单元的字符串ID
---@param source parser.guide.object
---@return string? id
local function getID(source)
    if not source then
        return nil
    end
    if source._id ~= nil then
        return source._id or nil
    end
    if source.type == 'field'
    or source.type == 'method' then
        source._id = false
        return nil
    end
    local current = source
    local index = 0
    while true do
        local id, node = getKey(current)
        if not id then
            break
        end
        index = index + 1
        IDList[index] = id
        if not node then
            break
        end
        current = node
        if current.special == '_G' then
            break
        end
    end
    if index == 0 then
        source._id = false
        return nil
    end
    for i = index + 1, #IDList do
        IDList[i] = nil
    end
    local mode = checkMode(current)
    if not mode then
        source._id = false
        return nil
    end
    util.revertTable(IDList)
    local id = mode .. table.concat(IDList, SPLIT_CHAR)
    source._id = id
    return id
end

---添加关联单元
---@param id string
---@param source parser.guide.object
local function pushSource(id, source)
    local link = GetLink(id)
    if not link.sources then
        link.sources = {}
    end
    link.sources[#link.sources+1] = source
end

---添加关联的前进ID
---@param id string
---@param forwardID string
local function pushForward(id, forwardID)
    if not id
    or not forwardID
    or forwardID == ''
    or id == forwardID then
        return
    end
    local link = GetLink(id)
    if not link.forward then
        link.forward = {}
    end
    link.forward[#link.forward+1] = forwardID
end

---添加关联的后退ID
---@param id string
---@param backwardID string
local function pushBackward(id, backwardID)
    if not id
    or not backwardID
    or backwardID == ''
    or id == backwardID then
        return
    end
    local link = GetLink(id)
    if not link.backward then
        link.backward = {}
    end
    link.backward[#link.backward+1] = backwardID
end

local function eachParentSelect(call, callback)
    if call.type ~= 'call' then
        return
    end
    if call.parent.type == 'select' then
        callback(call.parent, call.parent.index)
    end
    if not call.extParent then
        return
    end
    for _, sel in ipairs(call.extParent) do
        if sel.type == 'select' then
            callback(sel, sel.index)
        end
    end
end

---前进
---@param source parser.guide.object
---@return parser.guide.object[]
local function compileLink(source)
    local id = getID(source)
    local parent = source.parent
    if not parent then
        return
    end
    if source.value then
        -- x = y : x -> y
        pushForward(id, getID(source.value))
        pushBackward(getID(source.value), id)
    end
    -- self -> mt:xx
    if source.type == 'local' and source[1] == 'self' then
        local func = guide.getParentFunction(source)
        local setmethod = func.parent
        -- guess `self`
        if setmethod and ( setmethod.type == 'setmethod'
                        or setmethod.type == 'setfield'
                        or setmethod.type == 'setindex') then
            pushForward(id, getID(setmethod.node))
            pushBackward(getID(setmethod.node), id)
        end
    end
    -- 分解 @type
    if source.type == 'doc.type' then
        if source.bindSources then
            for _, src in ipairs(source.bindSources) do
                pushForward(getID(src), id)
                pushForward(id, getID(src))
            end
        end
        for _, typeUnit in ipairs(source.types) do
            pushForward(id, getID(typeUnit))
            pushBackward(getID(typeUnit), id)
        end
    end
    -- 分解 @class
    if source.type == 'doc.class' then
        pushForward(id, getID(source.class))
        pushForward(getID(source.class), id)
        if source.extends then
            for _, ext in ipairs(source.extends) do
                pushForward(id, getID(ext))
                pushBackward(getID(ext), id)
            end
        end
        if source.bindSources then
            for _, src in ipairs(source.bindSources) do
                pushForward(getID(src), id)
                pushForward(id, getID(src))
            end
        end
        do
            local start
            for _, doc in ipairs(source.bindGroup) do
                if doc.type == 'doc.class' then
                    start = doc == source
                end
                if start and doc.type == 'doc.field' then
                    local key = doc.field[1]
                    if key then
                        local keyID = ('%s%s%q'):format(
                            id,
                            SPLIT_CHAR,
                            key
                        )
                        pushForward(keyID, getID(doc.field))
                        pushBackward(getID(doc.field), keyID)
                        pushForward(keyID, getID(doc.extends))
                        pushBackward(getID(doc.extends), keyID)
                    end
                end
            end
        end
    end
    if source.type == 'doc.param' then
        pushForward(getID(source), getID(source.extends))
    end
    if source.type == 'doc.vararg' then
        pushForward(getID(source), getID(source.vararg))
    end
    if source.type == 'doc.see' then
        local nameID  = getID(source.name)
        local classID = nameID:gsub('^dsn:', 'dn:')
        pushForward(nameID, classID)
        if source.field then
            local fieldID      = getID(source.field)
            local fieldClassID = fieldID:gsub('^dsn:', 'dn:')
            pushForward(fieldID, fieldClassID)
        end
    end
    if source.type == 'call' then
        local node = source.node
        local nodeID = getID(node)
        -- 将call的返回值接收映射到函数返回值上
        eachParentSelect(source, function (sel)
            local selectID = getID(sel)
            local callID = ('%s%s%s%s'):format(
                nodeID,
                SPLIT_CHAR,
                RETURN_INDEX_CHAR,
                sel.index
            )
            pushForward(selectID, callID)
            pushBackward(callID, selectID)
            if sel.index == 1 then
                pushForward(id, callID)
                pushBackward(callID, id)
            end
        end)
        -- 将setmetatable映射到 param1 以及 param2.__index 上
        if node.special == 'setmetatable' then
            local callID = ('%s%s%s%s'):format(
                nodeID,
                SPLIT_CHAR,
                RETURN_INDEX_CHAR,
                1
            )
            local tblID  = getID(source.args and source.args[1])
            local metaID = getID(source.args and source.args[2])
            local indexID
            if metaID then
                indexID = ('%s%s%q'):format(
                    metaID,
                    SPLIT_CHAR,
                    '__index'
                )
            end
            pushForward(id, callID)
            pushBackward(callID, id)
            pushForward(callID, tblID)
            pushForward(callID, indexID)
            pushBackward(tblID, callID)
            --pushBackward(indexID, callID)
        end
    end
    -- 将函数的返回值映射到具体的返回值上
    if source.type == 'function' then
        -- 检查实体返回值
        if source.returns then
            local returns = {}
            for _, rtn in ipairs(source.returns) do
                for index, rtnObj in ipairs(rtn) do
                    if not returns[index] then
                        returns[index] = {}
                    end
                    returns[index][#returns[index]+1] = rtnObj
                end
            end
            for index, rtnObjs in ipairs(returns) do
                local returnID = ('%s%s%s%s'):format(
                    getID(source),
                    SPLIT_CHAR,
                    RETURN_INDEX_CHAR,
                    index
                )
                for _, rtnObj in ipairs(rtnObjs) do
                    pushForward(returnID, getID(rtnObj))
                    if rtnObj.type == 'function'
                    or rtnObj.type == 'call' then
                        pushBackward(getID(rtnObj), returnID)
                    end
                end
            end
        end
        -- 检查 luadoc
        if source.bindDocs then
            for _, doc in ipairs(source.bindDocs) do
                if doc.type == 'doc.return' then
                    for _, rtn in ipairs(doc.returns) do
                        local fullID = ('%s%s%s%s'):format(
                            id,
                            SPLIT_CHAR,
                            RETURN_INDEX_CHAR,
                            rtn.returnIndex
                        )
                        pushForward(getID(rtn), fullID)
                        pushBackward(fullID, getID(rtn))
                    end
                end
                if doc.type == 'doc.param' then
                    local paramName = doc.param[1]
                    for _, param in ipairs(source.args) do
                        if param[1] == paramName then
                            pushForward(getID(param), getID(doc))
                        end
                    end
                end
                if doc.type == 'doc.vararg' then
                    for _, param in ipairs(source.args) do
                        if param.type == '...' then
                            pushForward(getID(param), getID(doc))
                        end
                    end
                end
            end
        end
    end
end

---@class link
-- 当前节点的id
---@field id     string
-- 使用该ID的单元
---@field sources parser.guide.object[]
-- 前进的关联ID
---@field forward string[]
-- 后退的关联ID
---@field backward string[]

---创建source的链接信息
---@param id string
---@return link
function GetLink(id)
    if not Linkers[id] then
        Linkers[id] = {
            id = id,
        }
    end
    return Linkers[id]
end

local m = {}

m.SPLIT_CHAR = SPLIT_CHAR
m.RETURN_INDEX_CHAR = RETURN_INDEX_CHAR
m.PARAM_INDEX_CHAR = PARAM_INDEX_CHAR

---根据ID来获取所有的link
---@param root parser.guide.object
---@param id string
---@return link?
function m.getLinkByID(root, id)
    root = guide.getRoot(root)
    local linkers = root._linkers
    if not linkers then
        return nil
    end
    return linkers[id]
end

---根据ID来获取上个节点的ID
---@param id string
---@return string
function m.getLastID(id)
    if LastIDCache[id] then
        return LastIDCache[id] or nil
    end
    local lastID, count = id:gsub(SPLIT_REGEX, '')
    if count == 0 then
        LastIDCache[id] = false
        return nil
    end
    LastIDCache[id] = lastID
    return lastID
end

---获取source的ID
---@param source parser.guide.object
---@return string
function m.getID(source)
    return getID(source)
end

---获取source的special
---@param source parser.guide.object
---@return table
function m.getSpecial(source, key)
    if not source then
        return nil
    end
    local link = m.getLink(source)
    if not link then
        return nil
    end
    local special = link.special
    if not special then
        return nil
    end
    return special[key]
end

---编译整个文件的link
---@param  source parser.guide.object
---@return table
function m.compileLinks(source)
    local root = guide.getRoot(source)
    if root._linkers then
        return root._linkers
    end
    Linkers = {}
    root._linkers = Linkers
    guide.eachSource(root, function (src)
        local id = getID(src)
        if id then
            pushSource(id, src)
        end
        compileLink(src)
    end)
    return Linkers
end

return m