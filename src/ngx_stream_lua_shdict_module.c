
/*
 * Copyright (C) Yichun Zhang (agentzh)
 */


#include "ngx_lua_shdict_common.h"


static char *ngx_stream_lua_shdict(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);


static ngx_command_t ngx_stream_lua_shdict_cmds[] = {

    { ngx_string("lua_shared_mem"),
      NGX_STREAM_MAIN_CONF|NGX_CONF_TAKE2,
      ngx_stream_lua_shdict,
      0,
      0,
      NULL },

    ngx_null_command
};


static ngx_stream_module_t ngx_stream_lua_shdict_module_ctx = {
#if (nginx_version >= 1011002)
    NULL,                                    /* preconfiguration */
#endif
    NULL,                                    /* postconfiguration */

    ngx_lua_shdict_create_common_main_conf,  /* create main configuration */
    NULL,                                    /* init main configuration */

    NULL,                                    /* create server configuration */
    NULL,                                    /* merge server configuration */
};


ngx_module_t ngx_stream_lua_shdict_module = {
    NGX_MODULE_V1,
    &ngx_stream_lua_shdict_module_ctx, /* module context */
    ngx_stream_lua_shdict_cmds,        /* module directives */
    NGX_STREAM_MODULE,                 /* module type */
    NULL,                              /* init master */
    NULL,                              /* init module */
    NULL,                              /* init process */
    NULL,                              /* init thread */
    NULL,                              /* exit thread */
    NULL,                              /* exit process */
    NULL,                              /* exit master */
    NGX_MODULE_V1_PADDING
};


static char *
ngx_stream_lua_shdict(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    return ngx_lua_shdict_common_cmd_set(cf, cmd, conf,
                                         ngx_stream_lua_shared_memory_add,
                                         &ngx_stream_lua_shdict_module);
}