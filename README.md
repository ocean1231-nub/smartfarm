# 스마트팜 모니터링 대시보드.

정적 사이트(Netlify) + Supabase. ESP32 가 Supabase 에 센서값을 쌓고, 이 페이지가 읽어서 보여준다.

```
ESP32 ──(빠른 간격 INSERT)──▶ Supabase(sensor_data)
                                      │  ├─ 실시간 모드: 원본 최근 30분
                                      │  └─ 최근 7일 모드: sensor_5min 뷰(5분 평균)
브라우저 ◀── SELECT ───────────────────┘
Netlify 는 index.html/config.js 만 서빙 (데이터는 안 거침 → 부하 없음)
```

## 구성 파일

| 파일 | 용도 |
|---|---|
| `index.html` | 대시보드 본체 (Chart.js + supabase-js, CDN) |
| `config.js` | Supabase URL + Publishable key |
| `netlify.toml` | 빌드 없이 루트 게시 |
| `supabase/enable-public-read.sql` | **계정 주인이 1회 실행** |
| `supabase/schema.sql` | 현재 스키마 설명 (실행 불필요) |

## 화면

- 상단 토글 **실시간 / 최근 7일**
  - 실시간: `sensor_data` 원본, 최근 30분, 15초 갱신
  - 최근 7일: `sensor_5min` 뷰, 5분 간격, 60초 갱신
- 카드 4개(pH / EC / 온도 / 습도): 클릭하면 그래프가 해당 센서로 전환. 값은 항상 원본 최신 1행.

---

## 세팅

### 1. Supabase (계정 주인)

`supabase/enable-public-read.sql` 을 SQL Editor 에 붙여넣고 실행. 하는 일:
1. `sensor_data` 에 anon SELECT 정책 추가
2. `sensor_5min` (5분 평균) 뷰 생성 + anon grant
3. 스키마 캐시 새로고침

그리고 대시보드 **Settings → API → Max rows = 3000** 으로 (7일 x 5분 = 약 2,016행이라 기본값 1000 이면 잘림).
올리기 싫으면 SQL 의 `'5 minutes'` 를 `'1 hour'` 로 바꿔서 실행 (168행, 상한 안 걸림).

전달할 것: **Publishable key** (`sb_publishable_...`). Secret key 는 주지 말 것.

### 2. config.js

```js
window.SUPABASE_URL      = "https://eoioozljabtxxhzpjrnu.supabase.co";
window.SUPABASE_ANON_KEY = "sb_publishable_...";   // ← 받은 키로 교체
```

### 3. 로컬 확인

```bash
cd ~/smartfarm
python3 -m http.server 8000
# http://localhost:8000
```

### 4. Netlify 배포

1. GitHub 새 저장소에 push (`ocean1231-nub/smartfarm` 등)
2. Netlify → Add new site → Import from Git → 그 저장소 선택
3. Build command 비움, Publish directory `.`
4. Deploy. 이후 push 하면 자동 재배포.

> `config.js` 를 저장소에 커밋하기 싫으면: Netlify 환경변수(`SUPABASE_URL`, `SUPABASE_ANON_KEY`) 설정 후
> Build command 를 아래로 —
> `printf 'window.SUPABASE_URL=%s;window.SUPABASE_ANON_KEY=%s;' "\"$SUPABASE_URL\"" "\"$SUPABASE_ANON_KEY\"" > config.js`
> Publishable key 는 공개용이라 그냥 커밋해도 보안상 문제는 없음.

---

## 나중에

- 펌프 / 배수펌프 / LED 제어 → `actuators` 테이블 + 제어 UI (별도 작업)
- 일봉(하루 평균) 탭 → `sensor_daily` 뷰 추가하고 토글에 버튼 하나 더
- 임계치 경고 → 센서별 정상범위 벗어나면 카드 색 변경
