
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


static char *ngx_lua_shdict(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);


static ngx_command_t ngx_lua_shdict_cmds[] = {

    { ngx_string("lua_shared_mem"),
      NGX_HTTP_MAIN_CONF|NGX_STREAM_MAIN_CONF|NGX_CONF_TAKE2|NGX_MAIN_CONF,
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


char *
ngx_lua_shdict_conf_init(ngx_conf_t *cf, ngx_lua_shdict_conf_t **lscfp)
{
    ngx_lua_shdict_conf_t *lscf;

    lscf = ngx_pcalloc(cf->pool, sizeof(ngx_lua_shdict_conf_t));
    if (lscf == NULL) {
        return NGX_CONF_ERROR;
    }

    /* set by ngx_pcalloc:
     *      lscf->shdict_zones = NULL;
     */

    cf->cycle->conf_ctx[ngx_lua_shdict_module.index] = (void ***) lscf;

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

    value = cf->args->elts;

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

    lscf = (ngx_lua_shdict_conf_t *)ngx_get_conf(cf->cycle->conf_ctx,
                                                 ngx_lua_shdict_module);
    if (lscf == NULL &&
        NGX_CONF_OK != ngx_lua_shdict_conf_init(cf, &lscf)) {
            return NGX_CONF_ERROR;
    }

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_lua_shdict_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ctx->name = name;
    ctx->log = &cf->cycle->new_log;

    zone = ngx_shared_memory_add(cf, &name, (size_t) size, &ngx_lua_shdict_module);

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
