package s.s.saturn;

import android.content.Intent;
import android.os.Bundle;

import androidx.annotation.NonNull;
import androidx.webkit.ProxyConfig;
import androidx.webkit.ProxyController;
import androidx.webkit.WebViewFeature;

import com.ryanheise.audioservice.AudioServiceActivity;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends AudioServiceActivity {
    private static final String CHANNEL = "s.s.saturn/native";
    private static final String WEBVIEW_PROXY_CHANNEL = "s.s.saturn/webview_proxy";
    private String intentPreload;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        Intent intent = getIntent();
        intentPreload = intent.getStringExtra("preload");
        super.onCreate(savedInstanceState);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), WEBVIEW_PROXY_CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if (!call.method.equals("configure")) {
                        result.notImplemented();
                        return;
                    }
                    String address = call.argument("address");
                    if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
                        if (address == null || address.isEmpty()) {
                            result.success(null);
                        } else {
                            result.error("UNSUPPORTED", "Android WebView proxy override is unavailable", null);
                        }
                        return;
                    }
                    try {
                        if (address == null || address.isEmpty()) {
                            ProxyController.getInstance().clearProxyOverride(
                                    getMainExecutor(), () -> result.success(null));
                        } else {
                            ProxyConfig config = new ProxyConfig.Builder()
                                    .addProxyRule("http://" + address)
                                    .build();
                            ProxyController.getInstance().setProxyOverride(
                                    config, getMainExecutor(), () -> result.success(null));
                        }
                    } catch (RuntimeException error) {
                        result.error("PROXY_ERROR", error.getMessage(), null);
                    }
                });
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if (call.method.equals("getPreloadInfo")) {
                        result.success(intentPreload);
                        intentPreload = null;
                    } else {
                        result.notImplemented();
                    }
                });
    }
}
