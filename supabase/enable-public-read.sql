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

-- 2) "최근 7일" 모드용 5분 평균 집계 뷰
--    원본은 빠른 간격(5초)으로 쌓이고, 화면은 5분 단위로만 보여주기 위함.
drop view if exists public.sensor_5min;
create view public.sensor_5min as
select
  date_bin('5 minutes', created_at, timestamptz '2000-01-01') as bucket,
  round(avg("PH")::numeric, 2)   as ph,
  round(avg("EC")::numeric, 2)   as ec,
  round(avg("온도")::numeric, 1) as temp,
  round(avg("습도")::numeric, 1) as humidity,
  count(*)                        as samples
from public.sensor_data
group by 1
order by 1;

grant select on public.sensor_5min to anon;

-- 3) PostgREST 스키마 캐시 새로고침 (뷰가 API에 바로 안 잡히면)
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- ※ 이 SQL 로 안 되는 것: "Max rows" 설정.
--   대시보드 Settings -> API -> "Max rows" 를 3000 으로 바꿔야 함.
--   (7일 x 5분 = 약 2,016행. 기본 1000 이면 최근 3.5일치만 옴)
--   바꾸기 싫으면 위 2) 의 '5 minutes' 를 '1 hour' 로 고쳐서 실행 (168행).
-- ------------------------------------------------------------
