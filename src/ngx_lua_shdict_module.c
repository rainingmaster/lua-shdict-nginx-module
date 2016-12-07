
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


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


static char *ngx_lua_shdict(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);


typedef struct {
    void            *ctx;
    ngx_shm_add_pt   shared_memory_add;
    ngx_array_t     *shdict_zones;
} ngx_lua_shdict_conf_t;


static ngx_command_t ngx_lua_shdict_cmds[] = {

    { ngx_string("lua_shared_mem"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE2|NGX_MAIN_CONF,
      ngx_lua_shdict,
      0,
      0,
      NULL },

    ngx_null_command
};


ngx_module_t ngx_lua_shdict_module = {
    NGX_MODULE_V1,
    NULL,                              /* module context */
    ngx_lua_shdict_cmds,               /* module directives */
    NGX_CONF_MODULE,                   /* module type */
    NULL,                              /* init master */
    NULL,                              /* init module */
    NULL,                              /* init process */
    NULL,                              /* init thread */
    NULL,                              /* exit thread */
    NULL,                              /* exit process */
    NULL,                              /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_inline ngx_queue_t *
ngx_lua_shdict_get_list_head(ngx_lua_shdict_node_t *sd, size_t len)
{
    return (ngx_queue_t *) ngx_align_ptr(((u_char *) &sd->data + len),
                                         NGX_ALIGNMENT);
}


void
ngx_lua_shdict_rbtree_insert_node(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t           **p;
    ngx_lua_shdict_node_t        *sdn, *sdnt;

    for ( ;; ) {

        if (node->key < temp->key) {

            p = &temp->left;

        } else if (node->key > temp->key) {

            p = &temp->right;

        } else { /* node->key == temp->key */

            sdn = (ngx_lua_shdict_node_t *) &node->color;
            sdnt = (ngx_lua_shdict_node_t *) &temp->color;

            p = ngx_memn2cmp(sdn->data, sdnt->data, sdn->key_len,
                             sdnt->key_len) < 0 ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}


ngx_int_t
ngx_lua_shdict_init(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_lua_shdict_ctx_t       *octx = data;
    size_t                      len;
    ngx_lua_shdict_ctx_t       *ctx;

    ctx = shm_zone->data;

    if (octx) {
        ctx->sh = octx->sh;
        ctx->shpool = octx->shpool;

        return NGX_OK;
    }

    ctx->shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        ctx->sh = ctx->shpool->data;

        return NGX_OK;
    }

    ctx->sh = ngx_slab_alloc(ctx->shpool, sizeof(ngx_lua_shdict_shctx_t));
    if (ctx->sh == NULL) {
        return NGX_ERROR;
    }

    ctx->shpool->data = ctx->sh;

    ngx_rbtree_init(&ctx->sh->rbtree, &ctx->sh->sentinel,
                    ngx_lua_shdict_rbtree_insert_node);

    ngx_queue_init(&ctx->sh->lru_queue);

    len = sizeof(" in lua_shared_dict zone \"\"") + shm_zone->shm.name.len;

    ctx->shpool->log_ctx = ngx_slab_alloc(ctx->shpool, len);
    if (ctx->shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(ctx->shpool->log_ctx, " in lua_shared_dict zone \"%V\"%Z",
                &shm_zone->shm.name);

#if defined(nginx_version) && nginx_version >= 1005013
    ctx->shpool->log_nomem = 0;
#endif

    return NGX_OK;
}


static ngx_int_t
ngx_lua_shdict_lookup(ngx_shm_zone_t *shm_zone, ngx_uint_t hash,
    u_char *kdata, size_t klen, ngx_lua_shdict_node_t **sdp)
{
    ngx_int_t                    rc;
    ngx_time_t                  *tp;
    uint64_t                     now;
    int64_t                      ms;
    ngx_rbtree_node_t           *node, *sentinel;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;

    ctx = shm_zone->data;

    node = ctx->sh->rbtree.root;
    sentinel = ctx->sh->rbtree.sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /* hash == node->key */

        sd = (ngx_lua_shdict_node_t *) &node->color;

        rc = ngx_memn2cmp(kdata, sd->data, klen, (size_t) sd->key_len);

        if (rc == 0) {
            ngx_queue_remove(&sd->queue);
            ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

            *sdp = sd;

            if (sd->expires != 0) {
                tp = ngx_timeofday();

                now = (uint64_t) tp->sec * 1000 + tp->msec;
                ms = sd->expires - now;

                if (ms < 0) {
                    return NGX_DONE;
                }
            }

            return NGX_OK;
        }

        node = (rc < 0) ? node->left : node->right;
    }

    *sdp = NULL;

    return NGX_DECLINED;
}


static int
ngx_lua_shdict_expire(ngx_lua_shdict_ctx_t *ctx, ngx_uint_t n)
{
    ngx_time_t                      *tp;
    uint64_t                         now;
    ngx_queue_t                     *q, *list_queue, *lq;
    int64_t                          ms;
    ngx_rbtree_node_t               *node;
    ngx_lua_shdict_node_t           *sd;
    int                              freed = 0;
    ngx_lua_shdict_list_node_t      *lnode;

    tp = ngx_timeofday();

    now = (uint64_t) tp->sec * 1000 + tp->msec;

    /*
     * n == 1 deletes one or two expired entries
     * n == 0 deletes oldest entry by force
     *        and one or two zero rate entries
     */

    while (n < 3) {

        if (ngx_queue_empty(&ctx->sh->lru_queue)) {
            return freed;
        }

        q = ngx_queue_last(&ctx->sh->lru_queue);

        sd = ngx_queue_data(q, ngx_lua_shdict_node_t, queue);

        if (n++ != 0) {

            if (sd->expires == 0) {
                return freed;
            }

            ms = sd->expires - now;
            if (ms > 0) {
                return freed;
            }
        }

        if (sd->value_type == SHDICT_TLIST) {
            list_queue = ngx_lua_shdict_get_list_head(sd, sd->key_len);

            for (lq = ngx_queue_head(list_queue);
                 lq != ngx_queue_sentinel(list_queue);
                 lq = ngx_queue_next(lq))
            {
                lnode = ngx_queue_data(lq, ngx_lua_shdict_list_node_t,
                                       queue);

                ngx_slab_free_locked(ctx->shpool, lnode);
            }
        }

        ngx_queue_remove(q);

        node = (ngx_rbtree_node_t *)
                   ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

        ngx_rbtree_delete(&ctx->sh->rbtree, node);

        ngx_slab_free_locked(ctx->shpool, node);

        freed++;
    }

    return freed;
}


char *ngx_lua_shdict_conf_init(ngx_conf_t *cf,
    ngx_lua_shdict_conf_t **lscfp)
{
    ngx_lua_shdict_conf_t *lscf;

    lscf = ngx_pcalloc(cf->pool, sizeof(ngx_lua_shdict_conf_t));
    if (lscf == NULL) {
        return NGX_CONF_ERROR;
    }

    /* set by ngx_pcalloc:
     *      lscf->ctx = NULL;
     *      lscf->shared_memory_add = NULL;
     *      lscf->shdict_zones = NULL;
     */

    cf->cycle->conf_ctx[ngx_lua_shdict_module.index] = (void ***) lscf;

    if (NGX_HTTP_MODULE == cf->module_type) {
        /* http first */
        lscf->shared_memory_add = ngx_http_lua_shared_memory_add;

    } else { /* stream */
        lscf->shared_memory_add = ngx_stream_lua_shared_memory_add;

    }

    lscf->shdict_zones = ngx_palloc(cf->pool, sizeof(ngx_array_t));
    if (lscf->shdict_zones == NULL) {
        return NGX_CONF_ERROR;
    }

    if (ngx_array_init(lscf->shdict_zones, cf->pool, 2,
                       sizeof(ngx_shm_zone_t *))
        != NGX_OK)
    {
        return NGX_CONF_ERROR;
    }
    
    lscf->ctx = cf->ctx;

    *lscfp = lscf;
    return NGX_CONF_OK;
}


static char *
ngx_lua_shdict(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_lua_shdict_conf_t        *lscf;
    ngx_str_t                    *value, name;
    ngx_shm_zone_t               *zone;
    ngx_shm_zone_t              **zp;
    ngx_lua_shdict_ctx_t         *ctx;
    ssize_t                       size;
    void                         *old_ctx;

    if (cf->module_type != NGX_HTTP_MODULE &&
        cf->module_type != NGX_STREAM_MODULE) {
        return NGX_CONF_ERROR;
    }

    lscf = (ngx_lua_shdict_conf_t *)cf->cycle->conf_ctx[ngx_lua_shdict_module.index];
    if (lscf == NULL &&
        NGX_CONF_OK != ngx_lua_shdict_conf_init(cf, &lscf)) {
        return NGX_CONF_ERROR;
    }

    value = cf->args->elts;

    ctx = NULL;

    if (value[1].len == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid lua shdict name \"%V\"", &value[1]);
        return NGX_CONF_ERROR;
    }

    name = value[1];

    size = ngx_parse_size(&value[2]);

    if (size <= 8191) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid lua shm size \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_lua_shdict_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ctx->name = name;
    ctx->log = &cf->cycle->new_log;

    old_ctx = cf->ctx;
    cf->ctx = lscf->ctx;

    zone = lscf->shared_memory_add(cf, &name, (size_t) size,
                                    &ngx_lua_shdict_module);

    cf->ctx = old_ctx;

    if (zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (zone->data) {
        ctx = zone->data;

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "lua_shared_mem \"%V\" is already defined as "
                           "\"%V\"", &name, &ctx->name);
        return NGX_CONF_ERROR;
    }

    zone->init = ngx_lua_shdict_init;
    zone->data = ctx;

    zp = ngx_array_push(lscf->shdict_zones);
    if (zp == NULL) {
        return NGX_CONF_ERROR;
    }

    *zp = zone;

    return NGX_CONF_OK;
}


int
ngx_lua_ffi_shdict_find_zone(ngx_shm_zone_t **zones, u_char *name_data, size_t name_len)
{
    ngx_str_t                         *name;
    ngx_lua_shdict_conf_t             *lscf;

    ngx_uint_t        i;
    ngx_shm_zone_t  **shm_zone;

    lscf = (ngx_lua_shdict_conf_t *) ngx_get_conf(ngx_cycle->conf_ctx,
                                                   ngx_lua_shdict_module);
    if (lscf == NULL) {
        return NGX_ERROR;
    }

    shm_zone = lscf->shdict_zones->elts;

    for (i = 0; i < lscf->shdict_zones->nelts; i++) {
        name = &shm_zone[i]->shm.name;

        if (name->len == name_len
            && ngx_strncmp(name->data, name_data, name_len) == 0)
        {
            *zones = shm_zone[i];
            return NGX_OK;
        }
    }

    return NGX_ERROR;
}


int
ngx_lua_ffi_shdict_store_helper(ngx_shm_zone_t *zone, int op, u_char *key,
    size_t key_len, int value_type, u_char *str_value_buf,
    size_t str_value_len, double num_value, int exptime, int user_flags,
    char **errmsg, int *forcible)
{
    int                          i, n;
    u_char                       c, *p;
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_time_t                  *tp;
    ngx_queue_t                 *queue, *q;
    ngx_rbtree_node_t           *node;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;

    ctx = zone->data;

    *forcible = 0;

    hash = ngx_crc32_short(key, key_len);

    switch (value_type) {

    case SHDICT_TSTRING:
        /* do nothing */
        break;

    case SHDICT_TNUMBER:
        str_value_buf = (u_char *) &num_value;
        str_value_len = sizeof(double);
        break;

    case SHDICT_TBOOLEAN:
        c = num_value ? 1 : 0;
        str_value_buf = &c;
        str_value_len = sizeof(u_char);
        break;

    case LUA_TNIL:
        if (op & (NGX_LUA_SHDICT_ADD|NGX_LUA_SHDICT_REPLACE)) {
            *errmsg = "attempt to add or replace nil values";
            return NGX_ERROR;
        }

        str_value_buf = NULL;
        str_value_len = 0;
        break;

    default:
        *errmsg = "unsupported value type";
        return NGX_ERROR;
    }

    ngx_shmtx_lock(&ctx->shpool->mutex);

    ngx_lua_shdict_expire(ctx, 1);

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (op & NGX_LUA_SHDICT_EXPIRE) {

        if (rc == NGX_DECLINED || rc == NGX_DONE) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            *errmsg = "not found";
            return NGX_DECLINED;
        }

        if (sd->value_type == SHDICT_TLIST) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            *errmsg = "value is a list";
            return NGX_ERROR;
        }

        /* rc == NGX_OK */

        goto expire;
    }

    if (op & NGX_LUA_SHDICT_REPLACE) {

        if (rc == NGX_DECLINED || rc == NGX_DONE) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            *errmsg = "not found";
            return NGX_DECLINED;
        }

        /* rc == NGX_OK */

        goto replace;
    }

    if (op & NGX_LUA_SHDICT_ADD) {

        if (rc == NGX_OK) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            *errmsg = "exists";
            return NGX_DECLINED;
        }

        if (rc == NGX_DONE) {
            /* exists but expired */
            goto replace;
        }

        /* rc == NGX_DECLINED */

        goto insert;
    }

    if (rc == NGX_OK || rc == NGX_DONE) {

        if (value_type == LUA_TNIL) {
            goto remove;
        }

replace:

        if (str_value_buf
            && str_value_len == (size_t) sd->value_len
            && sd->value_type != SHDICT_TLIST)
        {

            ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                           "lua shared dict set: found old entry and value "
                           "size matched, reusing it");

            ngx_queue_remove(&sd->queue);
            ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

            sd->key_len = (u_short) key_len;

            sd->user_flags = user_flags;

            sd->value_len = (uint32_t) str_value_len;

            sd->value_type = (uint8_t) value_type;

            p = ngx_copy(sd->data, key, key_len);
            ngx_memcpy(p, str_value_buf, str_value_len);

            goto expire;
        }

        ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                       "lua shared dict set: found old entry but value size "
                       "NOT matched, removing it first");

