
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#ifndef _NGX_LUA_SHDICT_COMMON_H_
#define _NGX_LUA_SHDICT_COMMON_H_


#ifndef DDEBUG
#define DDEBUG 0
#endif
#include "ddebug.h"


#include <ngx_config.h>
#include <ngx_core.h>
#include <nginx.h>


#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>


#ifdef NGX_HAVE_HTTP_LUA_MODULE
#   include "ngx_http_lua_api.h"
#endif

#ifdef NGX_HAVE_STREAM_LUA_MODULE
#   include "ngx_stream_lua_api.h"
#endif


typedef struct {
    u_char                       color;
    uint8_t                      value_type;
    u_short                      key_len;
    uint32_t                     value_len;
    uint64_t                     expires;
    ngx_queue_t                  queue;
    uint32_t                     user_flags;
    u_char                       data[1];
} ngx_lua_shdict_node_t;


typedef struct {
    ngx_queue_t                  queue;
    uint32_t                     value_len;
    uint8_t                      value_type;
    u_char                       data[1];
} ngx_lua_shdict_list_node_t;


typedef struct {
    ngx_rbtree_t                  rbtree;
    ngx_rbtree_node_t             sentinel;
    ngx_queue_t                   lru_queue;
} ngx_lua_shdict_shctx_t;


typedef struct {
    ngx_lua_shdict_shctx_t       *sh;
    ngx_slab_pool_t              *shpool;
    ngx_str_t                     name;
    ngx_log_t                    *log;
} ngx_lua_shdict_ctx_t;


#define NGX_LUA_SHDICT_ADD         0x0001
#define NGX_LUA_SHDICT_REPLACE     0x0002
#define NGX_LUA_SHDICT_SAFE_STORE  0x0004


enum {
    SHDICT_TNIL = 0,        /* same as LUA_TNIL */
    SHDICT_TBOOLEAN = 1,    /* same as LUA_TBOOLEAN */
    SHDICT_TNUMBER = 3,     /* same as LUA_TNUMBER */
    SHDICT_TSTRING = 4,     /* same as LUA_TSTRING */
    SHDICT_TLIST = 5,
};


typedef struct {
    ngx_array_t     *shdict_zones;
} ngx_lua_shdict_conf_t;


extern ngx_module_t ngx_lua_shdict_module;

int ngx_lua_shdict_expire(ngx_lua_shdict_ctx_t *ctx, ngx_uint_t n);

ngx_int_t ngx_lua_shdict_lookup(ngx_shm_zone_t *shm_zone, ngx_uint_t hash,
    u_char *kdata, size_t klen, ngx_lua_shdict_node_t **sdp);


static ngx_inline ngx_queue_t *
ngx_lua_shdict_get_list_head(ngx_lua_shdict_node_t *sd, size_t len)
{
    return (ngx_queue_t *) ngx_align_ptr(((u_char *) &sd->data + len),
                                         NGX_ALIGNMENT);
}


#endif /* _NGX_LUA_SHDICT_COMMON_H_ */
