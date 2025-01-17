local _ENV = mkmodule('utils')

local df = df

function getval(obj, ...)
    if type(obj) == 'function' then
        return obj(...)
    else
        return obj
    end
end

-- Comparator function
function compare(a,b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    else
        return 0
    end
end

-- Sort strings; compare empty last
function compare_name(a,b)
    if a == '' then
        if b == '' then
            return 0
        else
            return 1
        end
    elseif b == '' then
        return -1
    else
        return compare(a,b)
    end
end

-- Make a field comparator
function compare_field(field,cmp)
    cmp = cmp or compare
    if field then
        return function (a,b)
            return cmp(a[field],b[field])
        end
    else
        return cmp
    end
end

-- Make a comparator of field vs key
function compare_field_key(field,cmp)
    cmp = cmp or compare
    if field then
        return function (a,b)
            return cmp(a[field],b)
        end
    else
        return cmp
    end
end

function is_container(obj)
    return df.isvalid(obj) == 'ref' and obj._kind == 'container'
end

-- Make a sequence of numbers in 1..size
function make_index_sequence(istart,iend)
    local index = {}
    for i=istart,iend do
        index[i-istart+1] = i
    end
    return index
end

--[[
    Sort items in data according to ordering.

    Each ordering spec is a table with possible fields:

    * key = function(value)
        Computes comparison key from a data value. Not called on nil.
    * key_table = function(data)
        Computes a key table from the data table in one go.
    * compare = function(a,b)
        Comparison function. Defaults to compare above.
        Called on non-nil keys; nil sorts last.
    * nil_first
        If true, nil keys are sorted first instead of last.
    * reverse
        If true, sort non-nil keys in descending order.

    Returns a table of integer indices into data.
--]]
function make_sort_order(data,ordering)
    -- Compute sort keys and comparators
    local keys = {}
    local cmps = {}
    local size = data.n or #data

    for i=1,#ordering do
        local order = ordering[i]

        if order.key_table then
            keys[i] = order.key_table(data)
        elseif order.key then
            local kt = {}
            local kf = order.key
            for j=1,size do
                if data[j] == nil then
                    kt[j] = nil
                else
                    kt[j] = kf(data[j])
                end
            end
            keys[i] = kt
        else
            keys[i] = data
        end

        cmps[i] = order.compare or compare
    end

    -- Make an order table
    local index = make_index_sequence(1,size)

    -- Sort the ordering table
    table.sort(index, function(ia,ib)
        for i=1,#keys do
            local ka = keys[i][ia]
            local kb = keys[i][ib]

            -- Sort nil keys to the end
            if ka == nil then
                if kb ~= nil then
                    return ordering[i].nil_first
                end
            elseif kb == nil then
                return not ordering[i].nil_first
            else
                local cmpv = cmps[i](ka,kb)
                if ordering[i].reverse then
                    cmpv = -cmpv
                end
                if cmpv < 0 then
                    return true
                elseif cmpv > 0 then
                    return false
                end
            end
        end
        return ia < ib -- this should ensure stable sort
    end)

    return index
end

--[[
    Iterate a 'list' structure, e.g. df.global.world.job_list
--]]
local function next_df_list(s,link)
    link = link.next
    if link then
        return link, link.item
    end
end

function listpairs(list)
    return next_df_list, nil, list
end


--[[
    Recursively assign data into a table.
--]]
function assign(tgt,src)
    if df.isvalid(tgt) == 'ref' then
        df.assign(tgt, src)
    elseif type(tgt) == 'table' then
        for k,v in pairs(src) do
            if type(v) == 'table' then
                local cv = tgt[k]
                if cv == nil then
                    cv = {}
                    tgt[k] = cv
                end
                assign(cv, v)
            else
                tgt[k] = v
            end
        end
    else
        error('Invalid assign target type: '..tostring(tgt))
    end
    return tgt
end

local function copy_field(obj,k,v,deep)
    if v == nil then
        return NULL
    end
    if deep then
        local field = obj:_field(k)
        if field == v then
            return clone(v,deep)
        end
    end
    return v
end

-- Copy the object as lua data structures.
function clone(obj,deep)
    if type(obj) == 'table' then
        if deep then
            return assign({},obj)
        else
            return copyall(obj)
        end
    elseif df.isvalid(obj) == 'ref' then
        local kind = obj._kind
        if kind == 'primitive' then
            return obj.value
        elseif kind == 'bitfield' then
            local rv = {}
            for k,v in pairs(obj) do
                rv[k] = v
            end
            return rv
        elseif kind == 'container' then
            local rv = {}
            for k,v in ipairs(obj) do
                rv[k+1] = copy_field(obj,k,v,deep)
            end
            return rv
        else -- struct
            local rv = {}
            for k,v in pairs(obj) do
                rv[k] = copy_field(obj,k,v,deep)
            end
            return rv
        end
    else
        return obj
    end
end

local function get_default(default,key,base)
    if type(default) == 'table' then
        local dv = default[key]
        if dv == nil then
            dv = default._default
        end
        if dv == nil then
            dv = base
        end
        return dv
    else
        return default
    end
end

-- Copy the object as lua data structures, skipping values matching defaults.
function clone_with_default(obj,default,force)
    local rv = nil
    local function setrv(k,v)
        if v ~= nil then
            if rv == nil then
                rv = {}
            end
            rv[k] = v
        end
    end
    if default == nil then
        return nil
    elseif type(obj) == 'table' then
        for k,v in pairs(obj) do
            setrv(k, clone_with_default(v, get_default(default,k)))
        end
    elseif df.isvalid(obj) == 'ref' then
        local kind = obj._kind
        if kind == 'primitive' then
            return clone_with_default(obj.value,default,force)
        elseif kind == 'bitfield' then
            for k,v in pairs(obj) do
                setrv(k, clone_with_default(v, get_default(default,k,false)))
            end
        elseif kind == 'container' then
            for k,v in ipairs(obj) do
                setrv(k+1, clone_with_default(v, default, true))
            end
        else -- struct
            for k,v in pairs(obj) do
                setrv(k, clone_with_default(v, get_default(default,k)))
            end
        end
    elseif obj == default and not force then
        return nil
    elseif obj == nil then
        return NULL
    else
        return obj
    end
    if force and rv == nil then
        rv = {}
    end
    return rv
end

-- Parse an integer value into a bitfield table
function parse_bitfield_int(value, type_ref)
    if value == 0 then
        return nil
    end
    local res = {}
    for i,v in ipairs(type_ref) do
        if bit32.extract(value, i) ~= 0 then
            res[v] = true
        end
    end
    return res
end

-- List the enabled flag names in the bitfield table
function list_bitfield_flags(bitfield, list)
    list = list or {}
    if bitfield then
        for name,val in pairs(bitfield) do
            if val then
                table.insert(list, name)
            end
        end
    end
    return list
end

-- Sort a vector or lua table
function sort_vector(vector,field,cmp)
    local fcmp = compare_field(field,cmp)
    local scmp = function(a,b)
        return fcmp(a,b) < 0
    end
    if df.isvalid(vector) then
        if vector._kind ~= 'container' then
            error('Container expected: '..tostring(vector))
        end
        local items = clone(vector, true)
        table.sort(items, scmp)
        vector:assign(items)
    else
        table.sort(vector, scmp)
    end
    return vector
end

-- Linear search

function linear_index(vector,key,field)
    local min,max
    if df.isvalid(vector) then
        min,max = 0,#vector-1
    else
        min,max = 1,#vector
    end
    if field then
        for i=min,max do
            local obj = vector[i]
            if obj[field] == key then
                return i, obj
            end
        end
    else
        for i=min,max do
            local obj = vector[i]
            if obj == key then
                return i, obj
            end
        end
    end
    return nil
end


-- Binary search in a vector or lua table
function binsearch(vector,key,field,cmp,min,max)
    if not(min and max) then
        if df.isvalid(vector) then
            min = -1
            max = #vector
        else
            min = 0
            max = #vector+1
        end
    end
    local mf = math.floor
    local fcmp = compare_field_key(field,cmp)
    while true do
        local mid = mf((min+max)/2)
        if mid <= min then
            return nil, false, max
        end
        local item = vector[mid]
        local cv = fcmp(item, key)
        if cv == 0 then
            return item, true, mid
        elseif cv < 0 then
            min = mid
        else
            max = mid
        end
    end
end

-- Binary search and insert
function insert_sorted(vector,item,field,cmp)
    local key = item
    if field and item then
        key = item[field]
    end
    local cur,found,pos = binsearch(vector,key,field,cmp)
    if found then
        return false,cur,pos
    else
        if df.isvalid(vector) then
            vector:insert(pos, item)
        else
            table.insert(vector, pos, item)
        end
        return true,vector[pos],pos
    end
end

-- Binary search, then insert or overwrite
function insert_or_update(vector,item,field,cmp)
    local added,cur,pos = insert_sorted(vector,item,field,cmp)
    if not added then
        vector[pos] = item
        cur = vector[pos]
    end
    return added,cur,pos
end

-- Binary search and erase
function erase_sorted_key(vector,key,field,cmp)
    local cur,found,pos = binsearch(vector,key,field,cmp)
    if found then
        if df.isvalid(vector) then
            vector:erase(pos)
        else
            table.remove(vector, pos)
        end
    end
    return found,cur,pos
end

function erase_sorted(vector,item,field,cmp)
    local key = item
    if field and item then
        key = item[field]
    end
    return erase_sorted_key(vector,key,field,cmp)
end

-- Calls a method with a string temporary
function call_with_string(obj,methodname,...)
    return dfhack.with_temp_object(
        df.new "string",
        function(str,obj,methodname,...)
            obj[methodname](obj,str,...)
            return str.value
        end,
        obj,methodname,...
    )
end

function getBuildingName(building)
    return call_with_string(building, 'getName')
end

function getBuildingCenter(building)
    return xyz2pos(building.centerx, building.centery, building.z)
end

function getItemDescription(item,mode)
    return call_with_string(item, 'getItemDescription', mode or 0)
end

function getItemDescriptionPrefix(item,mode)
    return call_with_string(item, 'getItemDescriptionPrefix', mode or 0)
end

-- Split the string by the given delimiter
function split_string(self, delimiter)
    return self:split(delimiter)
end

-- Ask a yes-no question
function prompt_yes_no(msg,default)
    local prompt = msg
    if default == nil then
        prompt = prompt..' (y/n): '
    elseif default then
        prompt = prompt..' (y/n)[y]: '
    else
        prompt = prompt..' (y/n)[n]: '
    end
    while true do
        local rv,err = dfhack.lineedit(prompt)
        if not rv then
            qerror(err);
        elseif string.match(rv,'^[Yy]') then
            return true
        elseif string.match(rv,'^[Nn]') then
            return false
        elseif rv == 'abort' then
            qerror('User abort')
        elseif rv == '' and default ~= nil then
            return default
        end
    end
end

-- Ask for input with check function
function prompt_input(prompt,check,quit_str)
    quit_str = quit_str or '~~~'
    while true do
        local rv,err = dfhack.lineedit(prompt)
        if not rv then
            qerror(err);
        end
        if rv == quit_str then
            qerror('User abort')
        end
        local rtbl = table.pack(check(rv))
        if rtbl[1] then
            return table.unpack(rtbl,2,rtbl.n)
        end
    end
end

function check_number(text)
    local nv = tonumber(text)
    return nv ~= nil, nv
end

-- Normalize directory separator slashes across platforms to '/' and collapse
-- adjacent slashes into a single slash.
local PLATFORM_SLASH = package.config:sub(1,1)
function normalizePath(path)
    return path:gsub(PLATFORM_SLASH, '/'):gsub('/+', '/')
end

function invert(tab)
    local result = {}
    for k,v in pairs(tab) do
        result[v]=k
    end
    return result
end

-- processArgs() and processArgsGetopt() have been moved to argparse.lua.
-- The 'require' statements are within the functions to avoid adding hard
-- dependencies to utils.lua (which could lead to circular dependency issues).
function processArgs(args, validArgs)
    return require('argparse').processArgs(args, validArgs)
end
function processArgsGetopt(args, optionActions)
    return require('argparse').processArgsGetopt(args, optionActions)
end

function fillTable(table1,table2)
    for k,v in pairs(table2) do
        table1[k] = v
    end
end

function unfillTable(table1,table2)
    for k,v in pairs(table2) do
        table1[k] = nil
    end
end

function df_shortcut_var(k)
    if k == 'scr' or k == 'screen' then
        return dfhack.gui.getCurViewscreen()
    elseif k == 'bld' or k == 'building' then
        return dfhack.gui.getSelectedBuilding()
    elseif k == 'item' then
        return dfhack.gui.getSelectedItem()
    elseif k == 'job' then
        return dfhack.gui.getSelectedJob()
    elseif k == 'wsjob' or k == 'workshop_job' then
        return dfhack.gui.getSelectedWorkshopJob()
    elseif k == 'unit' then
        return dfhack.gui.getSelectedUnit()
    elseif k == 'plant' then
        return dfhack.gui.getSelectedPlant()
    else
        for g in pairs(df.global) do
            if g == k then
                return df.global[k]
            end
        end

        return _G[k]
    end
end

function df_shortcut_env()
    local env = {}
    setmetatable(env, {__index = function(self, k) return df_shortcut_var(k) end})
    return env
end

df_env = df_shortcut_env()

function df_expr_to_ref(expr)
    expr = expr:gsub('%["(.-)"%]', function(field) return '.' .. field end)
        :gsub('%[\'(.-)\'%]', function(field) return '.' .. field end)
        :gsub('%[(%-?%d+)%]', function(field) return '.' .. field end)
    local parts = expr:split('.', true)
    local obj = df_env[parts[1]]
    for i = 2, #parts do
        local key = tonumber(parts[i]) or parts[i]
        if i == #parts then
            local ok, ret = pcall(function()
                return obj:_field(key)
            end)
            if ok then
                return ret
            end
        end
        obj = obj[key]
    end
    return obj
end

function addressof(obj)
    return select(2, df.sizeof(obj))
end

function OrderedTable()
    -- store values in a separate table to ensure that __index and __newindex
    -- run on every table index operation
    local t = {}
    local key_to_index = {}
    local index_to_key = {}

    local mt = {}
    function mt:__index(k)
        return t[k]
    end
    function mt:__newindex(k, v)
        if not key_to_index[k] then
            table.insert(index_to_key, k)
            key_to_index[k] = #index_to_key
        end
        t[k] = v
    end
    function mt:__pairs()
        return function(_, k)
            if k then
                k = index_to_key[key_to_index[k] + 1]
            else
                k = index_to_key[1]
            end
            if k then
                return k, t[k]
            end
        end, nil, nil
    end

    local self = {}
    setmetatable(self, mt)
    return self
end

return _ENV
