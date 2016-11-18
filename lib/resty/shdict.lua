

local ffi = require 'ffi'
local base = require "resty.core.base"

local ffi_new = ffi.new
local ffi_str = ffi.string
local C = ffi.C
local get_string_buf = base.get_string_buf
local get_string_buf_size = base.get_string_buf_size
local get_size_ptr = base.get_size_ptr
local new_tab = base.new_tab
local tonumber = tonumber
local tostring = tostring
local next = next
local type = type
local error = error
local getmetatable = getmetatable
local NGX_OK = 0


local _M = {}
local ZONE_INDEX = 1
local func = {}
func.__index = func


ffi.cdef[[
    int ngx_http_lua_ffi_shdict_get_zones_num();

    void ngx_http_lua_ffi_shdict_get_zones(ngx_str_t *names,
        void **zones);

    int ngx_http_lua_ffi_shdict_find_zone(void **zones,
        const unsigned char *name_data, size_t name_len);

    int ngx_http_lua_ffi_shdict_get_helper(void *zone, const unsigned char *key,
        size_t key_len, int *value_type, unsigned char **str_value_buf,
        size_t *str_value_len, double *num_value, int *user_flags,
        int get_stale, int *is_stale, char **errmsg);

    int ngx_http_lua_ffi_shdict_store_helper(void *zone, int op,
        const unsigned char *key, size_t key_len, int value_type,
        const unsigned char *str_value_buf, size_t str_value_len,
        double num_value, int exptime, int user_flags, char **errmsg,
        int *forcible);
        
    int ngx_http_lua_ffi_shdict_pop_helper(void *zone, const unsigned char *key,
        size_t key_len, int *value_type, unsigned char **str_value_buf,
        size_t *str_value_len, double *num_value, int flags, char **errmsg);
        
    int ngx_http_lua_ffi_shdict_push_helper(void *zone, const unsigned char *key,
        size_t key_len, int value_type, const unsigned char *str_value_buf,
        size_t str_value_len, double num_value, int *value_len,
        int flags, char **errmsg);
        
    int ngx_http_lua_ffi_shdict_llen(void *zone, const unsigned char *key,
        size_t key_len, int *value_num, char **errmsg);
        
    int ngx_http_lua_ffi_shdict_flush(void *zone, char **errmsg);
        
    int ngx_http_lua_ffi_shdict_flush_expired(void *zone, int attempts,
        int *freed, char **errmsg);
        
    int ngx_http_lua_ffi_shdict_get_keys(void *zone, int attempts,
        ngx_str_t **keys_buf, size_t *key_num, char **errmsg);
]]


if not pcall(function () return C.free end) then
    ffi.cdef[[
        void free(void *ptr);
    ]]
end


local value_type = ffi_new("int[1]")
local user_flags = ffi_new("int[1]")
local num_value = ffi_new("double[1]")
local is_stale = ffi_new("int[1]")
local forcible = ffi_new("int[1]")
local str_value_buf = ffi_new("unsigned char *[1]")
local errmsg = base.get_errmsg_ptr()


