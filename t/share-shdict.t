# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Test::Nginx::Socket::Lua::Stream;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

#my $pwd = cwd();

#our $StreamConfig = qq{
#    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
#    lua_shared_mem dict 900k;
#};

no_long_string();
run_tests();

__DATA__

=== TEST 1: set in stream & get in http
--- http_config
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    server {
        listen 1986;
        location = / {
            content_by_lua_block {
                local t = require("resty.shdict")
                local dict = t.dict

                local ret, err = dict:get("foo")
                if ret then
                    ngx.say("get: ", ret)
                else
                    ngx.say("get err: ", err)
                end
            }
        }
    }
--- stream_config
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
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

        local sock = ngx.socket.tcp()
        local ok, err = sock:connect("127.0.0.1", 1986)
        local req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        local bytes, err = sock:send(req)
        if not bytes then
            ngx.say("failed to send stream request: ", err)
            return
        end

        local line, err, partial = sock:receive("*a")
        ok = string.find(line, "?*\r\n9\r\nget: bar")
        if not ok then
            ngx.say("failed: " .. line)
        else
            ngx.say("get success")
        end
    }
--- stream_response
set success
get success
--- no_error_log
[error]


=== TEST 2: set in http & get in stream
--- stream_config
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    server {
        listen 1986;
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:get("foo")
            if ret then
                ngx.say("get: ", ret)
            else
                ngx.say("get err: ", err)
            end
        }
    }
--- stream_server_config
    content_by_lua_block {
        return
    }
--- http_config
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
--- config
    location = / {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:set("foo", "bar")
            if ret then
                ngx.say("set success")
            else
                ngx.say("set err: ", err)
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 1986)
            local line, err, partial = sock:receive("*a")
            ok = string.find(line, "get: bar")
            if not ok then
                ngx.say("failed: " .. line)
            else
                ngx.say("get success")
            end
        }
    }
--- request
GET /
--- response_body
set success
get success
--- no_error_log
[error]
