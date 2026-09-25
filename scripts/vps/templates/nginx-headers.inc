# Managed by 007resort-infrastructure. Security headers for @@APP@@.
# nginx add_header is NOT inherited into a location that has its own add_header, so every such
# location includes this file again. HSTS is here too: browsers ignore it over plain HTTP, and this way it also
# reaches static-asset responses (no includeSubDomains/preload: other subdomains are not ours to force onto HTTPS).
# No CSP here: the Laravel apps own their Content-Security-Policy.
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(self)" always;
@@ROBOTS_HEADER@@
