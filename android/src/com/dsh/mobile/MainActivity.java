package com.dsh.mobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.view.KeyEvent;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * The workspace window: one full-bleed WebView pointed at the desktop.
 *
 * <p>Everything the desktop UI can do, this does — it is the same client
 * bundle. The only genuinely native work here is the parts a WebView does not
 * give you for free: the file chooser for attachments, back-button routing into
 * the SPA, keeping the socket alive across screen-off, and an honest error
 * panel instead of Chrome's "webpage not available" wall.
 */
public class MainActivity extends Activity {

    private static final int REQ_FILE_CHOOSER = 1001;

    private WebView webView;
    private ProgressBar progress;
    private View errorPanel;
    private TextView errorDetail;

    private ValueCallback<Uri[]> fileCallback;
    private PowerManager.WakeLock wakeLock;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        if (!Prefs.isConfigured(this)) {
            startActivity(new Intent(this, SetupActivity.class));
            finish();
            return;
        }

        setContentView(R.layout.activity_main);

        webView = findViewById(R.id.webview);
        progress = findViewById(R.id.progress);
        errorPanel = findViewById(R.id.errorPanel);
        errorDetail = findViewById(R.id.errorDetail);

        findViewById(R.id.errorRetry).setOnClickListener(v -> {
            errorPanel.setVisibility(View.GONE);
            loadWorkspace();
        });
        findViewById(R.id.errorSettings).setOnClickListener(v -> {
            Prefs.clear(this);
            startActivity(new Intent(this, SetupActivity.class));
            finish();
        });

