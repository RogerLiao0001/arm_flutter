#!/usr/bin/env python3
# roll_IK_smooth.py (High FPS + Smooth Filtering)
#
# 針對操作手感優化版本：
# 1. 提升至 30 FPS (流暢)
# 2. 加入 EMA (指數移動平均) 濾波算法 (消除手抖與過度靈敏)
# 3. 最佳化 MQTT 發送邏輯

import leap, time, json, threading, sys, signal, math
import paho.mqtt.client as mqtt
import termios, tty

# ============================ 
# ========== CONFIG ========== 
# ============================ 

# ---------- 1. 位置映射與軸向定義 (與Flutter App完全同步) ----------
POSITION_MAPPING = { # input_mm 數值越小動越快
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
}
ROTATION_AXIS_MAPPING = { 'ry': 'roll', 'rx': 'yaw', 'rz': 'pitch' }
INVERT_RX = True
INVERT_RY = True
INVERT_RZ = False

# ---------- 3. 平滑與頻率設定 (關鍵修改區) ----------
# PUBLISH_FPS: 建議 20~30，太高會塞爆頻寬，太低會延遲
PUBLISH_FPS = 30 

# MIN_CHANGE_TO_PUBLISH: 數值越小越精細，但雜訊越多。
# 原本 pos:1, rot:2。稍微調大一點點可以過濾極微小的抖動，但主要靠下方的 SMOOTH_FACTOR
MIN_CHANGE_TO_PUBLISH = { 'pos': 1, 'rot': 2 }

# SMOOTH_FACTOR (0.0 ~ 1.0): 
# 數值越小 = 越平滑 (延遲感稍增，手感重)
# 數值越大 = 越靈敏 (反應快，但易抖動)
# 建議值: 0.15 ~ 0.3 (0.2 是一個很好的平衡點)
SMOOTH_FACTOR_POS = 0.2  # 位置平滑係數
SMOOTH_FACTOR_ROT = 0.2  # 旋轉平滑係數

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
    'ry': math.pi, # 180度 (手掌朝下)
    'rz': 0.0
}

# ---------- 6. 其他功能開關 ----------
START_PUBLISH_AFTER_ZERO = True
LOG_PUBLISHES = True
IK_CLM_DELAY_MS = 10 # 降低延遲，原本 50ms 太久
CLM_RESEND_COUNT = 3
GRAB_SMOOTHING_FACTOR = 0.2 # 手爪也稍微平滑一點
RY_LOCK_THRESHOLD = -360.0 

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
rot_offset_deg = {'rx': 0.0, 'ry': 0.0, 'rz': 0.0}
last_right_hand_raw_pos = {}
last_right_hand_raw_rot_deg = {}

# 平滑化專用的變數 (儲存上一次的平滑值)
smoothed_pos = {'x': 0.0, 'y': 0.0, 'z': 0.0}
smoothed_rot = {'rx': 0.0, 'ry': 0.0, 'rz': 0.0}
is_first_frame = True # 用來初始化平滑值

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

def ema_filter(current, previous, alpha):
    """指數移動平均濾波器"""
    return (alpha * current) + ((1.0 - alpha) * previous)

# ---------------- control action handlers ----------------

def create_adaptive_ik_payload(pos_dict, rot_rad_dict):
    x, y, z = pos_dict['x'], pos_dict['y'], pos_dict['z']
    rx_rad, ry_rad, rz_rad = rot_rad_dict['rx'], rot_rad_dict['ry'], rot_rad_dict['rz']
    
    # Try with 2 decimal places
    payload = f"IK {x} {y} {z} {rx_rad:.2f} {ry_rad:.2f} {rz_rad:.2f}"
    if len(payload) <= 32: return payload, 2

    # If too long, try with 1 decimal place
    payload = f"IK {x} {y} {z} {rx_rad:.1f} {ry_rad:.1f} {rz_rad:.1f}"
    if len(payload) <= 32: return payload, 1
    
    # If still too long, use integers
    payload = f"IK {x} {y} {z} {round(rx_rad)} {round(ry_rad)} {round(rz_rad)}"
    if len(payload) > 32: return payload[:32], -1 
    return payload, 0

