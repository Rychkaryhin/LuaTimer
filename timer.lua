-- Автор: Rychka - t.me/rychkayt

obs = obslua

local active_cfg = nil
local rychka_data_obj = nil
local text_cache = {}
local q_updates = {}

function script_description()
    return "Скрипт таймеров и времени.\n\nАвтор: Rychka - t.me/rychkayt"
end

function script_defaults(s)
    obs.obs_data_set_default_int(s, "time_correction", 0)
    obs.obs_data_set_default_int(s, "my_timezone", 3)
    obs.obs_data_set_default_string(s, "mode", "single")
    obs.obs_data_set_default_int(s, "single_target_tz", 3)
    obs.obs_data_set_default_int(s, "single_events_count", 1)

    -- дефолты для первого
    obs.obs_data_set_default_string(s, "single_ev1", "ny")
    obs.obs_data_set_default_string(s, "single_fmt1", "0")
    -- дефолты для второго
    obs.obs_data_set_default_string(s, "single_ev2", "summer")
    obs.obs_data_set_default_string(s, "single_fmt2", "0")
    -- дефолты мульти
    obs.obs_data_set_default_string(s, "multi_ev", "ny")
    obs.obs_data_set_default_string(s, "multi_fmt", "0")
end

-- Rychka - t.me/rychkayt: Заполняем выпадающий список текстовыми сурсами
local function fetch_text_sources(prop_list)
    obs.obs_property_list_add_string(prop_list, "", "")

    local all_srcs = obs.obs_enum_sources()
    if not all_srcs then return end

    for _, src in ipairs(all_srcs) do
        local id = obs.obs_source_get_unversioned_id(src)
        if id == "text_gdiplus" or id == "text_ft2_source" or id == "text_gdiplus_v2" then
            local n = obs.obs_source_get_name(src)
            obs.obs_property_list_add_string(prop_list, n, n)
        end
    end
    obs.source_list_release(all_srcs)
end

local function apply_text_change(src_name, txt)
    if not src_name or src_name == "" then return end

    -- Проверка кэша, чтобы не дергать OBS зря
    if text_cache[src_name] == txt then return end
    text_cache[src_name] = txt

    local s = obs.obs_get_source_by_name(src_name)
    if s then
        obs.obs_data_clear(rychka_data_obj)
        obs.obs_data_set_string(rychka_data_obj, "text", txt)
        obs.obs_source_update(s, rychka_data_obj)
        obs.obs_source_release(s)
    end
end

-- Rychka - t.me/rychkayt: Разгребаем очередь по паре штук за тик
local function drain_queue()
    for i = 1, 2 do
        if #q_updates == 0 then break end
        local task = table.remove(q_updates, 1)
        apply_text_change(task.s, task.t)
    end
end

local function get_goal_ts(ev_type, sim_now)
    local d = os.date("*t", sim_now)
    local res = 0
    local y = d.year

    -- Rychka - t.me/rychkayt: логика выбора сезона
    if ev_type == "ny" then
        res = os.time({year = y + 1, month = 1, day = 1, hour = 0, min = 0, sec = 0})
    elseif ev_type == "summer" then
        res = os.time({year = y, month = 6, day = 1, hour = 0, min = 0, sec = 0})
        if sim_now > res then res = os.time({year = y + 1, month = 6, day = 1, hour = 0, min = 0, sec = 0}) end
    elseif ev_type == "autumn" then
        res = os.time({year = y, month = 9, day = 1, hour = 0, min = 0, sec = 0})
        if sim_now > res then res = os.time({year = y + 1, month = 9, day = 1, hour = 0, min = 0, sec = 0}) end
    elseif ev_type == "winter" then
        res = os.time({year = y, month = 12, day = 1, hour = 0, min = 0, sec = 0})
        if sim_now > res then res = os.time({year = y + 1, month = 12, day = 1, hour = 0, min = 0, sec = 0}) end
    end

    return res
end

local function format_diff(diff, fmt_type)
    if diff < 0 then diff = 0 end

    local days = math.floor(diff / 86400)
    local hrs = math.floor((diff % 86400) / 3600)
    local mins = math.floor((diff % 3600) / 60)
    local secs = math.floor(diff % 60)

    local hs = string.format("%02d", hrs)
    local ms = string.format("%02d", mins)
    local ss = string.format("%02d", secs)

    -- Rychka - t.me/rychkayt: формат свордера
    if fmt_type == "5" then
        local ds = tostring(days)
        if days < 10 then
            return string.format(" %s  %s  %s  %s", ds, hs, ms, ss)
        elseif days < 100 then
            return string.format("%s  %s  %s  %s", ds, hs, ms, ss)
        end
        return string.format("%s %s  %s  %s", ds, hs, ms, ss)
    end

    local ds = tostring(days)
    if days < 10 then ds = " " .. ds end

    if fmt_type == "0" then return ds .. ":" .. hs .. ":" .. ms .. ":" .. ss end
    if fmt_type == "1" then return hs .. ":" .. ms .. ":" .. ss end
    if fmt_type == "2" then return string.format("%02d", math.floor(diff / 60)) .. ":" .. ss end
    if fmt_type == "3" then return tostring(math.floor(diff)) end
    if fmt_type == "4" then
        local total_m_no_d = hrs * 60 + mins
        return ds .. ":" .. string.format("%02d", total_m_no_d) .. ":" .. ss
    end

    return ds .. ":" .. hs .. ":" .. ms .. ":" .. ss
