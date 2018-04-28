# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua::Stream;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

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

=== TEST 1: incr key and set expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:set("foo", 32, 100)
        ngx.say("ttl is ", dict:ttl("foo"))
        local res, err = dict:incr("foo", 10502, nil, 20)
        ngx.say("incr: ", res, " ", err)
        ngx.say("ttl is ", dict:ttl("foo"))
    }
--- stream_response
ttl is 100
incr: 10534 nil
ttl is 20
--- no_error_log
[error]


=== TEST 2: incr key and set not expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:set("foo", 32, 100)
        ngx.say("ttl is ", dict:ttl("foo"))
        local res, err = dict:incr("foo", 10502, nil, -1)
        ngx.say("incr: ", res, " ", err)
        ngx.say("ttl is ", dict:ttl("foo"))
    }
--- stream_response
ttl is 100
incr: 10534 nil
ttl is 0
--- no_error_log
[error]


=== TEST 3: incr key without expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:set("foo", 32, 100)
        ngx.say("ttl is ", dict:ttl("foo"))
        ngx.sleep(2)
        local res, err = dict:incr("foo", 10502)
        ngx.say("incr: ", res, " ", err)
        local ttl = dict:ttl("foo")
        if ttl < 100 and ttl > 90 then
            ngx.say("ttl is normal")
        else
            ngx.say("ttl is abnormal: ", ttl)
        end
    }
--- stream_response
ttl is 100
incr: 10534 nil
ttl is normal
--- no_error_log
[error]


=== TEST 4: incr key with init and set expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:flush_all()
        local res, err = dict:incr("foo", 10502, 1, 20)
        ngx.say("incr: ", res, " ", err)
        ngx.say("ttl is ", dict:ttl("foo"))
    }
--- stream_response
incr: 10503 nil
ttl is 20
--- no_error_log
[error]


=== TEST 5: incr key with init and without expire
--- stream_config eval: $::StreamConfig
--- stream_server_config
    content_by_lua_block {
        local t = require("resty.shdict")
        local dict = t.dict
        dict:flush_all()
        local res, err = dict:incr("foo", 10502, 1)
        ngx.say("incr: ", res, " ", err)
        ngx.say("ttl is ", dict:ttl("foo"))
    }
--- stream_response
incr: 10503 nil
ttl is 0
--- no_error_log
[error]