remove:

        if (sd->value_type == SHDICT_TLIST) {
            queue = ngx_lua_shdict_get_list_head(sd, key_len);

            for (q = ngx_queue_head(queue);
                 q != ngx_queue_sentinel(queue);
                 q = ngx_queue_next(q))
            {
                p = (u_char *) ngx_queue_data(q,
                                              ngx_lua_shdict_list_node_t,
                                              queue);

                ngx_slab_free_locked(ctx->shpool, p);
            }
        }

        ngx_queue_remove(&sd->queue);

        node = (ngx_rbtree_node_t *)
                   ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

        ngx_rbtree_delete(&ctx->sh->rbtree, node);

        ngx_slab_free_locked(ctx->shpool, node);

    }

insert:

    /* rc == NGX_DECLINED or value size unmatch */

    if (str_value_buf == NULL) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        return NGX_OK;
    }

    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                   "lua shared dict set: creating a new entry");

    n = offsetof(ngx_rbtree_node_t, color)
        + offsetof(ngx_lua_shdict_node_t, data)
        + key_len
        + str_value_len;

    node = ngx_slab_alloc_locked(ctx->shpool, n);

    if (node == NULL) {

        if (op & NGX_LUA_SHDICT_SAFE_STORE) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);

            *errmsg = "no memory";
            return NGX_ERROR;
        }

        ngx_log_debug2(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                       "lua shared dict set: overriding non-expired items "
                       "due to memory shortage for entry \"%*s\"", key_len,
                       key);

        for (i = 0; i < 30; i++) {
            if (ngx_lua_shdict_expire(ctx, 0) == 0) {
                break;
            }

            *forcible = 1;

            node = ngx_slab_alloc_locked(ctx->shpool, n);
            if (node != NULL) {
                goto allocated;
            }
        }

        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *errmsg = "no memory";
        return NGX_ERROR;
    }

