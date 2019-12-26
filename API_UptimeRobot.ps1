$Api_key = $env:APIKEY_UPTROBOT
$uri = "https://api.uptimerobot.com/v2/"
$params = @{'api_key' = $Api_key; 'format'= 'json'; 'logs' =1}

$Method = "getMonitors"

$Url_Monitored = Invoke-RestMethod -Uri ($uri + $Method) -Method Post -Body $params