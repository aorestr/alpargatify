import datetime
import logging
import os
import sys
import threading
import time

import schedule

from navidrome_client import NavidromeClient
from telegram_bot import TelegramBot

# Configure Logging
log_level_str: str = os.environ.get("LOGGING", "INFO").upper()
log_level: int = getattr(logging, log_level_str, logging.INFO)

logging.basicConfig(
    level=log_level,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("bot")
logger.info(f"Logging configured at level: {log_level_str}")

# Global bot instance (shared between scheduler and polling threads)
bot_instance: TelegramBot = None

def daily_job() -> None:
    """
    Scheduled job that checks for new albums and anniversaries.
    Uses the global bot instance for sending notifications.
    """
    logger.info(f"Starting daily check at {datetime.datetime.now()}")
    
    client = NavidromeClient()
    
    # 1. New Albums (Last 24h)
    logger.info("Checking for new albums...")
    try:
        new_albums = client.get_new_albums(hours=24)
        if new_albums:
            logger.info(f"Found {len(new_albums)} new albums.")
            msg = bot_instance.format_album_list(new_albums, "🆕 Freshly Added Albums (Last 24h)")
            logger.debug(f"Message: {msg}")
            if msg:
                bot_instance.send_notification(msg)
        else:
            logger.info("No new albums found.")
    except Exception as e:
        logger.error(f"Error checking new albums: {e}", exc_info=True)

    # 2. Anniversaries (Same Day, Same Month)
    logger.info("Checking for anniversaries...")
    now = datetime.datetime.now()
    try:
        anniversaries = client.get_anniversary_albums(now.day, now.month)
        if anniversaries:
            logger.info(f"Found {len(anniversaries)} anniversaries.")
            msg = bot_instance.format_album_list(anniversaries, f"🎂 On this day ({now.strftime('%B %d')}) in music history")
            logger.debug(f"Message: {msg}")
            if msg:
                bot_instance.send_notification(msg)
        else:
            logger.info("No anniversaries found.")
    except Exception as e:
        logger.error(f"Error checking anniversaries: {e}", exc_info=True)

    logger.info("Daily check completed.")

# NOTE: The weekly top report is currently disabled as Navidrome API 
# doesn't support global stats for all users. Preserving code for future use.
# def weekly_job() -> None:
#     """
#     Scheduled job that shows the top 10 albums of the week.
#     """
#     logger.info(f"Starting Sunday weekly top report at {datetime.datetime.now()}")
#     
#     client = NavidromeClient()
#     try:
#         top_albums = client.get_top_albums_from_history(days=7, limit=10)
#         if top_albums:
#             msg = f"🏆 <b>Weekly Top 10 Albums</b>\n(Albums most played in the last 7 days)\n\n"
#             for i, alb in enumerate(top_albums, 1):
#                 msg += f"{i}. <b>{alb.get('name')}</b> - {alb.get('artist')} ({alb.get('playCount')} plays)\n"
#             
#             bot_instance.send_notification(msg, parse_mode="HTML")
#         else:
#             logger.info("No playback history found for the weekly report.")
#     except Exception as e:
#         logger.error(f"Error in Sunday report: {e}", exc_info=True)
#     
#     logger.info("Sunday check completed.")

def run_scheduler():
    """
    Run the scheduled job loop in a separate thread.
    """
    logger.info("Scheduler thread started")
    
    # Optional: Run once on startup if ENV var set
    if os.environ.get("RUN_ON_STARTUP", "false").lower() == "true":
        daily_job()
    
    # Schedule daily job
    schedule_time = os.environ.get("SCHEDULE_TIME", "08:00")
    logger.info(f"Scheduling daily job at {schedule_time}")
    schedule.every().day.at(schedule_time).do(daily_job)
    
    # Weekly Sunday report (Disabled: Navidrome API doesn't support global history)
    # logger.info("Scheduling weekly Sunday report at 12:00")
    # schedule.every().sunday.at("12:00").do(weekly_job)
    
    while True:
        schedule.run_pending()
        time.sleep(60)

def run_bot_polling():
    """
    Run the Telegram bot polling loop in a separate thread.
    Uses the global bot instance.
    """
    logger.info("Bot polling thread started")
    try:
        bot_instance.start_polling()
    except Exception as e:
        logger.error(f"Bot polling error: {e}", exc_info=True)

def main() -> None:
    """
    Main entrypoint for the application. Runs both scheduler and bot polling concurrently.
    """
    global bot_instance
    
    logger.info("Navidrome Telegram Bot Starting...")
    
    # Initialize single bot instance shared by both threads
    bot_instance = TelegramBot()
    
    # Create threads for scheduler and bot polling
    scheduler_thread = threading.Thread(target=run_scheduler, daemon=True, name="Scheduler")
    bot_thread = threading.Thread(target=run_bot_polling, daemon=True, name="BotPolling")
    
    # Start both threads
    scheduler_thread.start()
    bot_thread.start()
    
    logger.info("Both scheduler and bot polling threads started")
    
    # Keep main thread alive
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down gracefully...")

if __name__ == "__main__":
    main()
