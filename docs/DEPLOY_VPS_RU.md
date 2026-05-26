# Выгрузка Street Family на VPS: Git + Docker + Nginx

Эта инструкция рассчитана на первый деплой. Фронтенд работает в Docker-контейнере, а Supabase остается внешним сервисом. На VPS не нужно поднимать базу данных или Supabase Edge Functions.

## Как это будет устроено

```text
Интернет -> Nginx на VPS (80/443) -> 127.0.0.1:18087 -> контейнер Street Family
                                             ^
                                  порт можно выбрать другой
```

Контейнер намеренно опубликован только на `127.0.0.1`. Его не видно снаружи напрямую, а уже установленный Nginx может обслуживать этот и другие проекты по разным доменам.

## Что понадобится

- VPS с Ubuntu 22.04 или 24.04 и доступом по SSH.
- Домен или поддомен, например `street.example.com`, направленный A-записью на IP VPS.
- Репозиторий GitHub/GitLab с этим проектом.
- Заполненный корневой `.env` по инструкции [`SUPABASE_SETUP_RU.md`](SUPABASE_SETUP_RU.md).

Проект использует один файл `.env`. `VITE_SUPABASE_PUBLISHABLE_KEY` попадает в браузерную сборку по назначению, а Telegram secrets хранятся в том же `.env`, но Docker/Vite не публикуют переменные без префикса `VITE_`. Никогда не добавляйте `.env` или `service_role` key в Git.

## 1. Отправить проект в Git

Для проекта уже подготовлена локальная ветка Git `main`. В PowerShell, находясь в папке `STREET FAMILY`, выполните:

```powershell
git add .
git status
git commit -m "Prepare Street Family for VPS deployment"
git branch -M main
git remote add origin https://github.com/YOUR-NAME/street-family.git
git push -u origin main
```

Перед `git commit` посмотрите вывод `git status`: файла `.env` и секретов там быть не должно. На GitHub сначала создайте пустой репозиторий без README, чтобы первый push прошел без конфликта.

## 2. Зайти на VPS и проверить, что уже работает

Подключитесь с компьютера:

```bash
ssh your_user@YOUR_VPS_IP
```

Посмотрите текущие контейнеры, сайты Nginx и занятые порты:

```bash
sudo docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}" 2>/dev/null || true
sudo nginx -T 2>/dev/null | grep -E "server_name|proxy_pass|listen" || true
sudo ss -tulpn
```

Порты `80` и `443` могут быть заняты Nginx, это нормально. Для Street Family нужен отдельный свободный внутренний порт, например `18087`. Проверка конкретного варианта:

```bash
sudo ss -tulpn | grep ':18087 ' || echo "Порт 18087 свободен"
```

Если вместо строки `Порт 18087 свободен` показался процесс, выберите другой номер, например `18088`, и дальше везде используйте его.

## 3. Установить Git, Nginx и Docker

Если `git --version`, `nginx -v` и `docker compose version` уже работают, не переустанавливайте их и переходите к следующему разделу.

Git и Nginx:

```bash
sudo apt update
sudo apt install -y git nginx ca-certificates curl
sudo systemctl enable --now nginx
```

