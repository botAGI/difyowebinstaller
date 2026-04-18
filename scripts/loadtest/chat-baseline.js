// chat-baseline.js — concurrent chats directly to vLLM OpenAI endpoint
// Bypasses Dify to isolate LLM capacity. Ramp 1→2→4→8 VUs with 2min each.
// Usage: agmind loadtest chat [--duration 30s] [--vus 2]
// Env overrides: VLLM_URL, MODEL, DURATION_STAGE, MAX_VUS

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const VLLM_URL = __ENV.VLLM_URL || 'http://agmind-vllm:8000/v1/chat/completions';
const MODEL = __ENV.MODEL || 'google/gemma-4-26B-A4B-it';
const STAGE = __ENV.DURATION_STAGE || '2m';
const MAX_VUS = parseInt(__ENV.MAX_VUS || '8');

// Custom metrics (histogram-like)
const ttft = new Trend('agmind_ttft_seconds', true);
const e2eLatency = new Trend('agmind_e2e_seconds', true);
const errors = new Rate('agmind_errors');
const completions = new Counter('agmind_completions_total');

// Override with --vus/--duration from CLI for quick smoke test
const quickMode = !!(__ENV.K6_VUS || __ENV.K6_DURATION);

export const options = quickMode ? {
    // Smoke/dry-run: whatever CLI specified via --vus/--duration
    thresholds: { agmind_errors: ['rate<0.10'] }
} : {
    // Full ramp stages
    stages: [
        { duration: STAGE, target: 1 },
        { duration: STAGE, target: 2 },
        { duration: STAGE, target: 4 },
        { duration: STAGE, target: MAX_VUS },
        { duration: '30s', target: 0 },  // cooldown
    ],
    thresholds: {
        'agmind_ttft_seconds': ['p(95)<10'],   // TTFT p95 < 10s
        'agmind_e2e_seconds':  ['p(95)<30'],   // full response < 30s
        'agmind_errors':       ['rate<0.05'],  // <5% errors
    }
};

const prompts = [
    'Объясни что такое RAG в двух предложениях',
    'Напиши короткую функцию на Python для чтения JSON файла',
    'Переведи на английский: искусственный интеллект это будущее',
    'Что такое kv-cache в vLLM и зачем он нужен?',
    'Опиши архитектуру трансформера простыми словами',
];

export default function () {
    const prompt = prompts[Math.floor(Math.random() * prompts.length)];
    const start = Date.now();

    const payload = JSON.stringify({
        model: MODEL,
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 150,
        temperature: 0.7,
        stream: false,
    });

    const res = http.post(VLLM_URL, payload, {
        headers: { 'Content-Type': 'application/json' },
        timeout: '60s',
    });

    const elapsed = (Date.now() - start) / 1000;
    e2eLatency.add(elapsed);

    const ok = check(res, {
        'status 200': (r) => r.status === 200,
        'has content': (r) => r.status === 200 && r.json('choices.0.message.content'),
    });

    errors.add(!ok);

    if (ok) {
        completions.add(1);
        // TTFT approximation: for non-streaming, we only have total time.
        // Real TTFT requires streaming mode — tracked at Prometheus vllm:time_to_first_token_seconds.
        // Here we record e2e as a proxy for user-felt latency.
        ttft.add(elapsed);
    }

    sleep(1);  // think time between requests
}

export function handleSummary(data) {
    return {
        'stdout': textSummary(data),
        '/results/summary.json': JSON.stringify(data, null, 2),
    };
}

function textSummary(data) {
    const m = data.metrics;
    const p = (x) => x ? x.toFixed(2) : '-';
    return `
=== AGmind chat baseline ===
  completions: ${m.agmind_completions_total?.values?.count || 0}
  errors:      ${p((m.agmind_errors?.values?.rate || 0) * 100)}%
  e2e p50:     ${p(m.agmind_e2e_seconds?.values?.['p(50)'])}s
  e2e p95:     ${p(m.agmind_e2e_seconds?.values?.['p(95)'])}s
  e2e p99:     ${p(m.agmind_e2e_seconds?.values?.['p(99)'])}s
  reqs/sec:    ${p(m.http_reqs?.values?.rate)}
`;
}
