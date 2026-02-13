
from dotenv import load_dotenv
import os
from livekit import api
from dotenv import load_dotenv
import os

load_dotenv('development.env')

def generate_token(identity, room="my-room"):
    token = api.AccessToken() \
        .with_identity(identity) \
        .with_name(identity) \
        .with_grants(api.VideoGrants(room_join=True, room=room)) \
        .to_jwt()
    return token

if __name__ == "__main__":
    publisher_token = generate_token("python-bot", room="my-room")
    receiver_token = generate_token("web-receiver", room="my-room")
    
    print("Publisher token:", publisher_token)
    print("Receiver token:", receiver_token)
