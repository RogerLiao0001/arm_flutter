#!/usr/bin/env python3
# leap_mqtt_bridge_v12.py (IK Publisher with Adaptive Precision)
#
# 用法：
#   pip install paho-mqtt
#   python leap_mqtt_bridge_v12.py
#
# 鍵盤控制 (單鍵觸發，不需 Enter):
#   a  -> 設定當前位置為原點 (歸零Leap Motion參考點)
#   r  -> 將手臂重置到預設初始位置
#   s  -> 暫停 / 恢復 (toggle)
#   q  -> 退出程式
#
# MQTT 遠端控制 (topic: servo/arm2/cmd)
#   發送 payload "zero" / "reset" / "pause" / "resume" / "stop"

import leap, time, json, threading, sys, signal, math
import paho.mqtt.client as mqtt
import termios, tty

# ============================
# ========== CONFIG ==========
# ============================

# ---------- 1. 位置映射與軸向定義 (與Flutter App完全同步) ----------
POSITION_MAPPING = { #input_mm數值越小動越快
    'x': {'input_mm': 100, 'output_min': 70,   'output_max': 400,  'output_zero': 150},
    'y': {'input_mm': 100, 'output_min': -300, 'output_max': 300,  'output_zero': 0},
    'z': {'input_mm': 100, 'output_min': 30,  'output_max': 350,  'output_zero': 150},
}
POSITION_AXIS_MAPPING = { 'y': 'x', 'x': 'z', 'z': 'y' }
INVERT_X = False
INVERT_Y = False
INVERT_Z = False

# ---------- 2. 旋轉範圍與軸向定義 (Leap Motion讀取的是角度) ----------
ROTATION_MAPPING = {
    
    'rx': {'output_val': (-180, 180)},
    'ry': {'output_val': (-180, 180)},
    'rz': {'output_val': (-180, 180)},
    #'rx': {'output_val': (0, 0)},
    #'ry': {'output_val': (0, 0)},
    #'rz': {'output_val': (0, 0)},
}
ROTATION_AXIS_MAPPING = { 'ry': 'roll', 'rx': 'yaw', 'rz': 'pitch' }
INVERT_RX = True
INVERT_RY = True
INVERT_RZ = False

# ---------- 3. 輸出過濾與頻率 ----------
MIN_CHANGE_TO_PUBLISH = { 'pos': 1, 'rot': 2 }
PUBLISH_FPS = 5

# ---------- 4. MQTT 設定 ----------
MQTT_BROKER = "178.128.54.195"
MQTT_PORT = 1883
TOPIC_BASE = "servo/arm2/"
MQTT_CONTROL_TOPIC = TOPIC_BASE + "cmd"
TOPIC_IK_POSE = TOPIC_BASE + "ik"
TOPIC_CLAW = TOPIC_BASE + "clm"

# ---------- 5. 手臂重置狀態 (按下 'r' 鍵時的目標姿態) ----------
IK_RESET_STATE = {
    'x': 150, 'y': 0, 'z': 150,
    'rx': 0.0,
    'ry': math.pi, # 3.14 radians, 對應180度 (手掌朝下的姿態)
    'rz': 0.0
}

# ---------- 6. 其他功能開關 ----------
START_PUBLISH_AFTER_ZERO = True
LOG_PUBLISHES = True
IK_CLM_DELAY_MS = 50
CLM_RESEND_COUNT = 3
GRAB_SMOOTHING_FACTOR = 0.4
RY_LOCK_THRESHOLD = -360.0 # 單位為度，因為它直接與Leap Motion的輸出比較

# =======================================================
#      REMOVED: All local IK calculation logic
# =======================================================

# ---------------- init MQTT ----------------
client = mqtt.Client()
def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print(f"Connected to MQTT broker {MQTT_BROKER}:{MQTT_PORT}")
        client.subscribe(MQTT_CONTROL_TOPIC)
    else:
        print("MQTT connect failed with rc:", rc)
client.on_connect = on_connect

def on_message(client, userdata, msg):
    payload = msg.payload.decode('utf-8').strip().lower()
    print("MQTT control received:", payload)
    if payload == "zero": do_zero_command()
    elif payload == "reset": do_reset_command()
    elif payload == "pause": do_pause_command()
    elif payload == "resume": do_resume_command()
    elif payload == "stop": do_stop_command()
client.on_message = on_message
client.connect(MQTT_BROKER, MQTT_PORT, 60)
client.loop_start()