allocated:

    sd = (ngx_lua_shdict_node_t *) &node->color;

    node->key = hash;
    sd->key_len = (u_short) key_len;

    sd->user_flags = user_flags;
    sd->value_len = (uint32_t) str_value_len;
    sd->value_type = (uint8_t) value_type;

    p = ngx_copy(sd->data, key, key_len);
    ngx_memcpy(p, str_value_buf, str_value_len);

    ngx_rbtree_insert(&ctx->sh->rbtree, node);
    ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

expire:

    if (exptime > 0) {
        tp = ngx_timeofday();
        sd->expires = (uint64_t) tp->sec * 1000 + tp->msec
                      + (uint64_t) exptime;

    } else {
        sd->expires = 0;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_get_helper(ngx_shm_zone_t *zone, int op, u_char *key,
    size_t key_len, int *value_type, u_char **str_value_buf,
    size_t *str_value_len, double *num_value, int *user_flags,
    int *ttl, int *is_stale, char **errmsg)
{
    ngx_str_t                    name;
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;
    ngx_str_t                    value;
    uint64_t                     now;
    ngx_time_t                  *tp;

    ctx = zone->data;
    name = ctx->name;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    if (! (op & NGX_LUA_SHDICT_STALE)) {
        ngx_lua_shdict_expire(ctx, 1);
    }

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (op & NGX_LUA_SHDICT_TTL) {

        if (rc == NGX_DECLINED || rc == NGX_DONE) {
            *ttl = -2;
        } else { /* rc == NGX_OK */

            if (sd->value_type == SHDICT_TLIST) {
                ngx_shmtx_unlock(&ctx->shpool->mutex);
                *errmsg = "value is a list";
                return NGX_ERROR;
            }

            if (sd->expires == 0) {
                *ttl = -1;
            } else {
                tp = ngx_timeofday();
                now = (uint64_t) tp->sec * 1000 + tp->msec;
                *ttl = (int)((sd->expires - now) / 1000);
                if (*ttl < 0) {
                    *ttl = -2;
                }
            }
        }

        ngx_shmtx_unlock(&ctx->shpool->mutex);
        return NGX_OK;
    }

    if (rc == NGX_DECLINED || (rc == NGX_DONE && ! (op & NGX_LUA_SHDICT_STALE))) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        *value_type = LUA_TNIL;
        return NGX_OK;
    }

    /* rc == NGX_OK || (rc == NGX_DONE && (op & NGX_LUA_SHDICT_STALE)) */

    *value_type = sd->value_type;

    value.data = sd->data + sd->key_len;
    value.len = (size_t) sd->value_len;

    if (*str_value_len < (size_t) value.len) {

        if (*value_type == SHDICT_TBOOLEAN) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            *errmsg = "value is a list";
            return NGX_ERROR;
        }

        if (*value_type == SHDICT_TSTRING) {
            *str_value_buf = malloc(value.len);
            if (*str_value_buf == NULL) {
                ngx_shmtx_unlock(&ctx->shpool->mutex);
                *errmsg = "no memory";
                return NGX_ERROR;
            }
        }
    }

    switch (*value_type) {

    case SHDICT_TSTRING:
        *str_value_len = value.len;
        ngx_memcpy(*str_value_buf, value.data, value.len);
        break;

    case SHDICT_TNUMBER:

        if (value.len != sizeof(double)) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            ngx_log_error(NGX_LOG_ERR, ngx_cycle->log, 0,
                          "bad lua number value size found for key %*s "
                          "in shared_dict %V: %z", key_len, key,
                          &name, value.len);
            *errmsg = "bad lua number value size found";
            return NGX_ERROR;
        }

        *str_value_len = value.len;
        ngx_memcpy(num_value, value.data, sizeof(double));
        break;

    case SHDICT_TBOOLEAN:

        if (value.len != sizeof(u_char)) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            ngx_log_error(NGX_LOG_ERR, ngx_cycle->log, 0,
                          "bad lua boolean value size found for key %*s "
                          "in shared_dict %V: %z", key_len, key, &name,
                          value.len);
            *errmsg = "bad lua boolean value size";
            return NGX_ERROR;
        }

        ngx_memcpy(*str_value_buf, value.data, value.len);
        break;

    case SHDICT_TLIST:

        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *errmsg = "value is a list";
        return NGX_ERROR;

    default:

        ngx_shmtx_unlock(&ctx->shpool->mutex);
        ngx_log_error(NGX_LOG_ERR, ngx_cycle->log, 0,
                      "bad value type found for key %*s in "
                      "shared_dict %V: %d", key_len, key, &name,
                      *value_type);
        *errmsg = "unsupported value type";
        return NGX_ERROR;
    }

    *user_flags = sd->user_flags;

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    if (op & NGX_LUA_SHDICT_STALE) {

        /* always return value, flags, stale */

        *is_stale = (rc == NGX_DONE);
        return NGX_OK;
    }

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_push_helper(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, int value_type, u_char *str_value_buf,
    size_t str_value_len, double num_value, int *value_len,
    int flags, char **errmsg)
{
    uint32_t                         hash;
    int                              n;
    ngx_int_t                        rc;
    ngx_lua_shdict_ctx_t            *ctx;
    ngx_lua_shdict_node_t           *sd;
    ngx_rbtree_node_t               *node;
    ngx_queue_t                     *queue, *q;
    ngx_lua_shdict_list_node_t      *lnode;

    ctx = zone->data;

    hash = ngx_crc32_short(key, key_len);

    switch (value_type) {

    case SHDICT_TSTRING:
        /* do nothing */
        break;

    case SHDICT_TNUMBER:
        str_value_buf = (u_char *) &num_value;
        str_value_len = sizeof(double);
        break;

    default:
        *errmsg = "unsupported value type";
        return NGX_ERROR;
    }

    ngx_shmtx_lock(&ctx->shpool->mutex);

    ngx_lua_shdict_expire(ctx, 1);

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    /* exists but expired */

    if (rc == NGX_DONE) {

        if (sd->value_type != SHDICT_TLIST) {
            /* TODO: reuse when length matched */

            ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                           "lua shared dict push: found old entry and value "
                           "type not matched, remove it first");

            ngx_queue_remove(&sd->queue);

            node = (ngx_rbtree_node_t *)
                        ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

            ngx_rbtree_delete(&ctx->sh->rbtree, node);

            ngx_slab_free_locked(ctx->shpool, node);

            goto init_list;
        }

        ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                       "lua shared dict push: found old entry and value "
                       "type matched, reusing it");

        sd->expires = 0;

        /* free list nodes */

        queue = ngx_lua_shdict_get_list_head(sd, key_len);

        for (q = ngx_queue_head(queue);
             q != ngx_queue_sentinel(queue);
             q = ngx_queue_next(q))
        {
            /* TODO: reuse matched size list node */
            lnode = ngx_queue_data(q, ngx_lua_shdict_list_node_t, queue);
            ngx_slab_free_locked(ctx->shpool, lnode);
        }

        ngx_queue_init(queue);

        ngx_queue_remove(&sd->queue);
        ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

        goto push_node;
    }

    /* exists and not expired */

    if (rc == NGX_OK) {

        if (sd->value_type != SHDICT_TLIST) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);

            *errmsg = "value not a list";
            return NGX_ERROR;
        }

        queue = ngx_lua_shdict_get_list_head(sd, key_len);

        ngx_queue_remove(&sd->queue);
        ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

        goto push_node;
    }

    /* rc == NGX_DECLINED, not found */

