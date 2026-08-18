#!/bin/bash
set -e
cd /home/rutger/dmrai-ws/CACTUS/prod
source ../.venv/bin/activate
echo "[$(date +%H:%M:%S)] init";      yes '' | cactus1-substrates init     -config_file cactus_bundle.txt   >init.log 2>&1
echo "[$(date +%H:%M:%S)] optimize";  yes '' | cactus1-substrates optimize -config_file cactus_bundle.txt   >opt.log 2>&1
echo "[$(date +%H:%M:%S)] growth";    yes '' | cactus1-substrates grow -config_file cactus_bundle.txt -substep growth -run_case all >growth.log 2>&1
echo "[$(date +%H:%M:%S)] mesh";      yes '' | cactus1-substrates grow -config_file cactus_bundle.txt -substep mesh   -run_case all >mesh.log 2>&1
echo "[$(date +%H:%M:%S)] DONE"
