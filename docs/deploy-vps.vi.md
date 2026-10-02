# Triển khai VieNeu-TTS lên VPS CPU

Luồng: GitHub Actions chạy test → build image Linux amd64 → smoke test → GHCR → SSH vào VPS → Docker Compose → chờ healthy. Không build image trên VPS. Image được gắn tag `cpu-<commit SHA>`. Workflow PyPI hiện có vẫn giữ nguyên.

## 1. Chuẩn bị VPS

Dùng VPS Linux **x86_64/amd64**, Docker Engine và Docker Compose v2 có `up --wait`; script còn dùng Bash và `flock` (gói util-linux). Tài khoản SSH phải chạy được `docker info` mà không cần sudo tương tác. VPS cần truy cập GHCR và Hugging Face để tải image/model. Bản CPU không cần CUDA/NVIDIA.

Khởi đầu nên cấp 4 vCPU, 8 GB RAM và khoảng 20 GB đĩa trống, sau đó đo mức dùng thực tế. Đây là mức dự trù, không phải benchmark bảo đảm. Chạy cả Web UI và API sẽ dùng hai tiến trình/model riêng.

Chạy bằng chính tài khoản SSH dùng để deploy:

```bash
mkdir -p ~/vieneu-tts
chmod 700 ~/vieneu-tts
# .env được CI tạo từ GitHub Actions Variable ENV_FILE khi deploy.
docker info
docker compose version
```

Cấu hình chính trong `.env`:

| Biến | Giá trị |
| --- | --- |
| COMPOSE_PROFILES | `web` (mặc định), `api`, hoặc `web,api` |
| BIND_ADDRESS | `127.0.0.1` khi dùng reverse proxy hoặc SSH tunnel |
| PORT / API_PORT | `7860` / `8000` |
| VIENEU_WEB_AUTH | `admin:mat-khau-rieng` |
| VIENEU_API_KEY | Chuỗi bí mật dài cho Bearer authentication |
| HF_TOKEN | Để trống nếu model công khai |
| VIENEU_PRECISION | `fp32`; chỉ chọn `int8` sau khi đánh giá chất lượng và CPU |
| VIENEU_MAX_STREAMS | `1` cho VPS CPU |
| VIENEU_QUEUE | `4` |

Đặt mật khẩu/key trước khi mở truy cập bên ngoài. Với giá trị chứa ký tự `$`, bọc giá trị bằng nháy đơn theo cú pháp dotenv. CI tạo `.env` từ Variable `ENV_FILE` rồi chép vào thư mục release trên VPS với quyền 600. Sau khi healthy, `~/vieneu-tts/.env` trỏ tới cấu hình của release thành công. `IMAGE_NAME` và `IMAGE_TAG` được script truyền từ bản build khi deploy.

GHCR package có thể là private. Đăng nhập **một lần trên VPS bằng tài khoản deploy**, dùng PAT classic có quyền `read:packages` và quyền đọc package:

```bash
docker login ghcr.io -u TEN_GITHUB
# Dán PAT tại lời nhắc password.
```

Không cần đăng nhập nếu đã đặt package public. Token push trong CI dùng `GITHUB_TOKEN`, không dùng PAT của VPS.

## 2. Cấu hình GitHub Actions

File `.env` ở gốc dự án đã được tạo từ `.env.example` để bạn chỉnh giá trị. File này bị loại khỏi Git và Docker build context.

Trong repository → Settings → Secrets and variables → Actions → **Variables**, tạo **ENV_FILE**. Dán toàn bộ nội dung file `.env` vào giá trị của Variable này, giữ nguyên nhiều dòng (không đổi xuống dòng thành ký tự `\n`). Có thể đặt ENV_FILE trong environment `production` để ghi đè giá trị repository. Workflow dừng nếu Variable rỗng và không in nội dung ra log. Variables không được GitHub che như Secrets; giới hạn quyền truy cập cấu hình có mật khẩu/token.

Mỗi lần deploy, workflow tạo `.env` trong thư mục checkout, kiểm tra Compose, rồi chép lên VPS. File tạm trên runner được xóa khi job kết thúc. Không cần tự tạo `.env` trên VPS.

Trong tab **Secrets**, thêm secrets SSH:

| Secret | Nội dung |
| --- | --- |
| SSH_HOST | IP hoặc hostname VPS (IPv4/DNS) |
| SSH_USER | User SSH đã chuẩn bị |
| SSH_PORT | Port SSH, mặc định 22 |
| SSH_KEY | Nội dung private key SSH của tài khoản deploy |
| VPS_KNOWN_HOSTS | Dòng host key SSH đã xác minh của VPS |

