#!/usr/bin/env python3
# test_hand_angles.py
# 測試 Leap Python binding 中，hand / palm / direction / normal / rotation 等屬性與可用的 pitch/yaw/roll 介面
# 使用方式：在 venv (python3.8) 中執行，將手放入 Leap 視野內，當偵測到第一隻手會列印出資訊並結束。

import leap, time, math, sys

def deg(rad):
    try:
        return float(rad) * 180.0 / math.pi
    except:
        return None

def try_call(obj, name):
    """嘗試取得 obj.name 或 呼叫 obj.name()，回傳 (found, value, how)"""
    if obj is None:
        return (False, None, None)
    # 屬性優先
    if hasattr(obj, name):
        try:
            v = getattr(obj, name)
            # 如果是 callable，呼叫一次
            if callable(v):
                try:
                    val = v()
                    return (True, val, "call()")
                except:
                    return (True, v, "attr(callable-not-called)")
            else:
                return (True, v, "attr")
        except Exception as e:
            return (True, f"<error reading attribute: {e}>", "attr-error")
    # 試試加上小括號的呼叫方式（某些 binding 只有 method）
    try:
        m = getattr(obj, name + "()")
    except:
        pass
    return (False, None, None)

def dump_vector(name, v):
    """試著從一個向量或物件擷取 x,y,z 與 pitch/yaw/roll (如果有)"""
    out = []
    if v is None:
        return f"{name}: None"
    # try x,y,z
    x = getattr(v, 'x', None)
    y = getattr(v, 'y', None)
    z = getattr(v, 'z', None)
    if x is not None and y is not None and z is not None:
        out.append(f"{name}.x={x}, y={y}, z={z}")
    else:
        out.append(f"{name} repr: {repr(v)}")

    # try pitch/yaw/roll methods or attributes
    for fn in ('pitch', 'yaw', 'roll'):
        found, val, how = try_call(v, fn)
        if found:
            try:
                ang_deg = deg(val)
            except:
                ang_deg = None
            out.append(f"{name}.{fn} ({how}) -> raw={val}  deg={ang_deg}")
    return " | ".join(out)

class InspectListener(leap.Listener):
    def on_connection_event(self, event):
        print("Listener: Connected to Leap service")

    def on_device_event(self, event):
        try:
            with event.device.open():
                info = event.device.get_info()
        except Exception:
            info = event.device.get_info()
        print("Listener: Found device", getattr(info, 'serial', repr(info)))

    def on_tracking_event(self, event):
        # Wait until we have at least one hand, then inspect it thoroughly and exit
        if len(event.hands) == 0:
            return
        h = event.hands[0]
        print("\n=== Detected first hand ===")
        # Basic repr
        try:
            print("hand repr:", repr(h))
        except Exception as e:
            print("hand repr error:", e)

        # show top-level attributes (short list)
        try:
            attrs = [n for n in dir(h) if not n.startswith('_')]
            print("\n-- hand attributes (sample) --")
            print(", ".join(attrs))
        except Exception as e:
            print("could not list hand attributes:", e)

        # Try common properties: direction, palm, rotation, orientation, quaternion, etc.
        candidates = ['direction', 'palm', 'palm_normal', 'palmNormal', 'normal', 'normalVector',
                      'rotation', 'orientation', 'basis', 'basis_matrix', 'get_rotation', 'quaternion',
                      'pitch', 'yaw', 'roll', 'rotation_angle', 'rotation_axis']

        found_any = False
        for c in candidates:
            if hasattr(h, c):
                found_any = True
                try:
                    val = getattr(h, c)
                    print(f"\nhand.{c} (type={type(val)}):")
                    # If it's an object, try to print x,y,z or repr
                    try:
                        x = getattr(val, 'x', None)
                        y = getattr(val, 'y', None)
                        z = getattr(val, 'z', None)
                        if x is not None and y is not None and z is not None:
                            print(f"  -> x={x}, y={y}, z={z}")
                        else:
                            print("  -> repr:", repr(val))
                    except Exception as e:
                        print("  -> (error reading vector coords):", e)
                    # try calling pitch/yaw/roll on it
                    for fn in ('pitch','yaw','roll'):
                        fnd, v, how = try_call(val, fn)
                        if fnd:
                            print(f"  -> {c}.{fn} ({how}) = {v} (deg={deg(v)})")
                except Exception as e:
                    print(f"  error reading hand.{c}: {e}")

        # Inspect hand.direction explicitly (if present)
        if hasattr(h, 'direction'):
            try:
                d = h.direction
                print("\n-- hand.direction --")
                print(dump_vector("direction", d))
            except Exception as e:
                print("Error reading hand.direction:", e)
        else:
            print("\nhand.direction not found")

        # Inspect hand.palm and palm internals
        if hasattr(h, 'palm'):
            try:
                p = h.palm
                print("\n-- hand.palm --")
                print("palm repr:", repr(p))
                # palm attributes
                pal_attrs = [n for n in dir(p) if not n.startswith('_')]
                print("palm attributes:", ", ".join(pal_attrs))
                # check common names inside palm for normal vector
                for name in ('normal', 'normal_vector', 'normalVector', 'palm_normal', 'palmNormal'):
                    if hasattr(p, name):
                        val = getattr(p, name)
                        print(f"palm.{name} found -> {dump_vector('palm.'+name, val)}")
                # try methods on palm such as roll/pitch/yaw
                for fn in ('pitch','yaw','roll'):
                    fnd, v, how = try_call(p, fn)
                    if fnd:
                        print(f"palm.{fn} ({how}) = {v} (deg={deg(v)})")
            except Exception as e:
                print("Error inspecting palm:", e)
        else:
            print("\nhand.palm not found")

        # Try to find quaternion/rotation on hand (common names)
        for name in ('rotation', 'rotation_matrix', 'rotation_angle', 'rotation_axis', 'quaternion', 'basis'):
            if hasattr(h, name):
                try:
                    val = getattr(h, name)
                    print(f"\nhand.{name} found -> type {type(val)} repr: {repr(val)}")
                    # attempt to print x,y,z,w if quaternion-like
                    qw = getattr(val, 'w', None)
                    qx = getattr(val, 'x', None)
                    qy = getattr(val, 'y', None)
                    qz = getattr(val, 'z', None)
                    if qw is not None and qx is not None:
                        print(f"  quaternion w,x,y,z = {qw}, {qx}, {qy}, {qz}")
                except Exception as e:
                    print(f"Error reading hand.{name}: {e}")

        # Try to call hand.direction.pitch/yaw/roll if available
        try:
            if hasattr(h, 'direction'):
                d = h.direction
                for fn in ('pitch','yaw','roll'):
                    if hasattr(d, fn):
                        try:
                            val = getattr(d, fn)()
                            print(f"direction.{fn}() = {val} rad -> {deg(val)} deg")
                        except Exception as e:
                            print(f"direction.{fn}() call error: {e}")
        except Exception as e:
            print("Error calling direction.* methods:", e)

        print("\n=== End of inspection (exiting) ===")
        # exit program after first inspection
        sys.exit(0)


def main():
    listener = InspectListener()
    conn = leap.Connection()
    conn.add_listener(listener)
    print("Waiting for a hand to inspect... Put your hand in view.")
    with conn.open():
        try:
            while True:
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("Interrupted")

if __name__ == "__main__":
    main()
