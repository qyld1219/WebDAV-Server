package com.malixi.webdav.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 前台服务：负责拉起内置 webdav 内核、按需拉起 cloudflared 隧道，并把状态暴露给界面。
 * 两个内核都是以 .so 名字打包的官方静态二进制，从 nativeLibraryDir 直接执行。
 */
public class ServerService extends Service {

    public static volatile ServerService instance;

    private static final String CHANNEL_ID = "webdav_server";
    private static final int NOTIF_ID = 1001;
    private static final Pattern QUICK_URL = Pattern.compile("https://[a-z0-9-]+\\.trycloudflare\\.com");

    private Process serverProc;
    private Process tunnelProc;
    private volatile boolean serverRunning;
    private volatile int port = 8080;
    private volatile String tunnelUrl = "";
    private volatile String tunnelState = "off";   // off | starting | online | failed
    private volatile String tunnelError = "";
    private volatile boolean tunnelHTTP2;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private final List<String> logs = Collections.synchronizedList(new ArrayList<String>());

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        createChannel();
        startForegroundInternal("WebDAV 服务器已就绪");
        acquireLocks();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && intent.getAction() != null) {
            String action = intent.getAction();
            if ("start".equals(action)) {
                String dir = intent.getStringExtra("dir");
                if (dir == null || dir.isEmpty()) {
                    dir = getExternalFilesDir("共享").getAbsolutePath();
                }
                startServer(intent.getIntExtra("port", 8080),
                        intent.getStringExtra("user") != null ? intent.getStringExtra("user") : "webdav",
                        intent.getStringExtra("pass") != null ? intent.getStringExtra("pass") : "webdav123",
                        dir, false, true);
            } else if ("stop".equals(action)) {
                stopServer();
            } else if ("tunnel-start".equals(action)) {
                startTunnel();
            } else if ("tunnel-stop".equals(action)) {
                stopTunnel();
            }
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopTunnel();
        stopServer();
        releaseLocks();
        instance = null;
        super.onDestroy();
    }

    // ---------------- 服务 ----------------

    public boolean isServerRunning() { return serverRunning; }
    public int getPort() { return port; }
    public String getTunnelUrl() { return tunnelUrl; }
    public String getTunnelState() { return tunnelState; }
    public String getTunnelError() { return tunnelError; }
    public boolean isTunnelHTTP2() { return tunnelHTTP2; }

    public List<String> getLogs() {
        synchronized (logs) {
            return new ArrayList<>(logs);
        }
    }

    public void clearLogs() {
        synchronized (logs) { logs.clear(); }
    }

    private void log(String source, String text) {
        String stamp = String.format(Locale.US, "%s", android.text.format.DateFormat.format("HH:mm:ss", System.currentTimeMillis()));
        synchronized (logs) {
            logs.add("[" + stamp + "] [" + source + "] " + text);
            while (logs.size() > 1200) logs.remove(0);
        }
    }

    public void startServer(int port, String user, String pass, String dir, boolean readOnly, boolean listing) {
        if (serverRunning) return;
        this.port = port;
        try {
            writeConfig(port, user, pass, dir, readOnly, listing);
            File bin = new File(getApplicationInfo().nativeLibraryDir, "libwebdav.so");
            if (!bin.exists()) {
                log("服务", "内置 webdav 内核缺失：" + bin.getAbsolutePath());
                return;
            }
            ProcessBuilder pb = new ProcessBuilder(bin.getAbsolutePath(), "-c", configPath());
            pb.directory(getFilesDir());
            pb.redirectErrorStream(true);
            serverProc = pb.start();
            serverRunning = true;
            log("服务", "已启动服务进程（PID " + serverPid() + "），监听 0.0.0.0:" + port);
            pump(serverProc, "服务");
            updateNotification("共享中 · 端口 " + port);
        } catch (Exception e) {
            serverRunning = false;
            log("服务", "启动失败：" + e.getMessage());
        }
    }

    public void stopServer() {
        if (serverProc != null) {
            serverProc.destroy();
            try {
                final Process p = serverProc;
                new Thread(() -> {
                    try {
                        Thread.sleep(800);
                        p.destroyForcibly();
                    } catch (Exception ignored) { }
                }).start();
            } catch (Exception ignored) { }
            serverProc = null;
        }
        if (serverRunning) log("服务", "共享已停止");
        serverRunning = false;
        updateNotification("共享已停止");
    }

    // ---------------- 隧道 ----------------

    public void startTunnel() {
        if (tunnelProc != null) return;
        tunnelState = "starting";
        tunnelError = "";
        tunnelUrl = "";
        startTunnelProcess(false);
    }

    private void startTunnelProcess(boolean http2) {
        File bin = new File(getApplicationInfo().nativeLibraryDir, "libcloudflared.so");
        if (!bin.exists()) {
            tunnelState = "failed";
            tunnelError = "内置 cloudflared 内核缺失";
            log("隧道", tunnelError);
            return;
        }
        try {
            List<String> args = new ArrayList<>();
            args.add(bin.getAbsolutePath());
            args.add("tunnel");
            args.add("--no-autoupdate");
            args.add("--loglevel");
            args.add("info");
            if (http2) {
                args.add("--protocol");
                args.add("http2");
            }
            args.add("--url");
            args.add("http://127.0.0.1:" + port);
            ProcessBuilder pb = new ProcessBuilder(args);
            pb.directory(getFilesDir());
            pb.redirectErrorStream(true);
            pb.environment().put("HOME", getFilesDir().getAbsolutePath());
            pb.environment().put("TMPDIR", getCacheDir().getAbsolutePath());
            tunnelHTTP2 = http2;
            tunnelProc = pb.start();
            log("隧道", "隧道进程已启动（PID " + tunnelPid() + "）" + (http2 ? "，协议 http2" : ""));
            listenTunnel(tunnelProc);
        } catch (Exception e) {
            tunnelState = "failed";
            tunnelError = "启动失败：" + e.getMessage();
            log("隧道", tunnelError);
        }
    }

    private void listenTunnel(final Process p) {
        new Thread(() -> {
            boolean retried = false;
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    log("隧道", line);
                    String lower = line.toLowerCase(Locale.US);
                    if (line.contains("Registered tunnel connection")) {
                        tunnelState = "online";
                        log("隧道", tunnelUrl.isEmpty() ? "隧道已连通" : "公网地址已连通：" + tunnelUrl);
                    } else {
                        Matcher m = QUICK_URL.matcher(line);
                        if (m.find()) {
                            tunnelUrl = m.group();
                            log("隧道", "公网地址已分配：" + tunnelUrl + "，正在与 Cloudflare 边缘建立连接…");
                        } else if ((lower.contains("429") || lower.contains("too many requests")) && !"online".equals(tunnelState)) {
                            tunnelState = "failed";
                            tunnelError = "Cloudflare 临时限流（HTTP 429），请等待约 30 秒后重试";
                            log("隧道", "Cloudflare 拒绝了本次申请（429 限流）");
                            stopTunnel();
                            return;
                        } else if ((lower.contains("no recent network activity") || lower.contains("failed to dial a quic")) && !retried) {
                            retried = true;
                            log("隧道", "QUIC(UDP 7844) 不可用，自动切换到 HTTP/2 重连…");
                            stopTunnel();
                            tunnelState = "starting";
                            startTunnelProcess(true);
                            return;
                        }
                    }
                }
            } catch (Exception ignored) { }
            if (tunnelState.equals("starting") || tunnelState.equals("online")) {
                tunnelState = "failed";
                tunnelError = tunnelError.isEmpty() ? "隧道进程已退出" : tunnelError;
            }
        }).start();

        // 30 秒未连通即判定失败
        new Thread(() -> {
            try { Thread.sleep(30000); } catch (InterruptedException ignored) { }
            if ("starting".equals(tunnelState)) {
                tunnelState = "failed";
                tunnelError = "30 秒内未连通，请稍后重试";
                stopTunnel();
            }
        }).start();
    }

    public void stopTunnel() {
        if (tunnelProc != null) {
            final Process p = tunnelProc;
            tunnelProc = null;
            p.destroy();
            new Thread(() -> {
                try {
                    Thread.sleep(600);
                    p.destroyForcibly();
                } catch (Exception ignored) { }
            }).start();
        }
        if (!"off".equals(tunnelState)) log("隧道", "隧道已关闭");
        tunnelState = "off";
        tunnelUrl = "";
        tunnelError = "";
        tunnelHTTP2 = false;
    }

    // ---------------- 辅助 ----------------

    private void pump(final Process p, final String source) {
        new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) log(source, line);
            } catch (Exception ignored) { }
            if (source.equals("服务")) {
                serverRunning = false;
                log("服务", "服务进程已退出");
            }
        }).start();
    }

    private String serverPid() {
        try {
            return String.valueOf(pidOf(serverProc));
        } catch (Exception e) {
            return "?";
        }
    }

    private String tunnelPid() {
        try {
            return String.valueOf(pidOf(tunnelProc));
        } catch (Exception e) {
            return "?";
        }
    }

    private int pidOf(Process p) throws Exception {
        // Android 上没有 Process.pid()，用反射兜底；失败则返回 -1
        try {
            java.lang.reflect.Method m = Process.class.getMethod("pid");
            return (int) m.invoke(p);
        } catch (Exception e) {
            return -1;
        }
    }

    private String configPath() {
        return new File(getFilesDir(), "config.yml").getAbsolutePath();
    }

    private void writeConfig(int port, String user, String pass, String dir, boolean readOnly, boolean listing) throws IOException {
        String perm = readOnly ? "R" : "CRUD";
        String yaml = "# 由 WebDAV 服务器（Android）自动生成\n" +
                "address: 0.0.0.0\n" +
                "port: " + port + "\n" +
                "directory: " + yamlQuote(dir) + "\n" +
                "permissions: " + perm + "\n" +
                "prefix: /\n" +
                "debug: false\n" +
                "noSniff: false\n" +
                "behindProxy: false\n" +
                "listing:\n  enabled: " + listing + "\n  show_path: true\n" +
                "log:\n  format: console\n  colors: false\n  outputs:\n    - stderr\n" +
                "cors:\n  enabled: true\n  credentials: true\n  allowed_hosts:\n    - \"*\"\n" +
                "users:\n  - username: " + yamlQuote(user) + "\n    password: " + yamlQuote(pass) + "\n    permissions: " + perm + "\n";
        File f = new File(configPath());
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(yaml.getBytes(StandardCharsets.UTF_8));
        }
        File d = new File(dir);
        if (!d.exists()) d.mkdirs();
    }

    private static String yamlQuote(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    /** 局域网 IPv4（Wi-Fi 或热点） */
    public static String localIP() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InetAddress addr : Collections.list(ni.getInetAddresses())) {
                    if (addr instanceof Inet4Address && addr.isSiteLocalAddress()) {
                        return addr.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) { }
        return "127.0.0.1";
    }

    private void acquireLocks() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WebDAVServer:serve");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "WebDAVServer:wifi");
                wifiLock.setReferenceCounted(false);
                wifiLock.acquire();
            }
        } catch (Exception ignored) { }
    }

    private void releaseLocks() {
        try { if (wakeLock != null && wakeLock.isHeld()) wakeLock.release(); } catch (Exception ignored) { }
        try { if (wifiLock != null && wifiLock.isHeld()) wifiLock.release(); } catch (Exception ignored) { }
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "WebDAV 服务", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("WebDAV 服务器运行状态");
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) nm.createNotificationChannel(ch);
        }
    }

    private void startForegroundInternal(String text) {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            b = new Notification.Builder(this, CHANNEL_ID);
        } else {
            b = new Notification.Builder(this);
        }
        b.setContentTitle("WebDAV 服务器").setContentText(text).setSmallIcon(android.R.drawable.stat_sys_upload).setOngoing(true);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, b.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIF_ID, b.build());
        }
    }

    private void updateNotification(String text) {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            b = new Notification.Builder(this, CHANNEL_ID);
        } else {
            b = new Notification.Builder(this);
        }
        b.setContentTitle("WebDAV 服务器").setContentText(text).setSmallIcon(android.R.drawable.stat_sys_upload).setOngoing(true);
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIF_ID, b.build());
    }

    public static void ensureStarted(Context ctx) {
        Intent i = new Intent(ctx, ServerService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.startForegroundService(i);
        } else {
            ctx.startService(i);
        }
    }
}
