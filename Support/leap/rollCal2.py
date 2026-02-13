#!/usr/bin/env python3
# leap_mqtt_bridge_v3.py (v8.2 - Added Send Delay and Redundancy + onboard IK->JM conversion)
# 用法：
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

# --------- 新增依賴 ---------
# 逆向與正向運算使用 numpy（線性代數與偽逆）
import numpy as np

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
MIN_CHANGE_TO_PUBLISH = { 'pos': 2, 'rot': 2 }
PUBLISH_FPS = 2 # 越小越慢

# ---------- 4. MQTT 設定 ----------
MQTT_BROKER = "178.128.54.195"
MQTT_PORT = 1883
TOPIC_BASE = "servo/arm2/"
MQTT_CONTROL_TOPIC = TOPIC_BASE + "cmd"
TOPIC_IK_POSE = TOPIC_BASE + "ik"
TOPIC_CLAW = TOPIC_BASE + "clm"
# ---------- 新增：servo topic（將 jm 用此 topic 發送出去）----------
TOPIC_SERVO = TOPIC_BASE + "servo"

# ---------- 5. 發送時序與冗餘 (新增) ----------
IK_CLM_DELAY_MS = 500  # 單位：毫秒。設為 0 表示不延遲。
CLM_RESEND_COUNT = 3  # 設為 1 表示只發一次 (無冗餘)。

# ---------- 6. 其他功能開關 ----------
START_PUBLISH_AFTER_ZERO = True
LOG_PUBLISHES = True

# ============================
# ======== JM LIMITS =========
# ============================
# 使用者要求每個 jm 值都為獨立全域變數以便快速調整，預設皆為 -180..180
JM0_MIN, JM0_MAX = -180.0, 180.0
JM1_MIN, JM1_MAX = -180.0, 180.0
JM2_MIN, JM2_MAX = -180.0, 180.0
JM3_MIN, JM3_MAX = -180.0, 180.0
JM4_MIN, JM4_MAX = -180.0, 180.0
JM5_MIN, JM5_MAX = -180.0, 180.0

# 當需要快速調整極值時，可直接改上面六個變數

# ============================
# === 6-DOF DH 參數 (mm & rad) ===
# Provided CSV:
# joint,theta,alpha(radian),a(mm),d(mm)
# 0,variable,-1.57,0,136.1
# 1,variable,0,252.625,0
# 2,variable,1.57,0,0
# 3,variable,-1.57,0,0
# 4,variable,1.57,0,214.6
# 5,variable,0,0,119.47
#
# We use Standard DH (theta, d, a, alpha). theta are the joint variables.
# 正向單一變換矩陣 (standard DH):
# A_i = Rot(z, theta_i) * Trans(z, d_i) * Trans(x, a_i) * Rot(x, alpha_i)
# 以齊次矩陣形式實作（4x4）。
# ============================

DH_ALPHA = [-1.5707963267948966, 0.0, 1.5707963267948966, -1.5707963267948966, 1.5707963267948966, 0.0]
DH_A     = [0.0, 252.625, 0.0, 0.0, 0.0, 0.0]   # mm
DH_D     = [136.1, 0.0, 0.0, 0.0, 214.6, 119.47] # mm

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
last_publish_time = 0.0; last_published_ik = None; last_sent_h = None
claw_resend_counter = 0 # 用於 clm 冗餘發送的計數器
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

# ---------------- DH / FK / IK functions ----------------

def dh_transform(theta_rad, alpha_rad, a_mm, d_mm):
    """Standard DH transform A_i (4x4)"""
    ct = math.cos(theta_rad); st = math.sin(theta_rad)
    ca = math.cos(alpha_rad); sa = math.sin(alpha_rad)
    A = np.array([
        [ ct, -st*ca,  st*sa, a_mm*ct ],
        [ st,  ct*ca, -ct*sa, a_mm*st ],
        [  0,     sa,     ca,    d_mm ],
        [  0,      0,      0,      1  ]
    ], dtype=float)
    return A

def fkine_deg(thetas_deg):
    """Forward kinematics: input vector thetas in degrees -> returns (pos_mm (3,), R (3x3))"""
    thetas = [math.radians(t) for t in thetas_deg]
    T = np.eye(4)
    for i in range(6):
        A = dh_transform(thetas[i], DH_ALPHA[i], DH_A[i], DH_D[i])
        T = T @ A
    pos = T[0:3, 3]
    R = T[0:3, 0:3]
    return pos, R

def euler_to_R_from_input(rx_deg, ry_deg, rz_deg):
    """
    Convert the provided IK Euler angles into a rotation matrix.
    NOTE: mapping used in the original code:
      rx -> yaw (Z)
      ry -> roll (X)
      rz -> pitch (Y)
    We adopt the common sequence: R = Rz(yaw)*Ry(pitch)*Rx(roll)
    where yaw = rx, pitch = rz, roll = ry (degrees).
    """
    yaw = math.radians(rx_deg)
    pitch = math.radians(rz_deg)
    roll = math.radians(ry_deg)
    # Rz(yaw)
    Rz = np.array([[math.cos(yaw), -math.sin(yaw), 0],
                   [math.sin(yaw),  math.cos(yaw), 0],
                   [0, 0, 1]])
    # Ry(pitch)
    Ry = np.array([[ math.cos(pitch), 0, math.sin(pitch)],
                   [0, 1, 0],
                   [-math.sin(pitch), 0, math.cos(pitch)]])
    # Rx(roll)
    Rx = np.array([[1, 0, 0],
                   [0, math.cos(roll), -math.sin(roll)],
                   [0, math.sin(roll),  math.cos(roll)]])
    R = Rz @ Ry @ Rx
    return R

