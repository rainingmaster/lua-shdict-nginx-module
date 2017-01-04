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
use Cwd qw(cwd);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dogs 1m;
};

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

#no_diff();
no_long_string();
#master_on();
#workers(2);

no_shuffle();

run_tests();

__DATA__

=== TEST 1: initialize the fields in shdict
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua '
            local t = require("resty.shdict")
            local dogs = t.dogs
            dogs:set("foo", 32)
            dogs:set("bah", 10502)
            local val = dogs:get("foo")
            ngx.say(val, " ", type(val))
            val = dogs:get("bah")
            ngx.say(val, " ", type(val))
        ';
    }
--- request
GET /test
--- response_body
32 number
10502 number
--- no_error_log
[error]



=== TEST 2: retrieve the fields in shdict after HUP reload
--- http_config eval: $::HttpConfig
--- config
    location = /test {
        content_by_lua '
            local t = require("resty.shdict")
            local dogs = t.dogs

            -- dogs:set("foo", 32)
            -- dogs:set("bah", 10502)

            local val = dogs:get("foo")
            ngx.say(val, " ", type(val))
            val = dogs:get("bah")
            ngx.say(val, " ", type(val))
        ';
    }
--- request
GET /test
--- response_body
32 number
10502 number
--- no_error_log
[error]

