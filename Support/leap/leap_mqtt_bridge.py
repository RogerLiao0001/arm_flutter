#!/usr/bin/env python3
"""
Leap -> MQTT Bridge
- 讀取 Leap (leap python binding)
- 轉換為相對坐標（按下 'a' 鍵時歸零 current right-hand pos）
- 同步 publish 到 MQTT broker (178.128.54.195:1883)
- Topics: servo/x , servo/y , servo/z , servo/h
- Payload 格式：純文字或 JSON（下面使用 JSON 格式與你現有程式相容）
"""

import leap, time, json, threading, sys
import paho.mqtt.client as mqtt
from collections import deque

# ---------- CONFIG ----------
MQTT_BROKER = "178.128.54.195"
MQTT_PORT = 1883
TOPIC_X = "servo/x"
TOPIC_Y = "servo/y"
TOPIC_Z = "servo/z"
TOPIC_H = "servo/h"   # hand open/close (0..1 or mapped)
PUBLISH_FPS = 30      # 節流：每秒最多發多少幀
# --------------------------------

# state
zero_ref = None   # (x0,y0,z0), set when user presses 'a'
lock = threading.Lock()

# MQTT client
client = mqtt.Client()
client.connect(MQTT_BROKER, MQTT_PORT, 60)
client.loop_start()

def publish_xyzh(x,y,z,h):
    # 發 JSON；你可以改成單一數字 payload 如需
    client.publish(TOPIC_X, json.dumps({"v": round(x,3)}))
    client.publish(TOPIC_Y, json.dumps({"v": round(y,3)}))
    client.publish(TOPIC_Z, json.dumps({"v": round(z,3)}))
    client.publish(TOPIC_H, json.dumps({"v": round(h,3)}))

# keyboard listener (simple): 等待使用者輸入 'a' + Enter 來歸零
def keyboard_thread():
    global zero_ref
    print("Keyboard control: press 'a' + Enter to zero current RIGHT hand position.")
    while True:
        try:
            s = sys.stdin.readline().strip()
        except Exception:
            s = ""
        if s.lower() == 'a':
            with lock:
                zero_ref = last_right_hand_pos.copy() if last_right_hand_pos is not None else None
            print("Zero reference set to:", zero_ref)
            # 立即 publish a zero signal (you can change topic/payload)
            client.publish("servo/zero", json.dumps({"x":0,"y":0,"z":0,"h":0}))
        time.sleep(0.01)

# shared last hand pos
last_right_hand_pos = None  # [x,y,z,h]

# Listener
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
        global last_right_hand_pos, zero_ref
        if len(event.hands) == 0:
            return
        # pick the first right hand (or first hand)
        hand = None
        for h in event.hands:
            try:
                if str(h.type).endswith("Right"):
                    hand = h
                    break
            except Exception:
                pass
        if hand is None:
            hand = event.hands[0]

        # read palm position (mm)
        try:
            x = float(hand.palm.position.x)
            y = float(hand.palm.position.y)
            z = float(hand.palm.position.z)
        except Exception as e:
            # fallback if binding uses different names (shouldn't happen)
            print("Failed reading palm.position:", e)
            return

        # read hand open/close strength: common field is grab_strength (0..1)
        h_val = None
        for cand in ("grab_strength","grabStrength","grab", "grabStrengthValue","grab_strength_value","pinch_strength","pinch_strength"):
            if hasattr(hand, cand):
                try:
                    h_val = float(getattr(hand, cand))
                    break
                except:
                    pass
        if h_val is None:
            # 如果沒找到，將抓取指尖距離或設成 0
            h_val = 0.0

        # set last pos
        with lock:
            last_right_hand_pos = [x,y,z,h_val]
            if zero_ref is not None:
                xr, yr, zr, hr = zero_ref
                rx, ry, rz = x - xr, y - yr, z - zr
            else:
                rx, ry, rz = x, y, z

        # publish (throttled externally by Leap event rate)
        publish_xyzh(rx, ry, rz, h_val)


def main():
    # start keyboard thread
    t = threading.Thread(target=keyboard_thread, daemon=True)
    t.start()

    listener = BridgeListener()
    conn = leap.Connection()
    conn.add_listener(listener)
    with conn.open():
        conn.set_tracking_mode(leap.TrackingMode.Desktop)
        print("Bridge running. Move hand; press 'a' then Enter to zero.")
        try:
            while True:
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("Exiting.")

if __name__ == "__main__":
    main()

