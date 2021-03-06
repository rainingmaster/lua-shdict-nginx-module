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

=== TEST 1: lpush & lpop
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
            ngx.say("push err: ", err)
        end

        local val, err = dict:llen("foo")
        ngx.say(val, " ", err)

        local val, err = dict:lpop("foo")
        ngx.say(val, " ", err)

        local val, err = dict:llen("foo")
        ngx.say(val, " ", err)

        local val, err = dict:lpop("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
1 nil
bar nil
0 nil
nil nil
--- no_error_log
[error]



=== TEST 2: get operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
nil value is a list
--- no_error_log
[error]



=== TEST 3: set operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local ok, err = dict:set("foo", "bar")
        ngx.say(ok, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
true nil
bar nil
--- no_error_log
[error]



=== TEST 4: replace operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local ok, err = dict:replace("foo", "bar")
        ngx.say(ok, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
true nil
bar nil
--- no_error_log
[error]



=== TEST 5: add operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local ok, err = dict:add("foo", "bar")
        ngx.say(ok, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
false exists
nil value is a list
--- no_error_log
[error]



=== TEST 6: delete operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local ok, err = dict:delete("foo")
        ngx.say(ok, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
true nil
nil nil
--- no_error_log
[error]



=== TEST 7: incr operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local ok, err = dict:incr("foo", 1)
        ngx.say(ok, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
push success
nil not a number
nil value is a list
--- no_error_log
[error]



=== TEST 8: get_keys operation on list type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("foo", "bar")
        if len then
            ngx.say("push success")
        else
        ngx.say("push err: ", err)
        end

        local keys, err = dict:get_keys()
        ngx.say("key: ", keys[1])
    }
--- stream_response
push success
key: foo
--- no_error_log
[error]



=== TEST 9: push operation on key-value type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ok, err = dict:set("foo", "bar")
        if ok then
            ngx.say("set success")
        else
        ngx.say("set err: ", err)
        end

        local len, err = dict:lpush("foo", "bar")
        ngx.say(len, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
set success
nil value not a list
bar nil
--- no_error_log
[error]



=== TEST 10: pop operation on key-value type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ok, err = dict:set("foo", "bar")
        if ok then
            ngx.say("set success")
        else
        ngx.say("set err: ", err)
        end

        local val, err = dict:lpop("foo")
        ngx.say(val, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
set success
nil value not a list
bar nil
--- no_error_log
[error]



=== TEST 11: llen operation on key-value type
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ok, err = dict:set("foo", "bar")
        if ok then
            ngx.say("set success")
        else
        ngx.say("set err: ", err)
        end

        local val, err = dict:llen("foo")
        ngx.say(val, " ", err)

        local val, err = dict:get("foo")
        ngx.say(val, " ", err)
    }
--- stream_response
set success
nil value not a list
bar nil
--- no_error_log
[error]



=== TEST 12: lpush and lpop
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        for i = 1, 3 do
            local len, err = dict:lpush("foo", i)
            if len ~= i then
                ngx.say("push err: ", err)
                break
            end
        end

        for i = 1, 3 do
            local val, err = dict:lpop("foo")
            if not val then
                ngx.say("pop err: ", err)
                break
            else
                ngx.say(val)
            end
        end
    }
--- stream_response
3
2
1
--- no_error_log
[error]



=== TEST 13: lpush and rpop
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        for i = 1, 3 do
            local len, err = dict:lpush("foo", i)
            if len ~= i then
                ngx.say("push err: ", err)
                break
            end
        end

        for i = 1, 3 do
            local val, err = dict:rpop("foo")
            if not val then
                ngx.say("pop err: ", err)
                break
            else
                ngx.say(val)
            end
        end
    }
--- stream_response
1
2
3
--- no_error_log
[error]



=== TEST 14: rpush and lpop
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        for i = 1, 3 do
            local len, err = dict:rpush("foo", i)
            if len ~= i then
                ngx.say("push err: ", err)
                break
            end
        end

        for i = 1, 3 do
            local val, err = dict:lpop("foo")
            if not val then
                ngx.say("pop err: ", err)
                break
            else
                ngx.say(val)
            end
        end
    }
--- stream_response
1
2
3
--- no_error_log
[error]



=== TEST 15: list removed: expired
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local N = 100000
        local max = 0

        for i = 1, N do
            local key = string.format("%05d", i)

            local len , err = dict:lpush(key, i)
            if not len then
                max = i
                break
            end
        end

        local keys = dict:get_keys(0)

        ngx.say("max - 1 matched keys length: ", max - 1 == #keys)

        dict:flush_all()

        local keys = dict:get_keys(0)

        ngx.say("keys all expired, left number: ", #keys)

        for i = 100000, 1, -1 do
            local key = string.format("%05d", i)

            local len, err = dict:lpush(key, i)
            if not len then
                ngx.say("loop again, max matched: ", N + 1 - i == max)
                break
            end
        end

        dict:flush_all()

        dict:flush_expired()

        for i = 1, N do
            local key = string.format("%05d", i)

            local len, err = dict:lpush(key, i)
            if not len then
                ngx.say("loop again, max matched: ", i == max)
                break
            end
        end
    }
--- stream_response
max - 1 matched keys length: true
keys all expired, left number: 0
loop again, max matched: true
loop again, max matched: true
--- no_error_log
[error]
--- timeout: 9



=== TEST 16: list removed: forcibly
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local N = 200000
        local max = 0
        for i = 1, N do
            local ok, err, forcible  = dict:set(i, i)
            if not ok or forcible then
                max = i
                break
            end
        end

        local two = dict:get(2)

        ngx.say("two == number 2: ", two == 2)

        dict:flush_all()
        dict:flush_expired()

        local keys = dict:get_keys(0)

        ngx.say("no one left: ", #keys)

        for i = 1, N do
            local key = string.format("%05d", i)

            local len, err = dict:lpush(key, i)
            if not len then
                break
            end
        end

        for i = 1, max do
            local ok, err = dict:set(i, i)
            if not ok then
                ngx.say("set err: ", err)
                break
            end
        end

        local two = dict:get(2)

        ngx.say("two == number 2: ", two == 2)
    }
--- stream_response
two == number 2: true
no one left: 0
two == number 2: true
--- no_error_log
[error]
--- timeout: 9



=== TEST 17: expire on all types
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local len, err = dict:lpush("list", "foo")
        if not len then
            ngx.say("push err: ", err)
        end

        local ok, err = dict:set("key", "bar")
        if not ok then
            ngx.say("set err: ", err)
        end

        local keys = dict:get_keys(0)

        ngx.say("keys number: ", #keys)

        dict:flush_all()

        local keys = dict:get_keys(0)

        ngx.say("keys number: ", #keys)
    }
--- stream_response
keys number: 2
keys number: 0
--- no_error_log
[error]



=== TEST 18: long list node
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local long_str = string.rep("foo", 10)

        for i = 1, 3 do
            local len, err = dict:lpush("list", long_str)
            if not len then
                ngx.say("push err: ", err)
            end
        end

        for i = 1, 3 do
            local val, err = dict:lpop("list")
            if val then
                ngx.say(val)
            end
        end
    }
--- stream_response
foofoofoofoofoofoofoofoofoofoo
foofoofoofoofoofoofoofoofoofoo
foofoofoofoofoofoofoofoofoofoo
--- no_error_log
[error]



=== TEST 19: incr on expired list
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local long_str = string.rep("foo", 10 * 1024) -- 30k

        for i = 1, 100 do
            for j = 1, 10 do
                local key = "list" .. j
                local len, err = dict:lpush(key, long_str)
                if not len then
                ngx.say("push err: ", err)
                end
            end

            dict:flush_all()

            for j = 10, 1, -1 do
                local key = "list" .. j
                local newval, err = dict:incr(key, 1, 0)
                if not newval then
                ngx.say("incr err: ", err)
                end
            end

            dict:flush_all()
        end

        ngx.say("done")
    }
--- stream_response
done
--- no_error_log
[error]
