// embed-burst.js — sustained embedding load on vllm-embed
// Measures: queue depth, req/s throughput, embed latency.
// Usage: agmind loadtest embed [--duration 30s] [--vus 4]
// Env: EMBED_URL, EMBED_MODEL

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const EMBED_URL = __ENV.EMBED_URL || 'http://agmind-vllm-embed:8000/v1/embeddings';
const EMBED_MODEL = __ENV.EMBED_MODEL || 'deepvk/USER-bge-m3';

const embedLatency = new Trend('agmind_embed_seconds', true);
const embedErrors = new Rate('agmind_embed_errors');
const embedOps = new Counter('agmind_embeds_total');

const quickMode = !!(__ENV.K6_VUS || __ENV.K6_DURATION);

export const options = quickMode ? {
    thresholds: { agmind_embed_errors: ['rate<0.05'] }
} : {
    stages: [
        { duration: '1m', target: 2 },
        { duration: '2m', target: 4 },
        { duration: '2m', target: 8 },
        { duration: '30s', target: 0 },
    ],
    thresholds: {
        'agmind_embed_seconds': ['p(95)<5'],   // p95 < 5s even under load
        'agmind_embed_errors':  ['rate<0.02'], // <2% error
    }
};

// Varied-length texts to simulate real RAG chunks (short paragraphs)
const texts = [
    'Искусственный интеллект — это широкая область, которая включает машинное обучение, обработку естественного языка и компьютерное зрение.',
    'Retrieval-Augmented Generation combines a retrieval step over external documents with a generative model to produce grounded answers.',
    'vLLM — высокопроизводительная система инференса для больших языковых моделей, использующая PagedAttention.',
    'Docker Compose позволяет описать многоконтейнерное приложение в одном YAML-файле и управлять им одной командой.',
    'DGX Spark использует Grace CPU и Blackwell GPU, разделяющие unified memory — VRAM и RAM это одна область.',
    'PostgreSQL is an advanced open-source relational database supporting ACID transactions and JSON types.',
    'Weaviate is a vector database designed for semantic search over high-dimensional embeddings.',
    'BGE-M3 — мультиязычная embedding модель для dense/sparse/multi-vector retrieval в RAG пайплайнах.',
];

export default function () {
    const text = texts[Math.floor(Math.random() * texts.length)];
    const start = Date.now();

    const payload = JSON.stringify({
        model: EMBED_MODEL,
        input: text,
    });

    const res = http.post(EMBED_URL, payload, {
        headers: { 'Content-Type': 'application/json' },
        timeout: '30s',
    });

    embedLatency.add((Date.now() - start) / 1000);

    const ok = check(res, {
        'status 200': (r) => r.status === 200,
        'has embedding': (r) => r.status === 200 && Array.isArray(r.json('data.0.embedding')),
    });

    embedErrors.add(!ok);
    if (ok) embedOps.add(1);

    // No sleep — sustained load
}

export function handleSummary(data) {
    return {
        'stdout': textSummary(data),
        '/results/summary.json': JSON.stringify(data, null, 2),
    };
}

function textSummary(data) {
    const m = data.metrics;
    const p = (x) => x ? x.toFixed(3) : '-';
    return `
=== AGmind embed burst ===
  embeddings:  ${m.agmind_embeds_total?.values?.count || 0}
  errors:      ${p((m.agmind_embed_errors?.values?.rate || 0) * 100)}%
  latency p50: ${p(m.agmind_embed_seconds?.values?.['p(50)'])}s
  latency p95: ${p(m.agmind_embed_seconds?.values?.['p(95)'])}s
  latency p99: ${p(m.agmind_embed_seconds?.values?.['p(99)'])}s
  reqs/sec:    ${p(m.http_reqs?.values?.rate)}
`;
}
