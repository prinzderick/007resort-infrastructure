# Managed by 007resort-infrastructure. PHP-FPM handoff for @@APP@@ (its own pool, user @@APP_USER@@).
# Only index.php is executable; everything else ending in .php is a 404.
location ~ ^/index\.php(/|$) {
    fastcgi_pass unix:@@FPM_SOCK@@;
    fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
    fastcgi_param DOCUMENT_ROOT $realpath_root;
    include fastcgi_params;
    # TLS is terminated here: tell PHP the request is HTTPS (so url()/redirects/secure cookies are right even
    # when an app does not trust proxies) and the original scheme for apps that do (TRUSTED_PROXIES).
    fastcgi_param HTTPS $https if_not_empty;
    fastcgi_param HTTP_X_FORWARDED_PROTO $scheme;
    fastcgi_hide_header X-Powered-By;
    fastcgi_read_timeout 70s;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
}
location ~ \.php$ { return 404; }
