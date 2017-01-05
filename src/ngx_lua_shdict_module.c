
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


static void *ngx_lua_shdict_create_conf(ngx_cycle_t *cycle);
static char *ngx_lua_shdict_init_conf(ngx_cycle_t *cycle, void *conf);


static ngx_core_module_t  ngx_lua_shdict_module_ctx = {
    ngx_string("lua_shdict"),
    ngx_lua_shdict_create_conf,
    ngx_lua_shdict_init_conf
};


ngx_module_t  ngx_lua_shdict_module = {
    NGX_MODULE_V1,
    &ngx_lua_shdict_module_ctx,        /* module context */
    NULL,                              /* module directives */
    NGX_CORE_MODULE,                   /* module type */
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


static void *ngx_lua_shdict_create_conf(ngx_cycle_t *cycle)
{
    ngx_lua_shdict_conf_t *lscf;

    lscf = ngx_pcalloc(cycle->pool, sizeof(ngx_lua_shdict_conf_t));
    if (lscf == NULL) {
        return NGX_CONF_ERROR;
    }

    /* set by ngx_pcalloc:
     *      lscf->shdict_zones = NULL;
     */

    lscf->shdict_zones = ngx_palloc(cycle->pool, sizeof(ngx_array_t));
    if (lscf->shdict_zones == NULL) {
        return NULL;
    }

    if (ngx_array_init(lscf->shdict_zones, cycle->pool, 2,
                       sizeof(ngx_shm_zone_t *))
        != NGX_OK)
    {
        return NULL;
    }

    return lscf;
}


static char *ngx_lua_shdict_init_conf(ngx_cycle_t *cycle, void *conf)
{
#if defined(NGX_HAVE_HTTP_LUA_MODULE) && \
    defined(NGX_HAVE_STREAM_LUA_MODULE)
    ngx_str_t                     http_name = ngx_string("~http_post");
    ngx_str_t                     stream_name = ngx_string("~stream_post");
    ssize_t                       size = 8192;
    ngx_shm_zone_t               *zone;
    ngx_conf_t                    cf;

    ngx_memzero(&cf, sizeof(ngx_conf_t));
    cf.cycle = cycle;
    cf.pool = cycle->pool;
    cf.log = cycle->log;

    cf.ctx = cycle->conf_ctx[ngx_http_module.index];

    if (cf.ctx) {
        zone = ngx_http_lua_shared_memory_add(&cf, &http_name, (size_t) size,
                                              &ngx_lua_shdict_module);
        zone->init = ngx_lua_shdict_fake_init;
    }

    cf.ctx = cycle->conf_ctx[ngx_stream_module.index];

    if (cf.ctx) {
        zone = ngx_stream_lua_shared_memory_add(&cf, &stream_name, (size_t) size,
                                                &ngx_lua_shdict_module);
        zone->init = ngx_lua_shdict_fake_init;
    }
#endif

    return NGX_OK;
}


char *
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
    } else if (value[1].data[0] == '~') { // special  character
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "lua shdict name like ~* is protected");
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
    if (lscf == NULL) {
            return NGX_CONF_ERROR;
    }

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_lua_shdict_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ctx->name = name;
    ctx->log = &cf->cycle->new_log;

    switch(cf->module_type) {
#ifdef NGX_HAVE_HTTP_LUA_MODULE
    case NGX_HTTP_MODULE: 
         zone = ngx_http_lua_shared_memory_add(cf, &name, (size_t) size,
                                               &ngx_lua_shdict_module);
         break;
#endif

#ifdef NGX_HAVE_STREAM_LUA_MODULE
    case NGX_STREAM_MODULE: 
         zone = ngx_stream_lua_shared_memory_add(cf, &name, (size_t) size,
                                                 &ngx_lua_shdict_module);
         break;
#endif

    default:
#if !defined(NGX_HAVE_HTTP_LUA_MODULE) && \
    !defined(NGX_HAVE_STREAM_LUA_MODULE)
    ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                       "\"ngx_http_lua_module\" or ",
                       "\"ngx_stream_lua_module\" is required");
    return NGX_CONF_ERROR;
#else
    ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                       "\"%s\" directive is not allowed here",
                       cmd->name.data);
    return NGX_CONF_ERROR;
#endif
    }

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


ngx_int_t
ngx_lua_shdict_fake_init(ngx_shm_zone_t *shm_zone, void *data)
{
    return NGX_OK;
}