# ---------------- state ----------------
zero_ref_pos = {}
# --- MODIFIED: 新增旋轉校準相關的全域變數 ---
rot_offset_deg = {'rx': 0.0, 'ry': 0.0, 'rz': 0.0}
last_right_hand_raw_pos = {}
last_right_hand_raw_rot_deg = {}
# --- END MODIFIED ---

enabled = not START_PUBLISH_AFTER_ZERO; paused = False; running = True
last_publish_time = 0.0; last_published_ik_pos = None; last_published_ik_rot = None; last_sent_h = None
claw_resend_counter = 0
lock = threading.Lock()
smoothed_grab_strength = 0.0

# ---------------- helper functions ----------------
def getch():
    fd = sys.stdin.fileno(); old = termios.tcgetattr(fd)
    try: tty.setcbreak(fd); ch = sys.stdin.read(1)
    finally: termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return ch

def clamp(v, lo, hi): return max(lo, min(hi, v))

def map_asymmetric_position(rel_val, config):
    input_max = config['input_mm']
    out_min, out_max, out_zero = config['output_min'], config['output_max'], config['output_zero']
    if input_max == 0: return out_zero
    ratio = rel_val / input_max if rel_val >= 0 else rel_val / -input_max
    mapped_val = out_zero + ratio * (out_max - out_zero) if rel_val >= 0 else out_zero - ratio * (out_zero - out_min)
    return clamp(mapped_val, out_min, out_max)

def quantize(value, step):
    if step <= 0: return int(value)
    return int(round(value / step) * step)

# ---------------- control action handlers ----------------

# =========================================================================
# --- *** CORE FIX: New function for adaptive precision payload creation *** ---
# =========================================================================
def create_adaptive_ik_payload(pos_dict, rot_rad_dict):
    """Creates an IK payload string, adaptively reducing precision to fit under 32 bytes."""
    x, y, z = pos_dict['x'], pos_dict['y'], pos_dict['z']
    rx_rad, ry_rad, rz_rad = rot_rad_dict['rx'], rot_rad_dict['ry'], rot_rad_dict['rz']
    
    # Try with 2 decimal places
    payload = f"IK {x} {y} {z} {rx_rad:.2f} {ry_rad:.2f} {rz_rad:.2f}"
    if len(payload) <= 32:
        return payload, 2

    # If too long, try with 1 decimal place
    payload = f"IK {x} {y} {z} {rx_rad:.1f} {ry_rad:.1f} {rz_rad:.1f}"
    if len(payload) <= 32:
        return payload, 1
    
    # If still too long, use integers (0 decimal places)
    payload = f"IK {x} {y} {z} {round(rx_rad)} {round(ry_rad)} {round(rz_rad)}"

    # Final safety truncation, although very unlikely to be needed now
    if len(payload) > 32:
        print(f"!!! CRITICAL WARNING: Payload '{payload}' ({len(payload)} bytes) exceeded 32 and was TRUNCATED.")
        return payload[:32], -1 # Use -1 to indicate truncation
        
    return payload, 0

# --- MODIFIED: 大幅修改歸零函式，增加旋轉校準 ---
def do_zero_command():
    """設定Leap Motion的相對運動原點，並校準旋轉以符合預期"""
    global zero_ref_pos, rot_offset_deg, enabled, paused
    global last_published_ik_pos, last_published_ik_rot, smoothed_grab_strength

    # 定義歸零時的目標旋轉角度 (手掌朝下)
    # rx, rz 為 0, ry 為 180 度
    ZERO_TARGET_ROT_DEG = {'rx': 0.0, 'ry': 180.0, 'rz': 0.0}

    with lock:
        if last_right_hand_raw_pos and last_right_hand_raw_rot_deg:
            # 1. 位置歸零 (邏輯不變)
            zero_ref_pos = last_right_hand_raw_pos.copy()

            # 2. 旋轉校準 (全新邏輯)
            # 取得當前經過軸向映射和反轉後的絕對角度
            current_rot_mapped = {ik_axis: last_right_hand_raw_rot_deg[leap_axis] for ik_axis, leap_axis in ROTATION_AXIS_MAPPING.items()}
            if INVERT_RX: current_rot_mapped['rx'] *= -1
            if INVERT_RY: current_rot_mapped['ry'] *= -1
            if INVERT_RZ: current_rot_mapped['rz'] *= -1
            
            # 計算校準偏移量: 偏移量 = 目標值 - 當前值
            for axis in ['rx', 'ry', 'rz']:
                rot_offset_deg[axis] = ZERO_TARGET_ROT_DEG[axis] - current_rot_mapped[axis]

            # 3. 重置狀態
            enabled = True; paused = False
            last_published_ik_pos = None; last_published_ik_rot = None
            smoothed_grab_strength = 0.0
            
            print(f"\nPosition zero reference set to: { {k: round(v, 2) for k, v in zero_ref_pos.items()} }.")
            print(f"Rotation offset calculated (deg): { {k: round(v, 2) for k, v in rot_offset_deg.items()} }.")
        else:
            print("\nZero command failed: no hand detected.")
