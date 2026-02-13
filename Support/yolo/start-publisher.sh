#!/bin/bash

# 使用修復版推流器
MODEL_PATH=models/best.pt
CAMERA_INDEX=0
WIDTH=640
HEIGHT=480
FPS=15
SFU_URL="ws://178.128.54.195:7000"
STREAM_ID="yolo-main-stream"

# 啟動修復版發布者
python fixed_publisher.py \
  --sfu $SFU_URL \
  --model $MODEL_PATH \
  --camera $CAMERA_INDEX \
  --width $WIDTH \
  --height $HEIGHT \
  --fps $FPS \
  --stream-id $STREAM_ID \
  --log INFO