init_list:

    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                   "lua shared dict list: creating a new entry");

    /* NOTICE: we assume the begin point aligned in slab, be careful */
    n = offsetof(ngx_rbtree_node_t, color)
        + offsetof(ngx_lua_shdict_node_t, data)
        + key_len
        + sizeof(ngx_queue_t);

    n = (int) (uintptr_t) ngx_align_ptr(n, NGX_ALIGNMENT);

    node = ngx_slab_alloc_locked(ctx->shpool, n);

    if (node == NULL) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *errmsg = "no memory";
        return NGX_ERROR;
    }

    sd = (ngx_lua_shdict_node_t *) &node->color;

    queue = ngx_lua_shdict_get_list_head(sd, key_len);

    node->key = hash;
    sd->key_len = (u_short) key_len;

    sd->expires = 0;

    sd->value_len = 0;

    sd->value_type = (uint8_t) SHDICT_TLIST;

    ngx_memcpy(sd->data, key, key_len);

    ngx_queue_init(queue);

    ngx_rbtree_insert(&ctx->sh->rbtree, node);

    ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

push_node:

    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                   "lua shared dict list: creating a new list node");

    n = offsetof(ngx_lua_shdict_list_node_t, data)
        + str_value_len;

    lnode = ngx_slab_alloc_locked(ctx->shpool, n);

    if (lnode == NULL) {

        if (sd->value_len == 0) {

            ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                           "lua shared dict list: no memory for create"
                           " list node and list empty, remove it");

            ngx_queue_remove(&sd->queue);

            node = (ngx_rbtree_node_t *)
                        ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

            ngx_rbtree_delete(&ctx->sh->rbtree, node);

            ngx_slab_free_locked(ctx->shpool, node);
        }

        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *errmsg = "no memory";
        return NGX_ERROR;
    }

    sd->value_len = sd->value_len + 1;

    lnode->value_len = (uint32_t) str_value_len;

    lnode->value_type = (uint8_t) value_type;

    ngx_memcpy(lnode->data, str_value_buf, str_value_len);

    if (flags == NGX_LUA_SHDICT_LEFT) {
        ngx_queue_insert_head(queue, &lnode->queue);

    } else {
        ngx_queue_insert_tail(queue, &lnode->queue);
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    *value_len = sd->value_len;
    return NGX_OK;
}


