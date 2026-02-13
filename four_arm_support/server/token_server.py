from flask import Flask, request, jsonify
from flask_cors import CORS
import os
from livekit import api
from dotenv import load_dotenv

load_dotenv('development.env')

app = Flask(__name__)
CORS(app)

LIVEKIT_API_KEY = os.getenv('LIVEKIT_API_KEY')
LIVEKIT_API_SECRET = os.getenv('LIVEKIT_API_SECRET')
LIVEKIT_URL = os.getenv('LIVEKIT_URL')

@app.route('/get-livekit-token', methods=['GET'])
def get_token():
    identity = request.args.get('identity', 'user')
    room_name = request.args.get('room', 'my-room')
    
    if not LIVEKIT_API_KEY or not LIVEKIT_API_SECRET:
        return jsonify({'error': 'Server misconfigured'}), 500

    # 根據 Identity 分配權限
    # 只有 webcam-publisher 開頭的 identity 才擁有發布影像的權限
    is_publisher = identity.startswith('webcam-publisher')

    grant = api.VideoGrants(
        room_join=True,
        room=room_name,
        can_publish=is_publisher,       # 只有攝影機端能發布
        can_subscribe=True,             # 大家都能訂閱
        can_publish_data=True           # 大家都能發布 Data (MQTT 控制或 YOLO)
    )

    token = api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET) \
        .with_identity(identity) \
        .with_grants(grant) \
        .to_jwt()

    return jsonify({'token': token})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)