Thêm public key tương ứng vào `~/.ssh/authorized_keys` trên VPS. Lấy host key bằng `ssh-keyscan -p 22 HOST` và đối chiếu fingerprint qua console của nhà cung cấp VPS trước khi lưu. Port khác 22 dùng dạng `[HOST]:PORT`. Workflow bật kiểm tra host key, không tự tin tưởng kết quả quét mạng.

Tạo GitHub Environment tên `production` (có thể giới hạn nhánh develop). Secrets có thể để ở repository hoặc environment production. Tạo **repository variable** `VPS_DEPLOY_ENABLED=true` sau khi VPS và secrets đã sẵn sàng; nếu chưa bật, CI vẫn build/publish nhưng bỏ qua SSH deploy.

Push nhánh `develop` hoặc chạy workflow **CI** bằng `workflow_dispatch` trên develop. PR chỉ chạy test/build/smoke test, không publish/deploy. Repository cần cho phép GitHub Actions ghi package GHCR.

## 3. Kiểm tra sau deploy

```bash
cd ~/vieneu-tts
readarray -t release < last-success
export IMAGE_NAME="${release[1]}" IMAGE_TAG="${release[2]}"
docker compose -p vieneu-tts --env-file .env -f compose.yml ps
docker compose -p vieneu-tts --env-file .env -f compose.yml logs --tail 100
curl -f http://127.0.0.1:7860/
# Khi bật profile api:
curl -f http://127.0.0.1:8000/health
```

Web UI healthy nghĩa là HTTP server sẵn sàng; model được chọn/tải trong giao diện khi sử dụng. API healthcheck khởi tạo model nên lần chạy đầu có thể lâu. Deploy chờ tối đa 900 giây; nếu mạng tải model quá chậm, xem log rồi chạy lại workflow. Cache Hugging Face lưu trong named volume `vieneu-tts_huggingface_cache`, giữ lại qua các lần cập nhật.

Có thể kiểm tra Web UI qua SSH tunnel từ máy cá nhân:

```bash
ssh -L 7860:127.0.0.1:7860 USER@HOST
```

Mở `http://localhost:7860`. Để dùng domain công khai, cấu hình Nginx/Caddy trên VPS chuyển tới `127.0.0.1:7860` hoặc `127.0.0.1:8000`, bật HTTPS, WebSocket cho Gradio, tắt proxy buffering và tăng read timeout cho streaming API. Chưa có domain trong yêu cầu nên repo không tự cài/chạy reverse proxy.

Compose giới hạn log, chạy user không phải root, không mount source và không tạo tunnel công khai. `restart: unless-stopped` khởi động lại khi tiến trình thoát/VPS reboot; Docker không tự restart chỉ vì trạng thái unhealthy. CI phát hiện unhealthy trong lúc deploy.

## 4. Rollback

Script lưu mỗi compose trong `~/vieneu-tts/releases/<sha>-<run>-<attempt>/`. Sau khi healthy mới cập nhật `last-success` và symlink `compose.yml`. Nếu bản mới không healthy, script thử chạy lại compose và image của lần thành công trước; workflow vẫn báo lỗi để người vận hành kiểm tra. Lần đầu chưa có bản cũ nên không thể rollback. Pull image thất bại không thay đổi container đang chạy.

Rollback dùng `.env` lưu cùng release cũ; với release tạo trước khi hỗ trợ ENV_FILE, dùng `.env` ở thư mục gốc để tương thích. Không rollback dữ liệu trong volume. Cấu hình trong các thư mục release vẫn còn trên VPS để phục vụ rollback. Đây là triển khai recreate một VPS, có thể gián đoạn ngắn, không phải zero downtime. Không xóa image cũ cho đến khi hết nhu cầu rollback; không chạy `down -v` nếu muốn giữ model cache.

## 5. Build và chạy thủ công từ repo

```bash
cp .env.example .env
# Chỉnh auth/profile trước khi chạy.
docker compose --env-file .env -f docker/docker-compose.build.yml build cpu
docker compose --env-file .env -f docker/docker-compose.prod.yml up -d --wait --wait-timeout 900
```

Production compose mới dành cho CPU, thay các service GPU production cũ. Cấu hình phát triển/GPU vẫn ở `docker/docker-compose.yml`; đường dẫn bind mount và env_file của file này đã được sửa theo thư mục docker.

Tài liệu tham khảo: [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/), [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).