int
ngx_lua_ffi_shdict_pop_helper(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, int *value_type, u_char **str_value_buf,
    size_t *str_value_len, double *num_value, int flags, char **errmsg)
{
    ngx_str_t                        name;
    uint32_t                         hash;
    ngx_int_t                        rc;
    ngx_lua_shdict_ctx_t            *ctx;
    ngx_lua_shdict_node_t           *sd;
    int                              value_len;
    ngx_rbtree_node_t               *node;
    ngx_queue_t                     *queue;
    ngx_lua_shdict_list_node_t      *lnode;

    ctx = zone->data;
    name = ctx->name;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    ngx_lua_shdict_expire(ctx, 1);

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (rc == NGX_DECLINED || rc == NGX_DONE) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        *value_type = LUA_TNIL;
        return NGX_OK;
    }

    /* rc == NGX_OK */

    if (sd->value_type != SHDICT_TLIST) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *errmsg = "value not a list";
        return NGX_ERROR;
    }

    if (sd->value_len <= 0) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);

        ngx_log_error(NGX_LOG_ERR, ngx_cycle->log, 0,
                      "bad lua list length found for key %s "
                      "in shared_dict %s: %lu", key, name.data,
                      (unsigned long) sd->value_len);

        *errmsg = "bad lua list length";
        return NGX_ERROR;
    }

    queue = ngx_lua_shdict_get_list_head(sd, key_len);

    if (flags == NGX_LUA_SHDICT_LEFT) {
        queue = ngx_queue_head(queue);

    } else {
        queue = ngx_queue_last(queue);
    }

    lnode = ngx_queue_data(queue, ngx_lua_shdict_list_node_t, queue);

    *value_type = lnode->value_type;

    value_len = lnode->value_len;

    if (*str_value_len < (size_t) value_len) {
        if (*value_type == SHDICT_TSTRING) {
            *str_value_buf = malloc(value_len);
            if (*str_value_buf == NULL) {
                ngx_shmtx_unlock(&ctx->shpool->mutex);

                *errmsg = "no memory";
                return NGX_ERROR;
            }
        }
    }

    switch (*value_type) {

    case SHDICT_TSTRING:
        *str_value_len = value_len;
        ngx_memcpy(*str_value_buf, lnode->data, value_len);
        break;

    case SHDICT_TNUMBER:

        if (value_len != sizeof(double)) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            ngx_log_error(NGX_LOG_ERR, ngx_cycle->log, 0,
                          "bad lua list node number value size found "
                          "for key %s in shared_dict %s: %lu", key,
                          name.data, (unsigned long) value_len);

            *errmsg = "bad lua list node number value size";
            return NGX_ERROR;
        }

        *str_value_len = value_len;
        ngx_memcpy(num_value, lnode->data, sizeof(double));
        break;

    default:

        ngx_shmtx_unlock(&ctx->shpool->mutex);
        ngx_log_error(NGX_LOG_ERR, ngx_cycle->log, 0,
                      "bad list node value type found for key %s in "
                      "shared_dict %s: %d", key, name.data,
                      *value_type);

        *errmsg = "bad list node value type";
        return NGX_ERROR;
    }

    ngx_queue_remove(queue);

    ngx_slab_free_locked(ctx->shpool, lnode);

    if (sd->value_len == 1) {

        ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                       "lua shared dict list: empty node after pop, "
                       "remove it");

        ngx_queue_remove(&sd->queue);

        node = (ngx_rbtree_node_t *)
                    ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

        ngx_rbtree_delete(&ctx->sh->rbtree, node);

        ngx_slab_free_locked(ctx->shpool, node);

    } else {
        sd->value_len = sd->value_len - 1;

        ngx_queue_remove(&sd->queue);
        ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_llen(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, int *value_len, char **errmsg)
{
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_lua_shdict_ctx_t   *ctx;
    ngx_lua_shdict_node_t  *sd;

    ctx = zone->data;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    ngx_lua_shdict_expire(ctx, 1);

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (rc == NGX_OK) {

        if (sd->value_type != SHDICT_TLIST) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);

            *errmsg = "value not a list";
            return NGX_ERROR;
        }

        ngx_queue_remove(&sd->queue);
        ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *value_len = sd->value_len;
        return NGX_OK;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    *value_len = 0;
    return NGX_OK;
}


