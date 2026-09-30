package com.dsh.mobile;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Persisted connection facts.
 *
 * <p>We store the parsed pieces rather than the pasted string so the app can
 * rebuild a token-bearing URL on every cold start. Re-sending the token is
 * deliberate: {@code authorizeIndex} only mints the session cookie for a GET
 * of pathname {@code /} carrying exactly one valid {@code token} parameter,
 * and the cookie expires. Re-presenting the token each launch is therefore
 * self-healing — if the cookie survived, nothing changes; if it lapsed, the
 * server mints a fresh one and redirects to a clean {@code /}.
 */
final class Prefs {

    private static final String FILE = "dsh_mobile";

    private static final String KEY_HOST = "host";
    private static final String KEY_PORT = "port";
    private static final String KEY_TOKEN = "token";
    private static final String KEY_SCHEME = "scheme";
    private static final String KEY_IMMERSIVE = "immersive";
    private static final String KEY_WAKELOCK = "wakelock";

    private Prefs() {
    }

    private static SharedPreferences store(Context context) {
        return context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    static boolean isConfigured(Context context) {
        SharedPreferences prefs = store(context);
        return !prefs.getString(KEY_HOST, "").isEmpty();
    }

    static void save(Context context, String scheme, String host, int port, String token) {
        store(context).edit()
                .putString(KEY_SCHEME, scheme)
                .putString(KEY_HOST, host)
                .putInt(KEY_PORT, port)
                .putString(KEY_TOKEN, token)
                .apply();
    }

    static void clear(Context context) {
        store(context).edit()
                .remove(KEY_HOST)
                .remove(KEY_PORT)
                .remove(KEY_TOKEN)
                .remove(KEY_SCHEME)
                .apply();
    }

    /** Bare origin with no token, e.g. {@code http://100.x.y.z:3080}. */
    static String origin(Context context) {
        SharedPreferences prefs = store(context);
        String scheme = prefs.getString(KEY_SCHEME, "http");
        String host = prefs.getString(KEY_HOST, "");
        int port = prefs.getInt(KEY_PORT, 3080);
        return scheme + "://" + host + ":" + port;
    }

    /** Origin plus the auth token, shaped the way the server expects it. */
    static String authenticatedUrl(Context context) {
        String token = store(context).getString(KEY_TOKEN, "");
        String origin = origin(context);
        if (token.isEmpty()) {
            return origin + "/";
        }
        return origin + "/?token=" + token;
    }

    static String host(Context context) {
        return store(context).getString(KEY_HOST, "");
    }

    static boolean immersive(Context context) {
        return store(context).getBoolean(KEY_IMMERSIVE, false);
    }

    static void setImmersive(Context context, boolean value) {
        store(context).edit().putBoolean(KEY_IMMERSIVE, value).apply();
    }

    static boolean wakeLock(Context context) {
        return store(context).getBoolean(KEY_WAKELOCK, false);
    }

    static void setWakeLock(Context context, boolean value) {
        store(context).edit().putBoolean(KEY_WAKELOCK, value).apply();
    }
}
