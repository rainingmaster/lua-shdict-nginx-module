
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


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
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;

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
