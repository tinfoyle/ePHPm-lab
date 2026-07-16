import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

export const options = {
  scenarios: {
    browse: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 8),
      timeUnit: '1s',
      duration: __ENV.DURATION || '120s',
      preAllocatedVUs: 8,
      maxVUs: 24,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    wordpress_v5_ok: ['rate>0.99'],
  },
};

const base = __ENV.BASE_URL;
const headers = { Host: 'wordpress-v5.local' };
const ok = new Rate('wordpress_v5_ok');
const product = new Trend('product_ms');
const catalog = new Trend('catalog_ms');
const search = new Trend('search_ms');

export function setup() {
  const runtime = http.get(`${base}/wp-json/ephpm-lab/v1/runtime`, { headers });
  const cache = http.get(`${base}/wp-json/ephpm-lab/v1/cache-check`, { headers });
  check(runtime, { 'runtime endpoint 200': (r) => r.status === 200 });
  check(cache, { 'object cache read/write works': (r) => r.status === 200 && r.json('value') === 'ok' });
}

export default function () {
  const choice = __ITER % 10;
  let path;
  let metric;

  if (choice < 2) {
    path = '/';
    metric = catalog;
  } else if (choice < 4) {
    path = '/shop/';
    metric = catalog;
  } else if (choice < 6) {
    path = `/product/bench-simple-${String((__ITER % 1000) + 1).padStart(4, '0')}/`;
    metric = product;
  } else if (choice < 7) {
    path = `/product/bench-variable-${String((__ITER % 200) + 1).padStart(4, '0')}/`;
    metric = product;
  } else if (choice < 8) {
    path = `/product-category/bench-category-${String((__ITER % 15) + 1).padStart(2, '0')}/`;
    metric = catalog;
  } else if (choice < 9) {
    path = '/?s=Bench+Product&post_type=product';
    metric = search;
  } else {
    path = '/wp-json/wc/store/v1/products?per_page=12&orderby=popularity';
    metric = catalog;
  }

  const response = http.get(`${base}${path}`, { headers });
  metric.add(response.timings.duration);
  const passed = check(response, {
    'status 200': (r) => r.status === 200,
    'not WordPress error': (r) => typeof r.body === 'string' && !r.body.includes('There has been a critical error'),
  });
  ok.add(passed);
  sleep(0.05);
}
