#!/bin/sh
set -e

# Certificate store for the per-site certificates Squid generates.
if [ ! -f /var/spool/squid/ssl_db/index.txt ]; then
    rm -rf /var/spool/squid/ssl_db
    /usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 16MB
fi

mkdir -p /var/spool/squid/cache
chown -R proxy:proxy /var/spool/squid /var/log/squid

# Create cache directories if missing (no-op when they exist), then run in the foreground.
squid -N -z -f /etc/squid/squid.conf
rm -f /run/squid.pid
exec squid -N -f /etc/squid/squid.conf
