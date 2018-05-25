# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

repeat_each(2);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
    lua_shared_mem dogs 1m;
    lua_shared_mem cats 16k;
    lua_shared_mem birds 100k;
};

plan tests => repeat_each() * (blocks() * 3 + 22);

#no_diff();
no_long_string();
#master_on();
#workers(2);

run_tests();

__DATA__

=== TEST 1: incr key and set exists key expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict
            dict:set("foo", 32, 100)
            ngx.say("ttl is ", dict:ttl("foo"))
            local res, err = dict:incr("foo", 10502, 0, 20)
            ngx.say("incr: ", res, " ", err)
            ngx.say("ttl is ", dict:ttl("foo"))
        }
    }
--- request
GET /test
--- response_body
ttl is 100
incr: 10534 nil
ttl is 100
--- no_error_log
[error]


=== TEST 2: incr key and not set expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict
            dict:set("foo", 32, 100)
            ngx.say("ttl is ", dict:ttl("foo"))
            local res, err = dict:incr("foo", 10502)
            ngx.say("incr: ", res, " ", err)
            ngx.say("ttl is ", dict:ttl("foo"))
        }
    }
--- request
GET /test
--- response_body
ttl is 100
incr: 10534 nil
ttl is 100
--- no_error_log
[error]


=== TEST 3: incr key without expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict
            dict:set("foo", 32, 100)
            ngx.say("ttl is ", dict:ttl("foo"))
            ngx.location.capture("/sleep/2")
            local res, err = dict:incr("foo", 10502)
            ngx.say("incr: ", res, " ", err)
            local ttl = dict:ttl("foo")
            if ttl < 100 and ttl > 90 then
                ngx.say("ttl is normal")
            else
                ngx.say("ttl is abnormal: ", ttl)
            end
        }
    }
    location ~ ^/sleep/(.+) {
        echo_sleep $1;
    }
--- request
GET /test
--- response_body
ttl is 100
incr: 10534 nil
ttl is normal
--- no_error_log
[error]


=== TEST 4: incr key with init and set expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict
            dict:flush_all()
            local res, err = dict:incr("foo", 10502, 1, 20)
            ngx.say("incr: ", res, " ", err)
            ngx.say("ttl is ", dict:ttl("foo"))
        }
    }
--- request
GET /test
--- response_body
incr: 10503 nil
ttl is 20
--- no_error_log
[error]


=== TEST 5: incr key with init and without expire
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dict = t.dict
            dict:flush_all()
            local res, err = dict:incr("foo", 10502, 1)
            ngx.say("incr: ", res, " ", err)
            ngx.say("ttl is ", dict:ttl("foo"))
        }
    }
--- request
GET /test
--- response_body
incr: 10503 nil
ttl is 0
--- no_error_log
[error]



=== TEST 6: incr bad init_ttl argument
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            local pok, err = pcall(dogs.incr, dogs, "foo", 1, 0, -1)
            if not pok then
                ngx.say("not ok: ", err)
                return
            end

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
not ok: bad "init_ttl" argument
--- no_error_log
[error]
[alert]
[crit]



=== TEST 7: incr init_ttl argument is not a number
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            local pok, err = pcall(dogs.incr, dogs, "foo", 1, 0, "bar")
            if not pok then
                ngx.say("not ok: ", err)
                return
            end

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
not ok: bad init_ttl arg: number expected, got string
--- no_error_log
[error]
[alert]
[crit]



=== TEST 8: incr init_ttl argument without init
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            local pok, err = pcall(dogs.incr, dogs, "foo", 1, nil, 0.001)
            if not pok then
                ngx.say("not ok: ", err)
                return
            end

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
not ok: must provide "init" when providing "init_ttl"
--- no_error_log
[error]
[alert]
[crit]



=== TEST 9: incr key with init_ttl (key exists)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:set("foo", 32)

            local res, err = dogs:incr("foo", 10502, 0, 0.001)
            ngx.say("incr: ", res, " ", err)
            ngx.say("foo = ", dogs:get("foo"))

            ngx.sleep(0.002)

            ngx.say("foo after incr init_ttl = ", dogs:get("foo"))
        }
    }
--- request
GET /t
--- response_body
incr: 10534 nil
foo = 10534
foo after incr init_ttl = 10534
--- no_error_log
[error]
[alert]
[crit]



=== TEST 10: incr key with init and init_ttl (key not exists)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:flush_all()

            local res, err = dogs:incr("foo", 10502, 1, 0.001)
            ngx.say("incr: ", res, " ", err)
            ngx.say("foo = ", dogs:get("foo"))

            ngx.sleep(0.002)

            ngx.say("foo after init_ttl = ", dogs:get("foo"))
        }
    }