# --- END MODIFIED ---


def do_reset_command():
    """發送指令將手臂重置到預設位置"""
    print("\nResetting arm to default position.")
    # 從IK_RESET_STATE中分離位置和旋轉(弧度)
    pos = {k: v for k, v in IK_RESET_STATE.items() if k in ['x', 'y', 'z']}
    rot_rad = {k: v for k, v in IK_RESET_STATE.items() if k in ['rx', 'ry', 'rz']}
    
    # 使用自適應函式產生payload
    payload, precision = create_adaptive_ik_payload(pos, rot_rad)
    
    client.publish(TOPIC_IK_POSE, payload)
    # 同時重置手爪
    client.publish(TOPIC_CLAW, f"clm 180")
    print(f"Published Reset (P:{precision}): {payload}")


def do_pause_command(): global paused; paused = True; print("\nPaused")
def do_resume_command(): global paused, enabled; paused = False; enabled = True; print("\nResumed")
def do_stop_command(): global running; running = False; print("\nStop command received")

def keyboard_thread():
    global paused, running
    print("Keyboard: 'a' to zero, 'r' to reset arm, 's' to pause/resume, 'q' to quit.")
    while running:
        try:
            cmd = getch().lower()
            if cmd == 'a': do_zero_command()
            elif cmd == 'r': do_reset_command()
            elif cmd == 's':
                paused = not paused; print("\nPaused" if paused else "\nResumed")
            elif cmd == 'q':
                print("\nQuit command received."); running = False; break
        except Exception: break

