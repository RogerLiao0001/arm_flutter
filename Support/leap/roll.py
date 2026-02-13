#!/usr/bin/env python3
# leap_mqtt_bridge_v3.py (v8.2 - Added Send Delay and Redundancy)
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
PUBLISH_FPS = 4 # 越小越慢

# ---------- 4. MQTT 設定 ----------
MQTT_BROKER = "178.128.54.195"
MQTT_PORT = 1883
TOPIC_BASE = "servo/arm2/"
MQTT_CONTROL_TOPIC = TOPIC_BASE + "cmd"
TOPIC_IK_POSE = TOPIC_BASE + "ik"
TOPIC_CLAW = TOPIC_BASE + "clm"

# ---------- 5. 發送時序與冗餘 (新增) ----------
# 在發送 IK 和 clm 訊息之間，增加一個微小的延遲，防止接收端來不及處理。
IK_CLM_DELAY_MS = 500  # 單位：毫秒。設為 0 表示不延遲。

# 當手爪狀態改變時，重複發送 clm 訊息的次數，以確保接收成功。
CLM_RESEND_COUNT = 3  # 設為 1 表示只發一次 (無冗餘)。

# ---------- 6. 其他功能開關 ----------
START_PUBLISH_AFTER_ZERO = True
LOG_PUBLISHES = True

# ============================
# ======== END CONFIG ========
# ============================

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
        
        if LOG_PUBLISHES and (ik_changed or should_send_claw):
            log_ik = ik_payload if ik_changed else '(no change)'
            log_claw = claw_payload if should_send_claw else f'(no change, resend_ctr:{claw_resend_counter})'
            print(f"Published IK: {log_ik} | Claw: {log_claw}")

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