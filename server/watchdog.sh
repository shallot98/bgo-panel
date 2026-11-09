#!/bin/bash
# 面板保活。NEVER reboot container.
while true; do
  pgrep -f 'ops/panel/panel.py' >/dev/null || { /root/bililive-go/ops/panel/start.sh; echo "$(date -Is) restarted" >>/var/log/bgo-panel-watchdog.log; }
  sleep 30
done
