# inspect_hand.py
# 在 venv38 啟動後執行：python inspect_hand.py
# 將一隻手放到 Leap 視野內（右手），程式會印出第一隻 detected hand 的屬性和值，然後結束。

import leap, time, pprint, sys

class DumpListener(leap.Listener):
    def on_tracking_event(self, event):
        if len(event.hands) == 0:
            return
        h = event.hands[0]  # 取第一隻手
        print("=== Detected hand attributes (first hand) ===")
        attrs = [n for n in dir(h) if not n.startswith('_')]
        attrs.sort()
        for name in attrs:
            try:
                val = getattr(h, name)
                # 只印非 callable 的屬性，callable 可能是 method
                if callable(val):
                    print(f"{name}: <callable>")
                else:
                    # 列印簡短內容（避免太大）
                    try:
                        s = repr(val)
                        if len(s) > 200:
                            s = s[:200] + " ... (truncated)"
                    except Exception as e:
                        s = f"<value error: {e}>"
                    print(f"{name}: {s}")
            except Exception as e:
                print(f"{name}: <error reading attribute: {e}>")
        # 另外顯示常見的手掌位置與常見強度欄位
        print("\n--- quick access check ---")
        for cand in ("palm","palm_position","grab_strength","pinch_strength","pinch","grab","is_grab","palm.position"):
            try:
                parts = cand.split('.')
                obj = h
                for p in parts:
                    obj = getattr(obj, p)
                print(f"{cand} => {repr(obj)}")
            except Exception:
                pass
        print("=== END ===")
        sys.exit(0)

def main():
    conn = leap.Connection()
    conn.add_listener(DumpListener())
    with conn.open():
        conn.set_tracking_mode(leap.TrackingMode.Desktop)
        print("Waiting for hand... (put a hand in view, first hand will be inspected)")
        while True:
            time.sleep(0.1)

if __name__ == "__main__":
    main()

