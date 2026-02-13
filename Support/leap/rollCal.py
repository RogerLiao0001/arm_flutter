#!/usr/bin/env python3
# leap_mqtt_bridge_v3.py (v9.0 - IK calculation moved to client)
# 用法：
#   pip install numpy paho-mqtt
#   source venv38/bin/activate
#   python leap_mqtt_bridge_v3.py
#
# 鍵盤控制 (單鍵觸發，不需 Enter):
#   a  -> 設定當前位置為原點 (歸零)
#   s  -> 暫停 / 恢復 (toggle)
#   q  -> 退出程式
#
# MQTT 遠端控制 (topic: servo/arm2/cmd)
#   發送 payload "zero" / "pause" / "resume" / "stop"

import leap, time, json, threading, sys, signal, math
import paho.mqtt.client as mqtt
import termios, tty
import numpy as np # <<< 新增Numpy函式庫，用於運動學計算

# ============================
# ========== CONFIG ==========
# ============================

# ---------- 1. 位置映射與軸向定義 (相對運動) ----------
POSITION_MAPPING = {
    'x': {'input_mm': 500, 'output_min': 0, 'output_max': 200, 'output_zero': 0},
    'y': {'input_mm': 500, 'output_min': -200, 'output_max': 200, 'output_zero': 0},
    'z': {'input_mm': 500, 'output_min': 0, 'output_max': 200, 'output_zero': 0},
}
POSITION_AXIS_MAPPING = { 'y': 'x', 'x': 'z', 'z': 'y' }
INVERT_X = True
INVERT_Y = True
INVERT_Z = False

# ---------- 2. 旋轉範圍與軸向定義 (絕對角度) ----------
ROTATION_MAPPING = {
    'rx': {'output_val': (-180, 180)},
    'ry': {'output_val': (-180, 180)},
    'rz': {'output_val': (-180, 180)},
}
ROTATION_AXIS_MAPPING = { 'ry': 'roll', 'rx': 'yaw', 'rz': 'pitch' }
INVERT_RX = True
INVERT_RY = False
INVERT_RZ = True

# ---------- 3. 輸出過濾與頻率 ----------
MIN_CHANGE_TO_PUBLISH = { 'pos': 2, 'rot': 2, 'jm': 1 } # 新增 jm 的最小變化量
PUBLISH_FPS = 2 # 越小越慢

# ---------- 4. MQTT 設定 ----------
MQTT_BROKER = "178.128.54.195"
MQTT_PORT = 1883
TOPIC_BASE = "servo/arm2/"
MQTT_CONTROL_TOPIC = TOPIC_BASE + "cmd"
# TOPIC_IK_POSE = TOPIC_BASE + "ik" # 舊的IK主題，不再使用
TOPIC_JM_POSE = TOPIC_BASE + "servo" # <<< 新增：傳送馬達角度的新主題
TOPIC_CLAW = TOPIC_BASE + "clm"

# ---------- 5. 發送時序與冗餘 ----------
IK_CLM_DELAY_MS = 500
CLM_RESEND_COUNT = 3

# ---------- 6. 其他功能開關 ----------
START_PUBLISH_AFTER_ZERO = True
LOG_PUBLISHES = True

# ---------- 7. 馬達角度極值 (新增) ----------
JM_LIMITS = {
    'j0': {'min': -180, 'max': 180},
    'j1': {'min': -180, 'max': 180},
    'j2': {'min': -180, 'max': 180},
    'j3': {'min': -180, 'max': 180},
    'j4': {'min': -180, 'max': 180},
    'j5': {'min': -180, 'max': 180},
}

# ============================
# ======== END CONFIG ========
# ============================


# =======================================================
# ========== INVERSE KINEMATICS IMPLEMENTATION ==========
# =======================================================

# DH參數表 (根據您提供的CSV)
# joint, theta, alpha(rad), a(mm), d(mm)
# 0, var, -1.57 (-pi/2), 0, 136.1
# 1, var, 0, 252.625, 0
# 2, var, 1.57 (pi/2), 0, 0
# 3, var, -1.57 (-pi/2), 0, 0
# 4, var, 1.57 (pi/2), 0, 214.6
# 5, var, 0, 0, 119.47
DH_PARAMS = {
    'alpha': np.array([-np.pi/2, 0, np.pi/2, -np.pi/2, np.pi/2, 0]),
    'a':     np.array([0, 252.625, 0, 0, 0, 0]),
    'd':     np.array([136.1, 0, 0, 0, 214.6, 119.47]),
    'theta_offset': np.array([0, 0, 0, 0, 0, 0]) # 可根據需要調整偏移
}

