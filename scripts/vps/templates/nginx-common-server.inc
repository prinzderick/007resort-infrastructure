# Managed by 007resort-infrastructure. Server-level basics shared by every app (included first by each body).
server_tokens off;
charset utf-8;
index index.php;

gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css text/xml application/json application/javascript text/javascript application/xml application/rss+xml application/manifest+json image/svg+xml;