--- request
GET /t
--- response_body
incr: 10503 nil
foo = 10503
foo after init_ttl = nil
--- no_error_log
[error]
[alert]
[crit]



=== TEST 11: incr key with init and init_ttl as string (key not exists)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:flush_all()

            local res, err = dogs:incr("foo", 10502, 1, "0.001")
            ngx.say("incr: ", res, " ", err)
            ngx.say("foo = ", dogs:get("foo"))

            ngx.sleep(0.002)

            ngx.say("foo after init_ttl = ", dogs:get("foo"))
        }
    }
--- request
GET /t
--- response_body
incr: 10503 nil
foo = 10503
foo after init_ttl = nil
--- no_error_log
[error]
[alert]
[crit]



=== TEST 12: incr key with init and init_ttl (key expired and size matched)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            for i = 1, 20 do
                dogs:set("bar" .. i, i, 0.002)
            end
            dogs:set("foo", 32, 0.002)
            ngx.sleep(0.003)

            local res, err = dogs:incr("foo", 10502, 0, 0.001)
            ngx.say("incr: ", res, " ", err)
            ngx.say("foo = ", dogs:get("foo"))

            ngx.sleep(0.002)

            ngx.say("foo after init_ttl = ", dogs:get("foo"))
        }
    }
--- request
GET /t
--- response_body
incr: 10502 nil
foo = 10502
foo after init_ttl = nil
--- no_error_log
[error]
[alert]
[crit]



=== TEST 13: incr key with init and init_ttl (forcibly override other valid entries)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:flush_all()

            local long_prefix = string.rep("1234567890", 100)
            for i = 1, 1000 do
                local success, err, forcible = dogs:set(long_prefix .. i, i)
                if forcible then
                    dogs:delete(long_prefix .. i)
                    break
                end
            end

            local res, err, forcible = dogs:incr(long_prefix .. "bar", 10502, 0)
            ngx.say("incr: ", res, " ", err, " ", forcible)

            local res, err, forcible = dogs:incr(long_prefix .. "foo", 10502, 0, 0.001)
            ngx.say("incr: ", res, " ", err, " ", forcible)
            ngx.say("foo = ", dogs:get(long_prefix .. "foo"))

            ngx.sleep(0.002)
            ngx.say("foo after init_ttl = ", dogs:get("foo"))
        }
    }
--- request
GET /t
--- response_body
incr: 10502 nil false
incr: 10502 nil true
foo = 10502
foo after init_ttl = nil
--- no_error_log
[error]
[alert]
[crit]



=== TEST 14: exptime uses long type to avoid overflow in set() + ttl()
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:flush_all()

            local ok, err = dogs:set("huge_ttl", true, 2 ^ 31)
            if not ok then
                ngx.say("err setting: ", err)
                return
            end

            local ttl, err = dogs:ttl("huge_ttl")
            if not ttl then
                ngx.say("err retrieving ttl: ", err)
                return
            end

            ngx.say("ttl: ", ttl)
        }
    }
--- request
GET /t
--- response_body
ttl: 2147483648
--- no_error_log
[error]
[alert]
[crit]



=== TEST 14: exptime uses long type to avoid overflow in expire() + ttl()
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:flush_all()

            local ok, err = dogs:set("updated_huge_ttl", true)
            if not ok then
                ngx.say("err setting: ", err)
                return
            end

            local ok, err = dogs:expire("updated_huge_ttl", 2 ^ 31)
            if not ok then
                ngx.say("err expire: ", err)
                return
            end

            local ttl, err = dogs:ttl("updated_huge_ttl")
            if not ttl then
                ngx.say("err retrieving ttl: ", err)
                return
            end

            ngx.say("ttl: ", ttl)
        }
    }
--- request
GET /t
--- response_body
ttl: 2147483648
--- no_error_log
[error]
[alert]
[crit]



=== TEST 15: init_ttl uses long type to avoid overflow in incr() + ttl()
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:flush_all()

            local ok, err = dogs:incr("incr_huge_ttl", 1, 0, 2 ^ 31)
            if not ok then
                ngx.say("err incr: ", err)
                return
            end

            local ttl, err = dogs:ttl("incr_huge_ttl")
            if not ttl then
                ngx.say("err retrieving ttl: ", err)
                return
            end

            ngx.say("ttl: ", ttl)
        }
    }
--- request
GET /t
--- response_body
ttl: 2147483648
--- no_error_log
[error]
[alert]
[crit]