def euler_to_rot_matrix(yaw, pitch, roll):
    """ 將 ZYX Euler 角度轉換為旋轉矩陣 """
    Rz = np.array([[np.cos(yaw), -np.sin(yaw), 0],
                   [np.sin(yaw),  np.cos(yaw), 0],
                   [0,            0,           1]])
    Ry = np.array([[np.cos(pitch), 0, np.sin(pitch)],
                   [0,             1, 0],
                   [-np.sin(pitch),0, np.cos(pitch)]])
    Rx = np.array([[1, 0,             0],
                   [0, np.cos(roll), -np.sin(roll)],
                   [0, np.sin(roll),  np.cos(roll)]])
    return Rz @ Ry @ Rx

def dh_transform_matrix(theta, alpha, a, d):
    """ 根據Standard DH參數計算單一變換矩陣 """
    return np.array([
        [np.cos(theta), -np.sin(theta)*np.cos(alpha),  np.sin(theta)*np.sin(alpha), a*np.cos(theta)],
        [np.sin(theta),  np.cos(theta)*np.cos(alpha), -np.cos(theta)*np.sin(alpha), a*np.sin(theta)],
        [0,              np.sin(alpha),               np.cos(alpha),               d],
        [0,              0,                           0,                           1]
    ])

def calculate_inverse_kinematics(x, y, z, yaw_deg, pitch_deg, roll_deg):
    """
    逆向運動學主函式
    輸入末端點的 (x, y, z) 座標和 (yaw, pitch, roll) 姿態 (角度制)
    返回六個關節的角度 (弧度制)，若無解則返回 None
    """
    d0, d4, d5 = DH_PARAMS['d'][0], DH_PARAMS['d'][4], DH_PARAMS['d'][5]
    a1 = DH_PARAMS['a'][1]
    
    # 1. 計算旋轉矩陣和末端點位置
    yaw = np.deg2rad(yaw_deg)
    pitch = np.deg2rad(pitch_deg)
    roll = np.deg2rad(roll_deg)
    R_0_6 = euler_to_rot_matrix(yaw, pitch, roll)
    P_e = np.array([x, y, z])

    # 2. 計算手腕中心 (Wrist Center, WC) 的位置
    P_wc = P_e - d5 * R_0_6[:, 2]
    x_wc, y_wc, z_wc = P_wc[0], P_wc[1], P_wc[2]
    
    # 3. 計算前三個關節 (j0, j1, j2) - 定位
    # j0 (theta_0)
    j0 = np.arctan2(y_wc, x_wc)
    
    # j2 (theta_2)
    r_sq = x_wc**2 + y_wc**2
    s = z_wc - d0
    D_sq = r_sq + s**2
    
    cos_val_j2 = (D_sq - a1**2 - d4**2) / (2 * a1 * d4)
    if abs(cos_val_j2) > 1:
        # print("IK Warning: Position unreachable (j2).")
        return None # 位置無法到達
    
    # 選擇 elbow-up 解 (-acos)
    j2 = -np.arccos(cos_val_j2) 

    # j1 (theta_1)
    s_j2 = np.sin(j2)
    c_j2 = np.cos(j2)
    k1 = a1 + d4 * c_j2
    k2 = d4 * s_j2
    
    j1 = np.arctan2(s, np.sqrt(r_sq)) - np.arctan2(k2, k1)

    # 4. 計算後三個關節 (j3, j4, j5) - 定位
    # 首先計算 R_0_3
    T_0_1 = dh_transform_matrix(j0, DH_PARAMS['alpha'][0], DH_PARAMS['a'][0], DH_PARAMS['d'][0])
    T_1_2 = dh_transform_matrix(j1, DH_PARAMS['alpha'][1], DH_PARAMS['a'][1], DH_PARAMS['d'][1])
    T_2_3 = dh_transform_matrix(j2, DH_PARAMS['alpha'][2], DH_PARAMS['a'][2], DH_PARAMS['d'][2])
    T_0_3 = T_0_1 @ T_1_2 @ T_2_3
    R_0_3 = T_0_3[:3, :3]
    
    # 計算 R_3_6 = (R_0_3)^-1 * R_0_6
    R_3_6 = np.linalg.inv(R_0_3) @ R_0_6
    
    # 從 R_3_6 提取 j3, j4, j5
    # 這裡的解法對應於 alpha = [-pi/2, pi/2, 0] 的球形手腕
    r13, r23, r33 = R_3_6[0, 2], R_3_6[1, 2], R_3_6[2, 2]
    r31, r32 = R_3_6[2, 0], R_3_6[2, 1]

    s_j4 = np.sqrt(r13**2 + r23**2)
    c_j4 = r33
    j4 = np.arctan2(s_j4, c_j4)
    
    # 處理奇異點 (j4接近0)
    if np.isclose(s_j4, 0.0):
        # 在奇異點，j3 和 j5 是耦合的，可以將 j3 設為0
        j3 = 0.0
        r11, r12 = R_3_6[0,0], R_3_6[0,1]
        j5 = np.arctan2(-r12, r11)
    else:
        j3 = np.arctan2(r23 / s_j4, r13 / s_j4)
        j5 = np.arctan2(r32 / s_j4, -r31 / s_j4)

    return np.array([j0, j1, j2, j3, j4, j5])

