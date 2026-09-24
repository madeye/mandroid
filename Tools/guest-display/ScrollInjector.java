import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;

/** Long-running app_process entry point that turns host scroll input into
 * mouse ACTION_SCROLL events. The emulator's gRPC wheel is dropped on the
 * phone image, and a synthesised touch drag becomes a click wherever no
 * scroll container intercepts it. Reads "display x y vscroll hscroll" lines
 * from stdin until EOF.
 */
public final class ScrollInjector {
    public static void main(String[] args) throws Exception {
        Object manager;
        try {
            manager = Class.forName("android.hardware.input.InputManagerGlobal")
                    .getMethod("getInstance").invoke(null);
        } catch (ClassNotFoundException e) {
            manager = Class.forName("android.hardware.input.InputManager")
                    .getMethod("getInstance").invoke(null);
        }
        Method inject = manager.getClass().getMethod("injectInputEvent", InputEvent.class, int.class);
        Method setDisplayId = InputEvent.class.getMethod("setDisplayId", int.class);
        MotionEvent.PointerProperties[] properties = { new MotionEvent.PointerProperties() };
        properties[0].id = 0;
        properties[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        System.out.println("scroll-ready");
        System.out.flush();

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        for (String line; (line = in.readLine()) != null; ) {
            String[] f = line.trim().split(" ");
            if (f.length != 5) continue;
            coords[0].clear();
            coords[0].x = Float.parseFloat(f[1]);
            coords[0].y = Float.parseFloat(f[2]);
            coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, Float.parseFloat(f[3]));
            coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, Float.parseFloat(f[4]));
            long now = SystemClock.uptimeMillis();
            MotionEvent event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, properties, coords,
                    0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
            setDisplayId.invoke(event, Integer.parseInt(f[0]));
            // INJECT_INPUT_EVENT_MODE_ASYNC: never wait for the app to consume it.
            inject.invoke(manager, event, 0);
            event.recycle();
        }
    }
}
