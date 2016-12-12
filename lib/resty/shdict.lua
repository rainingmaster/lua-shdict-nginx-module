

local ffi          = require 'ffi'

local ffi_new      = ffi.new
local ffi_str      = ffi.string
local C            = ffi.C

local tonumber     = tonumber
local tostring     = tostring
local type         = type
local error        = error
local setmetatable = setmetatable
local NGX_OK       = 0


local ZONE_INDEX   = 1
local func         = {}
local _M           = {}
func.__index       = func


if not pcall(ffi.typeof, "ngx_str_t") then
    ffi.cdef[[
        typedef struct {
            size_t                 len;
            const unsigned char   *data;
        } ngx_str_t;

        struct ngx_http_request_s;
        typedef struct ngx_http_request_s  ngx_http_request_t;
    ]]
end


ffi.cdef[[
    int ngx_lua_ffi_shdict_find_zone(void **zones,
        const unsigned char *name_data, size_t name_len);
        
    int ngx_lua_ffi_shdict_expire_helper(void *zone,
        int op, const unsigned char *key, size_t key_len,
        int exptime, int *is_stale, char **errmsg);
        
    int ngx_lua_ffi_shdict_ttl_helper(void *zone,
        const unsigned char *key, size_t key_len, int *ttl,
        char **errmsg);
        
    int ngx_lua_ffi_shdict_get_keys(void *zone, int attempts,
        ngx_str_t **keys_buf, int *keys_num, char **errmsg);
        
    int ngx_lua_ffi_shdict_flush(void *zone, char **errmsg);
        
    int ngx_lua_ffi_shdict_flush_expired(void *zone, int attempts,
        int *freed, char **errmsg);


    int ngx_lua_ffi_shdict_get_helper(void *zone, int op,
        const unsigned char *key, size_t key_len, int *value_type,
        unsigned char **str_value_buf, size_t *str_value_len,
        double *num_value, int *user_flags,
        int *is_stale, char **errmsg);

    int ngx_lua_ffi_shdict_store_helper(void *zone, int op,
        const unsigned char *key, size_t key_len, int value_type,
        const unsigned char *str_value_buf, size_t str_value_len,
        double num_value, int exptime, int user_flags, char **errmsg,
        int *forcible);

    int ngx_lua_ffi_shdict_incr_helper(void *zone, const unsigned char *key,
        size_t key_len, double *value, char **err, int has_init, double init,
        int exptime, int *forcible);

        
    int ngx_lua_ffi_shdict_pop_helper(void *zone, const unsigned char *key,
        size_t key_len, int *value_type, unsigned char **str_value_buf,
        size_t *str_value_len, double *num_value, int flags, char **errmsg);
        
    int ngx_lua_ffi_shdict_push_helper(void *zone, const unsigned char *key,
        size_t key_len, int value_type, const unsigned char *str_value_buf,
        size_t str_value_len, double num_value, int *value_len,
        int flags, char **errmsg);
        
    int ngx_lua_ffi_shdict_llen(void *zone, const unsigned char *key,
        size_t key_len, int *value_len, char **errmsg);
]]


if not pcall(function () return C.free end) then
    ffi.cdef[[
        void free(void *ptr);
    ]]
end


local str_buf_size   = 4096
local str_buf        = ffi_new("char [?]", str_buf_size)
local int_tmp        = ffi_new("int[10][1]")

local num_value      = ffi_new("double[1]")
local str_value_buf  = ffi_new("unsigned char *[1]")
local str_value_len  = ffi_new("size_t[1]")
local errmsg         = ffi_new("char *[1]")
local ngx_str_buf    = ffi_new("ngx_str_t *[1]")


local function check_zone(zone)
    if not zone or type(zone) ~= "table" then
        return error("bad \"zone\" argument")
    end

    zone = zone[ZONE_INDEX]
    if not zone or type(zone) ~= "cdata" then
        return error("bad \"zone\" argument")
    end

    return zone
end


local function check_key(key)
    if key == nil then
        return nil, "nil key"
    end

    key = tostring(key)

    local key_len = #key

    if key_len == 0 then
        return nil, "empty key"
    end

    if key_len > 65535 then
        return nil, "key too long"
    end
    
    return key, key_len
