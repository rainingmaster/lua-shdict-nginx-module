# vim:set ft= ts=4 sw=4 et fdm=marker:

our $SkipReason;

BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
    $SkipReason = "unavailable for the hup tests";

    } else {
    $ENV{TEST_NGINX_USE_HUP} = 1;
    undef $ENV{TEST_NGINX_USE_STAP};
    }
}

use Test::Nginx::Socket::Lua $SkipReason ? (skip_all => $SkipReason) : ();
use Test::Nginx::Socket::Lua::Stream $SkipReason ? (skip_all => $SkipReason) : ();
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

$ENV{TEST_NGINX_LUA_PACK_PATH} ||= "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";

no_shuffle();

no_long_string();

run_tests();

__DATA__

=== TEST 1-1: initialize the shdict in stream
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem stream_dict 900k;
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.stream_dict

        local ret, err = dict:set("foo", "bar")
        if ret then
            ngx.say("set success")
        else
            ngx.say("set err: ", err)
        end

        local ret, err = dict:lpush("list", 1)
        if ret then
            ngx.say("push success")
        else
            ngx.say("push err: ", err)
        end
    }
--- stream_response
set success
push success
--- no_error_log
[error]


=== TEST 1-2: retrieve the shdict in http
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem stream_dict 900k;
--- stream_server_config
    content_by_lua_block {
        return
    }
--- config
    location = / {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.stream_dict

            local ret, err = dict:get("foo")
            if ret then
                ngx.say("get: ", ret)
            else
                ngx.say("get err: ", err)
            end

            local ret, err = dict:lpop("list")
            if ret then
                ngx.say("pop: ", ret)
            else
                ngx.say("pop err: ", err)
            end
        }
    }
--- request
GET /
--- response_body
get: bar
pop: 1
--- no_error_log
[error]


=== TEST 2-1: initialize the shdict in http
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem http_dict 900k;
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
--- stream_server_config
    content_by_lua_block {
        return
    }
--- config
    location = / {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.http_dict

            local ret, err = dict:set("foo2", "bar222")
            if ret then
                ngx.say("set success")
            else
                ngx.say("set err: ", err)
            end

            local ret, err = dict:lpush("list2", 10)
            if ret then
                ngx.say("push success")
            else
                ngx.say("push err: ", err)
            end
        }
    }
--- request
GET /
--- response_body
set success
push success
--- no_error_log
[error]


=== TEST 2-2: retrieve the shdict in stream
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem http_dict 900k;
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.http_dict

        local ret, err = dict:get("foo2")
        if ret then
            ngx.say("get: ", ret)
        else
            ngx.say("get err: ", err)
        end

        local ret, err = dict:lpop("list2")
        if ret then
            ngx.say("pop: ", ret)
        else
            ngx.say("pop err: ", err)
        end
    }
--- stream_response
get: bar222
pop: 10
--- no_error_log
[error]
