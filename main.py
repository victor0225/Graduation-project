from firebase_functions import firestore_fn, options
from firebase_admin import initialize_app, firestore
import google.cloud.firestore
import math

# Firebase Admin SDK 초기화
initialize_app()

@firestore_fn.on_document_created(document="ble_scans/{docId}", region="asia-northeast3")
def calculate_position(event: firestore_fn.Event[firestore_fn.DocumentSnapshot | None]) -> None:
    """Firestore에 데이터가 추가되면 실행되는 메인 함수"""
    
    # 1. 추가된 데이터 가져오기
    raw_snapshot = event.data
    if not raw_snapshot:
        return
    
    data = raw_snapshot.to_dict()
    
    # 앱에서 보낸 데이터 추출 (RSSI 목록, 센서 값 등)
    rssi_list = data.get('rssi_values', {}) # 예: {"beacon_1": -65, "beacon_2": -72}
    heading = data.get('heading', 0)         # 지자기 센서 방향 (0~360도)
    step_count = data.get('step_count', 0)   # PDR 걸음 수
    user_id = data.get('user_id', 'unknown_user')

    # 2. 실내 측위 알고리즘 적용 (여기에 로직 구현)
    # 예시: 간단한 RSSI 거리 환산 및 PDR 연산
    new_x, new_y = simple_pdr_and_rssi_algorithm(rssi_list, heading, step_count)

    # 3. 계산된 좌표를 user_location 컬렉션에 저장/업데이트
    db: google.cloud.firestore.Client = firestore.client()
    db.collection("user_location").document(user_id).set({
        "x": new_x,
        "y": new_y,
        "last_updated": firestore.SERVER_TIMESTAMP,
        "status": "active"
    })

def simple_pdr_and_rssi_algorithm(rssi_dict, heading, steps):
    """
    실제 PDR 및 RSSI 삼각측량 알고리즘이 들어갈 공간입니다.
    지금은 테스트를 위해 간단한 더미 연산값만 반환합니다.
    """
    # RSSI를 거리로 변환하는 공식 예시: Distance = 10^((Measured Power – RSSI) / (10 * N))
    # 여기에 복잡한 수학 연산을 파이썬 라이브러리로 처리하세요.
    
    dummy_x = 10.5 + (steps * 0.5 * math.cos(math.radians(heading)))
    dummy_y = 20.3 + (steps * 0.5 * math.sin(math.radians(heading)))
    
    return dummy_x, dummy_y