# ---------------- Leap listener ----------------
class BridgeListener(leap.Listener):
    def on_connection_event(self, event): print("Connected to Leap service")
    def on_device_event(self, event): print("Found device", event.device.get_info().serial)

    def on_tracking_event(self, event):
        global last_right_hand_raw_pos, last_right_hand_raw_rot_deg, last_publish_time
        global last_published_ik_pos, last_published_ik_rot, last_sent_h, claw_resend_counter
        global smoothed_grab_strength
        if not running or len(event.hands) == 0: return

        hand = next((h for h in event.hands if str(h.type).endswith("Right")), event.hands[0])

        try:
            pos = hand.palm.position
            raw_pos = {'x': float(pos.x), 'y': float(pos.y), 'z': float(pos.z)}
            q = hand.palm.orientation
            raw_angles = {
                'roll': math.degrees(math.atan2(2*(q.w*q.x + q.y*q.z), 1 - 2*(q.x*q.x + q.y*q.y))),
                'pitch': math.degrees(math.asin(clamp(2*(q.w*q.y - q.z*q.x), -1.0, 1.0))),
                'yaw': math.degrees(math.atan2(2*(q.w*q.z + q.x*q.y), 1 - 2*(q.y*q.y + q.z*q.z)))
            }
            raw_grab = float(getattr(hand, "grab_strength", 0.0))
        except Exception as e:
            print("Error reading hand data:", e); return

        # --- MODIFIED: 同時更新位置和旋轉的原始數據 ---
        with lock:
            last_right_hand_raw_pos = raw_pos
            last_right_hand_raw_rot_deg = raw_angles
        # --- END MODIFIED ---


        if not enabled or paused or not zero_ref_pos: return
        now = time.time()
        if now - last_publish_time < 1.0 / PUBLISH_FPS: return
        last_publish_time = now

        # --- 數據處理 (位置部分) ---
        rel_pos_raw = { axis: raw_pos[axis] - zero_ref_pos.get(axis, 0) for axis in ['x', 'y', 'z'] }
        rel_pos_mapped = { ik_axis: rel_pos_raw[leap_axis] for ik_axis, leap_axis in POSITION_AXIS_MAPPING.items() }
        if INVERT_X: rel_pos_mapped['x'] *= -1
        if INVERT_Y: rel_pos_mapped['y'] *= -1
        if INVERT_Z: rel_pos_mapped['z'] *= -1
        pos_out = { axis: quantize(map_asymmetric_position(val, POSITION_MAPPING[axis]), MIN_CHANGE_TO_PUBLISH['pos']) for axis, val in rel_pos_mapped.items() }

        # --- 數據處理 (旋轉部分，保持為角度用於比較) ---
        # 1. 取得絕對角度並做軸向映射與反轉
        abs_rot_mapped = { ik_axis: raw_angles[leap_axis] for ik_axis, leap_axis in ROTATION_AXIS_MAPPING.items() }
        if INVERT_RX: abs_rot_mapped['rx'] *= -1
        if INVERT_RY: abs_rot_mapped['ry'] *= -1
        if INVERT_RZ: abs_rot_mapped['rz'] *= -1
        
        # --- MODIFIED: 套用校準偏移量並正規化角度 ---
        # 2. 加上在歸零時計算出的偏移量
        offset_rot_deg = {axis: abs_rot_mapped[axis] + rot_offset_deg.get(axis, 0) for axis in ['rx', 'ry', 'rz']}

        # 3. 將角度正規化到 -180 ~ +180 的範圍內
        for axis in offset_rot_deg:
            angle = offset_rot_deg[axis]
            # (angle + 180) % 360 - 180 是一個標準的正規化公式
            offset_rot_deg[axis] = (angle + 180) % 360 - 180
        
        # 4. 使用校準和正規化後的角度進行後續處理
        rot_out_deg = { axis: quantize(clamp(val, ROTATION_MAPPING[axis]['output_val'][0], ROTATION_MAPPING[axis]['output_val'][1]), MIN_CHANGE_TO_PUBLISH['rot']) for axis, val in offset_rot_deg.items() }
        # --- END MODIFIED ---

        # --- 檢查狀態是否改變 ---
        current_ik_pos = (pos_out['x'], pos_out['y'], pos_out['z'])
        current_ik_rot_deg = (rot_out_deg['rx'], rot_out_deg['ry'], rot_out_deg['rz'])
        pos_changed = current_ik_pos != last_published_ik_pos
        rot_changed = current_ik_rot_deg != last_published_ik_rot

        # --- IK 指令發送邏輯 ---
        ik_payload = ""
        precision_log = ""
        if pos_changed or rot_changed:
            # 將最終的角度值轉換為弧度，準備發送
            rot_out_rad = {k: math.radians(v) for k, v in rot_out_deg.items()}
            
            # 使用自適應函式來產生payload
            ik_payload, precision = create_adaptive_ik_payload(pos_out, rot_out_rad)
            precision_log = f"(P:{precision})"
            
            client.publish(TOPIC_IK_POSE, ik_payload)
            last_published_ik_pos = current_ik_pos
            last_published_ik_rot = current_ik_rot_deg

        # --- 手爪平滑化與發送邏輯 ---
        claw_status_msg = ""
        if rot_out_deg['ry'] >= RY_LOCK_THRESHOLD:
            smoothed_grab_strength = (GRAB_SMOOTHING_FACTOR * raw_grab) + (1.0 - GRAB_SMOOTHING_FACTOR) * smoothed_grab_strength
        else:
            claw_status_msg = f"(ry < {RY_LOCK_THRESHOLD}, claw locked)"

        h_val = int(clamp(round((1.0 - smoothed_grab_strength) * 180.0), 0, 180))
        claw_changed = (h_val != last_sent_h)

        if claw_changed:
            claw_resend_counter = CLM_RESEND_COUNT
            last_sent_h = h_val

        claw_payload = ""
        should_send_claw = claw_resend_counter > 0

        if should_send_claw:
            if (pos_changed or rot_changed) and IK_CLM_DELAY_MS > 0:
                time.sleep(IK_CLM_DELAY_MS / 1000.0)
            claw_payload = f"clm {h_val}"
            client.publish(TOPIC_CLAW, claw_payload)
            claw_resend_counter -= 1
        
        # --- 日誌輸出 ---
        if LOG_PUBLISHES and (ik_payload or claw_payload):
            print("-" * 20)
            if ik_payload: print(f"Published IK {precision_log}: {ik_payload} ({len(ik_payload)} bytes)")
            if claw_payload: print(f"Published Claw: {claw_payload} {claw_status_msg}")

# ---------------- main ----------------
def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGTERM, signal.SIG_DFL)
    t = threading.Thread(target=keyboard_thread, daemon=True); t.start()
    listener = BridgeListener(); conn = leap.Connection(); conn.add_listener(listener)
    with conn.open():
        conn.set_tracking_mode(leap.TrackingMode.Desktop); print("Bridge running...")
        while running: time.sleep(0.1)
    client.loop_stop(); client.disconnect(); print("Bridge stopped. Bye.")

if __name__ == "__main__":
    main()