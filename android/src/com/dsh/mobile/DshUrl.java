package com.dsh.mobile;

import java.net.URI;
import java.net.URISyntaxException;

/**
 * The subset of a DSH launch URL this app cares about.
 *
 * <p>{@code dsh web} prints something like
 * {@code http://100.x.y.z:3080/?token=8f2c...}. We keep the scheme, host,
 * port, and token, and throw the rest away — the path is always {@code /} for
 * an index request and the token is the only query parameter that matters.
 */
final class DshUrl {

    final String scheme;
    final String host;
    final int port;
    final String token;

    private DshUrl(String scheme, String host, int port, String token) {
        this.scheme = scheme;
        this.host = host;
        this.port = port;
        this.token = token;
    }

    /**
     * Parse a pasted URL. Tolerates a bare {@code host:port}, a missing token,
     * and surrounding whitespace, because this string gets copy-pasted out of a
     * terminal and terminal copy-paste is hostile.
     *
     * @param raw the user-supplied text
     * @return the parsed URL, or {@code null} when no host can be recovered
     */
    static DshUrl parse(String raw) {
        if (raw == null) {
            return null;
        }
        String text = raw.trim();
        if (text.isEmpty()) {
            return null;
        }
        // Terminal paste sometimes drags the log prefix along.
        int marker = text.indexOf("http://");
        if (marker < 0) {
            marker = text.indexOf("https://");
        }
        if (marker > 0) {
            text = text.substring(marker);
        }
        if (!text.startsWith("http://") && !text.startsWith("https://")) {
            text = "http://" + text;
        }
        // Trailing prose after the URL (e.g. an unmatched bracket) breaks URI.
        int stop = text.length();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == ' ' || c == '\n' || c == '\t' || c == ')' || c == ']' || c == '>') {
                stop = i;
                break;
            }
        }
        text = text.substring(0, stop);

        URI uri;
        try {
            uri = new URI(text);
        } catch (URISyntaxException e) {
            return null;
        }
        String host = uri.getHost();
        if (host == null || host.isEmpty()) {
            return null;
        }
        String scheme = uri.getScheme() == null ? "http" : uri.getScheme();
        int port = uri.getPort();
        if (port <= 0) {
            port = "https".equals(scheme) ? 443 : 3080;
        }
        String token = extractToken(uri.getRawQuery());
        return new DshUrl(scheme, host, port, token);
    }

    /** Pull {@code token=...} out of a raw query string without decoding it. */
    private static String extractToken(String rawQuery) {
        if (rawQuery == null || rawQuery.isEmpty()) {
            return "";
        }
        for (String pair : rawQuery.split("&")) {
            int eq = pair.indexOf('=');
            if (eq <= 0) {
                continue;
            }
            if ("token".equals(pair.substring(0, eq))) {
                return pair.substring(eq + 1);
            }
        }
        return "";
    }
}
