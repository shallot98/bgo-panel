#!/bin/bash
# 启动 bgo 面板。NEVER reboot container.
cd /root/bililive-go/ops/panel
if pgrep -f 'ops/panel/panel.py' >/dev/null; then echo "already running pid=$(pgrep -f 'ops/panel/panel.py' | head -1)"; exit 0; fi
export PANEL_PORT=9090
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
nohup /opt/mamba/bin/python3 -u /root/bililive-go/ops/panel/panel.py >>/var/log/bgo-panel.log 2>&1 &
echo $! > panel.pid
echo "started pid=$!"
