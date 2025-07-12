-- battery_brtl_fixed_v6.lua
-- BRTL（Battery Return To Land）- 状態リセット修正版v6
-- 修正：Autoモード再開時の完全な状態リセット機能

-- ===== カスタムパラメータ設定 =====
local PARAM_TABLE_KEY = 50
local PARAM_PREFIX = "BRTL_"

-- パラメータ定義テーブル（修正版v6）
local param_definitions = {
    -- システム制御パラメータ
    { "ENABLE",       1 },   -- BRTL機能の有効/無効 (1=有効, 0=無効)
    { "THRESHOLD",   30 },   -- バッテリー残量閾値 (%, 1-99)
    { "HUD_ENABLE",   1 },   -- HUDメッセージ表示 (1=表示, 0=非表示)
    { "DEBUG",        1 },   -- デバッグ情報表示 (1=表示, 0=非表示)
    
    -- 飛行制御パラメータ
    { "DESC_RATE",  100 },   -- 降下速度 (cm/s, 50-500)
    { "TARGET_ALT",  10 },   -- ホーム上空目標高度 (m, 5-100)
    { "MAX_H_SPEED",  8 },   -- 最大水平速度 (m/s, 2-20)
    { "MSG_INTRVL",   5 },   -- メッセージ表示間隔 (秒, 1-30)
    
    -- 着陸制御パラメータ（修正版v6）
    { "HOVER_TIME",   2 },   -- ホーム上空ホバリング時間 (秒, 1-10)
    { "ARRIVE_DIST", 10 },   -- ホーム到着判定距離 (m, 5-20)
    { "ARV_ALT_DIFF", 5 },   -- ホーム到着判定高度差 (m, 3-10)
    { "LAND_TIMEOUT", 30 },  -- LAND切替タイムアウト (秒, 10-60)
    { "RETRY_DELAY",   2 },  -- リトライ間隔 (秒, 1-5)
    { "RTL_DIST",    20 },   -- ホーム手前距離でRTL切替 (m, 10-50)
    { "RTL_LOIT_SEC", 3 }    -- RTLホバリング時間 (秒, 1-10)
}

-- パラメータオブジェクト
local params = {}

-- フライトモード定数
local MODE_AUTO = 3
local MODE_GUIDED = 4
local MODE_RTL = 6
local MODE_LAND = 9

-- ===== メッセージ長制限対応関数 =====
local MAX_MSG_LENGTH = 50

-- ===== 基本ユーティリティ関数 =====
local function get_time_seconds()
    local millis_value = millis()
    return millis_value and math.floor(millis_value:tofloat() / 1000) or 0
end

local function get_param_value(name)
    return params[name] and params[name]:get() or 0
end

local function safe_send_message(severity, message, force_send)
    if force_send or get_param_value("HUD_ENABLE") == 1 then
        if gcs and gcs.send_text then
            local safe_msg = message
            if string.len(message) > MAX_MSG_LENGTH then
                safe_msg = string.sub(message, 1, MAX_MSG_LENGTH - 3) .. "..."
            end
            gcs:send_text(severity, safe_msg)
        end
    end
end

local function send_message(severity, message, force_send)
    safe_send_message(severity, message, force_send)
end

