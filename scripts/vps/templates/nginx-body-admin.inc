# Managed by 007resort-infrastructure. Body of the admin portal server (@@DOMAIN@@).
# Access controls (IP allow-list, optional basic auth) are in snippets/r007-admin-access.conf, included by the
# public HTTPS server only; the loopback health server bypasses them by design.
include @@NGINX_ETC@@/snippets/r007-common.conf;
include @@NGINX_ETC@@/snippets/r007-@@APP@@-headers.conf;
root @@APP_DIR@@/current/public;

# The portal forwards CMS media uploads (8 MB) and catalogue CSVs to the API: same limits as the API.
client_max_body_size 12m;

location ~ /\.(?!well-known) { deny all; }

# Nothing here should ever be indexed.
location = /robots.txt {
    include @@NGINX_ETC@@/snippets/r007-@@APP@@-headers.conf;
    default_type text/plain;
    return 200 "User-agent: *\nDisallow: /\n";
}

location ^~ /build/ {
    include @@NGINX_ETC@@/snippets/r007-@@APP@@-headers.conf;
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    access_log off;
    try_files $uri =404;
}

# Sign-in brute-force limit (POST only, 10/min/IP, then 429). The portal also throttles logins itself.
location = /login {
    limit_req zone=r007_login burst=5 nodelay;
    try_files /_r007_no_static_file /index.php?$query_string;
}

location / {
    try_files $uri $uri/ /index.php?$query_string;
}

include @@NGINX_ETC@@/snippets/r007-@@APP@@-php.conf;
