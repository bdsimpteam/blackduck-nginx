#!/bin/sh

while true; do
/usr/sbin/logrotate -s /opt/blackduck/hub/webserver/logrotate/logrotate.status -l /opt/blackduck/hub/webserver/logrotate/logrotate.log /etc/logrotate.d > /dev/null
sleep 1d
done