end

local function main_clock_pulse()
    if not active_cfg then return end

    q_updates = {} -- сбрасываем старую очередь

    local run_mode = obs.obs_data_get_string(active_cfg, "mode")
    local global_off = obs.obs_data_get_int(active_cfg, "time_correction")
    local my_tz = obs.obs_data_get_int(active_cfg, "my_timezone")
    local base_ts = os.time() + global_off

    if run_mode == "single" then
        local target_tz = obs.obs_data_get_int(active_cfg, "single_target_tz")
        local sim_now = base_ts + ((target_tz - my_tz) * 3600)
        local t_str = os.date("%H:%M:%S", sim_now)
        local ev_count = obs.obs_data_get_int(active_cfg, "single_events_count")

        local e1 = obs.obs_data_get_string(active_cfg, "single_ev1")
        local f1 = obs.obs_data_get_string(active_cfg, "single_fmt1")
        local d1 = get_goal_ts(e1, sim_now) - sim_now

        table.insert(q_updates, {s = obs.obs_data_get_string(active_cfg, "single_time1_src"), t = t_str})
        table.insert(q_updates, {s = obs.obs_data_get_string(active_cfg, "single_timer1_src"), t = format_diff(d1, f1)})

        -- Rychka - t.me/rychkayt: Если нужно два события, делаем и второе
        if ev_count == 2 then
            local e2 = obs.obs_data_get_string(active_cfg, "single_ev2")
            local f2 = obs.obs_data_get_string(active_cfg, "single_fmt2")
            local d2 = get_goal_ts(e2, sim_now) - sim_now

            table.insert(q_updates, {s = obs.obs_data_get_string(active_cfg, "single_time2_src"), t = t_str})
            table.insert(q_updates, {s = obs.obs_data_get_string(active_cfg, "single_timer2_src"), t = format_diff(d2, f2)})
        end

    elseif run_mode == "multi" then
        local e_multi = obs.obs_data_get_string(active_cfg, "multi_ev")
        local f_multi = obs.obs_data_get_string(active_cfg, "multi_fmt")

        for i = 1, 12 do
            local sim_now = base_ts + ((i - my_tz) * 3600)
            local t_str = os.date("%H:%M:%S", sim_now)
            local d_multi = get_goal_ts(e_multi, sim_now) - sim_now

            table.insert(q_updates, {s = obs.obs_data_get_string(active_cfg, "multi_time_"..i), t = t_str})
            table.insert(q_updates, {s = obs.obs_data_get_string(active_cfg, "multi_timer_"..i), t = format_diff(d_multi, f_multi)})
        end
    end
end

local function toggle_ui_prop(props, name, is_visible)
    local pr = obs.obs_properties_get(props, name)
    if pr then obs.obs_property_set_visible(pr, is_visible) end
end

local function refresh_ui(props, _, settings)
    local m = obs.obs_data_get_string(settings, "mode")
    local single = (m == "single")
    local multi = (m == "multi")
    local two_ev = (obs.obs_data_get_int(settings, "single_events_count") == 2)

    toggle_ui_prop(props, "single_target_tz", single)
    toggle_ui_prop(props, "single_events_count", single)
    toggle_ui_prop(props, "single_ev1", single)
    toggle_ui_prop(props, "single_fmt1", single)
    toggle_ui_prop(props, "single_time1_src", single)
    toggle_ui_prop(props, "single_timer1_src", single)

    local s_ev2 = single and two_ev
    toggle_ui_prop(props, "single_ev2", s_ev2)
    toggle_ui_prop(props, "single_fmt2", s_ev2)
    toggle_ui_prop(props, "single_time2_src", s_ev2)
    toggle_ui_prop(props, "single_timer2_src", s_ev2)

    toggle_ui_prop(props, "multi_ev", multi)
    toggle_ui_prop(props, "multi_fmt", multi)

    for i = 1, 12 do
        toggle_ui_prop(props, "multi_time_"..i, multi)
        toggle_ui_prop(props, "multi_timer_"..i, multi)
    end

    return true
end

