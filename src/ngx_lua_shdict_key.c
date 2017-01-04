
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


int
ngx_lua_ffi_shdict_find_zone(ngx_shm_zone_t **zones, u_char *name_data,
    size_t name_len)
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
ngx_lua_ffi_shdict_expire(ngx_shm_zone_t *zone, int force, u_char *key,
    size_t key_len, int exptime, int *is_stale, char **errmsg)
{
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_time_t                  *tp;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;

    ctx = zone->data;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    if (!force) {
        ngx_lua_shdict_expire(ctx, 1);
    }

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (rc == NGX_DECLINED || (rc == NGX_DONE && !force)) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        *errmsg = "not found";
        return NGX_DECLINED;
    }

    /* rc == NGX_OK || (rc == NGX_DONE && force) */

    if (exptime > 0) {
        tp = ngx_timeofday();
        sd->expires = (uint64_t) tp->sec * 1000 + tp->msec
                      + (uint64_t) exptime;

    } else {
        sd->expires = 0;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    if (force) {
        *is_stale = (rc == NGX_DONE);
        return NGX_OK;
    }

    return NGX_OK;
}


int
ngx_lua_ffi_shdict_ttl(ngx_shm_zone_t *zone, u_char *key,
    size_t key_len, int *ttl, char **errmsg)
{
    uint32_t                     hash;
    ngx_int_t                    rc;
    ngx_time_t                  *tp;
    ngx_lua_shdict_ctx_t        *ctx;
    ngx_lua_shdict_node_t       *sd;
    uint64_t                     now;

    ctx = zone->data;

    hash = ngx_crc32_short(key, key_len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    ngx_lua_shdict_expire(ctx, 1);

    rc = ngx_lua_shdict_lookup(zone, hash, key, key_len, &sd);

    if (rc == NGX_DECLINED || rc == NGX_DONE) {
        *ttl = -2;

    } else { /* rc == NGX_OK */

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