def rotation_error_vector(R_des, R_cur):
    """
    Compute orientation error as a 3-vector (axis * angle).
    R_err = R_des * R_cur.T
    angle = acos((trace(R_err)-1)/2)
    axis = (1/(2*sin(angle))) * [R_err[2,1]-R_err[1,2], R_err[0,2]-R_err[2,0], R_err[1,0]-R_err[0,1]]
    If angle ~ 0, return zero vector.
    """
    R_err = R_des @ R_cur.T
    tr = np.trace(R_err)
    # numerical clamp
    cos_angle = clamp((tr - 1.0) / 2.0, -1.0, 1.0)
    angle = math.acos(cos_angle)
    if abs(angle) < 1e-8:
        return np.zeros(3)
    denom = 2.0 * math.sin(angle)
    rx = (R_err[2,1] - R_err[1,2]) / denom
    ry = (R_err[0,2] - R_err[2,0]) / denom
    rz = (R_err[1,0] - R_err[0,1]) / denom
    return np.array([rx, ry, rz]) * angle

def pose_to_vec(pos, R):
    """Convert pos (3,) and rotation matrix to 6-vector [x,y,z, rx,ry,rz] where rx..rz is rotation vector (axis*angle)."""
    return np.concatenate([pos, rotation_error_vector(R, np.eye(3))])  # here rotation vector w.r.t identity (not used)

def ik_solve_numeric(desired_pos_mm, desired_R, init_thetas_deg=None, max_iters=60, tol_pos=1e-2, tol_ori=1e-2):
    """
    Numeric IK solver:
      - Inputs: desired_pos_mm (3,), desired_R (3x3)
      - init_thetas_deg: optional initial guess (list len6)
      - Returns: thetas_deg (list len6)
    Method:
      - iterative: compute current FK, build 6x6 Jacobian numerically (finite diff), compute delta_theta via pseudo-inverse:
          delta_theta = pinv(J) * err_vec
      - stop when position (mm) and orientation (angle in radians) errors are below tolerances
    """
    if init_thetas_deg is None:
        thetas = np.zeros(6, dtype=float)
    else:
        thetas = np.array(init_thetas_deg, dtype=float)

    lam = 0.7  # step damping factor
    for it in range(max_iters):
        # current pose
        cur_pos, cur_R = fkine_deg(thetas.tolist())
        # position error
        err_pos = desired_pos_mm - cur_pos
        # orientation error vector (axis*angle)
        err_ori = rotation_error_vector(desired_R, cur_R)
        err = np.concatenate([err_pos, err_ori])  # 6-vector
        err_norm_pos = np.linalg.norm(err_pos)
        err_norm_ori = np.linalg.norm(err_ori)
        if err_norm_pos < tol_pos and err_norm_ori < tol_ori:
            break

        # numeric Jacobian (6x6): perturb each theta by eps and compute finite diff
        eps = 1e-6  # radians equivalent in theta perturbation (we work in degrees, but perturb small deg -> rad)
        J = np.zeros((6,6), dtype=float)
        for i in range(6):
            th_backup = thetas[i]
            thetas[i] = th_backup + math.degrees(eps)  # perturb a tiny bit in degrees
            pos_p, R_p = fkine_deg(thetas.tolist())
            # position diff
            dp = pos_p - cur_pos
            # orientation diff
            dori = rotation_error_vector(R_p, cur_R)  # axis*angle from cur->pert
            J[:, i] = np.concatenate([dp, dori]) / math.degrees(eps)
            thetas[i] = th_backup

        # solve for delta_theta (degrees) using pseudo-inverse
        try:
            J_pinv = np.linalg.pinv(J)
            delta_theta = J_pinv @ err
        except Exception as e:
            # fallback small random nudges if pseudo-inverse fails
            delta_theta = 0.1 * np.random.randn(6)

        # update with damping
        thetas = thetas + lam * delta_theta

        # enforce joint limits at each step (degrees)
        thetas[0] = clamp(thetas[0], JM0_MIN, JM0_MAX)
        thetas[1] = clamp(thetas[1], JM1_MIN, JM1_MAX)
        thetas[2] = clamp(thetas[2], JM2_MIN, JM2_MAX)
        thetas[3] = clamp(thetas[3], JM3_MIN, JM3_MAX)
        thetas[4] = clamp(thetas[4], JM4_MIN, JM4_MAX)
        thetas[5] = clamp(thetas[5], JM5_MIN, JM5_MAX)

    return thetas.tolist()