function script_properties()
    local p = obs.obs_properties_create()

    obs.obs_properties_add_int(p, "time_correction", "Глобальная коррекция времени (сек)", -86400, 86400, 1)

    local tz_list = obs.obs_properties_add_list(p, "my_timezone", "Часовой пояс ПК (UTC)", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    for i = -12, 14 do
        local prefix = (i > 0) and "+" or ""
        obs.obs_property_list_add_int(tz_list, "UTC" .. prefix .. i, i)
    end

    local mode_list = obs.obs_properties_add_list(p, "mode", "Режим работы", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(mode_list, "Один часовой пояс", "single")
    obs.obs_property_list_add_string(mode_list, "Мульти-таймеры (+1 до +12 GMT)", "multi")

    -- Rychka - t.me/rychkayt: утилита для добавления форматов
    local function inject_formats(prop_obj)
        obs.obs_property_list_add_string(prop_obj, "Дни : Часы : Минуты : Секунды", "0")
        obs.obs_property_list_add_string(prop_obj, "Часы : Минуты : Секунды", "1")
        obs.obs_property_list_add_string(prop_obj, "Минуты : Секунды", "2")
        obs.obs_property_list_add_string(prop_obj, "Только секунды", "3")
        obs.obs_property_list_add_string(prop_obj, "Дни : Минуты : Секунды", "4")
        obs.obs_property_list_add_string(prop_obj, "Пробелы (стандартный формат)", "5")
    end

    local single_tz_list = obs.obs_properties_add_list(p, "single_target_tz", "Часовой пояс для таймера (UTC)", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    for i = -12, 14 do
        local prefix = (i > 0) and "+" or ""
        obs.obs_property_list_add_int(single_tz_list, "UTC" .. prefix .. i, i)
    end

    local ev_cnt_list = obs.obs_properties_add_list(p, "single_events_count", "Количество событий", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    obs.obs_property_list_add_int(ev_cnt_list, "Одно событие", 1)
    obs.obs_property_list_add_int(ev_cnt_list, "Два события", 2)

    -- Блок первого события
    local e1 = obs.obs_properties_add_list(p, "single_ev1", "[Соб. 1] Отсчет до:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(e1, "До Нового Года", "ny")
    obs.obs_property_list_add_string(e1, "До Лета", "summer")
    obs.obs_property_list_add_string(e1, "До Осени", "autumn")
    obs.obs_property_list_add_string(e1, "До Зимы", "winter")

    local f1 = obs.obs_properties_add_list(p, "single_fmt1", "[Соб. 1] Формат таймера", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    inject_formats(f1)

    local s_time1 = obs.obs_properties_add_list(p, "single_time1_src", "[Соб. 1] Источник для Времени", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fetch_text_sources(s_time1)

    local s_tmr1 = obs.obs_properties_add_list(p, "single_timer1_src", "[Соб. 1] Источник для Таймера", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fetch_text_sources(s_tmr1)

    -- Блок второго события
    local e2 = obs.obs_properties_add_list(p, "single_ev2", "[Соб. 2] Отсчет до:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(e2, "До Нового Года", "ny")
    obs.obs_property_list_add_string(e2, "До Лета", "summer")
    obs.obs_property_list_add_string(e2, "До Осени", "autumn")
    obs.obs_property_list_add_string(e2, "До Зимы", "winter")

    local f2 = obs.obs_properties_add_list(p, "single_fmt2", "[Соб. 2] Формат таймера", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    inject_formats(f2)

    local s_time2 = obs.obs_properties_add_list(p, "single_time2_src", "[Соб. 2] Источник для Времени", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fetch_text_sources(s_time2)

    local s_tmr2 = obs.obs_properties_add_list(p, "single_timer2_src", "[Соб. 2] Источник для Таймера", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fetch_text_sources(s_tmr2)

    -- Блок Мульти
    local e_multi = obs.obs_properties_add_list(p, "multi_ev", "[Мульти] Отсчет до:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(e_multi, "До Нового Года", "ny")
    obs.obs_property_list_add_string(e_multi, "До Лета", "summer")
    obs.obs_property_list_add_string(e_multi, "До Осени", "autumn")
    obs.obs_property_list_add_string(e_multi, "До Зимы", "winter")

    local f_multi = obs.obs_properties_add_list(p, "multi_fmt", "[Мульти] Формат таймера", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    inject_formats(f_multi)

    for i = 1, 12 do
        local t_src = obs.obs_properties_add_list(p, "multi_time_"..i, "Время (Пояс +"..i..")", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
        fetch_text_sources(t_src)

        local tmr_src = obs.obs_properties_add_list(p, "multi_timer_"..i, "Таймер (Пояс +"..i..")", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
        fetch_text_sources(tmr_src)
    end

    -- Коллбеки обновления UI
    obs.obs_property_set_modified_callback(mode_list, refresh_ui)
    obs.obs_property_set_modified_callback(ev_cnt_list, refresh_ui)

    return p
end

function script_update(settings)
    active_cfg = settings
end

function script_load(settings)
    active_cfg = settings
    if not rychka_data_obj then
        rychka_data_obj = obs.obs_data_create()
    end

    obs.timer_add(main_clock_pulse, 1000)
    obs.timer_add(drain_queue, 50)
end

function script_unload()
    obs.timer_remove(main_clock_pulse)
    obs.timer_remove(drain_queue)
    if rychka_data_obj then
        obs.obs_data_release(rychka_data_obj)
        rychka_data_obj = nil
    end
end