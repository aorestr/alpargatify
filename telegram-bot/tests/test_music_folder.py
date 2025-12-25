import logging
import os
import sys

# Add the parent directory to sys.path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from navidrome_client import NavidromeClient

# Configure basic logging to stdout
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("folder_test")

def test():
    logger.info("--- Starting Navidrome Music Folder Investigation ---")
    
    client = NavidromeClient()
    
    # 1. Check configured folder name
    logger.info(f"Configured Music Folder Name: '{client._music_folder_name}'")
    
    # 2. Get all music folders from Navidrome
    try:
        response = client._request('getMusicFolders')
        if not response:
            logger.error("FAILURE: Failed to connect to Navidrome API or empty response.")
            return

        folders = response.get('musicFolders', {}).get('musicFolder', [])
        logger.info(f"Successfully connected! Found {len(folders)} music folders in Navidrome:")
        
        found_match = False
        for f in folders:
            name = f.get('name')
            fid = f.get('id')
            match = "[MATCH!]" if name == client._music_folder_name else ""
            logger.info(f" - ID: {fid}, Name: '{name}' {match}")
            if name == client._music_folder_name:
                found_match = True
        
        if not found_match:
            logger.warning(f"WARNING: Configured folder name '{client._music_folder_name}' NOT FOUND in the list above.")
            logger.info("TIP: Check your docker-compose.yml NAVIDROME_MUSIC_FOLDER value.")
            
        # 3. Check client detection
        detected_id = client.get_music_folder_id()
        if detected_id:
            logger.info(f"SUCCESS: Client detected folder ID: {detected_id}")
        else:
            logger.error("FAILURE: client.get_music_folder_id() returned None.")

        # 4. Search Verification (Testing if filtering works)
        logger.info("4. Testing Search Filtering (Searching for 'a')...")
        results = client.search_albums("a", limit=10)
        logger.info(f"Search returned {len(results)} albums.")
        
        # 5. Folder Content Verification
        logger.info(f"5. Listing some albums from folder ID {detected_id}...")
        params = {'type': 'alphabeticalByArtist', 'size': 5, 'musicFolderId': detected_id}
        response = client._request('getAlbumList', params)
        if response and 'albumList' in response:
            albums = response['albumList'].get('album', [])
            logger.info(f"Retrieved {len(albums)} albums from folder:")
            for a in albums:
                logger.info(f" - {a.get('artist')} - {a.get('name')}")
        else:
            logger.warning("Could not retrieve album list for this folder.")
        
    except Exception as e:
        logger.error(f"FAILURE: An error occurred during testing: {e}", exc_info=True)

    logger.info("--- Investigation Completed ---")

if __name__ == "__main__":
    test()