-- ===== パラメータ初期化関数 =====
local function add_custom_params()
    if not param or not param.add_table then
        gcs:send_text(3, "param API not available")
        return false
    end
    
    if not param:add_table(PARAM_TABLE_KEY, PARAM_PREFIX, #param_definitions) then
        gcs:send_text(3, "Failed to add parameter table")
        return false
    end
    
    for i, param_def in ipairs(param_definitions) do
        if not param:add_param(PARAM_TABLE_KEY, i, param_def[1], param_def[2]) then
            safe_send_message(3, string.format("Failed to add param %s", param_def[1]), true)
            return false
        end
    end
    
    safe_send_message(4, "BRTL parameters added successfully", true)
    return true
end

local function init_parameter_objects()
    for _, param_def in ipairs(param_definitions) do
        local param_name = PARAM_PREFIX .. param_def[1]
        params[param_def[1]] = Parameter()
        if not params[param_def[1]]:init(param_name) then
            safe_send_message(3, string.format("Param init failed: %s", param_def[1]), true)
            return false
        end
    end
    return true
end

-- ===== パラメータ妥当性チェック関数 =====
local function validate_parameters()
    local valid = true
    local threshold = get_param_value("THRESHOLD")
    local target_alt = get_param_value("TARGET_ALT")
    local hover_time = get_param_value("HOVER_TIME")
    local rtl_dist = get_param_value("RTL_DIST")
    local rtl_loit = get_param_value("RTL_LOIT_SEC")
    
    if threshold < 1 or threshold > 99 then
        send_message(3, "BRTL_THRESHOLD must be 1-99%", true)
        valid = false
    end
    
    if target_alt < 5 or target_alt > 100 then
        send_message(3, "BRTL_TARGET_ALT must be 5-100m", true)
        valid = false
    end
    
    if hover_time < 1 or hover_time > 10 then
        send_message(3, "BRTL_HOVER_TIME must be 1-10s", true)
        valid = false
    end
    
    if rtl_dist < 10 or rtl_dist > 50 then
        send_message(3, "BRTL_RTL_DIST must be 10-50m", true)
        valid = false
    end
    
    if rtl_loit < 1 or rtl_loit > 10 then
        send_message(3, "BRTL_RTL_LOIT_SEC must be 1-10s", true)
        valid = false
    end
    
    return valid
end

-- ===== 状態変数（修正版v6） =====
local SCRIPT_NAME = "BRTL_StateReset_v6"
local state = {
    -- BRTL機能関連
    brtl_triggered = false,
    brtl_guided_mode = false,
    landing_completed = false,
    
    -- 修正された着陸状態v6
    phase = "IDLE",  -- IDLE, APPROACH, RTL_MODE, ARRIVED, HOVER, LANDING, DONE
    phase_start_time = 0,
    target_location = nil,
    land_attempt_count = 0,
    last_land_attempt_time = 0,
    rtl_start_time = 0,
    
    -- フライトモード監視【修正v6】
    current_mode = nil,
    last_mode = nil,
    auto_mode_active = false,
    auto_mode_entry_count = 0,  -- Auto入場回数カウンタ【新規v6】
    last_auto_entry_time = 0,   -- 最後のAuto入場時刻【新規v6】
    
    -- 初期化関連
    script_initialized = false,
    params_initialized = false,
    init_counter = 0,
    
    -- HUD・メッセージ関連
    last_hud_message_time = 0,
    last_status_message = "",
    message_counter = 0,
    
    -- BRTL制御関連
    brtl_total_distance = nil,
    last_message_time = 0,
    last_debug_time = 0
}

-- ===== 完全状態リセット関数【修正v6】 =====
local function complete_brtl_reset(reason)
    local current_time = get_time_seconds()
    
    -- 以前の状態を記録してリセット理由をログ出力
    local old_phase = state.phase
    local old_triggered = state.brtl_triggered
    
    send_message(4, string.format("BRTL complete reset: %s", reason), true)
    
    -- BRTL機能状態の完全リセット
    state.brtl_triggered = false
    state.brtl_guided_mode = false
    state.landing_completed = false
    
    -- 着陸シーケンス状態の完全リセット
    state.phase = "IDLE"
    state.phase_start_time = 0
    state.target_location = nil
    state.land_attempt_count = 0
    state.last_land_attempt_time = 0
    state.rtl_start_time = 0
    
    -- BRTL制御関連の完全リセット
    state.brtl_total_distance = nil
    state.last_message_time = 0
    state.last_status_message = ""
    state.message_counter = 0
    
    -- デバッグログ【新規v6】
    if get_param_value("DEBUG") == 1 and (old_triggered or old_phase ~= "IDLE") then
        send_message(6, string.format("Reset: %s->IDLE T:%s->F", old_phase, 
                     old_triggered and "T" or "F"), true)
    end
    
    return true
end

-- ===== フライトモード監視関数【修正v6】 =====
local function check_flight_mode()
    if not vehicle or not vehicle.get_mode then
        return
    end
    
    state.last_mode = state.current_mode
    state.current_mode = vehicle:get_mode()
    
    -- Autoモードへの変更を検知【修正v6】
    if state.current_mode == MODE_AUTO and state.last_mode ~= MODE_AUTO then
        local current_time = get_time_seconds()
        state.auto_mode_entry_count = state.auto_mode_entry_count + 1
        state.last_auto_entry_time = current_time
        state.auto_mode_active = true
        
        -- 完全状態リセット実行【重要修正v6】
        complete_brtl_reset(string.format("Auto entry #%d", state.auto_mode_entry_count))
        
        send_message(4, string.format("Auto mode entry #%d - BRTL armed", 
                     state.auto_mode_entry_count), true)
        
    -- Autoモードから他のモードへの変更を検知【修正v6】
    elseif state.current_mode ~= MODE_AUTO and state.last_mode == MODE_AUTO then
        state.auto_mode_active = false
        
        -- Auto退出時の状態報告【新規v6】
        local auto_duration = get_time_seconds() - state.last_auto_entry_time
        send_message(4, string.format("Auto mode exit after %.0fs - BRTL disarmed", 
                     auto_duration), true)
        
        -- ユーザーによる手動Guidedモード検知
        if state.current_mode == MODE_GUIDED and not state.brtl_guided_mode then
            send_message(4, "User manual GUIDED - BRTL disabled", true)
            complete_brtl_reset("Manual GUIDED entry")
        end
        
    -- Auto以外のモードでの動作
    elseif state.current_mode ~= MODE_AUTO then
        state.auto_mode_active = false
    end
    
    -- BRTLが発動したGuidedモードから他のモードに変更された場合【修正v6】
    if state.brtl_guided_mode and state.current_mode ~= MODE_GUIDED then
        if state.current_mode == MODE_RTL then
            send_message(3, "BRTL: Switched to RTL mode", true)
            state.phase = "RTL_MODE"
            state.phase_start_time = get_time_seconds()
            state.rtl_start_time = state.phase_start_time
            state.brtl_guided_mode = false  -- RTL移行時にGuidedモード解除
        elseif state.current_mode == MODE_LAND then
            send_message(3, "BRTL: Successfully switched to LAND", true)
            state.phase = "LANDING"
            state.phase_start_time = get_time_seconds()
        else
            send_message(4, "BRTL: Mode changed - system reset", true)
            complete_brtl_reset("Unexpected mode change")
        end
    end
end

-- ===== 位置・高度取得関数 =====
local function get_relative_altitude()
    if not ahrs or not ahrs.get_location or not ahrs.get_home then
        return nil
    end
    
    local current_location = ahrs:get_location()
    local home_location = ahrs:get_home()
    
    if not (current_location and home_location) then
        return nil
    end
    
    local current_alt_m = current_location:alt() * 0.01
    local home_alt_m = home_location:alt() * 0.01
    
    return current_alt_m - home_alt_m
end

local function get_distance_to_home()
    if not ahrs or not ahrs.get_home or not ahrs.get_location then
        return nil
    end
    
    local home = ahrs:get_home()
    local current_location = ahrs:get_location()
    return (home and current_location) and home:get_distance(current_location) or nil
end

-- ===== バッテリー残量取得関数 =====
local function get_battery_percentage()
    if not battery then
        return nil
    end
    
    local battery_instance = 0
    
    if battery.remaining_pct then
        local battery_pct = battery:remaining_pct(battery_instance)
        if battery_pct and battery_pct >= 0 and battery_pct <= 100 then
            return battery_pct
        end
    end
    
    if battery.pack_capacity_mah and battery.consumed_mah then
        local total_capacity = battery:pack_capacity_mah(battery_instance)
        local consumed = battery:consumed_mah(battery_instance)
        if total_capacity and consumed and total_capacity > 0 then
            return math.max(0, math.min(100, ((total_capacity - consumed) / total_capacity) * 100))
        end
    end
    
    return nil
end

-- ===== 着陸状態チェック関数 =====
local function check_landed_status()
    local current_altitude = get_relative_altitude()
    local is_armed = arming and arming.is_armed and arming:is_armed()
    
    if current_altitude and current_altitude < 3 and not is_armed then
        return true
    end
    
    if state.current_mode == MODE_LAND and current_altitude and current_altitude < 5 then
        return true
    end
    
    return false
end

-- ===== 目標位置作成関数 =====
local function create_home_target_location()
    local home_location = ahrs and ahrs.get_home and ahrs:get_home()
    if not home_location then
        return nil
    end
    
    -- ホームポイント上空の目標位置を作成
    local target_location = Location()
    target_location:lat(home_location:lat())
    target_location:lng(home_location:lng())
    
    -- 目標高度設定（ホームからの相対高度をcm単位で設定）
    local target_alt_m = get_param_value("TARGET_ALT")
    local home_alt_cm = home_location:alt()
    local target_alt_cm = home_alt_cm + (target_alt_m * 100)
    target_location:alt(target_alt_cm)
    
    return target_location
end

-- ===== ホーム到着判定関数 =====
local function check_home_arrival()
    local current_altitude = get_relative_altitude()
    local distance_to_home = get_distance_to_home()
    local target_altitude = get_param_value("TARGET_ALT")
    local arrive_distance = get_param_value("ARRIVE_DIST")
    local arrive_alt_diff = get_param_value("ARV_ALT_DIFF")
    
    if not (current_altitude and distance_to_home) then
        return false
    end
    
    -- 緩和された到着条件
    local distance_ok = distance_to_home <= arrive_distance
    local altitude_ok = math.abs(current_altitude - target_altitude) <= arrive_alt_diff
    
    return distance_ok and altitude_ok
end

-- ===== LANDモード切り替え関数 =====
local function attempt_land_mode()
    local current_time = get_time_seconds()
    local retry_delay = get_param_value("RETRY_DELAY")
    
    -- リトライ間隔チェック
    if current_time - state.last_land_attempt_time < retry_delay then
        return false
    end
    
    if not vehicle or not vehicle.set_mode then
        send_message(3, "BRTL: Vehicle API unavailable", true)
        return false
    end
    
    state.land_attempt_count = state.land_attempt_count + 1
    state.last_land_attempt_time = current_time
    
    local success = vehicle:set_mode(MODE_LAND)
    
    if success then
        send_message(3, string.format("BRTL: LAND mode success (attempt %d)", state.land_attempt_count), true)
        state.phase = "LANDING"
        state.phase_start_time = current_time
        state.brtl_guided_mode = false
        return true
    else
        send_message(3, string.format("BRTL: LAND mode failed (attempt %d)", state.land_attempt_count), true)
        
        -- 最大リトライ回数チェック
        if state.land_attempt_count >= 5 then
            send_message(3, "BRTL: Max LAND attempts reached - RTL fallback", true)
            vehicle:set_mode(MODE_RTL)
            state.phase = "DONE"
            return true  -- フォールバック成功
        end
        
        return false
    end
end

-- ===== RTLパラメータ設定関数 =====
local function configure_rtl_for_landing()
    if not param or not param.set then
        send_message(3, "BRTL: Cannot set RTL parameters", true)
        return false
    end
    
    -- RTL_ALT_FINALを0に設定して自動着陸を有効化
    param:set("RTL_ALT_FINAL", 0)
    
    -- RTL_LOIT_TIMEを設定（ミリ秒単位）
    local loit_time_ms = get_param_value("RTL_LOIT_SEC") * 1000
    param:set("RTL_LOIT_TIME", loit_time_ms)
    
    send_message(4, string.format("RTL config: Final=0 Loit=%ds", get_param_value("RTL_LOIT_SEC")), true)
    return true
end

-- ===== RTL着陸シーケンス =====
local function manage_rtl_landing_sequence()
    if state.landing_completed then
        return true
    end
    
    local current_time = get_time_seconds()
    local distance_to_home = get_distance_to_home()
    local current_altitude = get_relative_altitude()
    
    if not (distance_to_home and current_altitude) then
        return false
    end
    
    -- フェーズ別処理
    if state.phase == "IDLE" then
        -- アプローチフェーズ開始
        state.target_location = create_home_target_location()
        if state.target_location and vehicle and vehicle.set_target_location then
            local success = vehicle:set_target_location(state.target_location)
            if success then
                state.phase = "APPROACH"
                state.phase_start_time = current_time
                send_message(3, string.format("BRTL: Approaching home alt %.0fm", get_param_value("TARGET_ALT")), true)
            else
                send_message(3, "BRTL: Failed to set target - RTL fallback", true)
                if vehicle.set_mode then
                    configure_rtl_for_landing()
                    vehicle:set_mode(MODE_RTL)
                    state.phase = "RTL_MODE"
                    state.rtl_start_time = current_time
                end
                return false
            end
        else
            send_message(3, "BRTL: Target creation failed - RTL fallback", true)
            if vehicle and vehicle.set_mode then
                configure_rtl_for_landing()
                vehicle:set_mode(MODE_RTL)
                state.phase = "RTL_MODE"
                state.rtl_start_time = current_time
            end
            return false
        end
        
    elseif state.phase == "APPROACH" then
        -- RTL切り替えポイントチェック
        local rtl_dist = get_param_value("RTL_DIST")
        if distance_to_home <= rtl_dist then
            -- RTLパラメータ設定とモード切り替え
            if configure_rtl_for_landing() and vehicle and vehicle.set_mode then
                local success = vehicle:set_mode(MODE_RTL)
                if success then
                    state.phase = "RTL_MODE"
                    state.phase_start_time = current_time
                    state.rtl_start_time = current_time
                    state.brtl_guided_mode = false
                    send_message(3, string.format("BRTL: RTL mode at D%.1fm A%.1fm", 
                                 distance_to_home, current_altitude), true)
                else
                    send_message(3, "BRTL: RTL mode failed - continue approach", true)
                end
            end
        elseif check_home_arrival() then
            state.phase = "ARRIVED"
            state.phase_start_time = current_time
            send_message(3, "BRTL: HOME ARRIVED - Start hover", true)
        else
            -- アプローチタイムアウトチェック
            if current_time - state.phase_start_time > 60 then
                send_message(3, "BRTL: Approach timeout - RTL fallback", true)
                if configure_rtl_for_landing() and vehicle and vehicle.set_mode then
                    vehicle:set_mode(MODE_RTL)
                    state.phase = "RTL_MODE"
                    state.rtl_start_time = current_time
                end
                return false
            end
            
            -- 定期的な位置報告
            if (current_time - state.phase_start_time) % 10 == 0 then
                send_message(4, string.format("BRTL: Approaching D%.1fm A%.1fm", 
                             distance_to_home, current_altitude), true)
            end
        end
        
    elseif state.phase == "RTL_MODE" then
        -- RTLモード実行中の監視
        if state.current_mode == MODE_RTL then
            local rtl_duration = current_time - state.rtl_start_time
            local loit_time = get_param_value("RTL_LOIT_SEC")
            
            -- RTL自動着陸の進行監視
            if distance_to_home <= 5 then
                if rtl_duration >= loit_time then
                    -- RTL_LOIT_TIME経過後は自動着陸が開始されるはず
                    if current_altitude <= 10 then
                        send_message(3, "BRTL: RTL auto-landing in progress", true)
                        state.phase = "LANDING"
                        state.phase_start_time = current_time
                    else
                        -- 自動着陸が開始されない場合、手動でLANDモードに切り替え
                        if attempt_land_mode() then
                            send_message(3, "BRTL: Manual LAND after RTL timeout", true)
                        end
                    end
                else
                    -- ホバリング状況報告
                    send_message(4, string.format("BRTL-RTL: Hovering %.0fs/%.0fs", 
                                 rtl_duration, loit_time), true)
                end
            else
                -- RTL進行状況報告
                if (current_time - state.phase_start_time) % 5 == 0 then
                    send_message(4, string.format("BRTL-RTL: D%.1fm A%.1fm", 
                                 distance_to_home, current_altitude), true)
                end
            end
            
            -- RTL全体タイムアウトチェック
            if current_time - state.phase_start_time > 90 then
                send_message(3, "BRTL: RTL timeout - force LAND", true)
                if attempt_land_mode() then
                    send_message(3, "BRTL: Emergency LAND after RTL timeout", true)
                end
            end
        else
            -- RTLモードから外れた場合の処理（LANDに移行した可能性）
            if state.current_mode == MODE_LAND then
                send_message(3, "BRTL: RTL auto-transitioned to LAND", true)
                state.phase = "LANDING"
                state.phase_start_time = current_time
            else
                send_message(4, "BRTL: Exited RTL mode unexpectedly", true)
                state.phase = "HOVER"  -- 既存の処理に戻す
            end
        end
        
    elseif state.phase == "ARRIVED" then
        -- ホバリングフェーズ
        local hover_duration = current_time - state.phase_start_time
        local required_hover_time = get_param_value("HOVER_TIME")
        
        if hover_duration >= required_hover_time then
            state.phase = "HOVER"
            state.phase_start_time = current_time
            send_message(3, "BRTL: Hover complete - Attempting LAND", true)
        else
            -- ホバリング状況報告
            if math.floor(hover_duration) % 1 == 0 then
                send_message(4, string.format("BRTL: Hovering %.0fs/%.0fs", 
                             hover_duration, required_hover_time), true)
            end
        end
        
    elseif state.phase == "HOVER" then
        -- LANDモード切り替え試行
        if attempt_land_mode() then
            -- 成功またはフォールバック完了
            return true
        else
            -- タイムアウトチェック
            local land_timeout = get_param_value("LAND_TIMEOUT")
            if current_time - state.phase_start_time > land_timeout then
                send_message(3, "BRTL: LAND timeout - RTL fallback", true)
                if configure_rtl_for_landing() and vehicle and vehicle.set_mode then
                    vehicle:set_mode(MODE_RTL)
                    state.phase = "RTL_MODE"
                    state.rtl_start_time = current_time
                end
                return true
            end
        end
        
    elseif state.phase == "LANDING" then
        -- 着陸完了チェック
        if check_landed_status() then
            send_message(3, "BRTL: Landing completed successfully", true)
            state.landing_completed = true
            state.phase = "DONE"
            return true
        end
        
        -- 着陸タイムアウトチェック
        if current_time - state.phase_start_time > 60 then
            send_message(3, "BRTL: Landing timeout - may need manual intervention", true)
            state.landing_completed = true
            state.phase = "DONE"
            return true
        end
    end
    
    return false
end

-- ===== 制御関数 =====
local function set_descent_parameters()
    if not (param and param.set) then
        return false
    end
    
    local descent_cm_s = get_param_value("DESC_RATE")
    param:set("WPNAV_SPEED_DN", descent_cm_s)
    param:set("LAND_SPEED", descent_cm_s)
    param:set("WPNAV_SPEED", get_param_value("MAX_H_SPEED") * 100)
    
    -- RTL基本パラメータ設定
    param:set("RTL_ALT", get_param_value("TARGET_ALT") * 100)
    
    send_message(4, string.format("Flight params set: %.1fm/s", descent_cm_s * 0.01), true)
    return true
end

-- ===== BRTL制御 =====
local function manage_rtl_brtl_control()
    if not state.brtl_triggered or get_param_value("ENABLE") == 0 then
       return
   end
   
   -- RTL着陸シーケンス実行
   manage_rtl_landing_sequence()
   
   -- 着陸完了チェック
   if check_landed_status() then
       if not state.landing_completed then
           send_message(3, "BRTL: Landing completed", true)
           state.landing_completed = true
           state.phase = "DONE"
       end
       return
   end
end

-- ===== バッテリー状態判定関数 =====
local function get_battery_status(battery_remaining, threshold)
   local warn_threshold = threshold + 10  -- 閾値の10%前
   
   if battery_remaining < threshold then
       return "CRIT"
   elseif battery_remaining < warn_threshold then
       return "WARN"
   else
       return "Normal"
   end
end

-- ===== HUD表示関数（修正版v6） =====
local function update_hud_display(battery_remaining)
   local threshold = get_param_value("THRESHOLD")
   
   if not state.auto_mode_active and not state.brtl_triggered then
       local current_time = get_time_seconds()
       if current_time - state.last_hud_message_time >= 30 then
           local standby_msg = string.format("BRTL: Standby %.1f%% (T:%.1f%%) #%d", 
                              battery_remaining or 0, threshold, state.auto_mode_entry_count)
           send_message(6, standby_msg, false)
           state.last_hud_message_time = current_time
       end
       return
   end
   
   local current_time = get_time_seconds()
   local message_interval = get_param_value("MSG_INTRVL")
   
   if current_time - state.last_hud_message_time < message_interval then
       return
   end
   
   local status_msg, severity
   local current_alt = get_relative_altitude() or 0
   local distance = get_distance_to_home() or 0
   
   state.message_counter = state.message_counter + 1
   
   if state.phase == "DONE" or state.landing_completed then
       status_msg = string.format("[%d] BRTL Complete #%d", 
                                state.message_counter, state.auto_mode_entry_count)
       severity = 4
   elseif state.current_mode == MODE_LAND then
       status_msg = string.format("[%d] BRTL-LAND: %.1fm", state.message_counter, current_alt)
       severity = 3
   elseif state.phase == "LANDING" then
       status_msg = string.format("[%d] BRTL-LANDING", state.message_counter)
       severity = 3
   elseif state.phase == "RTL_MODE" then
       local rtl_duration = current_time - state.rtl_start_time
       status_msg = string.format("[%d] BRTL-RTL: D%.0f %.0fs", 
                                state.message_counter, distance, rtl_duration)
       severity = 3
   elseif state.phase == "HOVER" then
       status_msg = string.format("[%d] BRTL-HOVER: Try%d", state.message_counter, state.land_attempt_count)
       severity = 3
   elseif state.phase == "ARRIVED" then
       local hover_time = current_time - state.phase_start_time
       local required_time = get_param_value("HOVER_TIME")
       status_msg = string.format("[%d] BRTL-WAIT: %.0fs/%.0fs", 
                                state.message_counter, hover_time, required_time)
       severity = 3
   elseif state.phase == "APPROACH" then
       status_msg = string.format("[%d] BRTL-RTH: D%.0f A%.0f", 
                                state.message_counter, distance, current_alt)
       severity = 3
   elseif state.brtl_triggered and (state.brtl_guided_mode or state.current_mode == MODE_RTL) then
       status_msg = string.format("[%d] BRTL-ACTIVE: %.1f%% (T:%.1f%%)", 
                                state.message_counter, battery_remaining, threshold)
       severity = 3
   elseif battery_remaining < threshold then
       status_msg = string.format("[%d] AUTO CRIT: %.1f%% (T:%.1f%%)", 
                                state.message_counter, battery_remaining, threshold)
       severity = 4
   else
       -- バッテリー状態判定
       local battery_status = get_battery_status(battery_remaining, threshold)
       if battery_status == "WARN" then
           status_msg = string.format("[%d] AUTO WARN: %.1f%% (T:%.1f%%)", 
                                    state.message_counter, battery_remaining, threshold)
           severity = 4  -- 警告レベル
       else
           status_msg = string.format("[%d] AUTO Normal: %.1f%% (T:%.1f%%)", 
                                    state.message_counter, battery_remaining, threshold)
           severity = 6
       end
   end
   
   local force_send = (status_msg ~= state.last_status_message)
   send_message(severity, status_msg, force_send)
   
   state.last_status_message = status_msg
   state.last_hud_message_time = current_time
end

-- ===== BRTL発動処理 =====
local function trigger_brtl()
   send_message(3, "BRTL: Triggering emergency return", true)
   
   -- 初期距離計算
   local distance_to_home = get_distance_to_home()
   if distance_to_home then
       state.brtl_total_distance = distance_to_home
       send_message(2, string.format("BRTL: Distance to home %.0fm", distance_to_home), true)
   end
   
   -- Guidedモードへの切り替えを試行
   if vehicle and vehicle.set_mode then
       local success = vehicle:set_mode(MODE_GUIDED)
       if success then
           state.brtl_guided_mode = true
           state.phase = "IDLE"
           state.phase_start_time = get_time_seconds()
           send_message(3, "BRTL: GUIDED mode activated", true)
       else
           send_message(3, "BRTL: GUIDED failed - RTL fallback", true)
           if configure_rtl_for_landing() then
               vehicle:set_mode(MODE_RTL)
               state.brtl_triggered = true
               state.brtl_guided_mode = false
               state.phase = "RTL_MODE"
               state.rtl_start_time = get_time_seconds()
           end
           return
       end
   else
       send_message(3, "BRTL: Vehicle API unavailable", true)
       return
   end
   
   state.brtl_triggered = true
   send_message(3, "BRTL: RTL-enhanced landing sequence started", true)
end

-- ===== メイン更新関数（修正版v6） =====
function update()
   -- パラメータ初期化
   if not state.params_initialized then
       if add_custom_params() and init_parameter_objects() then
           state.params_initialized = true
           send_message(4, "Parameters ready (state-reset v6)", true)
       else
           return update, 5000
       end
   end
   
   -- システム有効性チェック
   if get_param_value("ENABLE") == 0 then
       return update, 5000
   end
   
   -- パラメータ妥当性チェック
   if not validate_parameters() then
       send_message(3, "BRTL: Invalid param values - check ranges", true)
       return update, 10000
   end
   
   -- フライトモード監視【重要v6】
   check_flight_mode()
   
   -- スクリプト初期化
   if not state.script_initialized then
      state.init_counter = state.init_counter + 1
      if state.init_counter >= 3 then
          set_descent_parameters()
          send_message(4, string.format("%s Ready - State Reset Control", SCRIPT_NAME), true)
          send_message(4, "Auto mode detection with complete state reset", true)
          send_message(4, "Sequence: GUIDED->APPROACH->RTL->AUTO_LAND", true)
          
          -- パラメータ情報表示v6
          local arrive_dist = get_param_value("ARRIVE_DIST")
          local arrive_alt = get_param_value("ARV_ALT_DIFF")
          local hover_time = get_param_value("HOVER_TIME")
          local land_timeout = get_param_value("LAND_TIMEOUT")
          local rtl_dist = get_param_value("RTL_DIST")
          local rtl_loit = get_param_value("RTL_LOIT_SEC")
          local threshold = get_param_value("THRESHOLD")
          
          send_message(4, string.format("Arrive: d<=%.0fm alt±%.0fm", arrive_dist, arrive_alt), true)
          send_message(4, string.format("Hover: %.0fs timeout: %.0fs", hover_time, land_timeout), true)
          send_message(4, string.format("RTL: trigger=%.0fm loit=%.0fs", rtl_dist, rtl_loit), true)
          send_message(4, string.format("Battery: %.0f%% threshold, WARN at %.0f%%", 
                       threshold, threshold + 10), true)
          send_message(4, "Auto re-entry triggers complete state reset", true)
          
          -- バッテリーAPI診断
          local battery_pct = get_battery_percentage()
          if battery_pct then
              send_message(4, string.format("Battery API working: %.1f%%", battery_pct), true)
          else
              send_message(3, "Battery API failed - check setup", true)
          end
          
          state.script_initialized = true
          state.last_hud_message_time = get_time_seconds()
      end
      return update, 1000
  end
  
  -- バッテリー残量取得
  local battery_remaining = get_battery_percentage()
  if not battery_remaining then
      if state.auto_mode_active or state.brtl_triggered then
          send_message(6, "AUTO/BRTL: Battery data unavailable", false)
      end
      return update, 1000
  end
  
  -- HUD表示更新
  update_hud_display(battery_remaining)
  
  -- BRTL制御の実行判定
  local brtl_control_active = state.auto_mode_active or state.brtl_triggered
  
  if brtl_control_active then
      -- RTL修正BRTL制御
      manage_rtl_brtl_control()
      
      -- BRTL発動判定
      local threshold = get_param_value("THRESHOLD")
      
      -- デバッグメッセージv6【Auto入場回数追加】
      if get_param_value("DEBUG") == 1 then
          local current_time = get_time_seconds()
          if current_time - state.last_debug_time > 8 then
              local mode_name = "UNK"
              if state.current_mode == MODE_AUTO then
                  mode_name = "AUTO"
              elseif state.current_mode == MODE_GUIDED then
                  mode_name = state.brtl_guided_mode and "BRTL-GU" or "USR-GU"
              elseif state.current_mode == MODE_RTL then
                  mode_name = state.brtl_triggered and "BRTL-RTL" or "RTL"
              elseif state.current_mode == MODE_LAND then
                  mode_name = "LAND"
              else
                  mode_name = "OTHER"
              end
              
              local distance = get_distance_to_home() or 0
              local battery_status = get_battery_status(battery_remaining, threshold)
              
              send_message(6, string.format("BRTL-DBG: %s %.1f%% %s D%.0fm %s #%d", 
                           mode_name, battery_remaining, battery_status, distance, 
                           state.phase, state.auto_mode_entry_count), true)
              state.last_debug_time = current_time
          end
      end
      
      -- バッテリー残量がAutoモード時の閾値を下回った場合のみBRTL発動
      if battery_remaining < threshold and not state.brtl_triggered and state.auto_mode_active then
          send_message(3, string.format("AUTO CRIT: %.1f%% < %.1f%% - BRTL!", 
                       battery_remaining, threshold), true)
          trigger_brtl()
      elseif battery_remaining >= threshold + 5 and state.brtl_triggered and state.phase == "IDLE" then
          -- 5%のヒステリシス追加（まだアプローチ開始前の場合のみ）
          send_message(4, string.format("AUTO RECOV: %.1f%% - BRTL cancelled", 
                       battery_remaining), true)
          complete_brtl_reset("Battery recovery")
      end
  else
      -- 通常のユーザーGuidedモードでは何もしない
      if state.current_mode == MODE_GUIDED and get_param_value("DEBUG") == 1 then
          local current_time = get_time_seconds()
          if current_time - state.last_debug_time > 30 then
              send_message(6, "Manual GUIDED mode - BRTL inactive", false)
              state.last_debug_time = current_time
          end
      end
  end
  
  state.init_counter = state.init_counter + 1
  return update, 1000
end

-- スクリプト開始
return update, 1000