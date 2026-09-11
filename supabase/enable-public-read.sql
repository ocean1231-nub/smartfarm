-- ============================================================
-- 스마트팜 공개 대시보드 - Supabase SQL Editor 에 통째로 붙여넣고 Run
-- (테이블 public.sensor_data / anon INSERT 정책은 이미 있는 상태)
-- 여러 번 실행해도 안전함.
-- ============================================================

-- 1) 방문자(anon)가 원본 테이블을 읽을 수 있게 (실시간 모드 + 카드 최신값)
drop policy if exists "Public can read sensor data" on public.sensor_data;
create policy "Public can read sensor data"
  on public.sensor_data
  for select
  to anon
  using (true);

-- 2) "최근 7일" 모드 소스는 retention.sql 로 이관됨
--    (뷰 방식 → 조회 때마다 raw 전체 재집계 → 테이블 방식으로 교체,
--     cron이 미리 계산해두고 방문자는 그 결과만 읽음. retention.sql 실행 필수.)

-- 3) created_at 인덱스 (실시간 조회 order/limit + 롤업 집계 가속)
--    5초마다 쌓여서 금방 수만 행 → 인덱스 없으면 매 조회가 풀스캔+정렬.
create index if not exists sensor_data_created_at_idx
  on public.sensor_data (created_at desc);

-- 4) PostgREST 스키마 캐시 새로고침
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- 다음 순서: supabase/retention.sql 실행
--   → sensor_5min(5분 평균), sensor_daily(일별 평균) 테이블 생성 +
--     자동 롤업(pg_cron) + raw 3일 보존. "최근 7일"/"최근 1년" 모드가 이걸 씀.
-- ------------------------------------------------------------
