#!/usr/bin/env python3
# leap_mqtt_bridge_v3.py (modified)
# 用法：
#   source venv38/bin/activate
#   python leap_mqtt_bridge_v3.py
#
# 鍵盤控制 (單鍵觸發，不需 Enter):
#   a  -> 歸零並啟用 publishing (把當前右手位置設為原點，並發送預設歸零角度)
#   s  -> 暫停 / 恢復 (toggle)
#   q  -> 退出程式
#
# MQTT 遠端控制 (topic: servo/arm2/cmd)
#   發送 payload "zero" / "pause" / "resume" / "stop"
#
# 注意：
#  - 程式預設 **不會在未歸零前發送**，請先按 a 歸零才開始動作。
#  - 若以 launchd/daemon 背景執行，請使用 MQTT 控制 topic。

import leap, time, json, threading, sys, signal
from math import copysign
import paho.mqtt.client as mqtt
import termios, tty  # 用於單鍵讀取

# ============================
# ========== CONFIG ==========
# ============================

# ---------- 主要控制參數 (最常用) ----------
SCALE_MM = 100.0           # 靈敏度：移動 +/- SCALE_MM (mm) 對應馬達角度中心到邊緣
PUBLISH_FPS = 20           # 最大發送頻率 (Hz)，調小可減輕網路與 ESP 壓力
STEP = 5                   # 角度量化步長 (一次跳動的最小單位，可防抖)

# ---------- 歸零時的預設角度 ----------
# 按 'a' 或收到 'zero' 指令時，會發送這些值
ZERO_ANGLES = {
    'l': 200, 'a': 90, 'z': 100, 'h': 100,
    'b': 90,  'd': 83, 'f': 90,  'c': 90, 'e': 90
}

# ---------- MQTT 設定 ----------
MQTT_BROKER = "178.128.54.195"      # MQTT Broker 位址
MQTT_PORT = 1883                    # MQTT Port
TOPIC_BASE = "servo/arm2/"          # Topic 根路徑
MQTT_CONTROL_TOPIC = TOPIC_BASE + "cmd"  # 遠端控制 Topic

# ---------- 控制標籤 (請與 ESP 端一致) ----------
LABEL_LEFT_RIGHT = 'a'   # Leap x -> 左右
LABEL_UP_DOWN    = 'z'   # Leap y -> 上下
LABEL_FORWARD    = 'l'   # Leap z -> 前後
LABEL_CLAW       = 'h'   # grab_strength -> 開合

# ---------- 映射與量化 ----------
ANGLE_MIN = 0              # ESP 馬達最小角度值
ANGLE_MAX = 500            # ESP 馬達最大角度
CENTER_ANGLE = (ANGLE_MIN + ANGLE_MAX) // 2
MIN_PUBLISH_DELTA = STEP   # 最小發送變動閥值

# ---------- 啟動與偵測 ----------
START_PUBLISH_AFTER_ZERO = True  # 建議 True，按 'a' 歸零後才啟動
DETECT_X_RANGE = None      # e.g., (-200, 200) 手部偵測有效 X 範圍 (mm)
DETECT_Y_RANGE = None      # e.g., (50, 250)  手部偵測有效 Y 範圍 (mm)
DETECT_Z_RANGE = None      # e.g., (-200, 200) 手部偵測有效 Z 範圍 (mm)

# ---------- 功能開關 (較少用) ----------
USE_H_AS_BINARY = False    # True: 手爪只有開/關, False: 0..100 連續值
H_BINARY_THRESHOLD = 0.5   # 若 USE_H_AS_BINARY=True，抓取強度超過此閥值視為 "關"
USE_SMOOTHING = False      # True: 啟用 EMA 低通濾波，讓移動更平滑 (會有些許延遲)
SMOOTHING_ALPHA = 0.3      # 平滑度 (0..1)，值越小越平滑但延遲越大
ENABLE_SERIAL = False      # True: 啟用 Serial 同步有線輸出 (備援)
LOG_PUBLISHES = True       # True: 在終端機印出發送的訊息
EXIT_ON_MQTT_ERROR = False # True: MQTT 連線失敗時直接退出程式

# ---------- Serial 設定 (若啟用) ----------
SERIAL_PORT = "/dev/tty.SLAB_USBtoUART"
SERIAL_BAUD = 115200
SERIAL_SEND_FORMAT = "{a},{z},{l},{h}\n"

# ============================
# ======== END CONFIG ========
# ============================

# Derived constants (不用改)
TOPIC_A = TOPIC_BASE + LABEL_LEFT_RIGHT
TOPIC_Z = TOPIC_BASE + LABEL_UP_DOWN
TOPIC_L = TOPIC_BASE + LABEL_FORWARD
TOPIC_H = TOPIC_BASE + LABEL_CLAW

