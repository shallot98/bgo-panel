#!/bin/bash
pkill -f 'ops/panel/panel.py' && echo stopped || echo "not running"