def do_zero_command():
    global zero_ref_pos, rot_offset_deg, enabled, paused
    global last_published_ik_pos, last_published_ik_rot, smoothed_grab_strength
    global smoothed_pos, smoothed_rot, is_first_frame

    ZERO_TARGET_ROT_DEG = {'rx': 0.0, 'ry': 180.0, 'rz': 0.0}

    with lock:
        if last_right_hand_raw_pos and last_right_hand_raw_rot_deg:
            # 1. 設定位置原點
            zero_ref_pos = last_right_hand_raw_pos.copy()

            # 2. 設定旋轉原點
            current_rot_mapped = {ik_axis: last_right_hand_raw_rot_deg[leap_axis] for ik_axis, leap_axis in ROTATION_AXIS_MAPPING.items()}
            if INVERT_RX: current_rot_mapped['rx'] *= -1
            if INVERT_RY: current_rot_mapped['ry'] *= -1
            if INVERT_RZ: current_rot_mapped['rz'] *= -1
            
            for axis in ['rx', 'ry', 'rz']:
                rot_offset_deg[axis] = ZERO_TARGET_ROT_DEG[axis] - current_rot_mapped[axis]

            # 3. 重置狀態與平滑器
            enabled = True; paused = False
            last_published_ik_pos = None; last_published_ik_rot = None
            smoothed_grab_strength = 0.0
            is_first_frame = True # 重置平滑器讓它重新抓取當前值，避免暴衝
            
            print(f"\n[OK] Zero Set. Pos: { {k: round(v, 2) for k, v in zero_ref_pos.items()} }.")
            print(f"[OK] Rot Offset: { {k: round(v, 2) for k, v in rot_offset_deg.items()} }.")
        else:
            print("\n[Error] Zero failed: No hand detected.")

def do_reset_command():
    print("\nResetting arm to default position.")
    pos = {k: v for k, v in IK_RESET_STATE.items() if k in ['x', 'y', 'z']}
    rot_rad = {k: v for k, v in IK_RESET_STATE.items() if k in ['rx', 'ry', 'rz']}
    payload, precision = create_adaptive_ik_payload(pos, rot_rad)
    client.publish(TOPIC_IK_POSE, payload)
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
                print("\nQuit."); running = False; break
        except Exception: break