# ---------------- init MQTT ----------------
client = mqtt.Client()

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print(f"Connected to MQTT broker {MQTT_BROKER}:{MQTT_PORT}")
        client.subscribe(MQTT_CONTROL_TOPIC)
    else:
        print("MQTT connect failed with rc:", rc)
        if EXIT_ON_MQTT_ERROR:
            sys.exit(1)

def on_message(client, userdata, msg):
    try:
        payload = msg.payload.decode('utf-8').strip().lower()
    except:
        payload = ''
    print("MQTT control received:", payload)
    if payload == "zero":
        do_zero_command()
    elif payload == "pause":
        do_pause_command()
    elif payload == "resume":
        do_resume_command()
    elif payload == "stop":
        do_stop_command()
    else:
        print("Unknown MQTT command:", payload)

client.on_connect = on_connect
client.on_message = on_message
client.connect(MQTT_BROKER, MQTT_PORT, 60)
client.loop_start()

# ---------------- optional serial init ----------------
ser = None
if ENABLE_SERIAL:
    try:
        import serial
        ser = serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=0.01)
        print("Serial port opened:", SERIAL_PORT, SERIAL_BAUD)
    except Exception as e:
        print("Serial init failed:", e)
        ser = None

# ---------------- state ----------------
zero_ref = None
enabled = not START_PUBLISH_AFTER_ZERO
paused = False
running = True
last_sent = {LABEL_LEFT_RIGHT: None, LABEL_UP_DOWN: None, LABEL_FORWARD: None, LABEL_CLAW: None}
last_publish_time = 0.0
lock = threading.Lock()
last_right_hand_pos = None
smoothed = None

# ---------------- helper functions ----------------
def getch():
    """Gets a single character from standard input. Does not echo to the screen."""
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setcbreak(sys.stdin.fileno())
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def quantize_angle(a):
    return int(round(a / STEP) * STEP)

def mm_to_angle(mm_value):
    half_span = CENTER_ANGLE - ANGLE_MIN
    if SCALE_MM == 0:
        ratio = 0
    else:
        ratio = mm_value / SCALE_MM
    angle = CENTER_ANGLE + ratio * half_span
    return clamp(angle, ANGLE_MIN, ANGLE_MAX)

def detect_in_range(x,y,z):
    if DETECT_X_RANGE and not (DETECT_X_RANGE[0] <= x <= DETECT_X_RANGE[1]):
        return False
    if DETECT_Y_RANGE and not (DETECT_Y_RANGE[0] <= y <= DETECT_Y_RANGE[1]):
        return False
    if DETECT_Z_RANGE and not (DETECT_Z_RANGE[0] <= z <= DETECT_Z_RANGE[1]):
        return False
    return True

def publish_angle(topic, angle):
    payload = json.dumps({"angle": int(angle)})
    client.publish(topic, payload)

def serial_send(a_val, z_val, l_val, h_val):
    if ser is None:
        return
    try:
        s = SERIAL_SEND_FORMAT.format(a=int(a_val), z=int(z_val), l=int(l_val), h=int(h_val))
        ser.write(s.encode())
    except Exception as e:
        print("Serial send error:", e)

def publish_all(rx, ry, rz, grab):
    """Map rx,ry,rz (mm relative) and grab (0..1) to topics and publish quantized."""
    global smoothed
    if USE_SMOOTHING:
        if smoothed is None:
            smoothed = [rx, ry, rz, grab]
        else:
            smoothed[0] = smoothed[0] * (1 - SMOOTHING_ALPHA) + rx * SMOOTHING_ALPHA
            smoothed[1] = smoothed[1] * (1 - SMOOTHING_ALPHA) + ry * SMOOTHING_ALPHA
            smoothed[2] = smoothed[2] * (1 - SMOOTHING_ALPHA) + rz * SMOOTHING_ALPHA
            smoothed[3] = smoothed[3] * (1 - SMOOTHING_ALPHA) + grab * SMOOTHING_ALPHA
        rx, ry, rz, grab = smoothed

    map_vals = {}
    map_vals[LABEL_LEFT_RIGHT] = mm_to_angle(rx)
    map_vals[LABEL_UP_DOWN]    = mm_to_angle(ry)
    map_vals[LABEL_FORWARD]    = mm_to_angle(rz)

    if USE_H_AS_BINARY:
        h_val = 0 if grab > H_BINARY_THRESHOLD else 100
    else:
        h_val = clamp(round((1.0 - grab) * 100.0), 0, 100)
    map_vals[LABEL_CLAW] = h_val

    sent = []
    global last_sent
    for label, raw_angle in map_vals.items():
        angle_q = quantize_angle(raw_angle)
        prev = last_sent.get(label)
        if prev is None or abs(angle_q - prev) >= MIN_PUBLISH_DELTA:
            topic = TOPIC_BASE + label
            publish_angle(topic, angle_q)
            last_sent[label] = angle_q
            sent.append((label, angle_q))

    if ENABLE_SERIAL:
        try:
            a_val = map_vals[LABEL_LEFT_RIGHT]
            z_val = map_vals[LABEL_UP_DOWN]
            l_val = map_vals[LABEL_FORWARD]
            h_val = map_vals[LABEL_CLAW]
            serial_send(a_val, z_val, l_val, h_val)
        except Exception:
            pass

    if LOG_PUBLISHES and sent:
        print("Published:", sent)
    return sent