# =======================================================
# ========== END OF KINEMATICS IMPLEMENTATION ===========
# =======================================================


# ---------------- init MQTT ----------------
client = mqtt.Client()
def on_connect(client, userdata, flags, rc):
    if rc == 0: print(f"Connected to MQTT broker {MQTT_BROKER}:{MQTT_PORT}"); client.subscribe(MQTT_CONTROL_TOPIC)
    else: print("MQTT connect failed with rc:", rc)
client.on_connect = on_connect
def on_message(client, userdata, msg):
    payload = msg.payload.decode('utf-8').strip().lower()
    print("MQTT control received:", payload)
    if payload == "zero": do_zero_command()
    elif payload == "pause": do_pause_command()
    elif payload == "resume": do_resume_command()
    elif payload == "stop": do_stop_command()
client.on_message = on_message
client.connect(MQTT_BROKER, MQTT_PORT, 60)
client.loop_start()

# ---------------- state ----------------
zero_ref_pos = {}
enabled = not START_PUBLISH_AFTER_ZERO; paused = False; running = True
last_publish_time = 0.0; last_published_jm = None; last_sent_h = None # last_published_ik -> last_published_jm
claw_resend_counter = 0
lock = threading.Lock(); last_right_hand_raw_pos = {}

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
    if rel_val >= 0:
        ratio = rel_val / input_max if input_max != 0 else 0
        mapped_val = out_zero + ratio * (out_max - out_zero)
    else:
        ratio = rel_val / -input_max if input_max != 0 else 0
        mapped_val = out_zero - ratio * (out_zero - out_min)
    return clamp(mapped_val, out_min, out_max)

def quantize(value, step):
    if step <= 0: return int(value)
    return int(round(value / step) * step)

# ---------------- control action handlers ----------------
def do_zero_command():
    global zero_ref_pos, enabled, paused, last_published_jm
    with lock:
        if last_right_hand_raw_pos:
            zero_ref_pos = last_right_hand_raw_pos.copy()
            enabled = True; paused = False; last_published_jm = None
            print(f"\nPosition zero reference set to: { {k: round(v, 2) for k, v in zero_ref_pos.items()} }.")
        else: print("\nZero command received but no hand detected.")

def do_pause_command(): global paused; paused = True; print("\nPaused")
def do_resume_command(): global paused, enabled; paused = False; enabled = True; print("\nResumed")
def do_stop_command(): global running; running = False; print("\nStop command received")

