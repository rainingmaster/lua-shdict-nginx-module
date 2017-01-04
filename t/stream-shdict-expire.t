# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua::Stream;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $StreamConfig = qq{
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
};

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: expire & ttl
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 100)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)

        local ok, err = dict:expire("foo", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)
    }
--- stream_response
set success
ttl is: 100
expire success: 1
ttl is: 10
--- no_error_log
[error]


=== TEST 2: ttl: get ttl on a list
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("list", "bar")
        if len then
            ngx.say("push success")
        else
            ngx.say("push err: ", err)
        end

        local val, err = dict:ttl("list")
        ngx.say("ttl is: ", val)

        local ok, err = dict:expire("list", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("list")
        ngx.say("ttl is: ", val)
    }
--- stream_response
push success
ttl is: -1
expire success: 1
ttl is: 10
--- no_error_log
[error]


=== TEST 3: expire: set ttl on a list
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("list", "bar")
        if len then
            ngx.say("push success")
        else
            ngx.say("push err: ", err)
        end

        local ok, err = dict:expire("list", 10)
        ngx.say(ok, " ", err)
    }
--- stream_response
push success
1 nil
--- no_error_log
[error]


=== TEST 4: expire: set ttl by negative number
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 100)

        local ok, err = dict:expire("foo", -10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end
    }
--- stream_response
--- error_log
bad "exptime" argument


=== TEST 5: expire: set ttl by illegal parameter
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 100)

        local ok, err = dict:expire("foo", "bar")
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end
    }
--- stream_response
--- error_log
bad "exptime" argument


=== TEST 6: ttl: get ttl on a expired key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 0.01)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        ngx.sleep(0.02)

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)
    }
--- stream_response
set success
ttl is: -2
--- no_error_log
[error]


=== TEST 7: ttl: get ttl on nil key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)
    }
--- stream_response
ttl is: -2
--- no_error_log
[error]


=== TEST 8: ttl: get ttl on a key exists but has no associated expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar")
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)
    }
--- stream_response
set success
ttl is: -1
--- no_error_log
[error]


=== TEST 9: expire: set ttl on a expired key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 0.01)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        ngx.sleep(0.02)

        local ok, err = dict:expire("foo", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end
    }
--- stream_response
set success
expire key not exist
--- no_error_log
[error]


=== TEST 10: expire: set ttl on a nil key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ok, err = dict:expire("foo", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end
    }
--- stream_response
expire key not exist
--- no_error_log
[error]


=== TEST 11: expire: get ttl on a key exists but has no associated expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar")
        if ret then
        ngx.say("set success")
        else
        ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)

        local ok, err = dict:expire("foo", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)
    }
--- stream_response
set success
ttl is: -1
expire success: 1
ttl is: 10
--- no_error_log
[error]


=== TEST 12: expire: set a key never expired by expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 10)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)

        local ok, err = dict:expire("foo", 0)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("foo")
        ngx.say("ttl is: ", val)
    }
--- stream_response
set success
ttl is: 10
expire success: 1
ttl is: -1
--- no_error_log
[error]


=== TEST 13: expire: set ttl on a expired key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar", 00.1)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end
        
        ngx.sleep(1)

        local val, flags, stale = dict:get_stale("foo")
        ngx.say(val, " ", flags, " ", stale)

        local ok, stale = dict:expire("foo", 10, true)
        if not ok then
            ngx.say("expire err: ", stale)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok, " ", stale)
        end

        local val, flags, stale = dict:get_stale("foo")
        ngx.say(val, " ", flags, " ", stale)
    }
--- stream_response
set success
bar nil true
expire success: 1 true
bar nil false
--- no_error_log
[error]


=== TEST 14: expire: set ttl on a nil key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ok, err = dict:expire("foo", 10, true)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end
    }
--- stream_response
expire key not exist
--- no_error_log
[error]
