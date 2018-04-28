# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
};

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: expire & ttl
--- http_config eval: $::HttpConfig
--- config
    location = /test {
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
            else
                ngx.say("expire success")
            end

            local val, err = dict:ttl("foo")
            ngx.say("ttl is: ", val)
        }
    }
--- request
GET /test
--- response_body
set success
ttl is: 100
expire success
ttl is: 10
--- no_error_log
[error]


=== TEST 2: ttl: get ttl on a list
--- http_config eval: $::HttpConfig
--- config
    location = /test {
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
            else
                ngx.say("expire success")
            end

            val, err = dict:ttl("list")
            ngx.say("ttl is: ", val)
        }
    }
--- request
GET /test
--- response_body
push success
ttl is: 0
expire success
ttl is: 10
--- no_error_log
[error]


=== TEST 3: expire: set ttl on a list
--- http_config eval: $::HttpConfig
--- config
    location = /test {
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
    }
--- request
GET /test
--- response_body
push success
true nil
--- no_error_log
[error]


=== TEST 4: expire: set ttl by negative number
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:set("foo", "bar", 100)

            local ok, err = dict:expire("foo", -10)
            if not ok then
                ngx.say("expire err: ", err)
            else
                ngx.say("expire success")
            end

            val, err = dict:ttl("foo")
            ngx.say("ttl is: ", val)
        }
    }
--- request
GET /test
--- response_body
expire success
ttl is: 0
--- no_error_log
[error]


=== TEST 5: expire: set ttl by illegal parameter
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:set("foo", "bar", 100)

            local ok, err = dict:expire("foo", "bar")
            if not ok then
                ngx.say("expire err: ", err)
            else
                ngx.say("expire success")
            end
        }
    }
--- request
GET /test
--- response_body_like: 500 Internal Server Error
--- error_code: 500
--- error_log
bad "exptime" argument


=== TEST 6: ttl: get ttl on a expired key
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:set("foo", "bar", 0.01)
            if ret then
                ngx.say("set success")
            else
                ngx.say("set err: ", err)
            end

            ngx.sleep(0.05)

            local val, err = dict:ttl("foo")
            if val < 0 then
                return ngx.say("key is expired")
            end

            ngx.say("failed: ", val)
        }
    }
--- request
GET /test
--- response_body
set success
key is expired
--- no_error_log
[error]


=== TEST 7: ttl: get ttl on nil key
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local val, err = dict:ttl("foo")
            ngx.say("ttl is: ", val)
        }
    }
--- request
GET /test
--- response_body
ttl is: nil
--- no_error_log
[error]


=== TEST 8: ttl: get ttl on a key exists but has no associated expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
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
    }
--- request
GET /test
--- response_body
set success
ttl is: 0
--- no_error_log
[error]


=== TEST 9: expire: set ttl on a expired key
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ret, err = dict:set("foo", "bar", 0.01)
            if ret then
                ngx.say("set success")
            else
                ngx.say("set err: ", err)
            end

            ngx.sleep(0.05)

            local ok, err = dict:expire("foo", 10)
            if not ok then
                ngx.say("expire err: ", err)
            else
                ngx.say("expire success")
            end
        }
    }
--- request
GET /test
--- response_body
set success
expire success
--- no_error_log
[error]


=== TEST 10: expire: set ttl on a nil key
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict

            local ok, err = dict:expire("foo", 10)
            if not ok then
                ngx.say("expire err: ", err)
            else
                ngx.say("expire success")
            end
        }
    }
--- request
GET /test
--- response_body
expire err: not found
--- no_error_log
[error]


=== TEST 11: expire: get ttl on a key exists but has no associated expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
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
            else
                ngx.say("expire success")
            end

            local val, err = dict:ttl("foo")
            ngx.say("ttl is: ", val)
        }
    }
--- request
GET /test
--- response_body
set success
ttl is: 0
expire success
ttl is: 10
--- no_error_log
[error]


=== TEST 12: expire: set a key never expired by expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
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
            else
                ngx.say("expire success")
            end

            local val, err = dict:ttl("foo")
            ngx.say("ttl is: ", val)
        }
    }
--- request
GET /test
--- response_body
set success
ttl is: 10
expire success
ttl is: 0
--- no_error_log
[error]
