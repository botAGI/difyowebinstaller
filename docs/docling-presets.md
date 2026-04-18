# Docling extractor presets (Phase 43)

Docling-serve `/v1/convert/file` принимает multipart-параметры, которые
позволяют выбрать подходящий профиль извлечения под тип документа.
Никакого внешнего роутера писать **не нужно** — три preset'а покрывают
80% кейсов.

## Preset 1 — FAST (текстовые PDF)

**Когда:** Word/LaTeX/Pages export без таблиц-картинок. PDF с selectable
text layer.

**Параметры в HTTP Request ноде Dify workflow:**
```
do_ocr=false
do_table_structure=false
table_mode=fast
```

**Профиль:** берёт готовый text layer через `pdf_backend=dlparse_v2`,
пропускает OCR (easyocr GPU) и TableFormer (GPU inference).

**Замер (5-page arxiv/1706.03762):** 4.05s vs 6.01s balanced (**−32%**).
На длинных текстовых PDF (100-300 стр) разница пропорциональная.

---

## Preset 2 — BALANCED (default, смешанные документы)

**Когда:** неизвестный тип PDF, Word с таблицами, отчёты, презентации.

**Параметры (ничего передавать не надо, это дефолт):**
```
# все параметры включены:
# do_ocr=auto (easyocr включается если extractable text неполный)
# do_table_structure=true
# table_mode=accurate
```

**Профиль:** полный pipeline. Docling layout + OCR при необходимости +
TableFormer. Самая высокая точность в среднем.

**Замер:** 6.01s на 5-page PDF. 88-191s на 284-стр PDF (из прежних
бенчмарков — зависит от наличия VLM picture_description).

---

## Preset 3 — SCAN (сканы, фото, картинка-PDF)

**Когда:** отсканированные страницы без text layer, фотографии
документов, PDF созданные через print-to-PDF без OCR.

**Параметры:**
```
do_ocr=true
ocr_custom_config={"kind":"easyocr","lang":["ru","en"],"use_gpu":true}
do_table_structure=true
do_picture_description=true
picture_description_api={"url":"http://vllm:8000/v1/chat/completions","prompt":"Опиши картинку","concurrency":8}
```

**Профиль:** максимальное извлечение — OCR + layout + TableFormer +
VLM описание картинок. Самый медленный (в 2-5 раз медленнее balanced).

**Требуется env docling-serve:** `DOCLING_SERVE_ALLOW_CUSTOM_OCR_CONFIG=true`
(уже установлено в AGmind по умолчанию).

**Замер VLM:** +103 сек на 284-стр PDF (с concurrency=8).

---

## Как выбрать в Dify

### Вариант A — разные KB pipeline под разные preset'ы (рекомендуемый)

Создать 3 разных Knowledge Base с соответствующим HTTP Request node
параметрами. Пользователь выбирает куда загружать — "Текстовые доки",
"Смешанные", "Сканы".

### Вариант B — auto-routing через Code node (сложнее)

Code node с `yevanchen/pymupdf` плагином: извлечь text, посчитать
символы, сравнить с page_count. Если >500 char/page → FAST, иначе
SCAN. BALANCED как fallback.

Пример скелета:
```python
import fitz
doc = fitz.open(stream=pdf_bytes)
total_chars = sum(len(page.get_text()) for page in doc)
density = total_chars / len(doc)
if density > 500:
    return {"preset": "fast"}
elif density < 50:
    return {"preset": "scan"}
else:
    return {"preset": "balanced"}
```

---

## Benchmark tool

Замерить разницу на своём документе:

```bash
agmind docling bench your.pdf --preset fast
agmind docling bench your.pdf --preset balanced
agmind docling bench your.pdf --preset scan
```

(`--preset` добавлен в Phase 43; предыдущая версия bench'а работала
только с balanced дефолтом.)
