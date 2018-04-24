
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


int
ngx_lua_ffi_shdict_find_zone(ngx_shm_zone_t **zone, u_char *name_data,
    size_t name_len, char **errmsg)
{
    ngx_uint_t                         i;
    ngx_str_t                         *name;
    ngx_lua_shdict_conf_t             *lscf;
    ngx_lua_shdict_ctx_t              *ctx;
    ngx_shm_zone_t                   **shm_zone;

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
            /* check zone init or not */
            ctx = shm_zone[i]->data;
            if (ctx->sh) {
                *zone = shm_zone[i];
                return NGX_OK;
            }

            *errmsg = "not init";
            return NGX_ERROR;
        }
    }

    *errmsg = "not found";
    return NGX_ERROR;
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
ngx_lua_ffi_shdict_flush_all(ngx_shm_zone_t *zone, char **errmsg)
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


static ngx_int_t
ngx_lua_shdict_peek(ngx_shm_zone_t *shm_zone, ngx_uint_t hash,
    u_char *kdata, size_t klen, ngx_lua_shdict_node_t **sdp)
{
    ngx_int_t                    rc;
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
            *sdp = sd;

            return NGX_OK;
        }

        node = (rc < 0) ? node->left : node->right;
    }

    *sdp = NULL;

    return NGX_DECLINED;
}


long
ngx_lua_ffi_shdict_get_ttl(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len)
{
    uint32_t                     hash;
    uint64_t                     now;
    uint64_t                     expires;
    ngx_int_t                    rc;
    ngx_time_t                  *tp;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;

    if (zone == NULL) {
        return NGX_ERROR;
    }

    ctx = zone->data;
    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    rc = ngx_lua_shdict_peek(zone, hash, key, key_len, &sd);

    if (rc == NGX_DECLINED) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);

        return NGX_DECLINED;
    }

    /* rc == NGX_OK */

    expires = sd->expires;

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    if (expires == 0) {
        return 0;
    }

    tp = ngx_timeofday();
    now = (uint64_t) tp->sec * 1000 + tp->msec;

    return expires - now;
}


int
ngx_lua_ffi_shdict_set_expire(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, long exptime)
{
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_time_t                  *tp = NULL;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;

    if (zone == NULL) {
        return NGX_ERROR;
    }

    if (exptime > 0) {
        tp = ngx_timeofday();
    }

    ctx = zone->data;
    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    rc = ngx_lua_shdict_peek(zone, hash, key, key_len, &sd);

    if (rc == NGX_DECLINED) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);

        return NGX_DECLINED;
    }

    /* rc == NGX_OK */

    if (exptime > 0) {
        sd->expires = (uint64_t) tp->sec * 1000 + tp->msec
                      + (uint64_t) exptime;

    } else {
        sd->expires = 0;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


size_t
ngx_lua_ffi_shdict_capacity(ngx_shm_zone_t *zone)
{
    return zone->shm.size;
}


#if nginx_version >= 1011007
size_t
ngx_lua_ffi_shdict_free_space(ngx_shm_zone_t *zone)
{
    size_t                       bytes;
    ngx_lua_shdict_ctx_t        *ctx;

    ctx = zone->data;

    ngx_shmtx_lock(&ctx->shpool->mutex);
    bytes = ctx->shpool->pfree * ngx_pagesize;
    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return bytes;
}
#endif /* nginx_version >= 1011007 */
