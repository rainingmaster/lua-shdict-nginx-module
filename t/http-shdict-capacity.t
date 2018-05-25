# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

repeat_each(2);

plan tests => repeat_each() * (blocks() * 5);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/t/lib/?.lua;$pwd/lib/?.lua;;";
    lua_shared_mem dict 900k;
    lua_shared_mem dogs 1m;
    lua_shared_mem cats 16k;
    lua_shared_mem birds 100k;
};

#no_diff();
no_long_string();
check_accum_error_log();
run_tests();

__DATA__

=== TEST 31: capacity
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local cats = t.cats
            local capacity = cats:capacity()
            ngx.say("capacity type: ", type(capacity))
            ngx.say("capacity: ", capacity)
        }
    }
--- request
GET /t
--- response_body
capacity type: number
capacity: 16384
--- no_error_log
[error]
[alert]
[crit]



=== TEST 32: free_space, empty (16k zone)
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local cats = t.cats
            cats:flush_all()
            cats:flush_expired()
            local free_page_bytes = cats:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body
free_page_bytes type: number
free_page_bytes: 4096
--- no_error_log
[error]
[alert]
[crit]



=== TEST 33: free_space, empty (100k zone)
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local birds = t.birds
            birds:flush_all()
            birds:flush_expired()
            local free_page_bytes = birds:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body_like chomp
\Afree_page_bytes type: number
free_page_bytes: (?:90112|94208)
\z
--- no_error_log
[error]
[alert]
[crit]



=== TEST 34: free_space, about half full, one page left
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local cats = t.cats
            cats:flush_all()
            cats:flush_expired()
            for i = 1, 31 do
                local key = string.format("key%05d", i)
                local val = string.format("val%05d", i)
                local success, err, forcible = cats:set(key, val)
                if err ~= nil then
                    ngx.say(string.format("got error, i=%d, err=%s", i, err))
                end
                if forcible then
                    ngx.say(string.format("got forcible, i=%d", i))
                end
                if not success then
                    ngx.say(string.format("got not success, i=%d", i))
                end
            end
            local free_page_bytes = cats:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body
free_page_bytes type: number
free_page_bytes: 4096
--- no_error_log
[error]
[alert]
[crit]



=== TEST 35: free_space, about half full, no page left
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local cats = t.cats
            cats:flush_all()
            cats:flush_expired()
            for i = 1, 32 do
                local key = string.format("key%05d", i)
                local val = string.format("val%05d", i)
                local success, err, forcible = cats:set(key, val)
                if err ~= nil then
                    ngx.say(string.format("got error, i=%d, err=%s", i, err))
                end
                if forcible then
                    ngx.say(string.format("got forcible, i=%d", i))
                end
                if not success then
                    ngx.say(string.format("got not success, i=%d", i))
                end
            end
            local free_page_bytes = cats:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body_like chomp
\Afree_page_bytes type: number
free_page_bytes: (?:0|4096)
\z
--- no_error_log
[error]
[alert]
[crit]



=== TEST 36: free_space, full
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local cats = t.cats
            cats:flush_all()
            cats:flush_expired()
            for i = 1, 63 do
                local key = string.format("key%05d", i)
                local val = string.format("val%05d", i)
                local success, err, forcible = cats:set(key, val)
                if err ~= nil then
                    ngx.say(string.format("got error, i=%d, err=%s", i, err))
                end
                if forcible then
                    ngx.say(string.format("got forcible, i=%d", i))
                end
                if not success then
                    ngx.say(string.format("got not success, i=%d", i))
                end
            end
            local free_page_bytes = cats:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body
free_page_bytes type: number
free_page_bytes: 0
--- no_error_log
[error]
[alert]
[crit]



=== TEST 37: free_space, got forcible
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local cats = t.cats
            cats:flush_all()
            cats:flush_expired()
            for i = 1, 64 do
                local key = string.format("key%05d", i)
                local val = string.format("val%05d", i)
                local success, err, forcible = cats:set(key, val)
                if err ~= nil then
                    ngx.say(string.format("got error, i=%d, err=%s", i, err))
                end
                if forcible then
                    ngx.say(string.format("got forcible, i=%d", i))
                end
                if not success then
                    ngx.say(string.format("got not success, i=%d", i))
                end
            end
            local free_page_bytes = cats:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body_like chomp
\A(?:got forcible, i=64
)?free_page_bytes type: number
free_page_bytes: 0
\z
--- no_error_log
[error]
[alert]
[crit]



=== TEST 38: free_space, full (100k)
--- skip_nginx: 5: < 1.11.7
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local t = require("resty.shdict")
            local birds = t.birds
            birds:flush_all()
            birds:flush_expired()
            for i = 1, 1000 do
                local key = string.format("key%05d", i)
                local val = string.format("val%05d", i)
                local ok, err, forcible = birds:set(key, val)
                if err ~= nil then
                    ngx.say(string.format("got error, i=%d, err=%s", i, err))
                end
                if forcible then
                    ngx.say(string.format("got forcible, i=%d", i))
                    break
                end
                if not ok then
                    ngx.say(string.format("got not ok, i=%d", i))
                    break
                end
            end
            local free_page_bytes = birds:free_space()
            ngx.say("free_page_bytes type: ", type(free_page_bytes))
            ngx.say("free_page_bytes: ", free_page_bytes)
        }
    }
--- request
GET /t
--- response_body_like chomp
\A(?:got forcible, i=736
)?free_page_bytes type: number
free_page_bytes: (?:0|32768)
\z
--- no_error_log
[error]
[alert]
[crit]
