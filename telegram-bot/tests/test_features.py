import os
import sys
import unittest
from unittest.mock import patch

# Add project root and src to path
root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.append(root_dir)
sys.path.append(os.path.join(root_dir, 'src'))

from navidrome_client import NavidromeClient

class TestNavidromeEnhancements(unittest.TestCase):
    def setUp(self):
        self.client = NavidromeClient()
        self.client.base_url = "http://localhost"
        self.client.username = "test"
        self.client.password = "test"

    @patch('navidrome_client.NavidromeClient._request')
    def test_get_music_folder_id(self, mock_request):
        # Mock response for getMusicFolders
        mock_request.return_value = {
            'musicFolders': {
                'musicFolder': [
                    {'id': 1, 'name': 'Other'},
                    {'id': 2, 'name': 'Music Library'}
                ]
            }
        }
        
        folder_id = self.client.get_music_folder_id()
        self.assertEqual(folder_id, '2')
        self.assertEqual(self.client._music_folder_id, '2')
        mock_request.assert_called_with('getMusicFolders')

    @patch('navidrome_client.NavidromeClient._request')
    def test_check_scan_status(self, mock_request):
        mock_request.return_value = {
            'scanStatus': {'scanning': False, 'count': 1000, 'lastScan': '2024-12-24T12:00:00Z'}
        }
        status = self.client.check_scan_status()
        self.assertEqual(status['count'], 1000)

    @patch('navidrome_client.NavidromeClient._request')
    def test_get_now_playing(self, mock_request):
        mock_request.return_value = {
            'nowPlaying': {
                'entry': [{'username': 'user1', 'title': 'song1', 'artist': 'artist1'}]
            }
        }
        playing = self.client.get_now_playing()
        self.assertEqual(len(playing), 1)
        self.assertEqual(playing[0]['username'], 'user1')

    @patch('navidrome_client.NavidromeClient._request')
    def test_get_top_albums_from_history(self, mock_request):
        import time
        now_ms = int(time.time() * 1000)
        mock_request.return_value = {
            'history': {
                'item': [
                    {'played': now_ms, 'albumId': 'a1', 'album': 'Album 1', 'artist': 'Artist 1'},
                    {'played': now_ms, 'albumId': 'a1', 'album': 'Album 1', 'artist': 'Artist 1'},
                    {'played': now_ms - (8 * 24 * 3600 * 1000), 'albumId': 'a2', 'album': 'Old', 'artist': 'Artist'}
                ]
            }
        }
        top = self.client.get_top_albums_from_history(days=7)
        self.assertEqual(len(top), 1)
        self.assertEqual(top[0]['id'], 'a1')
        self.assertEqual(top[0]['playCount'], 2)

    @patch('navidrome_client.NavidromeClient._request')
    @patch('navidrome_client.NavidromeClient.get_music_folder_id')
    def test_get_albums_by_genre(self, mock_folder, mock_request):
        mock_folder.return_value = '2'
        mock_request.return_value = {
            'albumList2': {
                'album': [{'id': 'alb1', 'name': 'Rock Album'}]
            }
        }
        albums = self.client.get_albums_by_genre('Rock', limit=1)
        self.assertEqual(len(albums), 1)
        # Check if musicFolderId was passed in params (second positional arg)
        args, kwargs = mock_request.call_args
        actual_params = args[1]
        self.assertEqual(actual_params['musicFolderId'], '2')
        self.assertEqual(actual_params['genre'], 'Rock')

if __name__ == '__main__':
    unittest.main()
