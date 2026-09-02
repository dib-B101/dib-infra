// k6 입찰 부하 시나리오
// 실행: $env:BASE_URL="http://<ALB주소>"; $env:TOKEN="<JWT>"; k6 run load-test/bid-scenario.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 100 },  // 워밍업
    { duration: '3m', target: 500 },  // 목표 부하 — HPA 발동 구간
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<300'], // 발표용 지표: p95 300ms
    http_req_failed: ['rate<0.01'],
  },
};

const BASE = __ENV.BASE_URL;

export default function () {
  // 1. 조회 (읽기 경로 — Redis 캐시 검증)
  const list = http.get(`${BASE}/api/v1/auctions?page=0`);
  check(list, { 'list 200': (r) => r.status === 200 });

  // 2. 입찰 (쓰기 경로 — 분산 락 검증)
  const bid = http.post(
    `${BASE}/api/v1/auctions/1/bids`,
    JSON.stringify({ amount: 10000 + Math.floor(Math.random() * 1000) * 100 }),
    { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${__ENV.TOKEN}` } },
  );
  check(bid, { 'bid ok or outbid': (r) => r.status === 200 || r.status === 409 });

  sleep(1);
}