Docker Engine и Compose Plugin через официальный репозиторий Docker:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
sudo docker compose version
```

Использование `sudo docker` в инструкции сделано намеренно: добавление пользователя в группу `docker` фактически дает ему привилегии администратора сервера.

## 4. Скачать проект на VPS

Рекомендуемая папка для сайтов:

```bash
sudo mkdir -p /opt/apps
sudo chown "$USER":"$USER" /opt/apps
cd /opt/apps
git clone https://github.com/YOUR-NAME/street-family.git
cd street-family
```

Если репозиторий приватный, настройте SSH-ключ для GitHub/GitLab и клонируйте SSH-адресом (`git@github.com:YOUR-NAME/street-family.git`). Не вставляйте пароль или access token в файлы проекта.

## 5. Создать единственный `.env` и выбрать свободный порт

Создайте на VPS тот же единый файл, который не попадет в Git:

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

Впишите значения из локального `.env`. Минимально для frontend/Docker нужны:

```dotenv
VITE_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
STREET_FAMILY_PORT=18087
```

Так как используется один файл, оставьте в нём также `TELEGRAM_*` и `KYC_PURGE_SECRET`. Они нужны Supabase Functions при команде `secrets set`, но не передаются frontend-контейнеру.

Сохранение в `nano`: `Ctrl+O`, `Enter`, затем выход `Ctrl+X`.

Запустите контейнер:

```bash
sudo docker compose --env-file .env -p street-family up -d --build
sudo docker compose --env-file .env -p street-family ps
curl http://127.0.0.1:18087/healthz
```

Ожидаемый ответ последней команды: `ok`. Если выбрали другой порт, подставьте его вместо `18087`.

## 6. Подключить домен через уже установленный Nginx

Не редактируйте общий `/etc/nginx/nginx.conf` и не удаляйте конфигурации других сайтов. Создайте новый отдельный файл:

```bash
sudo cp deploy/nginx-vps.conf.example /etc/nginx/sites-available/street-family.conf
sudo nano /etc/nginx/sites-available/street-family.conf
```

В этом файле замените:

- `street-family.example.com` на ваш настоящий домен;
- `18087` на выбранный свободный порт.

Включите только новый сайт и проверьте конфигурацию:

```bash
sudo ln -s /etc/nginx/sites-available/street-family.conf /etc/nginx/sites-enabled/street-family.conf
sudo nginx -t
sudo systemctl reload nginx
```

Откройте в браузере `http://ВАШ-ДОМЕН`. Если показывается другой проект, проверьте DNS, значение `server_name` и не использован ли тот же домен в другом файле `/etc/nginx/sites-enabled/`.

## 7. Включить HTTPS

DNS домена уже должен указывать на VPS, а сайт должен открываться по HTTP. Затем:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d street.example.com
sudo certbot renew --dry-run
```

Замените `street.example.com` своим доменом. Certbot добавит HTTPS в конфигурацию именно этого Nginx-сайта.

После появления HTTPS-адреса укажите его в `.env` как `TELEGRAM_MINI_APP_URL`, а загрузку миграций, Supabase Functions, Telegram secrets и webhook выполните пошагово по [`SUPABASE_SETUP_RU.md`](SUPABASE_SETUP_RU.md).

## 8. Обновлять сайт после изменений

После нового `git push` с компьютера зайдите на VPS:

```bash
cd /opt/apps/street-family
git pull origin main
sudo docker compose --env-file .env -p street-family up -d --build
sudo docker compose --env-file .env -p street-family ps
```

Сборка содержит публичные значения Supabase из `.env`. Если поменяли `VITE_SUPABASE_*`, обязательно пересоберите контейнер командой выше.

## Полезная диагностика

Статус и лог контейнера:

```bash
cd /opt/apps/street-family
sudo docker compose --env-file .env -p street-family ps
sudo docker compose --env-file .env -p street-family logs --tail=100 web
```

Проверка Nginx:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
sudo tail -n 80 /var/log/nginx/error.log
```

Остановить только Street Family, не затрагивая другие контейнеры:

```bash
cd /opt/apps/street-family
sudo docker compose --env-file .env -p street-family down
```

## Файлы деплоя в проекте

- `Dockerfile` собирает Vite-фронтенд и раздает готовые файлы через Nginx внутри контейнера.
- `compose.yml` публикует приложение лишь на локальный адрес VPS и выбранный порт.
- `.env.example` является единственным шаблоном настроек, реальный `.env` остается только локально и на VPS.
- `deploy/container-nginx.conf` поддерживает маршруты SPA и кеширование ассетов внутри контейнера.
- `deploy/nginx-vps.conf.example` является отдельным сайтом для системного Nginx.

## Официальные справки

- Docker Engine для Ubuntu: <https://docs.docker.com/engine/install/ubuntu/>
- Docker Compose plugin: <https://docs.docker.com/compose/install/linux/>
- Nginx reverse proxy: <https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/>
- Certbot: <https://certbot.eff.org/>
