#!/bin/bash
set -e

# 0. 準備工作：安裝相依庫
echo "Installing dependencies..."
# cJSON (for mosquitto_ctrl)
if [ ! -d "cJSON" ]; then
    git clone https://github.com/DaveGamble/cJSON.git
    cd cJSON
    mkdir build
    cd build
    cmake .. -DENABLE_CJSON_UTILS=On -DENABLE_CJSON_TEST=Off -DCMAKE_INSTALL_PREFIX=/usr
    make
    sudo make install
    cd ../..
fi

# libwebsockets (for MQTT over WebSocket)
if [ ! -d "libwebsockets" ]; then
    echo "Downloading libwebsockets..."
    git clone https://libwebsockets.org/repo/libwebsockets
    cd libwebsockets
    mkdir build
    cd build
    cmake .. -DLWS_WITH_EXTERNAL_POLL=1 -DLWS_WITHOUT_TESTAPPS=ON -DCMAKE_INSTALL_PREFIX=/usr
    make
    sudo make install
    sudo ldconfig
    cd ../..
fi

# 1. 下載 Mosquitto (如果還沒下載)
if [ ! -d "mosquitto-2.0.18" ]; then
    echo "Downloading Mosquitto..."
    wget http://mosquitto.org/files/source/mosquitto-2.0.18.tar.gz
    tar -xzf mosquitto-2.0.18.tar.gz
fi

cd mosquitto-2.0.18

echo "Compiling Mosquitto..."
# 修改 config.mk 啟用 websockets
sed -i 's/WITH_WEBSOCKETS:=no/WITH_WEBSOCKETS:=yes/' config.mk
sed -i 's/WITH_DOCS:=yes/WITH_DOCS:=no/' config.mk

# 編譯並安裝
make binary
sudo make install

# 2. 設定 Mosquitto 使用者
echo "Setting up Mosquitto user..."
sudo useradd -r -m -d /var/lib/mosquitto -s /sbin/nologin mosquitto || true

# 3. 建立設定檔
echo "Creating Mosquitto config..."
sudo mkdir -p /etc/mosquitto/conf.d
sudo bash -c 'cat > /etc/mosquitto/mosquitto.conf <<EOF
pid_file /var/run/mosquitto/mosquitto.pid

persistence true
persistence_location /var/lib/mosquitto/

log_dest file /var/log/mosquitto/mosquitto.log
log_type all

# Listener 1: TCP (ESP8266 & Native App)
listener 1883
allow_anonymous true

# Listener 2: WebSocket (Web App via Nginx or Direct)
# 我們讓 Nginx 處理 SSL，這裡只聽 Localhost 的 WS 埠，或者直接對外
listener 8083
protocol websockets
allow_anonymous true
EOF'

# 4. 建立 Systemd 服務
echo "Creating Systemd service..."
sudo bash -c 'cat > /etc/systemd/system/mosquitto.service <<EOF
[Unit]
Description=Mosquitto MQTT Broker
Documentation=man:mosquitto.conf(5) man:mosquitto(8)
After=network.target

[Service]
Type=notify
NotifyAccess=main
ExecStart=/usr/local/sbin/mosquitto -c /etc/mosquitto/mosquitto.conf
User=root
Group=root
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF'

# 注意：為了權限方便，暫時用 root 跑，或者確保 /etc/mosquitto 和 /var/lib/mosquitto 權限正確
# 修正為 mosquitto 使用者，並確保權限
sudo sed -i 's/User=root/User=mosquitto/' /etc/systemd/system/mosquitto.service
sudo sed -i 's/Group=root/Group=mosquitto/' /etc/systemd/system/mosquitto.service

# 5. 設定權限與啟動
echo "Setting permissions and starting..."
sudo mkdir -p /var/log/mosquitto /var/run/mosquitto /var/lib/mosquitto
sudo chown -R mosquitto:mosquitto /var/log/mosquitto /var/lib/mosquitto /var/run/mosquitto /etc/mosquitto

sudo systemctl daemon-reload
sudo systemctl enable mosquitto
sudo systemctl start mosquitto

echo "Mosquitto setup complete!"