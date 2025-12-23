# Navidrome Telegram Bot

A lightweight, optimized Telegram bot that integrates with your Navidrome (Subsonic) music server to deliver daily notifications about:
- **🆕 New Albums**: Albums added to your library in the last 24 hours.
- **🎂 Anniversaries**: Albums released on this day in history.

## Key Features

- **Incremental Synchronization**: Efficiently caches your library and only fetches detailed metadata for new albums, drastically reducing API load and execution time.
- **Rich Notifications**: Sends beautifully formatted messages with album artist, year, and genre tags.
- **Smart Date Parsing**: correctly handles various date formats from Navidrome/Subsonic API to ensure accurate anniversary detection.
- **Dockerized**: Easy to deploy with Docker Compose and Docker Secrets for security.

## Setup & Deployment

### 1. Secrets Configuration
Create a `secrets/` directory in the project root and add the following files (no extensions):

| File Name | Content |
|-----------|---------|
| `navidrome_url` | Your Navidrome server URL (e.g., `https://music.example.com`) |
| `navidrome_user` | Your Navidrome username |
| `navidrome_password` | Your Navidrome password (or hex-encoded password + salt if using legacy auth, but plain password works with modern clients) |
| `telegram_bot_token` | The token obtained from @BotFather |
| `telegram_chat_id` | The Chat ID where messages should be sent |

### 2. Environment Variables
You can configure the following in `docker-compose.yml`:

- `LOGGING`: Logging level (e.g., `INFO`, `DEBUG`). Default: `INFO`.
- `SCHEDULE_TIME`: Time to run the daily check (24h format, HH:MM). Default: `08:00`.
- `RUN_ON_STARTUP`: Set to `true` to run the check immediately when the container starts (useful for testing).

### 3. Run with Docker Compose
```bash
docker-compose up -d
```
The bot will start and schedule the daily job. The `data/` directory is mounted as a volume to persist the album cache, ensuring subsequent runs are fast.

## Development

### Project Structure
- `src/`: Source code (`main.py`, `navidrome_client.py`, `telegram_sender.py`).
- `tests/`: Test scripts (`test_navidrome.py`).
- `data/`: Local cache storage (in container).

### Running Tests
To verify connectivity and logic without sending real messages to the schedule:

```bash
# Run the test script inside the container
docker-compose run --rm telegram-bot python tests/test_navidrome.py
```
This script acts as a "speed test" and "functional test", verifying the incremental sync performance and the anniversary detection logic. 
