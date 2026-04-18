// dify-chat.js — load through Dify /v1/chat-messages (public API)
// Hits plugin-daemon indirectly via embedding provider + model provider calls.
// Used in Phase 41 to calibrate plugin-daemon mem_limit.
//
// Usage: DIFY_APP_TOKEN=app-... agmind loadtest dify-chat [--duration 2m --vus 4]

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const DIFY_URL = __ENV.DIFY_URL || 'http://agmind-nginx:80';
const APP_TOKEN = __ENV.DIFY_APP_TOKEN || '';

const e2e = new Trend('agmind_dify_e2e_seconds', true);
const errors = new Rate('agmind_dify_errors');
const msgs = new Counter('agmind_dify_messages');

const quickMode = !!(__ENV.K6_VUS || __ENV.K6_DURATION);

export const options = quickMode ? {
    thresholds: { agmind_dify_errors: ['rate<0.10'] }
} : {
    stages: [
        { duration: '30s', target: 1 },
        { duration: '1m',  target: 2 },
        { duration: '2m',  target: 4 },
        { duration: '30s', target: 0 },
    ],
    thresholds: {
        'agmind_dify_e2e_seconds': ['p(95)<20'],
        'agmind_dify_errors':      ['rate<0.05'],
    }
};

const queries = [
    'Что такое AGmind и для чего он используется?',
    'Как настроить RAG пайплайн в Dify?',
    'Объясни разницу между semantic и hybrid search',
    'Какие embedding модели поддерживаются?',
    'Как работает reranking в vector database?',
];

export function setup() {
    if (!APP_TOKEN) {
        throw new Error('DIFY_APP_TOKEN env required');
    }
    return { token: APP_TOKEN };
}

export default function (data) {
    const q = queries[Math.floor(Math.random() * queries.length)];
    const start = Date.now();

    const res = http.post(`${DIFY_URL}/v1/chat-messages`, JSON.stringify({
        query: q,
        inputs: {},
        response_mode: 'blocking',
        user: `loadtest-vu-${__VU}`,
    }), {
        headers: {
            'Authorization': `Bearer ${data.token}`,
            'Content-Type': 'application/json',
        },
        timeout: '60s',
    });

    const elapsed = (Date.now() - start) / 1000;
    e2e.add(elapsed);

    const ok = check(res, {
        'status 200': (r) => r.status === 200,
        'has answer': (r) => r.status === 200 && !!r.json('answer'),
    });
    errors.add(!ok);
    if (ok) msgs.add(1);
    sleep(0.5);
}

export function handleSummary(data) {
    return {
        'stdout': text(data),
        '/results/summary.json': JSON.stringify(data, null, 2),
    };
}

function text(data) {
    const m = data.metrics;
    const p = (x) => x != null ? x.toFixed(2) : '-';
    return `
=== Dify chat load ===
  messages:    ${m.agmind_dify_messages?.values?.count || 0}
  errors:      ${p((m.agmind_dify_errors?.values?.rate || 0) * 100)}%
  e2e p50:     ${p(m.agmind_dify_e2e_seconds?.values?.['p(50)'])}s
  e2e p95:     ${p(m.agmind_dify_e2e_seconds?.values?.['p(95)'])}s
  reqs/sec:    ${p(m.http_reqs?.values?.rate)}
`;
}
