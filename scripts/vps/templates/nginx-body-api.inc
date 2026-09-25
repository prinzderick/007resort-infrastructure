# Managed by 007resort-infrastructure. Body of the API server (@@DOMAIN@@). Included by the public and loopback servers.
include @@NGINX_ETC@@/snippets/r007-common.conf;
include @@NGINX_ETC@@/snippets/r007-@@APP@@-headers.conf;
root @@APP_DIR@@/current/public;

# CMS uploads are capped at 8 MB by the API; multipart overhead + margin. PHP pool: upload 9M / post 10M.
client_max_body_size 12m;

# Never serve dotfiles (.env, .git) - except ACME challenges handled in the server block.
location ~ /\.(?!well-known) { deny all; }

# Reverb WebSocket + Pusher-protocol HTTP API (Reverb listens on 127.0.0.1:8080 only).
location ~ ^/apps?/ {
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header Scheme $scheme;
    proxy_set_header SERVER_PORT $server_port;
    proxy_set_header REMOTE_ADDR $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_pass http://127.0.0.1:8080;
}

# Uploaded media (storage:link -> shared/storage/app/public). CMS media file names are unique ids: cache for a year.
location ^~ /storage/cms/ {
    include @@NGINX_ETC@@/snippets/r007-@@APP@@-headers.conf;
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    access_log off;
    try_files $uri =404;
}
location ^~ /storage/ {
    include @@NGINX_ETC@@/snippets/r007-@@APP@@-headers.conf;
    add_header Cache-Control "public, max-age=3600" always;
    try_files $uri =404;
}

# Local<->Cloud sync endpoint: extra per-IP rate limit (the API also limits per node credential).
location /api/v1/sync/ {
    limit_req zone=r007_sync burst=40 nodelay;
    try_files $uri /index.php?$query_string;
}

location /api/ {
    limit_req zone=r007_api burst=60 nodelay;
    try_files $uri /index.php?$query_string;
}

location / {
    try_files $uri $uri/ /index.php?$query_string;
}

location = /favicon.ico { access_log off; log_not_found off; }

include @@NGINX_ETC@@/snippets/r007-@@APP@@-php.conf;
