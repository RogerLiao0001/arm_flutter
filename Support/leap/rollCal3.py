#!/usr/bin/env python3
# leap_mqtt_bridge_v3.py (v9.4 - Added Absolute Angle Gate for Claw Control)
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
import numpy as np

# ============================
# ========== CONFIG ==========
# ============================

# ---------- 1. 位置映射與軸向定義 (相對運動) ----------
POSITION_MAPPING = {
    'x': {'input_mm': 500, 'output_min': 50, 'output_max': 250, 'output_zero': 150},
    'y': {'input_mm': 500, 'output_min': -200, 'output_max': 200, 'output_zero': 0},
    'z': {'input_mm': 500, 'output_min': 100, 'output_max': 350, 'output_zero': 150},
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
MIN_CHANGE_TO_PUBLISH = { 'pos': 1, 'rot': 1 }
PUBLISH_FPS = 5

# ---------- 4. MQTT 設定 ----------
MQTT_BROKER = "178.128.54.195"
MQTT_PORT = 1883
TOPIC_BASE = "servo/arm2/"
MQTT_CONTROL_TOPIC = TOPIC_BASE + "cmd"
TOPIC_IK_POSE = TOPIC_BASE + "ik"
TOPIC_SERVO = TOPIC_BASE + "servo"
TOPIC_CLAW = TOPIC_BASE + "clm"

# ---------- 5. 發送時序與冗餘 ----------
IK_CLM_DELAY_MS = 50
CLM_RESEND_COUNT = 3

# ---------- 6. 其他功能開關 ----------
START_PUBLISH_AFTER_ZERO = True
LOG_PUBLISHES = True

# ---------- 7. 手爪平滑化與鎖定 (修正) ----------
# EMA濾波係數，用於撫平輕微抖動
GRAB_SMOOTHING_FACTOR = 0.4
# <<< 新增：手腕角度鎖定閾值 (單位: 度)
# 當ry軸的角度小於此值時，將暫時鎖定手爪狀態，以防誤判
RY_LOCK_THRESHOLD = -30.0

# ---------- 8. 馬達角度極值 (全域變數) ----------
JM0_MIN, JM0_MAX = -180.0, 180.0
JM1_MIN, JM1_MAX = -180.0, 180.0
JM2_MIN, JM2_MAX = -180.0, 180.0
JM3_MIN, JM3_MAX = -180.0, 180.0
JM4_MIN, JM4_MAX = -180.0, 180.0
JM5_MIN, JM5_MAX = -180.0, 180.0

# =======================================================
# ========== INVERSE KINEMATICS (from Flutter) ==========
# =======================================================

DH_PARAMS = {
    'alpha': np.array([-math.pi/2, 0, math.pi/2, -math.pi/2, math.pi/2, 0]),
    'a':     np.array([0, 252.625, 0, 0, 0, 0]),
    'd':     np.array([136.1, 0, 0, 0, 214.6, 119.47]),
}

def dh_transform_matrix(theta, alpha, a, d):
    """ 根據Standard DH參數計算單一變換矩陣 """
    ct, st = np.cos(theta), np.sin(theta)
    ca, sa = np.cos(alpha), np.sin(alpha)
    return np.array([
        [ct, -st*ca,  st*sa, a*ct],
        [st,  ct*ca, -ct*sa, a*st],
        [0,      sa,     ca,    d],
        [0,       0,      0,    1]
    ])

def euler_to_rot_matrix(yaw_deg, pitch_deg, roll_deg):
    """ 將 ZYX Euler 角度轉換為旋轉矩陣 """
    yaw, pitch, roll = np.deg2rad([yaw_deg, pitch_deg, roll_deg])
    Rz = np.array([[np.cos(yaw), -np.sin(yaw), 0], [np.sin(yaw), np.cos(yaw), 0], [0, 0, 1]])
    Ry = np.array([[np.cos(pitch), 0, np.sin(pitch)], [0, 1, 0], [-np.sin(pitch), 0, np.cos(pitch)]])
    Rx = np.array([[1, 0, 0], [0, np.cos(roll), -np.sin(roll)], [0, np.sin(roll), np.cos(roll)]])
    return Rz @ Ry @ Rx

def calculate_inverse_kinematics(x, y, z, yaw_deg, pitch_deg, roll_deg):
    """ 解析解IK主函式 (用於位置移動) """
    try:
        d0, a1, d4, d5 = DH_PARAMS['d'][0], DH_PARAMS['a'][1], DH_PARAMS['d'][4], DH_PARAMS['d'][5]
        R_0_6 = euler_to_rot_matrix(yaw_deg, pitch_deg, roll_deg)
        P_e = np.array([x, y, z])
        P_wc = P_e - d5 * R_0_6[:, 2]
        
        j0 = np.arctan2(P_wc[1], P_wc[0])
        
        r_sq = P_wc[0]**2 + P_wc[1]**2
        s = P_wc[2] - d0
        D_sq = r_sq + s**2
        
        cos_val_j2 = np.clip((D_sq - a1**2 - d4**2) / (2 * a1 * d4), -1.0, 1.0)
        j2 = np.arccos(cos_val_j2) # 手肘向上解

        k1 = a1 + d4 * np.cos(j2)
        k2 = d4 * np.sin(j2)
        j1 = np.arctan2(s, np.sqrt(r_sq)) - np.arctan2(k2, k1)

        T_0_1 = dh_transform_matrix(j0, DH_PARAMS['alpha'][0], DH_PARAMS['a'][0], DH_PARAMS['d'][0])
        T_1_2 = dh_transform_matrix(j1, DH_PARAMS['alpha'][1], DH_PARAMS['a'][1], DH_PARAMS['d'][1])
        T_2_3 = dh_transform_matrix(j2, DH_PARAMS['alpha'][2], DH_PARAMS['a'][2], DH_PARAMS['d'][2])
        R_0_3 = (T_0_1 @ T_1_2 @ T_2_3)[:3, :3]
        R_3_6 = R_0_3.T @ R_0_6
        
        r13, r23 = R_3_6[0, 2], R_3_6[1, 2]
        r31, r32, r33 = R_3_6[2, 0], R_3_6[2, 1], R_3_6[2, 2]
        
        s_j4 = np.sqrt(r13**2 + r23**2)
        j4 = np.arctan2(s_j4, r33)
        
        if np.isclose(s_j4, 0.0):
            j3 = 0.0
            j5 = np.arctan2(-R_3_6[0, 1], R_3_6[0, 0])
        else:
            j3 = np.arctan2(r23 / s_j4, r13 / s_j4)
            j5 = np.arctan2(r32 / s_j4, -r31 / s_j4)
            
        return np.rad2deg([j0, j1, j2, j3, j4, j5])
    except Exception:
        return None

def recalculate_wrist_only_ik(target_rot, current_angles_deg):
    """ 只重新計算手腕關節，保持手臂位置不變 """
    try:
        j0, j1, j2 = np.deg2rad(current_angles_deg[:3])
        R_0_6_new = euler_to_rot_matrix(target_rot['rx'], target_rot['rz'], target_rot['ry'])

        T_0_1 = dh_transform_matrix(j0, DH_PARAMS['alpha'][0], DH_PARAMS['a'][0], DH_PARAMS['d'][0])
        T_1_2 = dh_transform_matrix(j1, DH_PARAMS['alpha'][1], DH_PARAMS['a'][1], DH_PARAMS['d'][1])
        T_2_3 = dh_transform_matrix(j2, DH_PARAMS['alpha'][2], DH_PARAMS['a'][2], DH_PARAMS['d'][2])
        R_0_3 = (T_0_1 @ T_1_2 @ T_2_3)[:3, :3]
        R_3_6 = R_0_3.T @ R_0_6_new

        r13, r23 = R_3_6[0, 2], R_3_6[1, 2]
        r31, r32, r33 = R_3_6[2, 0], R_3_6[2, 1], R_3_6[2, 2]
        
        s_j4 = np.sqrt(r13**2 + r23**2)
        j4 = np.arctan2(s_j4, r33)
        
        if np.isclose(s_j4, 0.0):
            j3 = 0.0
            j5 = np.arctan2(-R_3_6[0, 1], R_3_6[0, 0])
        else:
            j3 = np.arctan2(r23 / s_j4, r13 / s_j4)
            j5 = np.arctan2(r32 / s_j4, -r31 / s_j4)
        
        new_wrist_angles = np.rad2deg([j3, j4, j5])
        return np.concatenate((current_angles_deg[:3], new_wrist_angles))
    except Exception:
        return None

def unwrap_angles(new_angles, previous_angles):
    """ 角度解纏繞以確保運動平滑 """
    unwrapped = np.array(new_angles)
    diff = unwrapped - previous_angles
    unwrapped[diff > 180] -= 360
    unwrapped[diff < -180] += 360
    return unwrapped

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
last_publish_time = 0.0; last_published_ik_pos = None; last_published_ik_rot = None; last_sent_h = None
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
    global zero_ref_pos, enabled, paused, last_published_ik_pos, last_published_ik_rot
    with lock:
        if last_right_hand_raw_pos:
            zero_ref_pos = last_right_hand_raw_pos.copy()
            enabled = True; paused = False
            last_published_ik_pos = None; last_published_ik_rot = None
            BridgeListener.last_known_joint_angles = None
            BridgeListener.smoothed_grab_strength = 0.0
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
    last_known_joint_angles = None
    smoothed_grab_strength = 0.0

    def on_connection_event(self, event): print("Connected to Leap service")
    def on_device_event(self, event): print("Found device", event.device.get_info().serial)

    def on_tracking_event(self, event):
        global last_right_hand_raw_pos, last_publish_time, last_published_ik_pos, last_published_ik_rot, last_sent_h, claw_resend_counter
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
            raw_grab = float(getattr(hand, "grab_strength", 0.0))
        except Exception as e: print("Error reading hand data:", e); return

        with lock:
            last_right_hand_raw_pos = raw_pos

        if not enabled or paused or not zero_ref_pos: return
        now = time.time()
        if now - last_publish_time < 1.0 / PUBLISH_FPS: return
        last_publish_time = now

        # --- 數據處理 ---
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

        # --- IK 與 JM 計算邏輯 ---
        current_ik_pos = (pos_out['x'], pos_out['y'], pos_out['z'])
        current_ik_rot = (rot_out['rx'], rot_out['ry'], rot_out['rz'])
        
        pos_changed = current_ik_pos != last_published_ik_pos
        rot_changed = current_ik_rot != last_published_ik_rot
        
        jm_solution = None
        if pos_changed or rot_changed:
            if self.last_known_joint_angles is None:
                pos_changed = True

            if pos_changed:
                new_angles = calculate_inverse_kinematics(
                    pos_out['x'], pos_out['y'], pos_out['z'],
                    rot_out['rx'], rot_out['rz'], rot_out['ry'] # Yaw, Pitch, Roll
                )
            else:
                new_angles = recalculate_wrist_only_ik(rot_out, self.last_known_joint_angles)

            if new_angles is not None:
                if self.last_known_joint_angles is not None:
                    unwrapped_angles = unwrap_angles(new_angles, self.last_known_joint_angles)
                else:
                    unwrapped_angles = np.array(new_angles)
                
                self.last_known_joint_angles = unwrapped_angles
                jm_solution = unwrapped_angles
            else:
                jm_solution = self.last_known_joint_angles

        if pos_changed: last_published_ik_pos = current_ik_pos
        if rot_changed: last_published_ik_rot = current_ik_rot

        # --- 發送 JM ---
        if jm_solution is not None:
            jm_clamped = [
                int(round(clamp(jm_solution[0], JM0_MIN, JM0_MAX))),
                int(round(clamp(jm_solution[1], JM1_MIN, JM1_MAX))),
                int(round(clamp(jm_solution[2], JM2_MIN, JM2_MAX))),
                int(round(clamp(jm_solution[3], JM3_MIN, JM3_MAX))),
                int(round(clamp(jm_solution[4], JM4_MIN, JM4_MAX))),
                int(round(clamp(jm_solution[5], JM5_MIN, JM5_MAX))),
            ]
            jm_payload = f"jm {' '.join(map(str, jm_clamped))}"
            client.publish(TOPIC_SERVO, jm_payload)
        
        ik_payload = f"IK {current_ik_pos[0]} {current_ik_pos[1]} {current_ik_pos[2]} {current_ik_rot[0]} {current_ik_rot[1]} {current_ik_rot[2]}"
        if pos_changed or rot_changed:
            client.publish(TOPIC_IK_POSE, ik_payload)
        
        # --- 手爪平滑化與發送邏輯 ---
        # <<< 修正：基於ry絕對角度的門控邏輯 (Absolute Angle Gate)
        current_ry = rot_out['ry']
        claw_status_msg = ""

        # 只有當 ry 在 "可信區間" 時，才更新手爪的平滑值
        if current_ry >= RY_LOCK_THRESHOLD:
            self.smoothed_grab_strength = (GRAB_SMOOTHING_FACTOR * raw_grab) + \
                                          (1.0 - GRAB_SMOOTHING_FACTOR) * self.smoothed_grab_strength
        else:
            # 當 ry 進入 "不可信區間"，不更新平滑值，等於鎖定手爪狀態
            claw_status_msg = f"(ry < {RY_LOCK_THRESHOLD}, claw locked)"

        h_val = int(clamp(round((1.0 - self.smoothed_grab_strength) * 100.0), 0, 100))
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
        if LOG_PUBLISHES and (pos_changed or rot_changed or should_send_claw):
            print("-" * 20)
            print(f"IK: {ik_payload}")
            if jm_solution is not None:
                print(f"JM: {' '.join(map(str, jm_clamped))}")
            else:
                print("JM: (No solution found)")
            
            if claw_payload:
                print(f"Claw: {claw_payload} {claw_status_msg}")

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