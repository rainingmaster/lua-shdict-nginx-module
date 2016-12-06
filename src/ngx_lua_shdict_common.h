
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#ifndef _NGX_LUA_SHDICT_H_INCLUDED_
#define _NGX_LUA_SHDICT_H_INCLUDED_


#ifndef DDEBUG
#define DDEBUG 0
#endif
#include "ddebug.h"


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <nginx.h>


#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>


#include "ngx_http_lua_api.h"
#include "ngx_stream_lua_api.h"


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
    ngx_lua_shdict_shctx_t  *sh;
    ngx_slab_pool_t              *shpool;
    ngx_str_t                     name;
    ngx_log_t                    *log;
} ngx_lua_shdict_ctx_t;


#define NGX_LUA_SHDICT_ADD         0x0001
#define NGX_LUA_SHDICT_REPLACE     0x0002
#define NGX_LUA_SHDICT_SAFE_STORE  0x0004
#define NGX_LUA_SHDICT_EXPIRE      0x0008


#define NGX_LUA_SHDICT_STALE       0x0001
#define NGX_LUA_SHDICT_TTL         0x0002


#define NGX_LUA_SHDICT_LEFT        0x0001
#define NGX_LUA_SHDICT_RIGHT       0x0002


enum {
    SHDICT_TNIL = 0,        /* same as LUA_TNIL */
    SHDICT_TBOOLEAN = 1,    /* same as LUA_TBOOLEAN */
    SHDICT_TNUMBER = 3,     /* same as LUA_TNUMBER */
    SHDICT_TSTRING = 4,     /* same as LUA_TSTRING */
    SHDICT_TLIST = 5,
};


typedef ngx_shm_zone_t* (*ngx_shm_add_pt) \
                        (ngx_conf_t *cf, ngx_str_t *name, size_t size, void *tag);


typedef struct {
    ngx_shm_add_pt   shared_memory_add;
    ngx_array_t     *shdict_zones;
} ngx_lua_shdict_main_conf_t;


static void *ngx_lua_shdict_create_common_main_conf(ngx_conf_t *cf);

ngx_int_t ngx_lua_shdict_common_init(ngx_shm_zone_t *shm_zone, void *data);

static char *ngx_lua_shdict_common_cmd_set(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf, ngx_shared_memory_add_pt shared_memory_add, void *tag);


#endif /* _NGX_LUA_SHDICT_H_INCLUDED_ */