
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


int
ngx_lua_ffi_shdict_store_helper(ngx_shm_zone_t *zone, int op, u_char *key,
    size_t key_len, int value_type, u_char *str_value_buf,
    size_t str_value_len, double num_value, long exptime, int user_flags,
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
ngx_lua_ffi_shdict_fetch_helper(ngx_shm_zone_t *zone, int get_stale,
    u_char *key, size_t key_len, int *value_type, u_char **str_value_buf,
    size_t *str_value_len, double *num_value, int *user_flags,
    int *is_stale, char **errmsg)
{
    ngx_str_t                    name;
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;
    ngx_str_t                    value;

    ctx = zone->data;
    name = ctx->name;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    if (!get_stale) {
        ngx_lua_shdict_expire(ctx, 1);
    }

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (rc == NGX_DECLINED || (rc == NGX_DONE && !get_stale)) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        *value_type = LUA_TNIL;
        return NGX_OK;
    }

    /* rc == NGX_OK || (rc == NGX_DONE && get_stale) */

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

    if (get_stale) {
        *is_stale = (rc == NGX_DONE);
        return NGX_OK;
    }

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_incr_helper(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, double *value, char **err, int has_init, double init,
    long exptime, int *forcible)
{
    int                          i, n;
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_time_t                  *tp;
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

    if (exptime > 0) {
        tp = ngx_timeofday();
        sd->expires = (uint64_t) tp->sec * 1000 + tp->msec
                      + (uint64_t) exptime;

    } else if (exptime < 0) {
        sd->expires = 0;
    } else {
        /* use old ttl */
    }

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

    if (exptime > 0) {
        tp = ngx_timeofday();
        sd->expires = (uint64_t) tp->sec * 1000 + tp->msec
                      + (uint64_t) exptime;

    } else {
        sd->expires = 0;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    *value = num;
    return NGX_OK;
}
