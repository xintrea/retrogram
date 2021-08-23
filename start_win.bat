
echo "Start music"
start "play-klaudia-sound" /MIN .\sound\mpg123.exe .\sound\klaudia_blue_shawl.mp3

echo "Start Bonzomatic"
.\bonzomatic

echo "Stop music"
taskkill /F /FI "WINDOWTITLE eq play-klaudia-sound"