def keyboard_thread():
    global paused, running
    print("Keyboard: 'a' to zero/start, 's' to pause/resume, 'q' to quit.")
    while running:
        try:
            cmd = getch().lower()
            if cmd == 'a': do_zero_command()
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
        global last_right_hand_raw_pos, last_publish_time, last_published_jm, last_sent_h, claw_resend_counter
        if not running or len(event.hands) == 0: return

        hand = next((h for h in event.hands if str(h.type).endswith("Right")), event.hands[0])

        try:
            pos = hand.palm.position
            raw_pos = {'x': float(pos.x), 'y': float(pos.y), 'z': float(pos.z)}
            q = hand.palm.orientation; w, x, y, z = q.w, q.x, q.y, q.z
            raw_angles = {
                'roll': math.degrees(math.atan2(2*(w*x + y*z), 1 - 2*(x*x + y*y))),
                'pitch': math.degrees(math.asin(clamp(2*(w*y - z*x), -1.0, 1.0))),
                'yaw': math.degrees(math.atan2(2*(w*z + x*y), 1 - 2*(y*y + z*z)))
            }
            grab = float(getattr(hand, "grab_strength", 0.0))
        except Exception as e: print("Error reading hand data:", e); return

        with lock: last_right_hand_raw_pos = raw_pos
        if not enabled or paused or not zero_ref_pos: return
        now = time.time()
        if now - last_publish_time < 1.0 / PUBLISH_FPS: return
        last_publish_time = now

        # --- 數據處理 (座標轉換) ---
        rel_pos_raw = { axis: raw_pos[axis] - zero_ref_pos.get(axis, 0) for axis in ['x', 'y', 'z'] }
        rel_pos_mapped = { ik_axis: rel_pos_raw[leap_axis] for ik_axis, leap_axis in POSITION_AXIS_MAPPING.items() }
        if INVERT_X: rel_pos_mapped['x'] *= -1
        if INVERT_Y: rel_pos_mapped['y'] *= -1
        if INVERT_Z: rel_pos_mapped['z'] *= -1
        pos_out = { axis: quantize(map_asymmetric_position(val, POSITION_MAPPING[axis]), MIN_CHANGE_TO_PUBLISH['pos']) for axis, val in rel_pos_mapped.items() }

        abs_rot_mapped = { ik_axis: raw_angles[leap_axis] for ik_axis, leap_axis in ROTATION_AXIS_MAPPING.items() }
        if INVERT_RX: abs_rot_mapped['rx'] *= -1
        if INVERT_RY: abs_rot_mapped['ry'] *= -1
        if INVERT_RZ: abs_rot_mapped['rz'] *= -1
        rot_out = { axis: quantize(clamp(val, ROTATION_MAPPING[axis]['output_val'][0], ROTATION_MAPPING[axis]['output_val'][1]), MIN_CHANGE_TO_PUBLISH['rot']) for axis, val in abs_rot_mapped.items() }

        # --- 逆向運動學計算 (新) ---
        current_ik = (pos_out['x'], pos_out['y'], pos_out['z'], rot_out['rx'], rot_out['ry'], rot_out['rz'])
        
        # 呼叫IK函式，注意軸向對應
        joint_angles_rad = calculate_inverse_kinematics(
            current_ik[0], current_ik[1], current_ik[2],
            rot_out['rx'], rot_out['rz'], rot_out['ry'] # yaw, pitch, roll -> rx, rz, ry
        )

        jm_payload = ""
        jm_changed = False
        current_jm = None

        if joint_angles_rad is not None:
            # 轉換為角度並應用極值
            joint_angles_deg_raw = np.rad2deg(joint_angles_rad)
            
            # 套用極值和量化
            current_jm_list = []
            for i in range(6):
                joint_name = f'j{i}'
                angle = joint_angles_deg_raw[i]
                angle_clamped = clamp(angle, JM_LIMITS[joint_name]['min'], JM_LIMITS[joint_name]['max'])
                angle_quantized = quantize(angle_clamped, MIN_CHANGE_TO_PUBLISH['jm'])
                current_jm_list.append(angle_quantized)
            current_jm = tuple(current_jm_list)

            jm_changed = (current_jm != last_published_jm)
            
            if jm_changed:
                jm_payload = f"jm {current_jm[0]} {current_jm[1]} {current_jm[2]} {current_jm[3]} {current_jm[4]} {current_jm[5]}"
                client.publish(TOPIC_JM_POSE, jm_payload) # <<< 發送新的jm格式訊息
                last_published_jm = current_jm
        
        # --- 手爪發送邏輯 (不變) ---
        h_val = int(clamp(round((1.0 - grab) * 100.0), 0, 100))
        claw_changed = (h_val != last_sent_h)

        if claw_changed:
            claw_resend_counter = CLM_RESEND_COUNT
            last_sent_h = h_val
        
        claw_payload = ""
        should_send_claw = claw_resend_counter > 0

        if should_send_claw:
            if jm_changed and IK_CLM_DELAY_MS > 0:
                time.sleep(IK_CLM_DELAY_MS / 1000.0)

            claw_payload = f"clm {h_val}"
            client.publish(TOPIC_CLAW, claw_payload)
            claw_resend_counter -= 1
        
        # --- 更新終端機日誌輸出 ---
        if LOG_PUBLISHES and (jm_changed or should_send_claw):
            # 為了對照，我們在終端機同時顯示IK和JM
            ik_str = f"IK(xyz, rpy): ({current_ik[0]}, {current_ik[1]}, {current_ik[2]}, {current_ik[3]}, {current_ik[4]}, {current_ik[5]})"
            
            if current_jm is not None:
                jm_str = f"JM(j0-j5):   ({current_jm[0]}, {current_jm[1]}, {current_jm[2]}, {current_jm[3]}, {current_jm[4]}, {current_jm[5]})"
            else:
                jm_str = "JM(j0-j5):   (Unreachable)"
            
            log_jm_msg = jm_payload if jm_changed else '(no change)'
            log_claw = claw_payload if should_send_claw else f'(no change, resend_ctr:{claw_resend_counter})'

            print(f"\n{ik_str}\n{jm_str}")
            print(f"Published JM: {log_jm_msg} | Claw: {log_claw}")


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