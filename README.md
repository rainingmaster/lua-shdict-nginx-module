Name
====

ngx_http_lua_share_dict


Table of Contents
=================

* [Name](#name)
* [Installation](#installation)
* [Directives](#directives)


Installation
============


Directives
==========

* [lua_shared_mem](#lua_shared_mem)

lua_shared_mem
---------------

**syntax:** *lua_shared_mem &lt;name&gt; &lt;size&gt;*

**default:** *no*

**context:** *http*

**phase:** *depends on usage*

Declares a shared memory zone, `<name>`, to serve as storage for the shm.

Shared memory zones are always shared by all the nginx worker processes in the current nginx server instance.

The `<size>` argument accepts size units such as `k` and `m`:

```nginx

 http {
     lua_shared_mem dict 10m;
     ...
 }
```

Use following script to get the Lua table:
```lua
  local t = require('resty.shdict')
  local dict = t.dict
```

Following example will be based on the above settings.

See [Nginx shared dict API for Lua](#nginxshareddictapiforlua) for details.

The hard-coded minimum size is 8KB while the practical minimum size depends
on actual user data set (some people start with 12KB).

[Back to TOC](#directives)

Nginx shared dict API for Lua
=================

The resulting object `dict` has the following methods:

* [get](#get)
* [get_stale](#get_stale)
* [set](#set)
* [safe_set](#safe_set)
* [add](#add)
* [safe_add](#safe_add)
* [replace](#replace)
* [delete](#delete)
* [incr](#incr)
* [lpush](#lpush)
* [rpush](#rpush)
* [lpop](#lpop)
* [rpop](#rpop)
* [llen](#llen)
* [flush_all](#flush_all)
* [flush_expired](#flush_expired)
* [get_keys](#get_keys)
* [expire](#expire)
* [expire_stale](#expire_stale)
* [ttl](#ttl)


get
-------------------
**syntax:** *value, flags = dict:get(key)*

**context:** *init_by_lua&#42;, init_worker_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Retrieving the value in the dictionary `dict` for the key `key`. If the key does not exist or has expired, then `nil` will be returned.

In case of errors, `nil` and a string describing the error will be returned.

The value returned will have the original data type when they were inserted into the dictionary, for example, Lua booleans, numbers, or strings.

The first argument to this method must be the dictionary object itself, for example,

```lua

 local value, flags = dict.get(dict, "Marry")
```

or use Lua's syntactic sugar for method calls:

```lua

 local value, flags = dict:get("Marry")
```

These two forms are fundamentally equivalent.

If the user flags is `0` (the default), then no flags value will be returned.

[Back to TOC](#nginx-shared-dict-api-for-lua)

get_stale
-------------------------
**syntax:** *value, flags, stale = dict:get_stale(key)*

**context:** *set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Similar to the [get](#get) method but returns the value even if the key has already expired.

Returns a 3rd value, `stale`, indicating whether the key has expired or not.

Note that the value of an expired key is not guaranteed to be available so one should never rely on the availability of expired items.

[Back to TOC](#nginx-shared-dict-api-for-lua)

set
-------------------
**syntax:** *success, err, forcible = dict:set(key, value, exptime?, flags?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Unconditionally sets a key-value pair into the shm-based dictionary `dict`. Returns three values:

* `success`: boolean value to indicate whether the key-value pair is stored or not.
* `err`: textual error message, can be `"no memory"`.
* `forcible`: a boolean value to indicate whether other valid items have been removed forcibly when out of storage in the shared memory zone.

The `value` argument inserted can be Lua booleans, numbers, strings, or `nil`. Their value type will also be stored into the dictionary and the same data type can be retrieved later via the [get](#get) method.

The optional `exptime` argument specifies expiration time (in seconds) for the inserted key-value pair. The time resolution is `0.001` seconds. If the `exptime` takes the value `0` (which is the default), then the item will never expire.

The optional `flags` argument specifies a user flags value associated with the entry to be stored. It can also be retrieved later with the value. The user flags is stored as an unsigned 32-bit integer internally. Defaults to `0`. The user flags argument was first introduced in the `v0.5.0rc2` release.

When it fails to allocate memory for the current key-value item, then `set` will try removing existing items in the storage according to the Least-Recently Used (LRU) algorithm. Note that, LRU takes priority over expiration time here. If up to tens of existing items have been removed and the storage left is still insufficient (either due to the total capacity limit specified by [lua_shared_dict](#lua_shared_dict) or memory segmentation), then the `err` return value will be `no memory` and `success` will be `false`.

If this method succeeds in storing the current item by forcibly removing other not-yet-expired items in the dictionary via LRU, the `forcible` return value will be `true`. If it stores the item without forcibly removing other valid items, then the return value `forcible` will be `false`.

The first argument to this method must be the dictionary object itself, for example,

```lua

 local succ, err, forcible = dict.set(dict, "Marry", "it is a nice cat!")
```

or use Lua's syntactic sugar for method calls:

```lua

 local succ, err, forcible = dict:set("Marry", "it is a nice cat!")
```

These two forms are fundamentally equivalent.

Please note that while internally the key-value pair is set atomically, the atomicity does not go across the method call boundary.

[Back to TOC](#nginx-shared-dict-api-for-lua)

safe_set
------------------------
**syntax:** *ok, err = dict:safe_set(key, value, exptime?, flags?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Similar to the [set](#set) method, but never overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone. In this case, it will immediately return `nil` and the string "no memory".

[Back to TOC](#nginx-shared-dict-api-for-lua)

add
-------------------
**syntax:** *success, err, forcible = dict:add(key, value, exptime?, flags?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Just like the [set](#set) method, but only stores the key-value pair into the dictionary `dict` if the key does *not* exist.

If the `key` argument already exists in the dictionary (and not expired for sure), the `success` return value will be `false` and the `err` return value will be `"exists"`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

safe_add
------------------------
**syntax:** *ok, err = dict:safe_add(key, value, exptime?, flags?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Similar to the [add](#add) method, but never overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone. In this case, it will immediately return `nil` and the string "no memory".

[Back to TOC](#nginx-shared-dict-api-for-lua)

replace
-----------------------
**syntax:** *success, err, forcible = dict:replace(key, value, exptime?, flags?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Just like the [set](#set) method, but only stores the key-value pair into the dictionary `dict` if the key *does* exist.

If the `key` argument does *not* exist in the dictionary (or expired already), the `success` return value will be `false` and the `err` return value will be `"not found"`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

delete
----------------------
**syntax:** *dict:delete(key)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Unconditionally removes the key-value pair from the shm-based dictionary `dict`.

It is equivalent to `dict:set(key, nil)`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

incr
--------------------
**syntax:** *newval, err, forcible? = dict:incr(key, value, init?, exptime?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Increments the (numerical) value for `key` in the shm-based dictionary `dict` by the step value `value`. Returns the new resulting number if the operation is successfully completed or `nil` and an error message otherwise.

The optional `exptime` argument specifies expiration time for `key`, similar to [set](#set).

When the key does not exist or has already expired in the shared dictionary,

1. if the `init` argument is not specified or takes the value `nil`, this method will return `nil` and the error string `"not found"`, or
1. if the `init` argument takes a number value, this method will create a new `key` with the value `init + value`.

Like the [add](#add) method, it also overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone.

The `forcible` return value will always be `nil` when the `init` argument is not specified.

If this method succeeds in storing the current item by forcibly removing other not-yet-expired items in the dictionary via LRU, the `forcible` return value will be `true`. If it stores the item without forcibly removing other valid items, then the return value `forcible` will be `false`.

If the original value is not a valid Lua number in the dictionary, it will return `nil` and `"not a number"`.

The `value` argument and `init` argument can be any valid Lua numbers, like negative numbers or floating-point numbers.

[Back to TOC](#nginx-shared-dict-api-for-lua)

lpush
---------------------
**syntax:** *length, err = dict:lpush(key, value)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Inserts the specified (numerical or string) `value` at the head of the list named `key` in the shm-based dictionary `dict`. Returns the number of elements in the list after the push operation.

If `key` does not exist, it is created as an empty list before performing the push operation. When the `key` already takes a value that is not a list, it will return `nil` and `"value not a list"`.

It never overrides the (least recently used) unexpired items in the store when running out of storage in the shared memory zone. In this case, it will immediately return `nil` and the string "no memory".

[Back to TOC](#nginx-shared-dict-api-for-lua)

rpush
---------------------
**syntax:** *length, err = dict:rpush(key, value)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Similar to the [lpush](#lpush) method, but inserts the specified (numerical or string) `value` at the tail of the list named `key`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

lpop
--------------------
**syntax:** *val, err = dict:lpop(key)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Removes and returns the first element of the list named `key` in the shm-based dictionary `dict`.

If `key` does not exist, it will return `nil`. When the `key` already takes a value that is not a list, it will return `nil` and `"value not a list"`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

rpop
--------------------
**syntax:** *val, err = dict:rpop(key)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Removes and returns the last element of the list named `key` in the shm-based dictionary `dict`.

If `key` does not exist, it will return `nil`. When the `key` already takes a value that is not a list, it will return `nil` and `"value not a list"`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

llen
--------------------
**syntax:** *len, err = dict:llen(key)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Returns the number of elements in the list named `key` in the shm-based dictionary `dict`.

If key does not exist, it is interpreted as an empty list and 0 is returned. When the `key` already takes a value that is not a list, it will return `nil` and `"value not a list"`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

flush_all
-------------------------
**syntax:** *dict:flush_all()*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Flushes out all the items in the dictionary. This method does not actuall free up all the memory blocks in the dictionary but just marks all the existing items as expired.

See also [flush_expired](#flush_expired) and `dict`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

flush_expired
-----------------------------
**syntax:** *flushed = dict:flush_expired(max_count?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Flushes out the expired items in the dictionary, up to the maximal number specified by the optional `max_count` argument. When the `max_count` argument is given `0` or not given at all, then it means unlimited. Returns the number of items that have actually been flushed.

Unlike the [flush_all](#flush_all) method, this method actually free up the memory used by the expired items.

See also [flush_all](#flush_all) and `dict`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

get_keys
------------------------
**syntax:** *keys = dict:get_keys(max_count?)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Fetch a list of the keys from the dictionary, up to `<max_count>`.

By default, only the first 1024 keys (if any) are returned. When the `<max_count>` argument is given the value `0`, then all the keys will be returned even there is more than 1024 keys in the dictionary.

**WARNING** Be careful when calling this method on dictionaries with a really huge number of keys. This method may lock the dictionary for quite a while and block all the nginx worker processes that are trying to access the dictionary.

[Back to TOC](#nginx-shared-dict-api-for-lua)

expire
------------------------
**syntax:** *ret = dict:expire(key, exptime)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Set a key's time to live in seconds. The time resolution is `0.001` seconds. If the `exptime` takes the value `0` , then the item will never expire.

`1` means expire `key` successfully, if `key` does not exist or `key` is expired, it will return `0`.

[Back to TOC](#nginx-shared-dict-api-for-lua)

expire_stale
------------------------
**syntax:** *ret, stale = dict:expire_stale(key, exptime)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Similar to the [expire](#expire) method but set the `exptime` even if the key has already expired.

If `ret` equal to `1`, the 2nd returns, `stale`, indicating whether the key has expired or not.

[Back to TOC](#nginx-shared-dict-api-for-lua)

ttl
------------------------
**syntax:** *keys = dict:ttl(key)*

**context:** *init_by_lua&#42;, set_by_lua&#42;, rewrite_by_lua&#42;, access_by_lua&#42;, content_by_lua&#42;, header_filter_by_lua&#42;, body_filter_by_lua&#42;, log_by_lua&#42;, ngx.timer.&#42;, balancer_by_lua&#42;, ssl_certificate_by_lua&#42;, ssl_session_fetch_by_lua&#42;, ssl_session_store_by_lua&#42;*

Get the time to live for `key`.

If `key` does not exist, it will return `-1`, and if `key` is expired, it will return `-2`.

[Back to TOC](#nginx-shared-dict-api-for-lua)