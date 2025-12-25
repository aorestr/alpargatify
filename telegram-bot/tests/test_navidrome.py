import logging
import os
import sys

# Add the parent directory (or /app in Docker) to sys.path to import modules
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from navidrome_client import NavidromeClient
from telegram_bot import TelegramBot


SPEED_TEST: bool = False

# Configure basic logging to stdout
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("tester")

def test():
    logger.info("--- Starting Navidrome Connection Test ---")
    
    client = NavidromeClient()
    bot = TelegramBot()
    
    # Check 1: New Albums
    logger.info("1. Testing get_new_albums(hours=2400) (Checking last 100 days to ensure results)...")
    try:
        # Using a large window to make sure we find something if the server is old
        # force=False so we use/build cache efficiently
        new_albums = client.get_new_albums(hours=2400, force=False) 
        if new_albums:
            logger.info(f"SUCCESS: Found {len(new_albums)} albums.")
            
            # Visual check relative to Bot
            msg = bot.format_album_list(new_albums[:3], "Test Message Preview")
            logger.info(f"--- PREVIEW MESSAGE ---\n{msg}\n-----------------------")
            
        else:
            logger.info("SUCCESS: Connection worked, but no recent albums found (which might be expected).")
    except Exception as e:
        logger.error(f"FAILURE: get_new_albums failed: {e}", exc_info=True)

    # Check 2: Anniversaries
    # Change the day to one that has an album anniversary in your library
    check_day = 22
    check_month = 9
    logger.info(f"2. Testing get_anniversary_albums (Checking for {check_month}/{check_day})...")
    
    try:
        # force=False so we reuse the cache build in step 1
        anniversaries = client.get_anniversary_albums(check_day, check_month, force=False)
        if anniversaries:
            logger.info(f"SUCCESS: Found {len(anniversaries)} anniversaries.")
            
            # Check visual format for genres
            msg = bot.format_album_list(anniversaries[:3], "Anniversary Preview")
            logger.info(f"--- PREVIEW MESSAGE ---\n{msg}\n-----------------------")
            
        else:
            logger.info("FAILURE? Connection worked, but no anniversaries found for Sept 22.")
    except Exception as e:
        logger.error(f"FAILURE: get_anniversary_albums failed: {e}", exc_info=True)

    # Speed test (must be activated)
    if SPEED_TEST:

        # Speed Test
        import time
        
        logger.info("--- Speed Test: Force Sync (Full Enrichment) ---")
        start = time.time()
        # force=True means it will re-fetch details for ALL albums
        client.sync_library(force=True)
        duration_force = time.time() - start
        logger.info(f"Force Sync took {duration_force:.2f} seconds.")
        
        logger.info("--- Speed Test: Incremental Sync (Should be fast) ---")
        start = time.time()
        # force=False should trigger incremental logic (only fetching new IDs, which should be 0)
        client.sync_library(force=False)
        duration_inc = time.time() - start
        logger.info(f"Incremental Sync took {duration_inc:.2f} seconds.")
        
        if duration_inc < duration_force / 2:
            logger.info("SUCCESS: Incremental sync is significantly faster.")
        else:
            logger.warning(f"WARNING: Incremental sync ({duration_inc:.2f}s) was not significantly faster than Force ({duration_force:.2f}s). Cache might be ignored or overhead is high.")
            
        logger.info("--- Test Completed ---")

if __name__ == "__main__":
    test()
