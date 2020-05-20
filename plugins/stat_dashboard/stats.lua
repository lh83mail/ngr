---
--- Generated by EmmyLua(https://github.com/EmmyLua)
--- Created by jacobs.
--- DateTime: 2018/4/26 上午10:15
---

local tonumber = tonumber
local xpcall = xpcall
local debug = debug
local math = math
local server_info = require("core.server_info")

local KEY_PREFIX = "DASHBOARD_"
local STAT_LOCK = "STAT_LOCK"

local KEY_START_TIME = KEY_PREFIX.."START_TIME"
local KEY_NGR_WORKER_COUNT = KEY_PREFIX .. "NGR_WORKER_COUNT"
local KEY_ERROR_LOG_LEVEL = KEY_PREFIX .. "ERROR_LOG_LEVEL"
local KEY_NGR_VERSION = KEY_PREFIX .. "NGR_VERSION"
local KEY_NGINX_VERSION = KEY_PREFIX .. "NGINX_VERSION"
local KEY_NGX_LUA_VERSION = KEY_PREFIX .. "NGX_LUA_VERSION"

local KEY_TOTAL_COUNT = KEY_PREFIX .. "TOTAL_REQUEST_COUNT"
local KEY_TOTAL_SUCCESS_COUNT = KEY_PREFIX .. "TOTAL_SUCCESS_REQUEST_COUNT"
local KEY_TRAFFIC_READ = KEY_PREFIX .. "TRAFFIC_READ"
local KEY_TRAFFIC_WRITE = KEY_PREFIX .. "TRAFFIC_WRITE"
local KEY_TOTAL_REQUEST_TIME = KEY_PREFIX .."TOTAL_REQUEST_TIME"

local KEY_REQUEST_2XX = KEY_PREFIX .. "REQUEST_2XX"
local KEY_REQUEST_3XX = KEY_PREFIX .. "REQUEST_3XX"
local KEY_REQUEST_4XX = KEY_PREFIX .. "REQUEST_4XX"
local KEY_REQUEST_5XX = KEY_PREFIX .. "REQUEST_5XX"

local ngx = ngx
local utils = require("core.utils.utils")
local dashboard_cache_util = require("core.cache.local.dashboard_cache_util")

local log_config = require("core.utils.log_config")
local ngx_log = ngx.log
local ngx_debug= ngx.DEBUG
local ERR = ngx.ERR
local str_format = string.format
local Object = require("core.framework.classic")
local _M = Object:extend()


local function build_key(gateway_code, key, is_current_day)
    if is_current_day then
        local current_day = utils.current_day()
        return gateway_code.."_"..key.."_"..current_day;
    else
        return gateway_code.."_"..key;
    end
end

-- generate key for sample
-- @param host_or_service_name
-- @param metric_name
-- @return pattern is 'SAMPLE:[${HOST}|${SERVICE_NAME}]:${METRIC_NAME}'
local function build_key_for_sample(svc, host, key)
    if host ~= nil then
        return "SAMPLE:"..svc..":"..host.. ":"..key;
    else
        return "SAMPLE:"..svc..":"..key;
    end
end

local function build_last_key(key)
    return  key .. "_last";
end

local function set_cache(cache,key,data,is_set_expire)
    cache:set(key,data);
    if is_set_expire then
        -- 过期时间为2天
        cache:expire(key, 2 * 24 *3600)
    end
end

local function incr(key)
    dashboard_cache_util.incr(key,1)
end

local function incrby(key,increment)
    dashboard_cache_util.incr(key,increment)
end

local function cache_incrby(cache,key,value)
    local exist,err = cache:exists(key)
    if not exist or exist ==  0 then
        cache:incrby(key,value)
        cache:expire(key, dashboard_cache_util.DEFAULT_EXPIRE)
    else
        cache:incrby(key,value)
    end
end

local function cal_increment(key)
    local value = dashboard_cache_util.get(key) or 0
    local last_value = dashboard_cache_util.get(build_last_key(key)) or 0
    return value - last_value
end

local function to_storage(cache, key_name, part_key)
    local key = build_key(key_name, part_key,true)

    local increment = cal_increment(key)
    if increment > 0 then
        cache_incrby(cache,key,increment)
        incrby(build_last_key(key),increment)
    end

end

local function startswith(str, sub_str)
    local len = #sub_str
    local tmp = string.sub(str, 1, len)
    if tmp == sub_str then
        return true
    else
        return false
    end
end

local function flush_sample(cache)
    local current_time = ngx.now()
    local min_time = current_time - 24*60*60
    ngx_log(ngx_debug, "[start to flush sample]")
    local rem_keys, err = cache:zrangebyscore("SAMPLE:TS", "-inf", min_time)
    cache:zremrangebyscore("sample_ts", "-inf", min_time)
    for _, sample_key in pairs(dashboard_cache_util.keys()) do
        if startswith(sample_key, "SAMPLE") then
            local value = dashboard_cache_util.get(sample_key) or 0
            ngx_log(ngx_debug, "[flush sample] value of "..sample_key.." is:"..value)
            -- cache:zadd(sample_key, current_time, tostring(value).."_"..tostring(current_time))
            -- cache:zremrangebyscore(sample_key, "-inf", min_time)
            dashboard_cache_util.set(sample_key, 0, dashboard_cache_util.NEVER_EXPIRE)

            cache:hset(sample_key, current_time, value)
            if #rem_keys>0 then
                local res, err = cache:hdel(sample_key, unpack(rem_keys))
            end
            if err or res==false then
                ngx_log(ngx_debug, "[flush] hdel error")
            end
        end
    end
    cache:zadd("SAMPLE:TS", current_time, current_time)
    ngx_log(ngx_debug, "[flush sample] flush finish")
end

local function save_log(premature, cache, log_data)
    if premature then
        return
    end
    local ok, e
    ok = xpcall(function()
        local service_name = log_data.service_name
        local host = log_data.host

        incr(build_key(service_name,KEY_TOTAL_COUNT,true))
        incr(build_key_for_sample(service_name, host, KEY_TOTAL_COUNT))
        incr(build_key_for_sample(service_name, nil, KEY_TOTAL_COUNT))

        local http_status = log_data.http_status
        ngx_log(ngx_debug, "stat dashboard log http_status.",http_status)
        if http_status < 400 then
            incr(build_key(service_name,KEY_TOTAL_SUCCESS_COUNT,true))
            incr(build_key_for_sample(service_name, host, KEY_TOTAL_SUCCESS_COUNT))
            incr(build_key_for_sample(service_name, nil, KEY_TOTAL_SUCCESS_COUNT))
        else
            incrby(build_key_for_sample(service_name, host, KEY_TOTAL_SUCCESS_COUNT), 0)
            incrby(build_key_for_sample(service_name, nil, KEY_TOTAL_SUCCESS_COUNT), 0)
        end
        if http_status >= 200 and http_status < 300 then
            incr(build_key(service_name,KEY_REQUEST_2XX,true))
            incr(build_key_for_sample(service_name, host, KEY_REQUEST_2XX))
            incr(build_key_for_sample(service_name, nil, KEY_REQUEST_2XX))
        else
            incrby(build_key_for_sample(service_name, host, KEY_REQUEST_2XX), 0)
            incrby(build_key_for_sample(service_name, nil, KEY_REQUEST_2XX), 0)
        end
        if http_status >= 300 and http_status < 400 then
            incr(build_key(service_name,KEY_REQUEST_3XX,true))
            incr(build_key_for_sample(service_name, host, KEY_REQUEST_3XX))
            incr(build_key_for_sample(service_name, nil, KEY_REQUEST_3XX))
        else
            incrby(build_key_for_sample(service_name, host, KEY_REQUEST_3XX), 0)
            incrby(build_key_for_sample(service_name, nil, KEY_REQUEST_3XX), 0)
        end
        if http_status >= 400 and http_status < 500 then
            incr(build_key(service_name,KEY_REQUEST_4XX,true))
            incr(build_key_for_sample(service_name, host, KEY_REQUEST_4XX))
            incr(build_key_for_sample(service_name, nil, KEY_REQUEST_4XX))
        else
            incrby(build_key_for_sample(service_name, host, KEY_REQUEST_4XX), 0)
            incrby(build_key_for_sample(service_name, nil, KEY_REQUEST_4XX), 0)
        end
        if http_status >= 500 and http_status < 600 then
            incr(build_key(service_name,KEY_REQUEST_5XX,true))
            incr(build_key_for_sample(service_name, host, KEY_REQUEST_5XX))
            incr(build_key_for_sample(service_name, nil, KEY_REQUEST_5XX))
        else
            incrby(build_key_for_sample(service_name, host, KEY_REQUEST_5XX), 0)
            incrby(build_key_for_sample(service_name, nil, KEY_REQUEST_5XX), 0)
        end
        incrby(build_key(service_name,KEY_TRAFFIC_READ,true), log_data.request_length)
        incrby(build_key_for_sample(service_name, host, KEY_TRAFFIC_READ), log_data.request_length)
        incrby(build_key_for_sample(service_name, nil, KEY_TRAFFIC_READ), log_data.request_length)

        incrby(build_key(service_name,KEY_TRAFFIC_WRITE, true), log_data.bytes_sent)
        incrby(build_key_for_sample(service_name, host, KEY_TRAFFIC_WRITE), log_data.bytes_sent)
        incrby(build_key_for_sample(service_name, nil, KEY_TRAFFIC_WRITE), log_data.bytes_sent)

        ngx_log(ngx_debug,"request_time: ", log_data.request_time)
        incrby(build_key(service_name,KEY_TOTAL_REQUEST_TIME, true), log_data.request_time)
        incrby(build_key_for_sample(service_name, host, KEY_TOTAL_REQUEST_TIME), log_data.request_time)
        incrby(build_key_for_sample(service_name, nil, KEY_TOTAL_REQUEST_TIME), log_data.request_time)

        ngx_log(ngx_debug, "stat dashboard log successfully.")
    end, function()
        e = debug.traceback()
    end
    )
    if not ok or e then
        ngx_log(ERR,str_format(log_config.sys_error_format,log_config.ERROR,"stat dashboard save log error ".. e))
        -- TODO statsd
    end
end

function _M:new(cache_client,service_name)
    self.super.new(self)
    self.cache = cache_client
    if service_name then
        self.service_name = service_name
    end
end

function _M:init_worker(config)
    local ok, err = dashboard_cache_util.add(STAT_LOCK, true)
    if ok then
        if config and config.ngr_start_at then
            --self.cache:set(KEY_START_TIME,config.ngr_start_at )
            set_cache(self.cache, build_key(config.service_name,KEY_START_TIME,false),config.ngr_start_at,false)
        else
            local local_time = ngx.localtime()
            --self.cache:set(KEY_START_TIME,local_time)
            set_cache(self.cache, build_key(config.service_name,KEY_START_TIME,false),local_time,false)
        end


        -- 悟空版本
        set_cache(self.cache, build_key(config.service_name,KEY_NGR_VERSION,false),server_info.version,false)

        -- nginx 版本版本
        local _nginx_version = ngx.config.nginx_version
        -- set_cache(self.cache,bulid_key(config.service_name,KEY_NGINX_VERSION,false),ngx.var.nginx_version,false)
        set_cache(self.cache, build_key(config.service_name,KEY_NGINX_VERSION,false),_nginx_version,false)

        -- ngx_lua版本
        local ngx_lua_version = ngx.config.ngx_lua_version

        local lua_version = math.floor(ngx_lua_version / 1000000) .. '.' .. math.floor(ngx_lua_version / 1000) ..'.' .. math.floor(ngx_lua_version % 1000)
        set_cache(self.cache, build_key(config.service_name,KEY_NGX_LUA_VERSION,false),lua_version,false)

        --self.cache:set(KEY_NGR_WORKER_COUNT, (config.cluster_node_count or 1 )* ngx.worker.count())
        set_cache(self.cache, build_key(config.service_name,KEY_NGR_WORKER_COUNT,false),(config.cluster_node_count or 1 )* ngx.worker.count(),false)
        --self.cache:set(KEY_ERROR_LOG_LEVEL,config.application_conf.log_level)
        set_cache(self.cache, build_key(config.service_name,KEY_ERROR_LOG_LEVEL,false),config.application_conf.log_level,false)
        ngx_log(ngx_debug, "stat dashboard initialize successfully.")
    end
end

function _M:log()
    local ngx_var = ngx.var
    local cache = self.cache
    local log_data = {
        service_name = self.service_name,
        host = ngx_var.host,
        http_status = tonumber(ngx_var.status),
        request_length = ngx_var.request_length,
        bytes_sent = ngx_var.bytes_sent,
        -- convert to ms
        request_time = math.ceil((ngx.now() - ngx.req.start_time())*1000 )
    }
    local ok, err = ngx.timer.at(0, save_log, cache, log_data)
    if not ok then
        ngx_log(ERR,str_format(log_config.sys_error_format,log_config.ERROR,"stat_dashboard_handler's log handler".. err))
        return
    end
end


---
--
-- show dashboard stat
---
function _M:stat(services)
    local ngx_lua_version = ngx.config.ngx_lua_version

    local result = {}
    local base_infos = {}
    local request_infos ={}

    for _, service in ipairs(services) do
        local service_name = service.gateway_code
        ngx.log(ngx.INFO,"stat service_name = ",service_name)
        -- ngr start time 启动时间
        local start_time = self.cache:get(build_key(service_name,KEY_START_TIME,false))

        if not start_time then
            start_time = self.cache:get(KEY_START_TIME);
        end

        if start_time then
            local content = {
                base_info = {
                    service_name = service_name,
                    start_time = start_time,
                    -- 悟空版本
                    ngr_version = self.cache:get(build_key(service_name,KEY_NGR_VERSION,false)),

                    -- nginx 版本版本
                    nginx_version = self.cache:get(build_key(service_name,KEY_NGINX_VERSION,false)),

                    -- ngx_lua版本
                    ngx_lua_version = self.cache:get(build_key(service_name,KEY_NGX_LUA_VERSION,false)),

                    --当前时间戳
                    timestamp = ngx.time(),
                    -- ngr worker进程数
                    ngr_worker = self.cache :get(build_key(service_name,KEY_NGR_WORKER_COUNT,false)),

                    --ngr 错误日志级别
                    error_log_level = self.cache:get(build_key(service_name,KEY_ERROR_LOG_LEVEL,false))
                },
                request_info = {
                    service_name = service_name,
                    --total request count 总请求次数
                    total_count = self.cache:get(build_key(service_name,KEY_TOTAL_COUNT,true)) or 0,
                    --total request success count 成功请求次数
                    total_success_count = self.cache:get(build_key(service_name,KEY_TOTAL_SUCCESS_COUNT,true)) or 0,
                    -- total read size  请求总字节
                    traffic_read = self.cache:get(build_key(service_name,KEY_TRAFFIC_READ,true)) or 0,
                    -- total write size 响应总字节
                    traffic_write = self.cache:get(build_key(service_name,KEY_TRAFFIC_WRITE,true)) or 0,
                    -- total request time 总请求时间（毫秒）
                    total_request_time = math.floor(tonumber(self.cache:get(build_key(service_name,KEY_TOTAL_REQUEST_TIME,true))) or 0),
                    -- total http status [200,300) request count 200请求次数
                    request_2xx = self.cache:get(build_key(service_name,KEY_REQUEST_2XX,true)) or 0,
                    -- total http status [300,400) request count 300 请求次数
                    request_3xx = self.cache:get(build_key(service_name,KEY_REQUEST_3XX,true))  or 0,
                    -- total http status [400,500) request count 300 请求次数
                    request_4xx = self.cache:get(build_key(service_name,KEY_REQUEST_4XX,true))  or 0,
                    -- total http status [500,600) request count 500 请求次数
                    request_5xx = self.cache:get(build_key(service_name,KEY_REQUEST_5XX,true))  or 0
                }
            }
            table.insert(base_infos,content.base_info)
            table.insert(request_infos,content.request_info)
        end
    end
    if base_infos then
        result["base_infos"] = base_infos
    end
    if request_infos then
        result["request_infos"] = request_infos
    end
    return result
end

function _M:init_worker_ext_timer()
    local cache = self.cache
    local service_name = self.service_name
    local total_count = cal_increment(build_key(self.service_name,KEY_TOTAL_COUNT,true))
    -- 大于则写入 redis
    -- if total_count >= 60 then

        to_storage(cache,service_name,KEY_TOTAL_COUNT)

        to_storage(cache,service_name,KEY_TOTAL_SUCCESS_COUNT)

        to_storage(cache,service_name,KEY_REQUEST_2XX)

        to_storage(cache,service_name,KEY_REQUEST_3XX)

        to_storage(cache,service_name,KEY_REQUEST_4XX)

        to_storage(cache,service_name,KEY_REQUEST_5XX)

        to_storage(cache,service_name,KEY_TRAFFIC_READ)

        to_storage(cache,service_name,KEY_TRAFFIC_WRITE)

        to_storage(cache,service_name,KEY_TOTAL_REQUEST_TIME)

    -- end

    flush_sample(cache)
end

return _M