        configureWebView();
        applyImmersive(Prefs.immersive(this));
        applyWakeLock(Prefs.wakeLock(this));
        loadWorkspace();
    }

    private void configureWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setSupportZoom(false);
        settings.setBuiltInZoomControls(false);
        settings.setMediaPlaybackRequiresUserGesture(false);
        // The client bundle loads only from the desktop origin. File access is
        // needed for attachment previews the desktop UI renders inline.
        settings.setAllowFileAccess(true);
        settings.setAllowContentAccess(true);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // The desktop is plain HTTP over Tailscale; the client bundle may
            // still pull HTTPS assets. Permit the mix rather than break the UI.
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
            CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);
        }
        CookieManager.getInstance().setAcceptCookie(true);

        webView.setWebViewClient(new WebViewClient() {

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                // Keep the workspace in-app; hand everything else to the system
                // so OAuth flows, docs links, and mailto: behave normally.
                if (uri.getHost() != null && uri.getHost().equals(Prefs.host(MainActivity.this))) {
                    return false;
                }
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, uri));
                } catch (Exception ignored) {
                    // No handler installed for this scheme — staying put beats crashing.
                }
                return true;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                progress.setVisibility(View.GONE);
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request,
                                        WebResourceError error) {
                // Subresource failures are noisy and expected on a flaky link.
                // Only a failed main document means the workspace is unreachable.
                if (request.isForMainFrame()) {
                    showUnreachable(String.valueOf(error.getDescription()));
                }
            }

            @SuppressWarnings("deprecation")
            @Override
            public void onReceivedError(WebView view, int errorCode, String description,
                                        String failingUrl) {
                if (failingUrl != null && failingUrl.equals(view.getUrl())) {
                    showUnreachable(description);
                }
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {

            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                if (newProgress < 100) {
                    progress.setVisibility(View.VISIBLE);
                    progress.setProgress(newProgress);
                } else {
                    progress.setVisibility(View.GONE);
                }
            }

            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback,
                                             FileChooserParams params) {
                if (fileCallback != null) {
                    fileCallback.onReceiveValue(null);
                }
                fileCallback = callback;
                try {
                    Intent intent = params.createIntent();
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                    startActivityForResult(intent, REQ_FILE_CHOOSER);
                    return true;
                } catch (Exception e) {
                    fileCallback = null;
                    return false;
                }
            }

            @Override
            public void onPermissionRequest(PermissionRequest request) {
                // Deny by default: this client never needs camera or mic, and a
                // prompt here would be a phishing surface, not a feature.
                request.deny();
            }
        });
    }

    /**
     * Load with the token so a lapsed session cookie re-mints itself. The
     * server only honours this for a GET of {@code /} with exactly one token
     * parameter; it then sets the cookie and redirects to a clean path.
     */
    private void loadWorkspace() {
        errorPanel.setVisibility(View.GONE);
        webView.loadUrl(Prefs.authenticatedUrl(this));
    }

    private void showUnreachable(String detail) {
        progress.setVisibility(View.GONE);
        errorDetail.setText(getString(R.string.err_help,
                Prefs.origin(this) + "\n" + detail));
        errorPanel.setVisibility(View.VISIBLE);
    }

    private void applyImmersive(boolean enabled) {
        View decor = getWindow().getDecorView();
        if (enabled) {
            decor.setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        } else {
            decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        }
    }

    /**
     * A partial wake lock keeps the WebSocket generation alive while the screen
     * is off, so a long agent run keeps streaming instead of reconnecting on
     * unlock. Off by default — it costs battery and the connection recovers on
     * its own.
     */
    @SuppressWarnings("deprecation")
    private void applyWakeLock(boolean enabled) {
        if (enabled) {
            if (wakeLock == null) {
                PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dsh:session");
                wakeLock.setReferenceCounted(false);
            }
            if (!wakeLock.isHeld()) {
                wakeLock.acquire();
            }
        } else if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(0, 1, 0, R.string.menu_reload);
        menu.add(0, 2, 1, R.string.menu_settings);
        menu.add(0, 3, 2, R.string.menu_immersive)
                .setCheckable(true)
                .setChecked(Prefs.immersive(this));
        menu.add(0, 4, 3, R.string.menu_wakelock)
                .setCheckable(true)
                .setChecked(Prefs.wakeLock(this));
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        switch (item.getItemId()) {
            case 1:
                loadWorkspace();
                return true;
            case 2:
                startActivity(new Intent(this, SetupActivity.class));
                finish();
                return true;
            case 3:
                boolean immersive = !Prefs.immersive(this);
                Prefs.setImmersive(this, immersive);
                item.setChecked(immersive);
                applyImmersive(immersive);
                return true;
            case 4:
                boolean wake = !Prefs.wakeLock(this);
                Prefs.setWakeLock(this, wake);
                item.setChecked(wake);
                applyWakeLock(wake);
                return true;
            default:
                return super.onOptionsItemSelected(item);
        }
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            // The SPA owns its own history; walk it before we ever consider
            // leaving the app.
            if (webView != null && webView.canGoBack()) {
                webView.goBack();
                return true;
            }
            new AlertDialog.Builder(this)
                    .setMessage(R.string.exit_confirm)
                    .setPositiveButton(android.R.string.ok, (d, w) -> finish())
                    .setNegativeButton(android.R.string.cancel, null)
                    .show();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQ_FILE_CHOOSER) {
            if (fileCallback != null) {
                Uri[] result = null;
                if (resultCode == RESULT_OK && data != null) {
                    if (data.getClipData() != null) {
                        int count = data.getClipData().getItemCount();
                        result = new Uri[count];
                        for (int i = 0; i < count; i++) {
                            result[i] = data.getClipData().getItemAt(i).getUri();
                        }
                    } else if (data.getData() != null) {
                        result = new Uri[]{data.getData()};
                    }
                }
                fileCallback.onReceiveValue(result);
                fileCallback = null;
            }
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // A phone that slept through a desktop restart comes back to a dead
        // socket. Cheap check: if the page is gone, re-run the token load.
        if (webView != null && webView.getUrl() == null) {
            loadWorkspace();
        }
    }

    @Override
    protected void onDestroy() {
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
        if (webView != null) {
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
