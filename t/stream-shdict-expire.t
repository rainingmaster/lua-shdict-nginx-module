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
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end

        local ok, err = dict:expire("foo", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end
    }
--- stream_response
set success
ttl is: 100
expire success: 1
ttl is: 10
--- no_error_log
[error]


=== TEST 2: ttl operation on list type
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
        ngx.say(val, " ", err)
    }
--- stream_response
push success
nil value is a list
--- no_error_log
[error]


=== TEST 3: expire operation on list type
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
0 value is a list
--- no_error_log
[error]


=== TEST 4: expire operation with negative number
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


=== TEST 5: expire operation with illegal parameter
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


=== TEST 6: ttl operation on expired key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

        local ret, err = dict:set("foo", "bar", 0.01)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        ngx.sleep(0.02)

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end
    }
--- stream_response
set success
ttl is: -2
--- no_error_log
[error]


=== TEST 7: ttl operation on nonexistent key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end
    }
--- stream_response
ttl is: -2
--- no_error_log
[error]


=== TEST 8: ttl operation on no expiration time key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

        local ret, err = dict:set("foo", "bar")
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end
    }
--- stream_response
set success
ttl is: -1
--- no_error_log
[error]


=== TEST 9: expire operation on expired key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

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


=== TEST 10: expire operation on nonexistent key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

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


=== TEST 11: expire operation on no expiration time key
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

        local ret, err = dict:set("foo", "bar")
        if ret then
        ngx.say("set success")
        else
        ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end

        local ok, err = dict:expire("foo", 10)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end
    }
--- stream_response
set success
ttl is: -1
expire success: 1
ttl is: 10
--- no_error_log
[error]


=== TEST 11: set a key never expire by expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        dict:flush_all()

        local ret, err = dict:set("foo", "bar", 10)
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end

        local ok, err = dict:expire("foo", 0)
        if not ok then
            ngx.say("expire err: ", err)
        elseif ok == 0 then
            ngx.say("expire key not exist")
        else
            ngx.say("expire success: ", ok)
        end

        local val, err = dict:ttl("foo")
        if val then
            ngx.say("ttl is: ", val)
        else
            ngx.say("ttl err: ", err)
        end
    }
--- stream_response
set success
ttl is: 10
expire success: 1
ttl is: -1
--- no_error_log
[error]
