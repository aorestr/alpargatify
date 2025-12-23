import logging
from typing import List, Dict, Optional, Any

import requests

from secrets_loader import get_secret

logger = logging.getLogger(__name__)

class TelegramSender:
    """
    Handles formatting and sending messages to Telegram via the Bot API.
    """
    def __init__(self):
        """
        Initialize the Telegram sender with credentials.
        """
        self.token: Optional[str] = get_secret("telegram_bot_token")
        self.chat_id: Optional[str] = get_secret("telegram_chat_id")
        self.base_url: str = f"https://api.telegram.org/bot{self.token}"

    def send_message(self, text: str, parse_mode: str = "HTML") -> None:
        """
        Send a text message to the configured Chat ID.
        Automatically splits messages that exceed Telegram's 4096 character limit.
        
        :param text: The message content.
        :param parse_mode: HTML or MarkdownV2.
        """
        if not self.token or not self.chat_id:
            logger.error("Telegram token or Chat ID missing.")
            return

        # Telegram's message limit is 4096 characters
        max_length = 4096
        messages = self._split_message(text, max_length)
        
        for msg in messages:
            url = f"{self.base_url}/sendMessage"
            payload = {
                "chat_id": self.chat_id,
                "text": msg,
                "parse_mode": parse_mode
            }
            
            try:
                r = requests.post(url, json=payload)
                r.raise_for_status()
                logger.debug("Message sent successfully.")
            except requests.exceptions.RequestException as e:
                logger.error(f"Failed to send Telegram message: {e}")

    @staticmethod
    def _split_message(text: str, max_length: int) -> List[str]:
        """
        Split a message into chunks that fit within Telegram's character limit.
        Tries to split at album boundaries (double newlines) to keep albums together.
        
        :param text: The full message text.
        :param max_length: Maximum characters per message.
        :return: List of message chunks.
        """
        if len(text) <= max_length:
            return [text]
        
        chunks = []
        # Split by album entries (double newline)
        albums = text.split('\n\n')
        
        current_chunk = ""
        for album in albums:
            # Check if adding this album would exceed the limit
            test_chunk = current_chunk + album + '\n\n' if current_chunk else album + '\n\n'
            
            if len(test_chunk) > max_length:
                # If current chunk has content, save it
                if current_chunk:
                    chunks.append(current_chunk.rstrip())
                    current_chunk = album + '\n\n'
                else:
                    # Single album is too long, force split it
                    chunks.append(album[:max_length])
                    logger.warning(f"Album entry exceeded max length, truncated.")
            else:
                current_chunk = test_chunk
        
        # Add the last chunk if it has content
        if current_chunk:
            chunks.append(current_chunk.rstrip())
        
        logger.info(f"Split message into {len(chunks)} parts.")
        return chunks

    @staticmethod
    def format_album_list(albums: List[Dict[str, Any]], intro_text: str) -> Optional[str]:
        """
        Format a list of album dictionaries into a readable HTML message.

        :param albums: List of album objects from Navidrome API.
        :param intro_text: Header text for the message.
        :return: Formatted string or None if list is empty.
        """
        if not albums:
            return None

        message = f"<b>{intro_text}</b>\n\n"

        for album in albums:
            title = album.get("name", "Unknown Album")
            artist = album.get("artist", "Unknown Artist")

            # Year or Date
            date_display = str(album.get("year", ""))
            # Upgrade to ReleaseDate if available
            if "releaseDate" in album:
                rd = album["releaseDate"]
                if isinstance(rd, dict):
                    # Format dict {'year': 2021, 'month': 2, 'day': 23} to 2021-02-23
                    y = rd.get('year', '????')
                    m = rd.get('month', 1)
                    d = rd.get('day', 1)
                    date_display = f"{y}-{m:02d}-{d:02d}"
                elif len(str(rd)) >= 4:
                     date_display = str(rd)

            # Tags (Genres)
            genre_str = ""
            if "genres" in album:
                g_list = album["genres"]
                if isinstance(g_list, list):
                    names = [g.get("name") for g in g_list if isinstance(g, dict) and "name" in g]
                    if names:
                        genre_str = ", ".join(names)

            # Fallback to simple 'genre' if empty
            if not genre_str:
                genre_str = album.get("genre", "")

            message += f"💿 <b>{title}</b>\n"
            message += f"👤 {artist}\n"
            message += f"📅 {date_display}\n"
            if genre_str:
                message += f"🏷 {genre_str}\n"
            message += "\n"

        return message
