# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua::Stream;
use Cwd qw(cwd);

repeat_each(2);

my $pwd = cwd();

our $StreamConfig = qq{
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
};

plan tests => repeat_each() * (blocks() * 3 + 0);

#no_diff();
no_long_string();
#master_on();
#workers(2);

run_tests();

__DATA__

=== TEST 1: incr key with init (key exists)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:set("foo", 32)
        local res, err = dict:incr("foo", 10502, 1)
        ngx.say("incr: ", res, " ", err)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
incr: 10534 nil
foo = 10534
--- no_error_log
[error]



=== TEST 2: incr key with init (key not exists)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:flush_all()
        dict:set("bah", 32)
        local res, err = dict:incr("foo", 10502, 1)
        ngx.say("incr: ", res, " ", err)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
incr: 10503 nil
foo = 10503
--- no_error_log
[error]



=== TEST 3: incr key with init (key expired and size not matched)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        for i = 1, 20 do
            dict:set("bar" .. i, i, 0.001)
        end
        dict:set("foo", "32", 0.001)
        ngx.sleep(0.002)
        local res, err = dict:incr("foo", 10502, 0)
        ngx.say("incr: ", res, " ", err)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
incr: 10502 nil
foo = 10502
--- no_error_log
[error]



=== TEST 4: incr key with init (key expired and size matched)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        for i = 1, 20 do
            dict:set("bar" .. i, i, 0.001)
        end
        dict:set("foo", 32, 0.001)
        ngx.sleep(0.002)
        local res, err = dict:incr("foo", 10502, 0)
        ngx.say("incr: ", res, " ", err)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
incr: 10502 nil
foo = 10502
--- no_error_log
[error]



=== TEST 5: incr key with init (forcibly override other valid entries)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:flush_all()
        local long_prefix = string.rep("1234567890", 100)
        for i = 1, 1000 do
            local success, err, forcible = dict:set(long_prefix .. i, i)
            if forcible then
                dict:delete(long_prefix .. i)
                break
            end
        end
        local res, err, forcible = dict:incr(long_prefix .. "bar", 10502, 0)
        ngx.say("incr: ", res, " ", err, " ", forcible)
        local res, err, forcible = dict:incr(long_prefix .. "foo", 10502, 0)
        ngx.say("incr: ", res, " ", err, " ", forcible)
        ngx.say("foo = ", dict:get(long_prefix .. "foo"))
    }
--- stream_response
incr: 10502 nil false
incr: 10502 nil true
foo = 10502
--- no_error_log
[error]



=== TEST 6: incr key without init (no forcible returned)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:set("foo", 1)
        local res, err, forcible = dict:incr("foo", 1)
        ngx.say("incr: ", res, " ", err, " ", forcible)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
incr: 2 nil nil
foo = 2
--- no_error_log
[error]



=== TEST 7: incr key (original value is not number)
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:set("foo", true)
        local res, err = dict:incr("foo", 1, 0)
        ngx.say("incr: ", res, " ", err)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
incr: nil not a number
foo = true
--- no_error_log
[error]



=== TEST 8: init is not number
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        local res, err, forcible = dict:incr("foo", 1, "bar")
        ngx.say("incr: ", res, " ", err, " ", forcible)
        ngx.say("foo = ", dict:get("foo"))
    }
--- stream_response
--- error_log
number expected, got string
