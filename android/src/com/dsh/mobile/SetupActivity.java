package com.dsh.mobile;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;

import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * First-run and repair screen: paste the LAN URL, verify it, save it.
 *
 * <p>The URL carries a process-lifetime token, so this screen is also how you
 * re-pair after the desktop restarts — every {@code dsh web} boot mints a new
 * token and the old one stops working. "Forget" exists for exactly that.
 */
public class SetupActivity extends Activity {

    private EditText urlInput;
    private TextView status;
    private TextView lastKnown;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_setup);

        urlInput = findViewById(R.id.urlInput);
        status = findViewById(R.id.status);
        lastKnown = findViewById(R.id.lastKnown);

        Button save = findViewById(R.id.saveButton);
        Button test = findViewById(R.id.testButton);
        Button clear = findViewById(R.id.clearButton);

        if (Prefs.isConfigured(this)) {
            urlInput.setText(Prefs.authenticatedUrl(this));
            lastKnown.setText("Last saved origin: " + Prefs.origin(this));
            // Already paired — go straight through.
            openMain();
        }

        save.setOnClickListener(v -> {
            DshUrl parsed = DshUrl.parse(urlInput.getText().toString());
            if (parsed == null) {
                status.setTextColor(getColor(R.color.dsh_danger));
                status.setText(R.string.setup_bad_url);
                return;
            }
            Prefs.save(this, parsed.scheme, parsed.host, parsed.port, parsed.token);
            status.setTextColor(getColor(R.color.dsh_text_dim));
            status.setText(parsed.token.isEmpty()
                    ? "Saved. No token in that URL — the server will reject /api until you paste one with ?token=."
                    : "Saved " + parsed.host + ":" + parsed.port);
            openMain();
        });

        test.setOnClickListener(v -> {
            DshUrl parsed = DshUrl.parse(urlInput.getText().toString());
            if (parsed == null) {
                status.setTextColor(getColor(R.color.dsh_danger));
                status.setText(R.string.setup_bad_url);
                return;
            }
            status.setTextColor(getColor(R.color.dsh_text_dim));
            status.setText(R.string.setup_testing);
            probe(parsed);
        });

        clear.setOnClickListener(v -> {
            Prefs.clear(this);
            urlInput.setText("");
            lastKnown.setText("");
            status.setTextColor(getColor(R.color.dsh_text_dim));
            status.setText("Cleared.");
        });
    }

    /**
     * Plain TCP/HTTP reachability check. Resolves the URI only far enough to
     * prove the phone can open a socket to the port — it deliberately does not
     * validate the token, because a 401 still proves the network path works and
     * that distinction is the whole point of a separate Test button.
     */
    private void probe(final DshUrl target) {
        io.execute(() -> {
            String result;
            boolean ok = false;
            HttpURLConnection conn = null;
            try {
                URL url = new URL(target.scheme + "://" + target.host + ":" + target.port + "/");
                conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(5000);
                conn.setReadTimeout(5000);
                conn.setRequestMethod("GET");
                conn.setInstanceFollowRedirects(false);
                int code = conn.getResponseCode();
                ok = true;
                result = getString(R.string.setup_ok, code);
            } catch (IOException e) {
                String message = e.getMessage();
                result = getString(R.string.setup_fail,
                        TextUtils.isEmpty(message) ? e.getClass().getSimpleName() : message);
            } finally {
                if (conn != null) {
                    conn.disconnect();
                }
            }
            final String text = result;
            final boolean success = ok;
            main.post(() -> {
                status.setTextColor(getColor(success ? R.color.dsh_accent : R.color.dsh_danger));
                status.setText(text);
            });
        });
    }

    private void openMain() {
        startActivity(new Intent(this, MainActivity.class));
        finish();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        io.shutdownNow();
    }
}