int
ngx_lua_ffi_shdict_get_keys(ngx_shm_zone_t *zone, int attempts,
    ngx_str_t **keys_buf, int *keys_num, char **errmsg)
{
    ngx_queue_t                 *q, *prev;
    ngx_time_t                  *tp;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;
    ngx_str_t                   *keys;
    uint64_t                     now;
    int                          total = 0;

    ctx = zone->data;

    ngx_shmtx_lock(&ctx->shpool->mutex);

    if (ngx_queue_empty(&ctx->sh->lru_queue)) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        keys_buf = NULL;
        *keys_num = 0;
        return NGX_OK;
    }

    tp = ngx_timeofday();

    now = (uint64_t) tp->sec * 1000 + tp->msec;

    /* first run through: get total number of elements we need to allocate */

    q = ngx_queue_last(&ctx->sh->lru_queue);

    while (q != ngx_queue_sentinel(&ctx->sh->lru_queue)) {
        prev = ngx_queue_prev(q);

        sd = ngx_queue_data(q, ngx_lua_shdict_node_t, queue);

        if (sd->expires == 0 || sd->expires > now) {
            total++;
            if (attempts && total == attempts) {
                break;
            }
        }

        q = prev;
    }

    *keys_num = total;
    keys = malloc(total * sizeof(ngx_str_t));

    if (keys == NULL) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *errmsg = "no memory";
        return NGX_ERROR;
    }

    *keys_buf = keys;

    /* second run through: add keys to table */

    total = 0;
    q = ngx_queue_last(&ctx->sh->lru_queue);

    while (q != ngx_queue_sentinel(&ctx->sh->lru_queue)) {
        prev = ngx_queue_prev(q);

        sd = ngx_queue_data(q, ngx_lua_shdict_node_t, queue);

        if (sd->expires == 0 || sd->expires > now) {
            keys[total].data = (u_char *) sd->data;
            keys[total].len = sd->key_len;
            ++total;
            if (attempts && total == attempts) {
                break;
            }
        }

        q = prev;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_flush(ngx_shm_zone_t *zone, char **errmsg)
{
    ngx_queue_t                 *q;
    ngx_lua_shdict_node_t       *sd;
    ngx_lua_shdict_ctx_t        *ctx;

    ctx = zone->data;

    ngx_shmtx_lock(&ctx->shpool->mutex);

    for (q = ngx_queue_head(&ctx->sh->lru_queue);
         q != ngx_queue_sentinel(&ctx->sh->lru_queue);
         q = ngx_queue_next(q))
    {
        sd = ngx_queue_data(q, ngx_lua_shdict_node_t, queue);
        sd->expires = 1;
    }

    ngx_lua_shdict_expire(ctx, 0);

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_flush_expired(ngx_shm_zone_t *zone, int attempts,
    int *freed, char **errmsg)
{
    ngx_queue_t                     *q, *prev, *list_queue, *lq;
    ngx_lua_shdict_node_t           *sd;
    ngx_lua_shdict_ctx_t            *ctx;
    ngx_time_t                      *tp;
    ngx_rbtree_node_t               *node;
    uint64_t                         now;
    ngx_lua_shdict_list_node_t      *lnode;

    ctx = zone->data;

    ngx_shmtx_lock(&ctx->shpool->mutex);

    *freed = 0;

    if (ngx_queue_empty(&ctx->sh->lru_queue)) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        return NGX_OK;
    }

    tp = ngx_timeofday();

    now = (uint64_t) tp->sec * 1000 + tp->msec;

    q = ngx_queue_last(&ctx->sh->lru_queue);

    while (q != ngx_queue_sentinel(&ctx->sh->lru_queue)) {
        prev = ngx_queue_prev(q);

        sd = ngx_queue_data(q, ngx_lua_shdict_node_t, queue);

        if (sd->expires != 0 && sd->expires <= now) {

            if (sd->value_type == SHDICT_TLIST) {
                list_queue = ngx_lua_shdict_get_list_head(sd, sd->key_len);

                for (lq = ngx_queue_head(list_queue);
                     lq != ngx_queue_sentinel(list_queue);
                     lq = ngx_queue_next(lq))
                {
                    lnode = ngx_queue_data(lq, ngx_lua_shdict_list_node_t,
                                           queue);

                    ngx_slab_free_locked(ctx->shpool, lnode);
                }
            }

            ngx_queue_remove(q);

            node = (ngx_rbtree_node_t *)
                ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

            ngx_rbtree_delete(&ctx->sh->rbtree, node);
            ngx_slab_free_locked(ctx->shpool, node);
            (*freed)++;

            if (attempts && *freed == attempts) {
                break;
            }
        }

        q = prev;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_incr_helper(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, double *value, char **err, int has_init, double init,
    int *forcible)
{
    int                          i, n;
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;
    double                       num;
    ngx_rbtree_node_t           *node;
    u_char                      *p;
    ngx_queue_t                 *queue, *q;

    ctx = zone->data;

    *forcible = 0;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    ngx_lua_shdict_expire(ctx, 1);

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);


    if (rc == NGX_DECLINED || rc == NGX_DONE) {
        if (!has_init) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            *err = "not found";
            return NGX_ERROR;
        }

        /* add value */
        num = *value + init;

        if (rc == NGX_DONE) {

            /* found an expired item */

            if ((size_t) sd->value_len == sizeof(double)
                && sd->value_type != SHDICT_TLIST)
            {
                ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                               "lua shared dict incr: found old entry and "
                               "value size matched, reusing it");

                ngx_queue_remove(&sd->queue);
                ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

                goto setvalue;
            }

            goto remove;
        }

        goto insert;
    }

    /* rc == NGX_OK */

    if (sd->value_type != SHDICT_TNUMBER || sd->value_len != sizeof(double)) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        *err = "not a number";
        return NGX_ERROR;
    }

    ngx_queue_remove(&sd->queue);
    ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

    p = sd->data + key_len;

    ngx_memcpy(&num, p, sizeof(double));
    num += *value;

    ngx_memcpy(p, (double *) &num, sizeof(double));

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    *value = num;
    return NGX_OK;