end


local function shdict_find(name)
    local zone_buf = ffi_new("void *[1]")
    local rc = C.ngx_lua_ffi_shdict_find_zone(zone_buf, name, #name)
    if rc ~= NGX_OK then
        return nil
    end

    return zone_buf[0]
end


local function shdict_push(zone, flag, key, value)
    local meta_zone = check_zone(zone)

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
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
    
    local value_len = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_push_helper(meta_zone, key, key_len,
                                                    valtyp, str_value_buf,
                                                    str_value_len, num_value,
                                                    value_len, flag, errmsg)

    if rc == NGX_OK then  -- NGX_OK
        return tonumber(value_len[0])
    end

    -- NGX_DECLINED or NGX_ERROR
    return nil, ffi_str(errmsg[0])
end


local function shdict_lpush(zone, key, value)
    return shdict_push(zone, 0x0001, key, value)
end


local function shdict_rpush(zone, key, value)
    return shdict_push(zone, 0x0002, key, value)
end


local function shdict_pop(zone, flag, key)
    local meta_zone = check_zone(zone)

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
    end

    str_value_buf[0] = str_buf
    str_value_len[0] = str_buf_size
    
    local value_type = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_pop_helper(meta_zone, key, key_len, value_type, 
                                                  str_value_buf, str_value_len, num_value, 
                                                  flag, errmsg)

    if rc ~= NGX_OK then
        return nil, ffi_str(errmsg[0])
    end

    local typ = tonumber(value_type[0])

    local val

    if typ == 4 then -- LUA_TSTRING
        val = ffi_str(str_value_buf[0], str_value_len[0])
        if str_value_buf[0] ~= str_buf then
            C.free(str_value_buf[0])
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
    local meta_zone = check_zone(zone)

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
    end
    
    local value_len = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_llen(meta_zone, key, key_len, value_len, errmsg)

    if rc ~= NGX_OK then
        return nil, ffi_str(errmsg[0])
    end

    return tonumber(value_len[0])
end


local function shdict_store(zone, op, key, value, exptime, flags)
    local meta_zone = check_zone(zone)

    exptime = tonumber(exptime)
    if not exptime then
        exptime = 0
    elseif exptime < 0 then
        return error("bad \"exptime\" argument")
    end

    flags = tonumber(flags)
    if not flags then
        flags = 0
    end

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
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
        return false, "bad value type"
    end
    
    local forcible = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_store_helper(meta_zone, op, key, key_len,
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


local function shdict_expire(zone, key, exptime, op)
    local meta_zone = check_zone(zone)

    exptime = tonumber(exptime)
    if not exptime or exptime < 0 then
        return error("bad \"exptime\" argument")
    end

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
    end

    op = op or 0

    local is_stale = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_expire_helper(meta_zone, op, key, key_len,
                                                  exptime * 1000, is_stale, errmsg)

    if rc ~= NGX_OK then
        return 0, ffi_str(errmsg[0])
    end

    if op == 0 then
        return 1
    else
        return 1, is_stale[0] == 1
    end
end


local function shdict_expire_stale(zone, key, exptime)
    return shdict_expire(zone, key, exptime, 0x0008)
end


local function shdict_ttl(zone, key)
    local meta_zone = check_zone(zone)

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
    end
    
    local ttl = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_ttl_helper(meta_zone, key,
                                               key_len, ttl, errmsg)
    
    if rc ~= NGX_OK then
        return nil, ffi_str(errmsg[0])
    end
    
    return tonumber(ttl[0])
end


local function shdict_fetch(zone, key, op)
    local meta_zone = check_zone(zone)

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
    end

    str_value_buf[0] = str_buf
    str_value_len[0] = str_buf_size
    
    op = op or 0
    
    local value_type = int_tmp[0]
    local user_flags = int_tmp[1]
    local is_stale   = int_tmp[2]

    local rc = C.ngx_lua_ffi_shdict_get_helper(meta_zone, op, key,
                                               key_len, value_type, str_value_buf,
                                               str_value_len, num_value, user_flags,
                                               is_stale, errmsg)
    if rc ~= NGX_OK then
        return nil, ffi_str(errmsg[0])
    end

    local typ = value_type[0]

    if typ == 0 then -- LUA_TNIL
        return nil
    end

    local flags = tonumber(user_flags[0])

    local val

    if typ == 4 then -- LUA_TSTRING
        val = ffi_str(str_value_buf[0], str_value_len[0])
        if str_value_buf[0] ~= str_buf then
            C.free(str_value_buf[0])
        end

    elseif typ == 3 then -- LUA_TNUMBER
        val = tonumber(num_value[0])

    elseif typ == 1 then -- LUA_TBOOLEAN
        val = (tonumber(str_value_buf[0][0]) ~= 0)

    else
        return error("unknown value type: " .. typ)
    end

    if flags ~= 0 then
        flags = nil
    end

    if op == 0 then
        return val, flags
    else
        return val, flags, is_stale[0] == 1
    end
end


local function shdict_get(zone, key)
    return shdict_fetch(zone, key, 0)
end


local function shdict_get_stale(zone, key)
    return shdict_fetch(zone, key, 0x0008)
end


local function shdict_flush_all(zone)
    local meta_zone = check_zone(zone)

    local rc = C.ngx_lua_ffi_shdict_flush(meta_zone, errmsg)
    if rc ~= 0 then
        return nil, "failed to flush"
    end

    return true
end


local function shdict_flush_expired(zone, attempts)
    local meta_zone = check_zone(zone)

    attempts = tonumber(attempts)
    if not attempts then
        attempts = 0
    end

    local freed = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_flush_expired(meta_zone, attempts, freed, errmsg)
    if rc ~= 0 then
        return error("failed get flush expire")
    end

    return tonumber(freed[0])
end


local function shdict_incr(zone, key, value, init, exptime)
    local meta_zone = check_zone(zone)

    local key, key_len = check_key(key)
    if key == nil then
        return key, key_len
    end

    if type(value) ~= "number" then
        value = tonumber(value)
    end
    num_value[0] = value

    local has_init

    if init then
        local typ = type(init)
        if typ ~= "number" then
            init = tonumber(init)

            if not init then
                return error("bad init arg: number expected, got " .. typ)
            end
        end

        has_init = 1

    else
        has_init = 0
        init = 0
    end

    exptime = tonumber(exptime)
    if not exptime then
        exptime = 0
    elseif exptime < 0 then
        return error("bad \"exptime\" argument")
    end

    local forcible = int_tmp[0]

    local rc = C.ngx_lua_ffi_shdict_incr_helper(meta_zone, key, key_len, num_value,
                                              errmsg, has_init, init, exptime,
                                              forcible)
    if rc ~= NGX_OK then  -- ~= NGX_OK
        return nil, ffi_str(errmsg[0])
    end

    if has_init == 0 then
        return tonumber(num_value[0])
    end

    return tonumber(num_value[0]), nil, forcible[0] == 1
end


local function shdict_get_keys(zone, attempts)
    local meta_zone = check_zone(zone)

    local keys_buf = ngx_str_buf
    local keys_num = int_tmp[0]

    attempts = tonumber(attempts)
    if not attempts then
        attempts = 1024
    end

    local rc = C.ngx_lua_ffi_shdict_get_keys(meta_zone, attempts, keys_buf,
        keys_num, errmsg)
    if rc ~= 0 then
        return nil, ffi_str(errmsg)
    end

    local keys = {}
    local num = tonumber(keys_num[0])

    if num > 0 then
        for i = 0, num - 1 do
            keys[#keys + 1] = ffi_str(keys_buf[0][i].data, keys_buf[0][i].len)
        end
        C.free(keys_buf[0])
    end

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
func.incr               = shdict_incr
func.flush_expired      = shdict_flush_expired
func.flush_all          = shdict_flush_all
func.expire             = shdict_expire
func.expire_stale       = shdict_expire_stale
func.ttl                = shdict_ttl


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


set_index()


return _M

