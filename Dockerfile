# FitMe in the cloud (Bult.ai): builds the website, then runs the backend that serves it at /app/.
# Keep the persistent disk mounted at /data: accounts' pictures live there.

FROM debian:bookworm-slim AS site
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
 && git clone --depth 1 --branch 3.47.9 https://github.com/flutter/flutter.git /flutter
ENV PATH="/flutter/bin:${PATH}"
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
COPY lib ./lib
COPY web ./web
RUN flutter pub get && flutter build web --release --base-href /app/ --no-wasm-dry-run

FROM python:3.11-slim
WORKDIR /srv
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/app ./app
COPY --from=site /src/build/web ./app/web_app

ENV FITME_STORAGE_DIR=/data \
    PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