# ---------------- control action handlers ----------------
def do_zero_command():
    global zero_ref_pos, enabled, paused, last_published_ik
    with lock:
        if last_right_hand_raw_pos:
            zero_ref_pos = last_right_hand_raw_pos.copy()
            enabled = True; paused = False; last_published_ik = None
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
        global last_right_hand_raw_pos, last_publish_time, last_published_ik, last_sent_h, claw_resend_counter
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

        with lock:
            last_right_hand_raw_pos = raw_pos

        if not enabled or paused or not zero_ref_pos: return
        now = time.time()
        if now - last_publish_time < 1.0 / PUBLISH_FPS: return
        last_publish_time = now

        # --- 數據處理 (與之前相同) ---
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

        # --- 發送邏輯 (已修改) ---
        current_ik = (pos_out['x'], pos_out['y'], pos_out['z'], rot_out['rx'], rot_out['ry'], rot_out['rz'])
        ik_changed = (current_ik != last_published_ik)
        
        ik_payload = ""
        if ik_changed:
            ik_payload = f"IK {current_ik[0]} {current_ik[1]} {current_ik[2]} {current_ik[3]} {current_ik[4]} {current_ik[5]}"
            client.publish(TOPIC_IK_POSE, ik_payload) # IK 輸出！！
            last_published_ik = current_ik
        
        # ----------------------------
        # 新增：從 IK (x,y,z,rx,ry,rz) -> 計算關節角 jm0..jm5，並發送到 servo topic
        # 保持 IK 原始輸出完全不動（如使用者要求），在此基於該 IK 值額外計算關節角
        # ----------------------------
        try:
            # desired position in mm = pos_out values (they already是 mm 映射)
            desired_pos_mm = np.array([current_ik[0], current_ik[1], current_ik[2]], dtype=float)
            # desired rotation matrix: convert from IK rx,ry,rz (degrees) to rotation matrix using mapping described earlier
            desired_R = euler_to_R_from_input(current_ik[3], current_ik[4], current_ik[5])
            # use previous JM as initial guess if available
            init_guess = None
            # try to keep a persistent last_jm guess
            if hasattr(self := BridgeListener, 'last_jm_guess') and isinstance(self.last_jm_guess, (list, tuple, np.ndarray)):
                init_guess = list(self.last_jm_guess)
            # solve numeric IK
            jm_solution = ik_solve_numeric(desired_pos_mm, desired_R, init_thetas_deg=init_guess, max_iters=60, tol_pos=0.5, tol_ori=0.02)
            # clamp to jm limits and round to integers for publishing
            jm_solution = [
                int(round(clamp(jm_solution[0], JM0_MIN, JM0_MAX))),
                int(round(clamp(jm_solution[1], JM1_MIN, JM1_MAX))),
                int(round(clamp(jm_solution[2], JM2_MIN, JM2_MAX))),
                int(round(clamp(jm_solution[3], JM3_MIN, JM3_MAX))),
                int(round(clamp(jm_solution[4], JM4_MIN, JM4_MAX))),
                int(round(clamp(jm_solution[5], JM5_MIN, JM5_MAX))),
            ]
            # persist guess for next call
            BridgeListener.last_jm_guess = jm_solution.copy()
        except Exception as e:
            # on error, fall back to zeros
            print("IK->JM conversion error:", e)
            jm_solution = [0,0,0,0,0,0]

        # build jm payload and publish
        jm_payload = f"jm {jm_solution[0]} {jm_solution[1]} {jm_solution[2]} {jm_solution[3]} {jm_solution[4]} {jm_solution[5]}"
        client.publish(TOPIC_SERVO, jm_payload)

        # ----------------------------
        # claw handling (unchanged)
        # ----------------------------
        h_val = int(clamp(round((1.0 - grab) * 100.0), 0, 100))
        claw_changed = (h_val != last_sent_h)

        if claw_changed:
            claw_resend_counter = CLM_RESEND_COUNT # 當狀態改變，重置重發計數器
            last_sent_h = h_val                    # 並更新最後的狀態

        claw_payload = ""
        should_send_claw = claw_resend_counter > 0

        if should_send_claw:
            # 在發送 clm 之前，先執行延遲 (如果 IK 也剛發送完)
            if ik_changed and IK_CLM_DELAY_MS > 0:
                time.sleep(IK_CLM_DELAY_MS / 1000.0)

            claw_payload = f"clm {h_val}"
            client.publish(TOPIC_CLAW, claw_payload)
            claw_resend_counter -= 1 # 每發送一次，計數器減 1
        
        # --- Logging: 顯示 IK 與 JM 兩行（使用者要求） ---
        if LOG_PUBLISHES and (ik_changed or should_send_claw):
            log_ik = ik_payload if ik_changed else '(no change)'
            log_claw = claw_payload if should_send_claw else f'(no change, resend_ctr:{claw_resend_counter})'
            # 顯示兩行：第一行原始 IK，第二行 jm（確保原 IK 不被更動）
            print(f"Published IK: {log_ik} | Claw: {log_claw}")
            # 顯示 JM 對照
            print(f"JM {jm_solution[0]} {jm_solution[1]} {jm_solution[2]} {jm_solution[3]} {jm_solution[4]} {jm_solution[5]}")

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
