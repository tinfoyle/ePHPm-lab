import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    carts: {
      executor: 'per-vu-iterations',
      vus: 2,
      iterations: 2,
      maxDuration: '90s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate==1'],
  },
};

const base = __ENV.BASE_URL;
const headers = { Host: 'wordpress-v5.local' };
export function setup() {
  const response = http.get(`${base}/wp-json/ephpm-lab/v1/cart-products`, { headers });
  const products = response.json('products');
  check(response, {
    'cart fixture endpoint 200': (r) => r.status === 200,
    'two cart fixture products': () => Array.isArray(products) && products.length === 2,
  });
  return { products };
}

export default function (data) {
  const mine = data.products[__VU - 1];
  const other = data.products[__VU % data.products.length];
  const jar = http.cookieJar();

  const add = http.get(`${base}/?add-to-cart=${mine.id}`, { headers, jar, redirects: 1 });
  check(add, { 'add to cart succeeds': (r) => r.status === 200 });

  const cart = http.get(`${base}/wp-json/wc/store/v1/cart`, { headers, jar });
  const items = cart.json('items') || [];
  check(cart, {
    'cart contains own product': (r) => r.status === 200 && items.some((item) => item.id === mine.id),
    'cart excludes other product': () => !items.some((item) => item.id === other.id),
  });
}
