# STOCKPULSE - 한국투자증권 KIS API 전환 계획

## 현재 → 목표

| 항목 | 현재 (crawl.py) | 전환 후 |
|------|----------------|---------|
| 시장지수 | 네이버 금융 HTML 크롤링 + Yahoo Finance | KIS API (`inquire-index-price`) |
| 이슈종목 | 네이버 금융 거래대금/상승률 크롤링 | KIS API (`volume-rank`) |
| 섹터 | 네이버 금융 업종별시세 크롤링 | KIS API (`inquire-index-category-price`) |
| 섹터종목 | 네이버 금융 업종상세 크롤링 | KIS API (업종별 종목 조회) |
| 뉴스 | 네이버 금융 주요뉴스 크롤링 | **유지** (KIS에 뉴스 API 없음) |
| 해외지수 | Yahoo Finance API | KIS API 해외시세 또는 Yahoo 유지 |
| 환율 | 네이버 환율 크롤링 | KIS API 또는 네이버 유지 |
| 실행방식 | GitHub Actions 30분 간격 | 로컬 PC 상시 실행 |

## 구현 단계

### Step 1: KIS API 인증 모듈 작성
- `kis_api.py` 신규 생성
- 앱키/시크릿키 → access_token 발급
- 토큰 캐싱 (24시간 유효, 파일 저장)
- 공통 헤더 생성 함수

### Step 2: REST API 함수 구현
각 기존 함수를 KIS API로 대체:

1. **시장지수** (`crawl_market_index` 대체)
   - `GET /uapi/domestic-stock/v1/quotations/inquire-index-price`
   - tr_id: `FHPUP02100000`
   - KOSPI(`0001`), KOSDAQ(`1001`)

2. **이슈종목** (`crawl_issue_stocks` 대체)
   - `GET /uapi/domestic-stock/v1/quotations/volume-rank`
   - tr_id: `FHPST01710000`
   - 거래량 순위 상위 10개

3. **섹터** (`crawl_sectors` 대체)
   - `GET /uapi/domestic-stock/v1/quotations/inquire-index-category-price`
   - tr_id: `FHPUP02140000`
   - 업종별 시세 조회

4. **뉴스** - 네이버 크롤링 유지 (KIS에 뉴스 API 없음)

5. **해외지수/환율** - 추후 KIS 해외시세 API 확인 후 전환, 우선 Yahoo/네이버 유지

### Step 3: crawl.py 수정
- KIS API 함수로 기존 함수 교체
- 환경변수 추가: `KIS_APP_KEY`, `KIS_APP_SECRET`, `KIS_ACCOUNT_NO`
- API 호출 속도 제한 처리 (초당 20회 이내)

### Step 4: 실행 스크립트 정리
- 로컬 실행용 설정 (`.env` 파일)
- GitHub Actions도 병행 가능하도록 유지

## 환경변수 (추가)

```
KIS_APP_KEY=발급받은_앱키
KIS_APP_SECRET=발급받은_시크릿키
KIS_ACCOUNT_NO=계좌번호 (XXXXXXXX-XX 형식)
```

## KIS API 주요 제약사항

- REST API: 초당 20회 제한 (실전), 초당 5회 (모의)
- 토큰: 24시간 유효, 6시간 이내 재발급 불가
- WebSocket: 세션당 41종목 구독 제한
- TLS 1.2 이상 필요

## 참고: 뉴스는 왜 유지?
한국투자증권 Open API에는 금융뉴스 조회 API가 없음.
네이버 금융 크롤링이 가장 현실적인 뉴스 소스.