# ---------------- control action handlers ----------------
def do_zero_command():
    global zero_ref, enabled, paused
    with lock:
        if last_right_hand_pos is not None:
            zero_ref = last_right_hand_pos.copy()
            enabled = True
            paused = False
            print("\nZero reference set:", zero_ref)
            
            # 發布所有預設的歸零角度
            print("Publishing zero angles...")
            for label, angle in ZERO_ANGLES.items():
                topic = TOPIC_BASE + label
                publish_angle(topic, angle)
                print(f"  -> {topic}: {angle}")
            # 更新 last_sent 避免立即被覆蓋
            for label, angle in ZERO_ANGLES.items():
                if label in last_sent:
                   last_sent[label] = angle
        else:
            print("\nZero command received but no hand detected.")

def do_pause_command():
    global paused
    paused = True
    print("\nPaused via MQTT")

def do_resume_command():
    global paused, enabled
    paused = False
    enabled = True
    print("\nResumed via MQTT")

def do_stop_command():
    global running
    running = False
    print("\nStop command received via MQTT")

def keyboard_thread():
    global paused, running
    print("Keyboard: 'a' to zero/start, 's' to pause/resume, 'q' to quit.")
    while running:
        try:
            cmd = getch().lower()
            if cmd == 'a':
                do_zero_command()
            elif cmd == 's':
                paused = not paused
                print("\nPaused" if paused else "\nResumed")
            elif cmd == 'q':
                print("\nQuit command received.")
                running = False
                break
        except Exception as e:
            # 在背景執行時，stdin 可能不可用，會引發錯誤
            print("Keyboard thread error (this is expected if running as daemon):", e)
            break

# ---------------- Leap listener ----------------
class BridgeListener(leap.Listener):
    def on_connection_event(self, event):
        print("Connected to Leap service")

    def on_device_event(self, event):
        try:
            with event.device.open():
                info = event.device.get_info()
        except Exception:
            info = event.device.get_info()
        print("Found device", info.serial)

    def on_tracking_event(self, event):
        global last_right_hand_pos, last_publish_time
        if not running:
            return
        if len(event.hands) == 0:
            return

        hand = None
        for h in event.hands:
            try:
                if str(h.type).endswith("Right"):
                    hand = h
                    break
            except:
                pass
        if hand is None:
            hand = event.hands[0]

        try:
            x = float(hand.palm.position.x)
            y = float(hand.palm.position.y)
            z = float(hand.palm.position.z)
        except Exception:
            return

        try:
            grab = float(getattr(hand, "grab_strength", 0.0))
        except:
            grab = 0.0

        if not detect_in_range(x, y, z):
            return

        with lock:
            last_right_hand_pos = [x, y, z, grab]
            if zero_ref is not None:
                xr, yr, zr, _ = zero_ref
                rx, ry, rz = x - xr, y - yr, z - zr
            else:
                rx, ry, rz = x, y, z

        if not enabled or paused:
            return

        now = time.time()
        global last_publish_time
        if now - last_publish_time < 1.0 / PUBLISH_FPS:
            return
        last_publish_time = now

        publish_all(rx, ry, rz, grab)

# ---------------- signal handlers & main ----------------
def signal_handler(sig, frame):
    global running
    print("\nSignal received, shutting down...")
    running = False

def main():
    global running
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    t = threading.Thread(target=keyboard_thread, daemon=True)
    t.start()

    listener = BridgeListener()
    conn = leap.Connection()
    conn.add_listener(listener)
    with conn.open():
        conn.set_tracking_mode(leap.TrackingMode.Desktop)
        print("Bridge running (waiting for zero if START_PUBLISH_AFTER_ZERO=True).")
        try:
            while running:
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass

    client.loop_stop()
    client.disconnect()
    if ser:
        try:
            ser.close()
        except:
            pass
    print("Bridge stopped. Bye.")

if __name__ == "__main__":
    main()