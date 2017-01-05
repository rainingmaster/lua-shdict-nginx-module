# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Test::Nginx::Socket::Lua::Stream;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

$ENV{TEST_NGINX_LUA_PACK_PATH} ||= "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";

no_long_string();
run_tests();

__DATA__

=== TEST 1: stream's set & http's get
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
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
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
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


=== TEST 2: http's set & stream's get
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
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
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
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


=== TEST 3: stream's push & http's pop
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    server {
        listen 1986;
        location = / {
            content_by_lua_block {
                local t = require("resty.shdict")
                local dict = t.dict

                local ret, err = dict:rpop("foo")
                if ret then
                    ngx.say("pop: ", ret)
                else
                    ngx.say("pop err: ", err)
                end
            }
        }
    }
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem dict 900k;
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:lpush("foo", "bar")
        if ret then
            ngx.say("push success")
        else
            ngx.say("push err: ", err)
        end

        local len, err = dict:llen("foo")
        ngx.say("len: ", len)

        local sock = ngx.socket.tcp()
        local ok, err = sock:connect("127.0.0.1", 1986)
        local req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        local bytes, err = sock:send(req)
        if not bytes then
            ngx.say("failed to send stream request: ", err)
            return
        end

        local line, err, partial = sock:receive("*a")
        ok = string.find(line, "?*\r\n9\r\npop: bar")
        if not ok then
            ngx.say("failed: " .. line)
        else
            ngx.say("pop success")
        end

        local len, err = dict:llen("foo")
        ngx.say("len: ", len)
    }
--- stream_response
push success
len: 1
pop success
len: 0
--- no_error_log
[error]


=== TEST 4: http's push & stream's pop
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    server {
        listen 1986;
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:rpop("foo")
            if ret then
                ngx.say("pop: ", ret)
            else
                ngx.say("pop err: ", err)
            end
        }
    }
--- stream_server_config
    content_by_lua_block {
        return
    }
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem dict 900k;
--- config
    location = / {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:lpush("foo", "bar")
            if ret then
                ngx.say("push success")
            else
                ngx.say("push err: ", err)
            end

            local len, err = dict:llen("foo")
            ngx.say("len: ", len)

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 1986)
            local line, err, partial = sock:receive("*a")
            ok = string.find(line, "pop: bar")
            if not ok then
                ngx.say("failed: " .. line)
            else
                ngx.say("pop success")
            end

            local len, err = dict:llen("foo")
            ngx.say("len: ", len)
        }
    }
--- request
GET /
--- response_body
push success
len: 1
pop success
len: 0
--- no_error_log
[error]


=== TEST 5: stream's expire & http's ttl
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    server {
        listen 1986;
        location = / {
            content_by_lua_block {
                local t = require("resty.shdict")
                local dict = t.dict

                local ret, err = dict:ttl("foo")
                if ret then
                    ngx.say("ttl: ", ret)
                else
                    ngx.say("ttl err: ", err)
                end
            }
        }
    }
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem dict 900k;
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict

        local ret, err = dict:set("foo", "bar")
        ret, err = dict:expire("foo", 123)
        if ret then
            ngx.say("expire success")
        else
            ngx.say("expire err: ", err)
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
        if not line then
            ngx.say("receive err: ", err)
            return
        end

        ok, err = ngx.re.match(line, "ttl: (\\d+)")
        if not ok then
            ngx.say("failed: " .. line)
        else
            if tonumber(ok[1]) <= 123 then
                ngx.say("ttl less than 123")
            else
                ngx.say("failed: ", ok)
            end
        end
    }
--- stream_response
expire success
ttl less than 123
--- no_error_log
[error]


=== TEST 6: http's expire & stream's ttl
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    server {
        listen 1986;
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:ttl("foo")
            if ret then
                ngx.say("ttl: ", ret)
            else
                ngx.say("ttl err: ", err)
            end
        }
    }
--- stream_server_config
    content_by_lua_block {
        return
    }
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem dict 900k;
--- config
    location = / {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:set("foo", "bar")
            ret, err = dict:expire("foo", 321)
            if ret then
                ngx.say("expire success")
            else
                ngx.say("expire err: ", err)
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 1986)
            local line, err, partial = sock:receive("*a")
            if not line then
                ngx.say("receive err: ", err)
                return
            end

            ok, err = ngx.re.match(line, "ttl: (\\d+)")
            if not ok then
                ngx.say("failed: " .. line)
            else
                if tonumber(ok[1]) <= 321 then
                    ngx.say("ttl less than 321")
                else
                    ngx.say("failed: ", ok)
                end
            end
        }
    }
--- request
GET /
--- response_body
expire success
ttl less than 321
--- no_error_log
[error]


=== TEST 7: two shdict
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem dict2 900k;
    server {
        listen 1986;
        location = / {
            content_by_lua_block {
                local t = require("resty.shdict")
                local dict1 = t.dict1
                local dict2 = t.dict2

                local ret, err = dict1:get("foo")
                if not ret then
                    ngx.say("get err: ", err)
                end

                local ret2, err = dict2:get("hello")
                if not ret2 then
                    ngx.say("get err: ", err)
                end

                ngx.say("get: ", ret, " and ", ret2)
            }
        }
    }
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem dict1 900k;
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict1 = t.dict1
        local dict2 = t.dict2

        dict1:set("foo", "bar")
        dict2:set("hello", "world")

        local sock = ngx.socket.tcp()
        local ok, err = sock:connect("127.0.0.1", 1986)
        local req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        local bytes, err = sock:send(req)
        if not bytes then
            ngx.say("failed to send stream request: ", err)
            return
        end

        local line, err, partial = sock:receive("*a")
        ok = string.find(line, "?*\r\n13\r\nget: bar and world")
        if not ok then
            ngx.say("failed: " .. line)
        else
            ngx.say("get success")
        end
    }
--- stream_response
get success
--- no_error_log
[error]


=== TEST 8: oper in init_by_lua respective
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem http_dict 900k;
    init_by_lua_block {
        local t = require("resty.shdict")
        local http_dict = t.http_dict

        http_dict:set("hello", "world")
    }
    server {
        listen 1986;
        location = / {
            content_by_lua_block {
                local t = require("resty.shdict")
                local http_dict = t.http_dict

                local ret, err = http_dict:get("hello")
                if ret then
                    ngx.say("stream get: ", ret)
                else
                    ngx.say("stream get err: ", err)
                end
            }
        }
    }
--- stream_config
    lua_package_path "$TEST_NGINX_LUA_PACK_PATH";
    lua_shared_mem stream_dict 900k;
    init_by_lua_block {
        local t = require("resty.shdict")
        local stream_dict = t.stream_dict

        stream_dict:set("foo", "bar")
    }
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local stream_dict = t.stream_dict

        local ret, err = stream_dict:get("foo")
        if ret then
            ngx.say("http get: ", ret)
        else
            ngx.say("http get err: ", err)
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
        ok = string.find(line, "?*\r\n12\r\nstream get: world")
        if not ok then
            ngx.say("failed: " .. line)
        else
            ngx.say("stream get success")
        end
    }
--- stream_response
http get: bar
stream get success
--- no_error_log
[error]
