#!/bin/bash

# ICE 修正版推流器
CAMERA_INDEX=0
WIDTH=640
HEIGHT=480
FPS=15
SFU_URL="ws://178.128.54.195:7000"
STREAM_ID="yolo-main-stream"

# 啟動 ICE 修正版發布者
python ice_fixed_publisher.py \
  --sfu $SFU_URL \
  --camera $CAMERA_INDEX \
  --width $WIDTH \
  --height $HEIGHT \
  --fps $FPS \
  --stream-id $STREAM_ID \
  --log INFO