# ---------------- Leap listener ----------------
class BridgeListener(leap.Listener):
    def on_connection_event(self, event): print("Connected to Leap service")
    def on_device_event(self, event): print("Found device", event.device.get_info().serial)

    def on_tracking_event(self, event):
        global last_right_hand_raw_pos, last_right_hand_raw_rot_deg, last_publish_time
        global last_published_ik_pos, last_published_ik_rot, last_sent_h, claw_resend_counter
        global smoothed_grab_strength, smoothed_pos, smoothed_rot, is_first_frame

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
            return

        # 更新原始數據 (用於歸零)
        with lock:
            last_right_hand_raw_pos = raw_pos
            last_right_hand_raw_rot_deg = raw_angles

        if not enabled or paused or not zero_ref_pos: return
        
        # 頻率控制 (Rate Limiting)
        now = time.time()
        if now - last_publish_time < 1.0 / PUBLISH_FPS: return
        last_publish_time = now

        # --- 1. 原始數據處理 ---
        rel_pos_raw = { axis: raw_pos[axis] - zero_ref_pos.get(axis, 0) for axis in ['x', 'y', 'z'] }
        rel_pos_mapped = { ik_axis: rel_pos_raw[leap_axis] for ik_axis, leap_axis in POSITION_AXIS_MAPPING.items() }
        if INVERT_X: rel_pos_mapped['x'] *= -1
        if INVERT_Y: rel_pos_mapped['y'] *= -1
        if INVERT_Z: rel_pos_mapped['z'] *= -1
        
        mapped_pos_val = { axis: map_asymmetric_position(val, POSITION_MAPPING[axis]) for axis, val in rel_pos_mapped.items() }

        abs_rot_mapped = { ik_axis: raw_angles[leap_axis] for ik_axis, leap_axis in ROTATION_AXIS_MAPPING.items() }
        if INVERT_RX: abs_rot_mapped['rx'] *= -1
        if INVERT_RY: abs_rot_mapped['ry'] *= -1
        if INVERT_RZ: abs_rot_mapped['rz'] *= -1

        offset_rot_deg = {axis: abs_rot_mapped[axis] + rot_offset_deg.get(axis, 0) for axis in ['rx', 'ry', 'rz']}
        for axis in offset_rot_deg:
            angle = offset_rot_deg[axis]
            offset_rot_deg[axis] = (angle + 180) % 360 - 180
        
        mapped_rot_val = { axis: clamp(val, ROTATION_MAPPING[axis]['output_val'][0], ROTATION_MAPPING[axis]['output_val'][1]) for axis, val in offset_rot_deg.items() }

        # --- 2. 平滑化處理 (EMA Smoothing) ---
        # 這一步是解決「太靈敏」的關鍵
        if is_first_frame:
            smoothed_pos = mapped_pos_val.copy()
            smoothed_rot = mapped_rot_val.copy()
            is_first_frame = False
        else:
            for k in smoothed_pos:
                smoothed_pos[k] = ema_filter(mapped_pos_val[k], smoothed_pos[k], SMOOTH_FACTOR_POS)
            for k in smoothed_rot:
                smoothed_rot[k] = ema_filter(mapped_rot_val[k], smoothed_rot[k], SMOOTH_FACTOR_ROT)

        # --- 3. 量化 (Quantize) ---
        # 使用平滑後的值進行量化
        pos_out = { k: quantize(v, MIN_CHANGE_TO_PUBLISH['pos']) for k,v in smoothed_pos.items() }
        rot_out_deg = { k: quantize(v, MIN_CHANGE_TO_PUBLISH['rot']) for k,v in smoothed_rot.items() }

        # --- 4. 檢查變化並發送 ---
        current_ik_pos = (pos_out['x'], pos_out['y'], pos_out['z'])
        current_ik_rot_deg = (rot_out_deg['rx'], rot_out_deg['ry'], rot_out_deg['rz'])
        
        pos_changed = current_ik_pos != last_published_ik_pos
        rot_changed = current_ik_rot_deg != last_published_ik_rot

        ik_payload = ""
        precision_log = ""
        
        if pos_changed or rot_changed:
            rot_out_rad = {k: math.radians(v) for k, v in rot_out_deg.items()}
            ik_payload, precision = create_adaptive_ik_payload(pos_out, rot_out_rad)
            precision_log = f"(P:{precision})"
            
            client.publish(TOPIC_IK_POSE, ik_payload)
            last_published_ik_pos = current_ik_pos
            last_published_ik_rot = current_ik_rot_deg

        # --- 5. 手爪處理 ---
        claw_status_msg = ""
        if rot_out_deg['ry'] >= RY_LOCK_THRESHOLD:
            smoothed_grab_strength = (GRAB_SMOOTHING_FACTOR * raw_grab) + (1.0 - GRAB_SMOOTHING_FACTOR) * smoothed_grab_strength
        else:
            claw_status_msg = f"(ry locked)"

        h_val = int(clamp(round((1.0 - smoothed_grab_strength) * 180.0), 0, 180))
        claw_changed = (h_val != last_sent_h)

        if claw_changed:
            claw_resend_counter = CLM_RESEND_COUNT
            last_sent_h = h_val

        claw_payload = ""
        should_send_claw = claw_resend_counter > 0

        if should_send_claw:
            # 只有在剛送完 IK 且需要送爪子時才延遲一點點，避免封包碰撞
            if (pos_changed or rot_changed) and IK_CLM_DELAY_MS > 0:
                time.sleep(IK_CLM_DELAY_MS / 1000.0)
            
            claw_payload = f"clm {h_val}"
            client.publish(TOPIC_CLAW, claw_payload)
            claw_resend_counter -= 1
        
        if LOG_PUBLISHES and (ik_payload or claw_payload):
            # 精簡 Log 輸出，避免洗版
            log_str = f"IK: {ik_payload}" if ik_payload else ""
            if claw_payload: log_str += f" | Claw: {claw_payload}"
            print(log_str)

# ---------------- main ----------------
def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGTERM, signal.SIG_DFL)
    t = threading.Thread(target=keyboard_thread, daemon=True); t.start()
    listener = BridgeListener(); conn = leap.Connection(); conn.add_listener(listener)
    with conn.open():
        conn.set_tracking_mode(leap.TrackingMode.Desktop); print("Bridge running... (Smooth V3)")
        while running: time.sleep(0.1)
    client.loop_stop(); client.disconnect(); print("Bridge stopped. Bye.")

if __name__ == "__main__":
    main()
