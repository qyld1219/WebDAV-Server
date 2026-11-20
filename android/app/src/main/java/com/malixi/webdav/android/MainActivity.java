package com.malixi.webdav.android;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.provider.Settings;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 单页界面（不依赖 AndroidX/Compose，纯平台控件），轮询前台服务状态。
 */
public class MainActivity extends Activity {

    private SharedPreferences prefs;
    private TextView statusView, urlView, tunnelStateView, tunnelUrlView, logView;
    private EditText dirView, portView, userView, passView;
    private CheckBox readOnlyView;
    private Button serverBtn, tunnelBtn;
    private final Handler handler = new Handler();
    private boolean polling;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("cfg", MODE_PRIVATE);
        setContentView(buildUI());
        requestNotificationPermission();
        ServerService.ensureStarted(this);
    }

    private int dp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private View buildUI() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(18), dp(18), dp(18), dp(32));
        root.setBackgroundColor(Color.parseColor("#F5F6F8"));
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("WebDAV 服务器");
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("把手机存储变成标准 WebDAV 服务 · 内置 hacdias/webdav + cloudflared");
        sub.setTextSize(12);
        sub.setTextColor(Color.parseColor("#6B7280"));
        sub.setPadding(0, dp(4), 0, dp(12));
        root.addView(sub);

        statusView = new TextView(this);
        statusView.setText("已停止");
        statusView.setTextSize(13);
        statusView.setPadding(dp(10), dp(6), dp(10), dp(6));
        root.addView(statusView);
        setPill(statusView, "已停止", false);

        root.addView(label("共享目录"));
        dirView = new EditText(this);
        dirView.setText(prefs.getString("dir", defaultDir()));
        dirView.setTextSize(13);
        root.addView(dirView);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        left.setLayoutParams(new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        left.addView(label("端口"));
        portView = new EditText(this);
        portView.setInputType(InputType.TYPE_CLASS_NUMBER);
        portView.setText(String.valueOf(prefs.getInt("port", 8080)));
        portView.setTextSize(13);
        left.addView(portView);
        LinearLayout right = new LinearLayout(this);
        right.setOrientation(LinearLayout.VERTICAL);
        right.setLayoutParams(new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        right.addView(label("用户名"));
        userView = new EditText(this);
        userView.setText(prefs.getString("user", "webdav"));
        userView.setTextSize(13);
        right.addView(userView);
        row.addView(left);
        row.addView(right);
        root.addView(row);

        root.addView(label("密码"));
        passView = new EditText(this);
        passView.setText(prefs.getString("pass", "webdav123"));
        passView.setTextSize(13);
        root.addView(passView);

        readOnlyView = new CheckBox(this);
        readOnlyView.setText("只读共享（客户端只能下载）");
        readOnlyView.setTextSize(13);
        readOnlyView.setChecked(prefs.getBoolean("readOnly", false));
        root.addView(readOnlyView);

        serverBtn = new Button(this);
        serverBtn.setText("开始共享");
        serverBtn.setOnClickListener(v -> toggleServer());
        root.addView(serverBtn);

        urlView = new TextView(this);
        urlView.setTextSize(13);
        urlView.setTextColor(Color.parseColor("#111827"));
        urlView.setTypeface(Typeface.MONOSPACE);
        urlView.setPadding(dp(10), dp(8), dp(10), dp(8));
        urlView.setBackgroundColor(Color.parseColor("#FFFFFF"));
        urlView.setText("服务未运行");
        root.addView(urlView);

        Button copy = new Button(this);
        copy.setText("复制地址与账号");
        copy.setOnClickListener(v -> {
            String text = urlView.getText().toString() + "\n账号 " + userView.getText() + " · 密码 " + passView.getText();
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null) {
                cm.setPrimaryClip(ClipData.newPlainText("webdav", text));
                toast("已复制");
            }
        });
        root.addView(copy);

        root.addView(sectionTitle("远程访问（Cloudflare 快速隧道）"));
        tunnelStateView = new TextView(this);
        tunnelStateView.setText("未开启");
        tunnelStateView.setTextSize(13);
        root.addView(tunnelStateView);

        tunnelUrlView = new TextView(this);
        tunnelUrlView.setTextSize(12);
        tunnelUrlView.setTypeface(Typeface.MONOSPACE);
        tunnelUrlView.setTextColor(Color.parseColor("#0F766E"));
        tunnelUrlView.setText("");
        root.addView(tunnelUrlView);

        tunnelBtn = new Button(this);
        tunnelBtn.setText("开启快速隧道");
        tunnelBtn.setOnClickListener(v -> toggleTunnel());
        root.addView(tunnelBtn);

        TextView tip = new TextView(this);
        tip.setText("免账号，自动 HTTPS；地址随机且隧道重启后会变化。手机需能访问外网。");
        tip.setTextSize(11);
        tip.setTextColor(Color.parseColor("#6B7280"));
        tip.setPadding(0, dp(4), 0, dp(10));
        root.addView(tip);

        root.addView(sectionTitle("运行日志"));
        logView = new TextView(this);
        logView.setTextSize(11);
        logView.setTypeface(Typeface.MONOSPACE);
        logView.setTextColor(Color.parseColor("#CBD5E1"));
        logView.setBackgroundColor(Color.parseColor("#0F172A"));
        logView.setPadding(dp(10), dp(8), dp(10), dp(8));
        logView.setMaxLines(14);
        root.addView(logView);

        Button permBtn = new Button(this);
        permBtn.setText("授予「所有文件访问权限」（共享手机任意目录时必选）");
        permBtn.setTextSize(11);
        permBtn.setOnClickListener(v -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    Intent i = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:" + getPackageName()));
                    startActivity(i);
                } catch (Exception e) {
                    startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
                }
            } else {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + getPackageName())));
            }
        });
        root.addView(permBtn);
        return scroll;
    }

    private String defaultDir() {
        return Environment.getExternalStorageDirectory().getAbsolutePath() + "/WebDAV共享";
    }

    private TextView label(String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(12);
        t.setTextColor(Color.parseColor("#6B7280"));
        t.setPadding(0, dp(10), 0, dp(2));
        return t;
    }

    private TextView sectionTitle(String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(14);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, dp(18), 0, dp(4));
        return t;
    }

    private void setPill(TextView v, String text, boolean on) {
        v.setText(text);
        v.setTextColor(on ? Color.parseColor("#15803D") : Color.parseColor("#6B7280"));
        v.setBackgroundColor(on ? Color.parseColor("#F0FDF4") : Color.parseColor("#FFFFFF"));
    }

    private void toggleServer() {
        ServerService svc = ServerService.instance;
        if (svc == null) { toast("服务尚未就绪，请稍候"); return; }
        if (svc.isServerRunning()) {
            svc.stopServer();
            return;
        }
        int port;
        try {
            port = Integer.parseInt(portView.getText().toString().trim());
        } catch (Exception e) {
            toast("端口不合法");
            return;
        }
        String dir = dirView.getText().toString().trim();
        if (dir.isEmpty()) dir = defaultDir();
        String user = userView.getText().toString().trim();
        String pass = passView.getText().toString();
        if (user.isEmpty() || pass.isEmpty()) { toast("请填写用户名和密码"); return; }
        prefs.edit()
                .putString("dir", dir).putInt("port", port)
                .putString("user", user).putString("pass", pass)
                .putBoolean("readOnly", readOnlyView.isChecked())
                .apply();
        svc.startServer(port, user, pass, dir, readOnlyView.isChecked(), true);
        toast("正在启动服务…");
    }

    private void toggleTunnel() {
        ServerService svc = ServerService.instance;
        if (svc == null) { toast("服务尚未就绪"); return; }
        if (!svc.isServerRunning()) { toast("请先开始共享"); return; }
        if ("off".equals(svc.getTunnelState())) {
            svc.startTunnel();
        } else {
            svc.stopTunnel();
        }
    }

    private void refresh() {
        ServerService svc = ServerService.instance;
        if (svc == null) return;
        boolean running = svc.isServerRunning();
        if (running) {
            setPill(statusView, "运行中", true);
            serverBtn.setText("停止共享");
            String ip = ServerService.localIP();
            urlView.setText("http://" + ip + ":" + svc.getPort() + "/\n本机自环：http://127.0.0.1:" + svc.getPort() + "/");
        } else {
            setPill(statusView, "已停止", false);
            serverBtn.setText("开始共享");
            urlView.setText("服务未运行");
        }

        String ts = svc.getTunnelState();
        String host = svc.getTunnelUrl();
        String label;
        if ("off".equals(ts)) label = "未开启";
        else if ("starting".equals(ts)) label = "正在建立隧道…";
        else if ("online".equals(ts)) label = "已连接";
        else label = "失败：" + svc.getTunnelError();
        tunnelStateView.setText(label + (svc.isTunnelHTTP2() ? "（HTTP/2）" : ""));
        tunnelUrlView.setText(host);
        tunnelBtn.setText("off".equals(ts) ? "开启快速隧道" : "关闭隧道");

        java.util.List<String> lines = svc.getLogs();
        StringBuilder sb = new StringBuilder();
        int start = Math.max(0, lines.size() - 40);
        for (int i = start; i < lines.size(); i++) sb.append(lines.get(i)).append('\n');
        logView.setText(sb.toString());
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 12);
        }
    }

    private void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
    }

    @Override
    protected void onResume() {
        super.onResume();
        polling = true;
        handler.post(new Runnable() {
            @Override
            public void run() {
                if (!polling) return;
                refresh();
                handler.postDelayed(this, 1000);
            }
        });
    }

    @Override
    protected void onPause() {
        polling = false;
        super.onPause();
    }
}
