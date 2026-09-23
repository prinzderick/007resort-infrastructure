# Managed by 007resort-infrastructure (scripts/vps/provision-stack.sh). Included by every r007 server block.
root @@APP_ROOT@@/current/public;
index index.php;
charset utf-8;
client_max_body_size 20m;

add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

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
location = /robots.txt  { access_log off; log_not_found off; }

location ~ ^/index\.php(/|$) {
    fastcgi_pass unix:/run/php/php@@PHP_VER@@-fpm.sock;
    fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
    fastcgi_param DOCUMENT_ROOT $realpath_root;
    include fastcgi_params;
    fastcgi_hide_header X-Powered-By;
    fastcgi_read_timeout 70s;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
}

# Only index.php is executable.
location ~ \.php$ { return 404; }