local function shdict_find(name)
    local zones = ffi_new("void *[1]")
    local rc = C.ngx_http_lua_ffi_shdict_find_zone(zones, name, #name)
    if rc ~= NGX_OK then
        return
    end

    return zones[0]
end


local function shdict_push(zone, flag, key, value)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    if key == nil then
        return nil, "nil key"
    end

    if type(key) ~= "string" then
        key = tostring(key)
    end

    local key_len = #key
    if key_len == 0 then
        return nil, "empty key"
    end
    if key_len > 65535 then
        return nil, "key too long"
    end

    local str_value_buf
    local str_value_len = 0
    local num_value = 0
    local valtyp = type(value)

    if valtyp == "string" then
        valtyp = 4  -- LUA_TSTRING
        str_value_buf = value
        str_value_len = #value

    elseif valtyp == "number" then
        valtyp = 3  -- LUA_TNUMBER
        num_value = value

    else
        return nil, "bad value type"
    end
    
    local value_len = ffi_new("int[1]")

    local rc = C.ngx_http_lua_ffi_shdict_push_helper(zone, key, key_len,
                                                    valtyp, str_value_buf,
                                                    str_value_len, num_value,
                                                    value_len, flag, errmsg)

    if rc == NGX_OK then  -- NGX_OK
        return true, tonumber(value_len)
    end

    -- NGX_DECLINED or NGX_ERROR
    return false, ffi_str(errmsg[0])
end


local function shdict_lpush(zone, key, value)
    return shdict_push(zone, 0x0001, key, value)
end


local function shdict_rpush(zone, key, value)
    return shdict_push(zone, 0x0002, key, value)
end


local function shdict_pop(zone, flag, key)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    if key == nil then
        return nil, "nil key"
    end

    if type(key) ~= "string" then
        key = tostring(key)
    end

    local key_len = #key
    if key_len == 0 then
        return nil, "empty key"
    end
    if key_len > 65535 then
        return nil, "key too long"
    end

    local value_len = get_size_ptr()

    local rc = C.ngx_http_lua_ffi_shdict_pop_helper(zone, key, key_len, value_type, 
                                                  str_value_buf, value_len, num_value, 
                                                  flag, errmsg)

    if rc ~= NGX_OK then
        return error("failed to pop the key")
    end

    local typ = tonumber(value_type[0])

    local val

    if typ == 4 then -- LUA_TSTRING
        if str_value_buf[0] ~= buf then
            buf = str_value_buf[0]
            val = ffi_str(buf, value_len[0])
            C.free(buf)
        else
            val = ffi_str(buf, value_len[0])
        end

    elseif typ == 3 then -- LUA_TNUMBER
        val = tonumber(num_value[0])

    elseif typ == 0 then -- LUA_TNIL
        val = nil

    else
        return error("unknown value type: " .. typ)
    end

    return val
end


local function shdict_lpop(zone, key)
    return shdict_pop(zone, 0x0001, key)
end


local function shdict_rpop(zone, key)
    return shdict_pop(zone, 0x0002, key)
end


local function shdict_llen(zone, key)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    if key == nil then
        return nil, "nil key"
    end

    if type(key) ~= "string" then
        key = tostring(key)
    end

    local key_len = #key
    if key_len == 0 then
        return nil, "empty key"
    end
    if key_len > 65535 then
        return nil, "key too long"
    end

    local value_num = ffi_new("int[1]")

    local rc = C.ngx_http_lua_ffi_shdict_llen(zone, key, key_len, value_num, errmsg)

    if rc ~= NGX_OK then
        return error("failed to pop the key")
    end

    local val = tonumber(value_num[0])

    return val
end


local function shdict_store(zone, op, key, value, exptime, flags)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error('bad "zone" argument')
    end

    if not exptime then
        exptime = 0
    end

    if not flags then
        flags = 0
    end

    if key == nil then
        return nil, "nil key"
    end

    if type(key) ~= "string" then
        key = tostring(key)
    end

    local key_len = #key
    if key_len == 0 then
        return nil, "empty key"
    end
    if key_len > 65535 then
        return nil, "key too long"
    end

    local str_value_buf
    local str_value_len = 0
    local num_value = 0
    local valtyp = type(value)

    if valtyp == "string" then
        valtyp = 4  -- LUA_TSTRING
        str_value_buf = value
        str_value_len = #value

    elseif valtyp == "number" then
        valtyp = 3  -- LUA_TNUMBER
        num_value = value

    elseif value == nil then
        valtyp = 0  -- LUA_TNIL

    elseif valtyp == "boolean" then
        valtyp = 1  -- LUA_TBOOLEAN
        num_value = value and 1 or 0

    else
        return nil, "bad value type"
    end

    local rc = C.ngx_http_lua_ffi_shdict_store_helper(zone, op, key, key_len,
                                                    valtyp, str_value_buf,
                                                    str_value_len, num_value,
                                                    exptime * 1000, flags, errmsg,
                                                    forcible)

    if rc == NGX_OK then  -- NGX_OK
        return true, nil, forcible[0] == 1
    end

    -- NGX_DECLINED or NGX_ERROR
    return false, ffi_str(errmsg[0]), forcible[0] == 1
end


local function shdict_set(zone, key, value, exptime, flags)
    return shdict_store(zone, 0, key, value, exptime, flags)
end


local function shdict_safe_set(zone, key, value, exptime, flags)
    return shdict_store(zone, 0x0004, key, value, exptime, flags)
end


local function shdict_add(zone, key, value, exptime, flags)
    return shdict_store(zone, 0x0001, key, value, exptime, flags)
end


local function shdict_safe_add(zone, key, value, exptime, flags)
    return shdict_store(zone, 0x0005, key, value, exptime, flags)
end


local function shdict_replace(zone, key, value, exptime, flags)
    return shdict_store(zone, 0x0002, key, value, exptime, flags)
end


local function shdict_delete(zone, key)
    return shdict_set(zone, key, nil)
end


local function shdict_get(zone, key)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error('bad "zone" argument')
    end

    if key == nil then
        return nil, "nil key"
    end

    if type(key) ~= "string" then
        key = tostring(key)
    end

    local key_len = #key
    if key_len == 0 then
        return nil, "empty key"
    end
    if key_len > 65535 then
        return nil, "key too long"
    end

    local size = get_string_buf_size()
    local buf = get_string_buf(size)
    str_value_buf[0] = buf
    local value_len = get_size_ptr()
    value_len[0] = size

    local rc = C.ngx_http_lua_ffi_shdict_get_helper(zone, key, key_len, value_type,
                                                  str_value_buf, value_len,
                                                  num_value, user_flags, 0,
                                                  is_stale, errmsg)
    if rc ~= NGX_OK then
        return error("failed to get the key")
    end

    local typ = value_type[0]

    if typ == 0 then -- LUA_TNIL
        return nil
    end

    local flags = tonumber(user_flags[0])

    local val

    if typ == 4 then -- LUA_TSTRING
        if str_value_buf[0] ~= buf then
            buf = str_value_buf[0]
            val = ffi_str(buf, value_len[0])
            C.free(buf)
        else
            val = ffi_str(buf, value_len[0])
        end

    elseif typ == 3 then -- LUA_TNUMBER
        val = tonumber(num_value[0])

    elseif typ == 1 then -- LUA_TBOOLEAN
        val = (tonumber(buf[0]) ~= 0)

    else
        return error("unknown value type: " .. typ)
    end

    if flags ~= 0 then
        return val, flags
    end

    return val
end


local function shdict_get_stale(zone, key)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    if key == nil then
        return nil, "nil key"
    end

    if type(key) ~= "string" then
        key = tostring(key)
    end

    local key_len = #key
    if key_len == 0 then
        return nil, "empty key"
    end
    if key_len > 65535 then
        return nil, "key too long"
    end

    local size = get_string_buf_size()
    local buf = get_string_buf(size)
    str_value_buf[0] = buf
    local value_len = get_size_ptr()
    value_len[0] = size

    local rc = C.ngx_http_lua_ffi_shdict_get_zone(zone, key, key_len, value_type,
                                                  str_value_buf, value_len,
                                                  num_value, user_flags, 1,
                                                  is_stale, errmsg)
    if rc ~= 0 then
        return error("failed to get the key")
    end

    local typ = value_type[0]

    if typ == 0 then -- LUA_TNIL
        return nil
    end

    local flags = tonumber(user_flags[0])
    local val

    if typ == 4 then -- LUA_TSTRING
        if str_value_buf[0] ~= buf then
            -- ngx.say("len: ", tonumber(value_len[0]))
            buf = str_value_buf[0]
            val = ffi_str(buf, value_len[0])
            C.free(buf)
        else
            val = ffi_str(buf, value_len[0])
        end

    elseif typ == 3 then -- LUA_TNUMBER
        val = tonumber(num_value[0])

    elseif typ == 1 then -- LUA_TBOOLEAN
        val = (tonumber(buf[0]) ~= 0)

    else
        return error("unknown value type: " .. typ)
    end

    if flags ~= 0 then
        return val, flags, is_stale[0] == 1
    end

    return val, nil, is_stale[0] == 1
end


local function shdict_flush_all(zone)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    local rc = C.ngx_http_lua_ffi_shdict_flush(zone, errmsg)
    if rc ~= 0 then
        return nil, "failed to flush"
    end

    return true
end


local function shdict_flush_expired(zone, attempts)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end
    
    attempts = tonumber(attempts)
    if not attempts then
        attempts = 1024
    end

    local freed = ffi_new("int[1]")

    local rc = C.ngx_http_lua_ffi_shdict_flush_expired(zone, attempts, freed, errmsg)
    if rc ~= 0 then
        return error("failed get flush expire")
    end

    return tonumber(freed[0])
end


local function shdict_get_keys(zone, attempts)
    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    local keys_buf = ffi_new("ngx_str_t *[1]")
    local key_num = get_size_ptr()

    attempts = tonumber(attempts)
    if not attempts then
        attempts = 1024
    end

    local rc = C.ngx_http_lua_ffi_shdict_get_keys(zone, attempts, keys_buf,
        key_num, errmsg)
    if rc ~= 0 then
        C.free(keys_buf[0])
        return error("failed to get the key")
    end
    
    local keys = {}
    for i = 0, tonumber(key_num[0]) - 1 do
        keys[#keys + 1] = ffi_str(keys_buf[0][i].data, keys_buf[0][i].len)
    end
    C.free(keys_buf[0])
    
    return keys
end


func.get_keys           = shdict_get_keys
func.get                = shdict_get
func.get_stale          = shdict_get_stale
func.set                = shdict_set
func.safe_set           = shdict_safe_set
func.add                = shdict_add
func.safe_add           = shdict_safe_add
func.replace            = shdict_replace
func.delete             = shdict_delete
func.lpush              = shdict_lpush
func.rpush              = shdict_rpush
func.lpop               = shdict_lpop
func.rpop               = shdict_rpop
func.llen               = shdict_llen
func.flush_expired      = shdict_flush_expired
func.flush_all          = shdict_flush_all


local function get_all()
    local num = C.ngx_http_lua_ffi_shdict_get_zones_num()

    if num > 0 then
        local names = ffi_new("ngx_str_t [?]", num)
        zones = ffi_new("void *[?]", num)

        C.ngx_http_lua_ffi_shdict_get_zones(names, zones)

        _M = new_tab(0, num)

        for i = 0, num - 1 do
            local name = ffi_str(names[i].data, names[i].len)

            _M[name] = setmetatable({ [ZONE_INDEX] = zones[i] }, func)
        end
    end
end


local function set_index()
    local mt = {
        __index = function(tb, name)
            local zone = shdict_find(name)
            if not zone then
                return error("can not find zone named \"" .. name .. "\"")
            end

            tb[name] = {
                [ZONE_INDEX] = zone
            }
            setmetatable(tb[name], func)
            return tb[name]
        end
    }
    setmetatable(_M, mt)
end


--get_all()
set_index()

_M.peter:set("111", 2222)
_M.peter:set("112", 2222)
_M.peter:set("113", 2222)
_M.peter:get_keys()


return {
    version = base.version
}