remove:

    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                   "lua shared dict incr: found old entry but value size "
                   "NOT matched, removing it first");

    if (sd->value_type == SHDICT_TLIST) {
        queue = ngx_lua_shdict_get_list_head(sd, key_len);

        for (q = ngx_queue_head(queue);
             q != ngx_queue_sentinel(queue);
             q = ngx_queue_next(q))
        {
            p = (u_char *) ngx_queue_data(q, ngx_lua_shdict_list_node_t,
                                          queue);

            ngx_slab_free_locked(ctx->shpool, p);
        }
    }

    ngx_queue_remove(&sd->queue);

    node = (ngx_rbtree_node_t *)
               ((u_char *) sd - offsetof(ngx_rbtree_node_t, color));

    ngx_rbtree_delete(&ctx->sh->rbtree, node);

    ngx_slab_free_locked(ctx->shpool, node);

insert:

    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                   "lua shared dict incr: creating a new entry");

    n = offsetof(ngx_rbtree_node_t, color)
        + offsetof(ngx_lua_shdict_node_t, data)
        + key_len
        + sizeof(double);

    node = ngx_slab_alloc_locked(ctx->shpool, n);

    if (node == NULL) {

        ngx_log_debug2(NGX_LOG_DEBUG_HTTP, ctx->log, 0,
                       "lua shared dict incr: overriding non-expired items "
                       "due to memory shortage for entry \"%*s\"", key_len,
                       key);

        for (i = 0; i < 30; i++) {
            if (ngx_lua_shdict_expire(ctx, 0) == 0) {
                break;
            }

            *forcible = 1;

            node = ngx_slab_alloc_locked(ctx->shpool, n);
            if (node != NULL) {
                goto allocated;
            }
        }

        ngx_shmtx_unlock(&ctx->shpool->mutex);

        *err = "no memory";
        return NGX_ERROR;
    }

allocated:

    sd = (ngx_lua_shdict_node_t *) &node->color;

    node->key = hash;

    sd->key_len = (u_short) key_len;

    sd->value_len = (uint32_t) sizeof(double);

    ngx_rbtree_insert(&ctx->sh->rbtree, node);

    ngx_queue_insert_head(&ctx->sh->lru_queue, &sd->queue);

setvalue:

    sd->user_flags = 0;

    sd->expires = 0;

    sd->value_type = (uint8_t) LUA_TNUMBER;

    p = ngx_copy(sd->data, key, key_len);
    ngx_memcpy(p, (double *) &num, sizeof(double));

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    *value = num;
    return NGX_OK;
}